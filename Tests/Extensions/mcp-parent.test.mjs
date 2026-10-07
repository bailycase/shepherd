// shepherd-mcp-parent.ts (docs/mcp.md › Subprojects): a project inside another project's folder shares the parent's
// `.pi/mcp.json` servers. Real pi in RPC mode against the stand-in stdio server, a loopback fake provider and a temporary
// home. pi runs in `work/apps/web`, a subproject of `work`, with SHEPHERD_PARENT_PROJECT naming `work`.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/mcp-parent.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { withPi, sleep, until } from "./fixtures/pi-rpc-harness.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const stdio = path.join(root, "Tests/Extensions/fixtures/fake-mcp-stdio.mjs");
const extension = path.join(root, "Extensions/shepherd-mcp-parent.ts");
const ARGS = ["-e", "builtin:mcp", "-e", "builtin:tool-search", "-e", extension];
// The stand-in writes `<dir>/<marker>.pid` when it starts, which `pi.spawned(marker)` reads.
const server = (dir, marker) => ({ command: process.execPath, args: [stdio], env: { FAKE_MCP_PIDFILE: path.join(dir, `${marker}.pid`) } });
const mcpFile = (folder, servers) => {
  fs.mkdirSync(path.join(folder, ".pi"), { recursive: true });
  fs.writeFileSync(path.join(folder, ".pi/mcp.json"), JSON.stringify({ mcpServers: servers }));
};
const web = (work) => path.join(work, "apps/web");

/** pi in `work/apps/web`; the parent `work` names `shared` and `docs` (the parent's own `docs`). */
function subproject({ trusted = true, deniedChild = false, parent = (work) => work, own } = {}) {
  return {
    args: ARGS,
    cwd: (_dir, work) => web(work),
    env: (_dir, work) => (parent(work) ? { SHEPHERD_PARENT_PROJECT: parent(work) } : {}),
    files: (_dir, work) => {
      const decisions = trusted ? { [fs.realpathSync(work)]: true } : {};
      if (deniedChild) { fs.mkdirSync(web(work), { recursive: true }); decisions[fs.realpathSync(web(work))] = false; }
      return { "trust.json": decisions };
    },
    project: (dir, work) => {
      fs.mkdirSync(web(work), { recursive: true });
      mcpFile(work, { shared: server(dir, "shared"), docs: server(dir, "parent-docs") });
      if (own) mcpFile(web(work), own(dir));
    },
  };
}

async function status(pi) {
  const mark = pi.events.length;
  await pi.request({ type: "prompt", message: "/mcp" });
  await sleep(100);
  return pi.events.slice(mark).filter((e) => e.type === "extension_ui_request" && e.method === "notify").map((e) => e.message).join("\n");
}

test("a subproject starts its parent's servers next to its own", { timeout: 120000 }, async (t) => {
  await withPi(t, subproject({ own: (dir) => ({ local: server(dir, "local") }) }), async (pi) => {
    await until("the parent's and the subproject's servers to start", () => pi.spawned("shared") && pi.spawned("parent-docs") && pi.spawned("local"));
    await until("all three to connect", async () => {
      const text = await status(pi);
      return ["shared", "docs", "local"].every((name) => new RegExp(`^${name}: connected`, "m").test(text));
    });
  });
});

test("the subproject's own server of the same name wins over the parent's", { timeout: 120000 }, async (t) => {
  await withPi(t, subproject({ own: (dir) => ({ docs: server(dir, "own-docs") }) }), async (pi) => {
    await until("the subproject's docs and the parent's shared to start", () => pi.spawned("own-docs") && pi.spawned("shared"));
    await sleep(1500);
    assert.equal(pi.spawned("parent-docs"), false, "the parent's docs is overridden, never started");
  });
});

test("an untrusted subproject shares nothing, and neither does a missing or wrong parent", { timeout: 180000 }, async (t) => {
  for (const [what, options] of [
    ["untrusted", subproject({ trusted: false })],
    ["a trusted parent, but the subproject refused", subproject({ deniedChild: true })],
    ["no parent named", subproject({ parent: () => undefined })],
    ["a parent that does not hold the subproject", subproject({ parent: (work) => path.join(work, "elsewhere") })],
  ]) {
    await withPi(t, options, async (pi) => {
      await pi.commands();
      await sleep(1500);
      assert.equal(pi.spawned("shared"), false, `${what}: the parent's server never starts`);
    });
  }
});
