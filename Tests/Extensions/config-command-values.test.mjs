// The pinned Shepherd SDK rejects command values even when upstream Pi still supports them.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const patch = JSON.parse(fs.readFileSync(path.join(root, "scripts/pi-engine-patches/skills.json")));
const change = patch.files.find((entry) => entry.path === "dist/core/resolve-config-value.js");
const hash = (text) => createHash("sha256").update(text).digest("hex");
function patchedSource(change) {
  let source = fs.readFileSync(path.join(process.env.PI_PACKAGE_DIR, change.path), "utf8");
  if (hash(source) !== change.after) {
    assert.equal(hash(source), change.before, "patch must match the pinned upstream SDK");
    for (const edit of change.edits) {
      assert.equal(source.split(edit.old).length, 2, "each patch anchor must be unique");
      source = source.replace(edit.old, edit.new);
    }
  }
  assert.equal(hash(source), change.after);
  return source;
}
const source = patchedSource(change);
const sdk = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);

test("the SDK bundle also removes command resolver implementations and calls", () => {
  const bundle = patchedSource(patch.files.find((entry) => entry.path.startsWith("dist/bundle/chunks/") && entry.edits?.some((edit) => edit.new.includes("Command configuration values"))));
  assert.doesNotMatch(bundle, /executeCommand|executeWithConfiguredShell|executeWithDefaultShell|commandResultCache/);
  assert.match(bundle, /Command configuration values are not supported/);
});

test("configuration values never execute commands, including cached and uncached auth and headers", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-config-values-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const marker = path.join(dir, "executed");
  const command = `!touch '${marker}'; printf token`;
  assert.equal(sdk.resolveConfigValue(command), undefined);
  assert.equal(sdk.resolveConfigValueUncached(command), undefined);
  assert.throws(() => sdk.resolveConfigValueOrThrow(command, "MCP env"), /Command configuration values are not supported/);
  assert.equal(sdk.resolveHeaders({ Authorization: command }), undefined);
  assert.throws(() => sdk.resolveHeadersOrThrow({ Authorization: command }, "MCP"), /Command configuration values are not supported/);
  sdk.clearConfigValueCache();
  assert.equal(fs.existsSync(marker), false);
  assert.equal(sdk.resolveConfigValue("Bearer ${TOKEN}", { TOKEN: "scratch-token" }), "Bearer scratch-token");
  assert.equal(sdk.resolveConfigValue("plain value"), "plain value");
});
