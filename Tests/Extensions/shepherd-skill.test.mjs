// The built-in skill on how to work in Shepherd (Extensions/shepherd-skill/, installed by
// PanesExtension.installedSkillDirectory with shepherd.md as SKILL.md) and the panes extension handing it to pi.
import assert from "node:assert/strict";
import { test } from "node:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const require = createRequire(path.join(pkg, "package.json"));
const { createJiti } = require("jiti");
const jiti = createJiti(import.meta.url, { alias: {
  "@earendil-works/pi-coding-agent": path.join(pkg, "dist/index.js"),
  typebox: path.join(pkg, "node_modules/typebox/build/index.mjs"),
} });
const { default: install } = await jiti.import(path.join(root, "Extensions/shepherd-panes.ts"));
const { loadSkillsFromDir } = await import(path.join(pkg, "dist/core/skills.js"));

const source = path.join(root, "Extensions/shepherd-skill");

/** The skill as the app installs it: shepherd.md becomes SKILL.md, the rest keep their names. */
function installed() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-skill-"));
  for (const name of fs.readdirSync(source)) {
    fs.copyFileSync(path.join(source, name), path.join(dir, name === "shepherd.md" ? "SKILL.md" : name));
  }
  return dir;
}

function discover(skillDirectory) {
  Object.assign(process.env, { SHEPHERD_SOCKET: "/tmp/no-such.sock", SHEPHERD_AGENT_ID: "agent-1", SHEPHERD_SKILL_DIR: skillDirectory });
  const handlers = {};
  try {
    install({ registerTool() {}, on: (event, cb) => (handlers[event] ??= []).push(cb), sendUserMessage() {}, sendMessage() {} });
  } finally {
    delete process.env.SHEPHERD_SKILL_DIR;
  }
  return handlers.resources_discover?.[0]?.({ type: "resources_discover", cwd: "/work", reason: "startup" });
}

test("pi loads the installed skill without complaint, and every area file it names is there and named", () => {
  const dir = installed();
  const { skills, diagnostics } = loadSkillsFromDir({ dir, source: "path" });
  assert.deepEqual(diagnostics, []);
  assert.deepEqual(skills.map((skill) => skill.name), ["shepherd"]);
  const entry = fs.readFileSync(path.join(dir, "SKILL.md"), "utf8");
  const linked = [...entry.matchAll(/\]\(([^)#]+\.md)\)/g)].map((match) => match[1]).sort();
  const areas = fs.readdirSync(dir).filter((name) => name !== "SKILL.md").sort();
  assert.deepEqual(linked, areas, "the entry links every area file, and only files that exist");
});

test("a thread's panes extension hands pi the skill folder, and nothing when it is missing", async () => {
  const dir = installed();
  assert.deepEqual(await discover(dir), { skillPaths: [dir] });
  assert.equal(await discover(path.join(os.tmpdir(), "no-such-skill")), undefined);
  assert.equal(await discover(""), undefined);
});
