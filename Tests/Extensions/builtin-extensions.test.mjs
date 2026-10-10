// pi 1.0's built-in extensions (MCP, codemode, tool search, llama.cpp) in the pi Shepherd starts: Shepherd's home
// switches the first three off with `-builtin:<name>` in settings.json's `extensions` (PiHome.disabledBuiltIns), and
// this pins what pi does with that switch, so a pi that renames it or loads them anyway fails here before a release.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/builtin-extensions.test.mjs
// Real pi in RPC mode against a loopback fake provider, in a temporary HOME. No extensions of Shepherd's load: the
// question is what pi itself adds.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { startProvider } from "./fake-provider.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, fn, timeout = 30000) {
  const end = Date.now() + timeout;
  while (!(await fn())) { if (Date.now() > end) throw Error(`Timed out waiting for ${what}`); await sleep(20); }
}

// What PiHome.install writes (keep in step with PiHome.disabledBuiltIns).
const OFF = ["-builtin:mcp", "-builtin:codemode", "-builtin:tool-search"];
const fixture = path.join(root, "Tests/Extensions/fixtures/fake-mcp-stdio.mjs");

// A server in an MCP config whose start leaves a pid file: spawned or not.
function server(dir, name) {
  return { command: process.execPath, args: [fixture], env: { FAKE_MCP_PIDFILE: path.join(dir, `${name}.pid`) } };
}

async function withPi(t, { settings = {}, files = () => ({}), project, args = [] }, body) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "builtin-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const provider = await startProvider();
  t.after(() => provider.stop());
  const home = path.join(dir, "home");
  const work = path.join(dir, "work");
  fs.mkdirSync(home, { recursive: true });
  fs.mkdirSync(work, { recursive: true });
  fs.writeFileSync(path.join(home, "settings.json"), JSON.stringify({ retry: { enabled: false }, ...settings }));
  fs.writeFileSync(path.join(home, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${provider.port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: [{ id: "fixture", name: "fixture", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  for (const [name, content] of Object.entries(files(dir, work))) {
    fs.mkdirSync(path.dirname(name.startsWith("/") ? name : path.join(home, name)), { recursive: true });
    fs.writeFileSync(name.startsWith("/") ? name : path.join(home, name), JSON.stringify(content));
  }
  project?.(dir, work);
  const env = { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: home, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" };
  const child = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--session-dir", path.join(dir, "sessions"),
    "--model", "fixture/fixture", ...args], { cwd: work, env, stdio: ["pipe", "pipe", "pipe"] });
  t.after(() => child.kill("SIGKILL"));
  const events = [];
  let out = "", err = "", next = 0;
  child.stdout.on("data", (chunk) => {
    out += chunk;
    for (let nl; (nl = out.indexOf("\n")) >= 0; out = out.slice(nl + 1)) { try { events.push(JSON.parse(out.slice(0, nl))); } catch {} }
  });
  child.stderr.on("data", (chunk) => { err += chunk; });
  child.stdin.on("error", () => {});
  const pi = {
    dir, events, provider, get stderr() { return err; },
    async request(command) {
      const id = `r${++next}`;
      child.stdin.write(JSON.stringify({ id, ...command }) + "\n");
      await until(`the answer to ${command.type}`, () => events.some((e) => e.type === "response" && e.id === id));
      return events.find((e) => e.type === "response" && e.id === id);
    },
    async commands() { return (await pi.request({ type: "get_commands" })).data.commands; },
    // What the next model call is sent: the tools declared and the system prompt.
    async promptSent() {
      await pi.request({ type: "prompt", message: "hello" });
      await until("the turn", () => events.some((e) => e.type === "agent_settled"));
      const body = provider.requests.at(-1).body;
      const text = (m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content));
      return { tools: (body.tools ?? []).map((tool) => tool.function.name), system: body.messages.filter((m) => m.role === "system" || m.role === "developer").map(text).join("\n") };
    },
    spawned: (name) => fs.existsSync(path.join(dir, `${name}.pid`)),
  };
  await body(pi);
}

test("with Shepherd's switches pi lists no /mcp, declares no codemode and starts no server from the home's mcp.json", { timeout: 120000 }, async (t) => {
  await withPi(t, { settings: { extensions: OFF }, files: (dir) => ({ "mcp.json": { mcpServers: { probe: server(dir, "home") } } }) }, async (pi) => {
    const commands = await pi.commands();
    assert.ok(!commands.some((c) => c.name === "mcp"), `no /mcp: ${commands.map((c) => c.name)}`);
    const sent = await pi.promptSent();
    assert.deepEqual(sent.tools, ["read", "bash", "edit", "write"]);
    assert.ok(!/mcp_servers/.test(sent.system), "no MCP server section in the system prompt");
    assert.equal(pi.spawned("home"), false, "the server in <home>/mcp.json was never started");
  });
});

test("the switch is pi's own: without it the same files start the server, offer codemode and list /mcp", { timeout: 120000 }, async (t) => {
  await withPi(t, { files: (dir) => ({ "mcp.json": { mcpServers: { probe: server(dir, "home") } } }) }, async (pi) => {
    const mcp = (await pi.commands()).find((c) => c.name === "mcp");
    assert.equal(mcp?.sourceInfo?.path, "builtin:mcp", "pi names a built-in extension's file builtin:<name>");
    assert.equal(mcp.sourceInfo.source, "builtin");
    await until("pi's MCP to start the server", () => pi.spawned("home"));
    const sent = await pi.promptSent();
    assert.ok(sent.tools.includes("codemode"), `codemode is declared once a server needs it: ${sent.tools}`);
    assert.match(sent.system, /mcp_servers/);
  });
});

test("+builtin:mcp, the documented way to turn it back on, is kept by the switch rule and works", { timeout: 120000 }, async (t) => {
  await withPi(t, { settings: { extensions: ["+builtin:mcp", "-builtin:codemode", "-builtin:tool-search"] },
    files: (dir) => ({ "mcp.json": { mcpServers: { probe: server(dir, "home") } } }) }, async (pi) => {
    assert.ok((await pi.commands()).some((c) => c.name === "mcp"));
    await until("pi's MCP to start the server", () => pi.spawned("home"));
    const sent = await pi.promptSent();
    assert.ok(!sent.tools.includes("codemode"), "codemode stays off: only MCP was turned on");
  });
});

test("a trusted project's .pi/mcp.json starts a server only while the built-in is on", { timeout: 180000 }, async (t) => {
  const project = (dir, work) => {
    const config = JSON.parse(fs.readFileSync(path.join(process.env.PI_PACKAGE_DIR, "package.json"))).piConfig?.configDir ?? ".pi";
    fs.mkdirSync(path.join(work, config), { recursive: true });
    fs.writeFileSync(path.join(work, config, "mcp.json"), JSON.stringify({ mcpServers: { project: server(dir, "project") } }));
  };
  const trust = (dir, work) => ({ "trust.json": { [fs.realpathSync(work)]: true } });
  await withPi(t, { files: trust, project }, async (pi) => {
    await until("pi's MCP to start the trusted project's server", () => pi.spawned("project"));
  });
  await withPi(t, { settings: { extensions: OFF }, files: trust, project }, async (pi) => {
    await pi.commands();
    await sleep(1500);
    assert.equal(pi.spawned("project"), false, "switched off, a trusted project's server is never started");
  });
});

test("--no-extensions loads none of pi's built-ins, and an explicit builtin:<name> loads one", { timeout: 120000 }, async (t) => {
  await withPi(t, { args: ["--no-extensions"] }, async (pi) => {
    assert.deepEqual((await pi.commands()).map((c) => c.name), [], "drafts and native children run like this");
  });
  await withPi(t, { args: ["--no-extensions", "-e", "builtin:llama.cpp"] }, async (pi) => {
    assert.deepEqual((await pi.commands()).map((c) => c.name), ["llama"]);
  });
});

test("llama.cpp, the built-in that stays, lists /llama as pi's own file, which the thread's command menu leaves out", { timeout: 120000 }, async (t) => {
  await withPi(t, { settings: { extensions: OFF } }, async (pi) => {
    const llama = (await pi.commands()).find((c) => c.name === "llama");
    assert.equal(llama?.sourceInfo?.path, "builtin:llama.cpp");
    const reply = await pi.request({ type: "prompt", message: "/llama" });
    assert.equal(reply.data.disposition, "handled");
    const notice = pi.events.find((e) => e.type === "extension_ui_request" && e.method === "notify");
    assert.match(notice.message, /interactive mode/, "over RPC it does nothing, which is why the menu hides it");
  });
});
