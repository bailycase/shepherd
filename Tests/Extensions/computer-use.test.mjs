// The computer-use extension: inert without its environment and where no person watches; the tools it takes from the
// driver and the ones it leaves out; the driver's name kept out of what the model reads; deferral; a call's text and
// image; an error result; the tool list read once per driver build; the driver started on the first call and killed at
// session_shutdown; and the driver's environment (its own home, no telemetry, none of Shepherd's variables). A stand-in
// driver answers over stdio; no desktop is touched.
import test from "node:test";
import assert from "node:assert/strict";
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
const jiti = createJiti(import.meta.url, { alias: { "@earendil-works/pi-coding-agent": path.join(pkg, "dist/index.js") } });
// A model that can't view images gets words unless the vision extension describes the picture; this host's is not ours.
delete process.env.SHEPHERD_EXT_VISION;
const extension = await jiti.import(path.join(root, "Extensions/shepherd-computer-use.ts"));

const KEYS = ["SHEPHERD_COMPUTER_USE", "SHEPHERD_COMPUTER_USE_HOME", "SHEPHERD_CHILD", "SHEPHERD_DESIGN_ID", "SHEPHERD_AUTOMATION",
  "SHEPHERD_DEFER_TOOLS", "SHEPHERD_AGENT_ID"];

// A driver that lists a few tools (one the extension leaves out) and answers calls. It appends what it saw to $LOG.
const DRIVER = `#!/usr/bin/env node
const fs = require("node:fs");
const log = (entry) => fs.appendFileSync(process.env.LOG, JSON.stringify(entry) + "\\n");
log({ started: process.argv.slice(2), env: Object.keys(process.env).filter((k) => /^(CUA|SHEPHERD)_/.test(k)).sort(),
  home: process.env.CUA_DRIVER_RS_HOME, telemetry: process.env.CUA_DRIVER_RS_TELEMETRY_ENABLED });
// The service: it only has to hold its socket until it is killed.
if (process.argv[2] === "serve") {
  require("node:net").createServer().listen(process.argv[process.argv.indexOf("--socket") + 1]);
  return;
}
const tools = [
  { name: "list_apps", description: "List apps, e.g. Cua Driver itself.", inputSchema: { type: "object", properties: {} } },
  { name: "click", description: "Click a target pid. Run \`cua-driver permissions grant\` first. Uses CuaDriver.app.",
    inputSchema: { type: "object", properties: { pid: { type: "integer", description: "pid from cua-driver" } }, required: ["pid"] } },
  { name: "check_for_update", description: "Updates the driver", inputSchema: { type: "object", properties: {} } },
];
let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let end;
  while ((end = buffer.indexOf("\\n")) >= 0) {
    const message = JSON.parse(buffer.slice(0, end));
    buffer = buffer.slice(end + 1);
    if (message.id === undefined) continue;
    const reply = (result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) + "\\n");
    if (message.method === "initialize") reply({ protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "cua-driver" } });
    else if (message.method === "tools/list") { log({ listed: true }); reply({ tools }); }
    else if (message.method === "tools/call") {
      log({ called: message.params });
      // A request of the driver's own that happens to share the call's id is not the call's answer.
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: message.id, method: "ping" }) + "\\n");
      if (message.params.arguments.pid === 0) reply({ isError: true, content: [{ type: "text", text: "No such pid in cua-driver" }] });
      else reply({ content: [{ type: "text", text: "Clicked via Cua Driver" }, { type: "image", data: "aGk=", mimeType: "image/png" }] });
    }
  }
});
`;

function scratch() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cu-"));
  const driver = path.join(dir, "computer-use");
  fs.writeFileSync(driver, DRIVER, { mode: 0o755 });
  const log = path.join(dir, "log.jsonl");
  return { dir, driver, home: path.join(dir, "home"), log, entries: () => fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l)) : [] };
}

function fakePi() {
  const tools = [];
  const handlers = {};
  return { tools, handlers, registerTool: (tool) => tools.push(tool), on: (name, fn) => { handlers[name] = fn; } };
}

async function load(env) {
  const saved = KEYS.map((key) => process.env[key]);
  for (const key of KEYS) if (env[key] === undefined) delete process.env[key]; else process.env[key] = env[key];
  const pi = fakePi();
  try {
    await extension.default(pi);
  } finally {
    KEYS.forEach((key, i) => { if (saved[i] === undefined) delete process.env[key]; else process.env[key] = saved[i]; });
  }
  return pi;
}

async function eventually(what, check, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (check()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.fail(`timed out waiting for ${what}`);
}

test("inert without its environment, in a subagent, a design's agent and an automation", async () => {
  const s = scratch();
  const on = { SHEPHERD_COMPUTER_USE: s.driver, SHEPHERD_COMPUTER_USE_HOME: s.home };
  for (const env of [{}, { ...on, SHEPHERD_CHILD: "1" }, { ...on, SHEPHERD_DESIGN_ID: "d" }, { ...on, SHEPHERD_AUTOMATION: "1" }]) {
    assert.equal((await load(env)).tools.length, 0, JSON.stringify(env));
  }
  assert.deepEqual(s.entries(), [], "the driver never ran");
});

test("the driver's tools, without its name or the ones a thread does not get", async () => {
  const s = scratch();
  process.env.LOG = s.log;
  const pi = await load({ SHEPHERD_COMPUTER_USE: s.driver, SHEPHERD_COMPUTER_USE_HOME: s.home, SHEPHERD_DEFER_TOOLS: "1", SHEPHERD_AGENT_ID: "a" });
  assert.deepEqual(pi.tools.map((t) => t.name), ["list_apps", "click"]);
  const read = JSON.stringify(pi.tools.map(({ execute, ...rest }) => rest));
  assert.doesNotMatch(read, /cua/i);
  assert.match(pi.tools[1].description, /^Click a target pid\. Uses Shepherd\.$/);
  assert.equal(pi.tools[1].exposure, "deferred");
  assert.equal(pi.tools[1].namespace.name, "shepherd_computer");
  assert.deepEqual(pi.tools[1].parameters.required, ["pid"]);

  // Every request says when to reach for these tools, once, even while they wait for tool_search.
  const rules = ["existing"];
  pi.handlers.before_agent_start({ systemPromptOptions: { promptGuidelines: rules } });
  pi.handlers.before_agent_start({ systemPromptOptions: { promptGuidelines: rules } });
  assert.deepEqual(rules, ["existing", extension.HINT]);
  assert.match(extension.HINT, /tool_search/);

  // The list was read once, by a driver that has exited; a second load reads the kept copy.
  await eventually("the listing driver to log", () => s.entries().some((e) => e.listed));
  const first = s.entries().filter((e) => e.started).length;
  assert.equal(first, 1);
  assert.equal((await load({ SHEPHERD_COMPUTER_USE: s.driver, SHEPHERD_COMPUTER_USE_HOME: s.home })).tools[0].exposure, undefined,
    "direct when Shepherd's tools are not deferred");
  assert.equal(s.entries().filter((e) => e.started).length, first, "no driver ran for the second load");

  // Its environment: its own home, telemetry off, and none of Shepherd's variables.
  const started = s.entries().find((e) => e.started);
  assert.deepEqual(started.started, ["mcp", "--direct", "--embedded"]);
  assert.equal(started.home, s.home);
  assert.equal(started.telemetry, "0");
  assert.ok(!started.env.some((key) => key.startsWith("SHEPHERD_")), started.env.join(","));
  delete process.env.LOG;
});

test("a call starts the thread's service and a client of it once, passes text and pictures, fails on an error, and stops at shutdown", async () => {
  const s = scratch();
  process.env.LOG = s.log;
  const pi = await load({ SHEPHERD_COMPUTER_USE: s.driver, SHEPHERD_COMPUTER_USE_HOME: s.home });
  const click = pi.tools.find((t) => t.name === "click");
  const runs = (word) => s.entries().filter((e) => e.started?.[0] === word && (word === "serve" || e.started.includes("--socket")));

  const seeing = await click.execute("1", { pid: 42 }, undefined, undefined, { model: { input: ["text", "image"] } });
  assert.deepEqual(seeing.content, [{ type: "text", text: "Clicked via Shepherd" }, { type: "image", data: "aGk=", mimeType: "image/png" }]);
  const blind = await click.execute("2", { pid: 42 }, undefined, undefined, { model: { input: ["text"] } });
  assert.equal(blind.content.length, 1);
  assert.match(blind.content[0].text, /can't view images/);
  await assert.rejects(click.execute("3", { pid: 0 }, undefined, undefined, {}), /No such pid in Shepherd/);

  assert.deepEqual(s.entries().filter((e) => e.called).map((e) => e.called),
    [42, 42, 0].map((pid) => ({ name: "click", arguments: { pid } })));
  assert.equal(runs("serve").length, 1, "one service serves the session");
  assert.equal(runs("mcp").length, 1, "through one client");
  const [service] = runs("serve");
  const socket = service.started[service.started.indexOf("--socket") + 1];
  assert.ok(Buffer.byteLength(socket) < 104, socket);
  assert.deepEqual(runs("mcp")[0].started, ["mcp", "--socket", socket, "--embedded"]);

  pi.handlers.session_shutdown();
  await eventually("the service's folder to go", () => !fs.existsSync(path.dirname(socket)));
  const again = await click.execute("4", { pid: 42 }, undefined, undefined, {});
  assert.equal(again.content[0].text, "Clicked via Shepherd");
  assert.equal(runs("serve").length, 2, "a call after shutdown starts a new service");
  pi.handlers.session_shutdown();
  delete process.env.LOG;
});

test("a cancelled call is given up", async () => {
  const s = scratch();
  process.env.LOG = s.log;
  const pi = await load({ SHEPHERD_COMPUTER_USE: s.driver, SHEPHERD_COMPUTER_USE_HOME: s.home });
  const controller = new AbortController();
  controller.abort();
  const list = pi.tools.find((t) => t.name === "list_apps");
  await assert.rejects(list.execute("1", {}, controller.signal, undefined, {}), /cancelled/);
  pi.handlers.session_shutdown();
  delete process.env.LOG;
});
