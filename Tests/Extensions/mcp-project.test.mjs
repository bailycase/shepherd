// shepherd-mcp-project.ts, the one piece of MCP that runs in an agent's pi (docs/mcp.md): with the switch on it registers the
// servers of a repo's `.mcp.json` with pi's own MCP, which connects them, and the model reaches them through tool_search.
// Real pi in RPC mode against the stand-in stdio server, a loopback fake provider and a temporary home.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/mcp-project.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { withPi, script, sleep, until } from "./fixtures/pi-rpc-harness.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const stdio = path.join(root, "Tests/Extensions/fixtures/fake-mcp-stdio.mjs");
const extension = path.join(root, "Extensions/shepherd-mcp-project.ts");
const OFF = ["-builtin:mcp", "-builtin:codemode", "-builtin:tool-search"];
const ARGS = ["-e", "builtin:mcp", "-e", "builtin:tool-search", "-e", extension];
const ON = { SHEPHERD_EXT_MCP_PROJECT: "1" };
const entry = (extra = {}) => ({ command: process.execPath, args: [stdio], ...extra });
const tool = (name, args = {}) => ({ tool: { name, arguments: args } });
const writeRepo = (dir, servers, file = ".mcp.json") => {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, file), typeof servers === "string" ? servers : JSON.stringify({ mcpServers: servers }));
};

async function status(pi) {
  const mark = pi.events.length;
  await pi.request({ type: "prompt", message: "/mcp" });
  await sleep(100);
  return pi.events.slice(mark).filter((e) => e.type === "extension_ui_request" && e.method === "notify").map((e) => e.message).join("\n");
}

async function connected(pi, name) {
  await until(`${name} to connect`, async () => new RegExp(`^${name}: connected`, "m").test(await status(pi)));
}

test("with the switch on, the repo's servers are registered, searched through tool_search and called", { timeout: 120000 }, async (t) => {
  await withPi(t, {
    settings: { extensions: OFF }, args: ARGS, env: ON,
    project: (_dir, work) => writeRepo(work, { repo: entry({ env: { FAKE_MCP_TOOLS: "10" } }) }),
    onRequest: script([tool("tool_search", { query: "echo the text back" }), tool("mcp__repo__echo", { text: "from the repo" })]),
  }, async (pi) => {
    await connected(pi, "repo");
    assert.match(await status(pi), /^repo: connected, 16 tools \(deferred\)$/m);
    const turn = await pi.prompt("use it");
    assert.ok(!turn.requests[0].tools.some((name) => name.startsWith("mcp__")), "its tools cost nothing until a search");
    const ends = pi.toolEvents(turn.events).filter((e) => e.type === "tool_execution_end");
    assert.equal(ends.at(-1).result.content[0].text, "echo: from the repo");
  });
});

test("without the switch the extension registers nothing", { timeout: 120000 }, async (t) => {
  await withPi(t, {
    settings: { extensions: OFF }, args: ARGS,
    project: (_dir, work) => writeRepo(work, { repo: entry() }),
  }, async (pi) => {
    await sleep(1000);
    assert.doesNotMatch(await status(pi), /repo:/);
    assert.equal(pi.spawned("repo"), false);
  });
});

test("the .mcp.json is found at the nearest ancestor that holds .git, and not beyond it", { timeout: 120000 }, async (t) => {
  const nested = (dir, work) => path.join(work, "packages", "app");
  await withPi(t, {
    settings: { extensions: OFF }, args: ARGS, env: ON, cwd: nested,
    project: (dir, work) => { writeRepo(work, { up: entry() }); fs.mkdirSync(path.join(work, ".git")); fs.mkdirSync(nested(dir, work), { recursive: true }); },
  }, async (pi) => {
    await connected(pi, "up");
  });
  await withPi(t, {
    settings: { extensions: OFF }, args: ARGS, env: ON, cwd: (dir, work) => path.join(work, "repo", "src"),
    project: (dir, work) => {
      writeRepo(work, { above: entry() });
      fs.mkdirSync(path.join(work, "repo", ".git"), { recursive: true });
      fs.mkdirSync(path.join(work, "repo", "src"), { recursive: true });
    },
  }, async (pi) => {
    await sleep(1000);
    assert.doesNotMatch(await status(pi), /above:/);
  });
});

test("a server of the same name in the user's own file wins over the repo's", { timeout: 120000 }, async (t) => {
  await withPi(t, {
    settings: { extensions: OFF }, args: ARGS, env: ON,
    files: () => ({ "mcp.json": { mcpServers: { shared: entry({ exposure: "deferred" }) } } }),
    project: (_dir, work) => writeRepo(work, { shared: { command: "/nonexistent/binary" }, only: entry() }),
  }, async (pi) => {
    await connected(pi, "only");
    const text = await status(pi);
    assert.match(text, /^shared: connected/m, "the user's server runs");
    assert.match(text, /^only: connected/m);
    assert.match(text, /overridden: "shared" registered by .*shepherd-mcp-project\.ts is overridden/);
  });
});

test("${VAR} and ${VAR:-default} in a repo's entry are settled from the environment, in memory only", { timeout: 120000 }, async (t) => {
  await withPi(t, {
    settings: { extensions: OFF }, args: ARGS, env: { ...ON, REPO_TOKEN: "tok", REPO_FOLDER: "from-env" },
    project: (_dir, work) => writeRepo(work, { repo: entry({
      args: [stdio],
      env: { PLAIN: "${REPO_TOKEN}", DEFAULTED: "${NOT_SET:-fallback}", SET_DEFAULT: "${REPO_FOLDER:-unused}" } }) }),
    onRequest: script([tool("tool_search", { query: "reads one environment variable" }), ...["PLAIN", "DEFAULTED", "SET_DEFAULT"].map((name) => tool("mcp__repo__env", { name }))]),
  }, async (pi) => {
    await connected(pi, "repo");
    const turn = await pi.prompt("env");
    const texts = pi.toolEvents(turn.events).filter((e) => e.type === "tool_execution_end").map((e) => e.result.content[0].text);
    assert.deepEqual(texts.slice(-3), ["PLAIN=tok", "DEFAULTED=fallback", "SET_DEFAULT=from-env"]);
  });
});

test("what pi's MCP cannot run, and a file that is not JSON, register nothing and leave the other servers alone", { timeout: 120000 }, async (t) => {
  await withPi(t, {
    settings: { extensions: OFF }, args: ARGS, env: ON,
    project: (_dir, work) => writeRepo(work, { sse: { type: "sse", url: "http://127.0.0.1:1/sse" }, off: entry({ disabled: true }), "bad name": entry(), good: entry(), empty: {} }),
  }, async (pi) => {
    await connected(pi, "good");
    const text = await status(pi);
    assert.doesNotMatch(text, /^(sse|off|empty|bad name):/m);
  });
  await withPi(t, {
    settings: { extensions: OFF }, args: ARGS, env: ON,
    files: () => ({ "mcp.json": { mcpServers: { home: entry({ exposure: "deferred" }) } } }),
    project: (_dir, work) => writeRepo(work, "{ not json", ".mcp.json"),
  }, async (pi) => {
    await connected(pi, "home");
  });
});
