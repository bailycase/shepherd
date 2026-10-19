import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { test } from "node:test";
import { pkg, withPi, until } from "./fixtures/pi-rpc-harness.mjs";

// CI installs the unpatched SDK. Load the canonical engine patch without changing that package.
const spec = JSON.parse(fs.readFileSync(new URL("../../scripts/pi-engine-patches/skills.json", import.meta.url)));
const sources = Object.fromEntries(spec.files.filter((change) => change.source).map((change) => [
  change.source, fs.readFileSync(new URL(`../../scripts/pi-engine-patches/${change.source}`, import.meta.url), "utf8"),
]));
const hook = `
  import { registerHooks } from "node:module";
  import { createHash } from "node:crypto";
  import assert from "node:assert/strict";
  const root = ${JSON.stringify(pathToFileURL(fs.realpathSync(pkg) + path.sep).href)};
  const files = ${JSON.stringify(spec.files)};
  const sources = ${JSON.stringify(sources)};
  const find = (url) => files.find((change) => new URL(change.path, root).href === url);
  const hash = (source) => createHash("sha256").update(source).digest("hex");
  registerHooks({
    resolve(specifier, context, next) {
      if (context.parentURL?.startsWith(root)) {
        const url = new URL(specifier, context.parentURL).href;
        if (find(url)?.source) return { url, shortCircuit: true };
      }
      return next(specifier, context);
    },
    load(url, context, next) {
      const change = find(url);
      if (!change) return next(url, context);
      if (change.source) {
        const source = sources[change.source];
        assert.equal(hash(source), change.after);
        return { format: "module", source, shortCircuit: true };
      }
      const result = next(url, context);
      let source = Buffer.from(result.source).toString("utf8");
      if (hash(source) === change.after) return result;
      assert.equal(hash(source), change.before, change.path);
      for (const edit of change.edits ?? []) {
        assert.equal(source.split(edit.old).length, 2, "unique patch anchor");
        source = source.replace(edit.old, edit.new);
      }
      assert.equal(hash(source), change.after, change.path);
      return { ...result, source };
    }
  });
`;

test("startup UI answers bypass initialization while state and prompts wait", { timeout: 30000 }, async (t) => {
  await withPi(t, {
    settings: { extensions: ["-builtin:mcp", "-builtin:codemode", "-builtin:tool-search", "./startup.ts"] },
    env: (dir) => ({ NODE_OPTIONS: `--import=${pathToFileURL(path.join(dir, "home", "engine-patch.mjs")).href}` }),
    files: () => ({ "engine-patch.mjs": hook, "startup.ts": `export default function(pi) {
      let answered = false;
      pi.on("session_start", async (_, ctx) => {
        answered = await ctx.ui.confirm("Startup permission", "Continue?", { timeout: 10000 });
        process.stderr.write("startup-answer:" + answered + "\\n");
      });
      pi.on("before_agent_start", () => {
        if (!answered) throw new Error("Prompt ran before startup permission");
      });
    }` }),
  }, async (pi) => {
    const state = pi.request({ type: "get_state" });
    const prompt = pi.request({ type: "prompt", message: "hello" });
    const question = await until("the startup confirmation", () => pi.events.find((e) => e.type === "extension_ui_request" && e.method === "confirm"));
    assert.equal(pi.provider.requests.length, 0, "no inference before permission");
    assert.equal(pi.events.some((e) => e.type === "response"), false, "startup is not advertised as ready");
    pi.child.stdin.write(JSON.stringify({ type: "extension_ui_response", id: question.id, confirmed: true }) + "\n");
    const [ready, sent] = await Promise.all([state, prompt]);
    assert.equal(ready.success, true);
    assert.equal(sent.success, true);
    assert.match(pi.stderr, /startup-answer:true/);
    await until("the first turn to settle", () => pi.events.some((e) => e.type === "agent_settled"), 10000);
    assert.equal(pi.provider.requests.length, 1, "the queued first prompt executes once");
  });
});
