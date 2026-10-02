// pi 1.0's built-in MCP, as Shepherd depends on it (docs/mcp.md): real pi in RPC mode, in a temporary home, against
// stand-in MCP servers on stdio and loopback HTTP (fixtures/fake-mcp-*.mjs) and a fake provider. Each test pins one thing
// the layering relies on, so a pi that changes it fails here before a release: what each exposure puts in a prompt,
// the flow of a deferred tool, where `${VAR}` expands, what a stdio server inherits, the explicit -e that turns the
// built-ins on over the home's switch, the `pi mcp` commands and OAuth against a local authorization server, and what
// /mcp and a changed mcp.json do in a running session.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/pi-mcp.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { withPi, runPiCli, fakeBrowserBin, script, sleep, until } from "./fixtures/pi-rpc-harness.mjs";
import { startFakeMcpHttp } from "./fixtures/fake-mcp-http.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const stdio = path.join(root, "Tests/Extensions/fixtures/fake-mcp-stdio.mjs");
const oauthServer = path.join(root, "Tests/Extensions/fixtures/fake-mcp-oauth.py");

// What Shepherd's home carries (PiHome.disabledBuiltIns), and the explicit flags an agent's launch adds.
const OFF = ["-builtin:mcp", "-builtin:codemode", "-builtin:tool-search"];
const AGENT_FLAGS = ["-e", "builtin:mcp", "-e", "builtin:tool-search"];
const BASE_TOOLS = ["read", "bash", "edit", "write"];
const mcpTools = (names) => names.filter((name) => name.startsWith("mcp__"));
const server = (env = {}, extra = {}) => ({ command: process.execPath, args: [stdio], env, ...extra });
const mcpFile = (servers) => () => ({ "mcp.json": { mcpServers: servers } });
const tool = (name, args = {}) => ({ tool: { name, arguments: args } });
const total = (sent) => sent.toolsJSON.length + sent.system.length;
const notices = (pi, from = 0) => pi.events.slice(from).filter((e) => e.type === "extension_ui_request" && e.method === "notify").map((e) => e.message);

/** pi connects servers in the background after it starts; a first request waits only for `direct` ones. */
async function connected(pi, name) {
  await until(`${name} to connect`, async () => {
    const mark = pi.events.length;
    await pi.request({ type: "prompt", message: "/mcp" });
    await sleep(50);
    return notices(pi, mark).some((text) => new RegExp(`^${name}: connected`, "m").test(text));
  });
}

test("a deferred server costs a tool_search declaration and a line of prompt, not its tools", { timeout: 120000 }, async (t) => {
  let none, deferred, direct;
  await withPi(t, { settings: { extensions: OFF } }, async (pi) => { none = await pi.promptSent(); });
  await withPi(t, { settings: { extensions: OFF }, args: AGENT_FLAGS, files: mcpFile({ fake: server({ FAKE_MCP_TOOLS: "20" }, { exposure: "deferred" }) }) }, async (pi) => {
    await connected(pi, "fake");
    deferred = await pi.promptSent();
    assert.deepEqual(deferred.tools, [...BASE_TOOLS, "tool_search"], "no server tool is declared");
    assert.match(deferred.system, /<mcp_servers>[\s\S]*- mcp__fake \(tool_search\)/, "the server is listed in the system prompt");
  });
  await withPi(t, { settings: { extensions: OFF }, args: AGENT_FLAGS, files: mcpFile({ fake: server({ FAKE_MCP_TOOLS: "20" }, { exposure: "direct" }) }) }, async (pi) => {
    direct = await pi.promptSent();
    assert.equal(mcpTools(direct.tools).length, 26, "direct declares all 26 tools like built-ins");
    assert.ok(!direct.tools.includes("tool_search"));
  });
  const deferredCost = total(deferred) - total(none), directCost = total(direct) - total(none);
  console.log(`prompt cost over no MCP: deferred +${deferredCost} chars, direct +${directCost} chars (26 tools)`);
  assert.ok(deferredCost < 1200, `deferred adds ${deferredCost} characters`);
  assert.ok(directCost > 12 * deferredCost, `direct adds ${directCost} characters, deferred ${deferredCost}`);
});

test("tool_search loads the best matches for the next call, the call works, and its result reaches the model", { timeout: 120000 }, async (t) => {
  await withPi(t, {
    settings: { extensions: OFF }, args: AGENT_FLAGS,
    files: mcpFile({ fake: server({ FAKE_MCP_TOOLS: "20" }, { exposure: "deferred" }) }),
    onRequest: script([tool("tool_search", { query: "echo the text back" }), tool("mcp__fake__echo", { text: "hi there" }), tool("mcp__fake__add", { a: 2, b: 3 })]),
  }, async (pi) => {
    await connected(pi, "fake");
    const turn = await pi.prompt("use the tool");
    const [first, afterSearch] = turn.requests;
    assert.ok(!first.tools.some((name) => name.startsWith("mcp__")), "nothing declared before the search");
    assert.equal(mcpTools(afterSearch.tools).length, 8, "a search loads eight");
    assert.ok(afterSearch.tools.includes("mcp__fake__echo"));
    const ends = pi.toolEvents(turn.events).filter((e) => e.type === "tool_execution_end");
    const search = ends.find((e) => e.toolName === "tool_search");
    assert.match(search.result.content[0].text, /^Loaded 8 tools\./);
    const echo = ends.find((e) => e.toolName === "mcp__fake__echo");
    assert.equal(echo.isError, false);
    assert.equal(echo.result.content[0].text, "echo: hi there");
    assert.deepEqual(echo.result.details, { server: "fake", tool: "echo" }, "an MCP result says which server and tool it came from");
    assert.ok(turn.requests.at(-1).messages.some((m) => m.role === "tool" && /echo: hi there/.test(JSON.stringify(m.content))), "the model was sent the result");
    const unloaded = ends.find((e) => e.toolName === "mcp__fake__add");
    assert.equal(unloaded.isError, true, "a tool that was never loaded cannot be called");
    assert.match(unloaded.result.content[0].text, /not found/);
  });
});

test("a direct server's tools are declared, and an error result is an error", { timeout: 120000 }, async (t) => {
  await withPi(t, {
    settings: { extensions: OFF }, args: AGENT_FLAGS,
    files: mcpFile({ fake: server({}, { exposure: "direct" }) }),
    onRequest: script([tool("mcp__fake__fail"), tool("mcp__fake__add", { a: 1, b: 2 })]),
  }, async (pi) => {
    const turn = await pi.prompt("call");
    assert.deepEqual(mcpTools(turn.requests[0].tools).sort(), ["mcp__fake__add", "mcp__fake__echo", "mcp__fake__env", "mcp__fake__fail", "mcp__fake__grow", "mcp__fake__slow"]);
    const ends = pi.toolEvents(turn.events).filter((e) => e.type === "tool_execution_end");
    assert.equal(ends[0].isError, true);
    assert.equal(ends[0].result.content[0].text, "the database is down");
    assert.equal(ends[1].isError, false);
    assert.deepEqual(ends[1].result.structuredContent, { content: [], structuredContent: { sum: 3 } });
  });
});

test("Choose which tools: a hidden server with toolExposure offers only the chosen tools, each in the mode given", { timeout: 120000 }, async (t) => {
  await withPi(t, {
    settings: { extensions: OFF }, args: AGENT_FLAGS,
    files: mcpFile({ fake: server({}, { exposure: "hidden", toolExposure: { echo: "deferred", add: "direct" } }) }),
  }, async (pi) => {
    await connected(pi, "fake");
    const sent = await pi.promptSent();
    assert.deepEqual(mcpTools(sent.tools), ["mcp__fake__add"], "add is declared; echo waits for a search; the rest are unreachable");
    assert.ok(sent.tools.includes("tool_search"));
  });
});

test("a server left on pi's default exposure is unreachable with codemode off, and the prompt still points at codemode", { timeout: 120000 }, async (t) => {
  await withPi(t, { settings: { extensions: OFF }, args: AGENT_FLAGS, files: mcpFile({ fake: server() }) }, async (pi) => {
    await connected(pi, "fake");
    const sent = await pi.promptSent();
    assert.deepEqual(sent.tools, BASE_TOOLS, "neither codemode nor tool_search is declared");
    assert.match(sent.system, /Call the tools of `codemode` servers from codemode scripts/, "which is why Shepherd always writes an exposure");
  });
});

test("an explicit -e builtin:mcp wins over the home's -builtin:mcp, which keeps helpers from loading it", { timeout: 120000 }, async (t) => {
  const files = mcpFile({ fake: server({}, { exposure: "deferred" }) });
  await withPi(t, { settings: { extensions: OFF }, files }, async (pi) => {
    assert.ok(!(await pi.commands()).some((c) => c.name === "mcp"), "the home's switch alone: no /mcp");
    assert.equal(pi.spawned("fake"), false);
  });
  await withPi(t, { settings: { extensions: OFF }, args: AGENT_FLAGS, files }, async (pi) => {
    const mcp = (await pi.commands()).find((c) => c.name === "mcp");
    assert.equal(mcp?.sourceInfo?.path, "builtin:mcp");
    await connected(pi, "fake");
  });
  await withPi(t, { settings: { extensions: OFF }, args: ["--no-extensions"], files }, async (pi) => {
    assert.deepEqual((await pi.commands()).map((c) => c.name), [], "a native child or a draft loads no built-in");
  });
});

test("${VAR} expands in env and headers only; a default, a missing variable and ! commands behave as documented", { timeout: 120000 }, async (t) => {
  const http = await startFakeMcpHttp({ bearer: "tok-123" });
  t.after(() => http.stop());
  const argvFile = path.join(os.tmpdir(), `pi-mcp-argv-${process.pid}`);
  t.after(() => fs.rmSync(argvFile, { force: true }));
  await withPi(t, {
    settings: { extensions: OFF }, args: AGENT_FLAGS, env: { LAB_SECRET: "s3cret", LAB_TOKEN: "tok-123" },
    files: mcpFile({
      local: server({ A_VAR: "${LAB_SECRET}", B_MIX: "pre-${LAB_SECRET}-post", C_DEFAULT: "${NOPE:-fallback}", D_CMD: "!printf '%s' \"${NOPE:-from-sh}-${LAB_SECRET}\"",
        FAKE_MCP_ARGVFILE: argvFile }, { args: [stdio, "${LAB_SECRET}"], exposure: "direct" }),
      web: { url: http.url, exposure: "direct", headers: { Authorization: "Bearer ${LAB_TOKEN}", "X-Default": "${NOPE:-dflt}" } },
    }),
    onRequest: script([...["A_VAR", "B_MIX", "C_DEFAULT", "D_CMD"].map((name) => tool("mcp__local__env", { name })), tool("mcp__web__whoami")]),
  }, async (pi) => {
    const turn = await pi.prompt("env");
    const texts = pi.toolEvents(turn.events).filter((e) => e.type === "tool_execution_end").map((e) => e.result.content[0].text);
    assert.deepEqual(texts.slice(0, 4), ["A_VAR=s3cret", "B_MIX=pre-s3cret-post", "C_DEFAULT=${NOPE:-fallback}", "D_CMD=from-sh-s3cret"]);
    const headers = JSON.parse(texts[4]);
    assert.equal(headers.authorization, "Bearer tok-123", "a header is expanded from pi's environment");
    assert.equal(headers["x-default"], "${NOPE:-dflt}", "a default is not a form pi knows");
    assert.deepEqual(JSON.parse(fs.readFileSync(argvFile, "utf8")).argv, ["${LAB_SECRET}"], "args are never expanded");
  });
});

test("a variable that is not set fails that server alone, naming the variable", { timeout: 120000 }, async (t) => {
  await withPi(t, {
    settings: { extensions: OFF }, args: AGENT_FLAGS,
    files: mcpFile({ missing: server({ TOKEN: "${NOT_SET_ANYWHERE}" }, { exposure: "deferred" }), fine: server({}, { exposure: "deferred" }) }),
  }, async (pi) => {
    await connected(pi, "fine");
    const mark = pi.events.length;
    await pi.request({ type: "prompt", message: "/mcp" });
    await sleep(100);
    const status = notices(pi, mark).join("\n");
    assert.match(status, /^missing: failed/m);
    assert.match(status, /env "TOKEN" from environment variable: NOT_SET_ANYWHERE/);
    assert.match(status, /^fine: connected/m);
  });
});

test("a ${keychain:…} reference is not a variable to pi: it reaches the server as text, so Shepherd must always translate it", { timeout: 120000 }, async (t) => {
  await withPi(t, {
    settings: { extensions: OFF }, args: AGENT_FLAGS,
    files: mcpFile({ ref: server({ TOKEN: "${keychain:ref/TOKEN}" }, { exposure: "direct" }) }),
    onRequest: script([tool("mcp__ref__env", { name: "TOKEN" })]),
  }, async (pi) => {
    const turn = await pi.prompt("env");
    const [text] = pi.toolEvents(turn.events).filter((e) => e.type === "tool_execution_end").map((e) => e.result.content[0].text);
    assert.equal(text, "TOKEN=${keychain:ref/TOKEN}");
  });
});

test("a ${…} in a url is no URL: that server fails and the others run", { timeout: 120000 }, async (t) => {
  await withPi(t, {
    settings: { extensions: OFF }, args: AGENT_FLAGS,
    files: mcpFile({ web: { url: "http://${SOMETHING}/mcp", exposure: "deferred" }, fine: server({}, { exposure: "deferred" }) }),
  }, async (pi) => {
    await connected(pi, "fine");
    const mark = pi.events.length;
    await pi.request({ type: "prompt", message: "/mcp" });
    await sleep(100);
    assert.match(notices(pi, mark).join("\n"), /^web: failed/m);
  });
});

test("a stdio server inherits pi's whole environment, and a shell wrapper keeps the other servers' secrets from it", { timeout: 120000 }, async (t) => {
  // The app's wrapper is `/bin/zsh -f -c 'unset -m "SHEPHERD_MCP_SECRET_*"; exec "$@"'` (MCPStdioWrapperTests runs the real
  // one). This pins pi's side of it, so it uses what every runner has: CI is Linux, which has no /bin/zsh, so a zsh
  // wrapper never started the server there and its tools came back "not found".
  const unsetSecrets = String.raw`for v in $(env | sed -n 's/^\(SHEPHERD_MCP_SECRET_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done; exec "$@"`;
  const wrapped = (own) => ({
    command: "/bin/sh", args: ["-c", unsetSecrets, "shepherd-mcp", process.execPath, stdio],
    env: { OWN: own }, exposure: "direct",
  });
  await withPi(t, {
    settings: { extensions: OFF }, args: AGENT_FLAGS,
    env: { SHEPHERD_MCP_SECRET_ONE: "one", SHEPHERD_MCP_SECRET_TWO: "two", PLAIN_IN_PI: "visible" },
    files: mcpFile({ bare: server({}, { exposure: "direct" }), wrapped: wrapped("${SHEPHERD_MCP_SECRET_ONE}") }),
    onRequest: script(["mcp__bare__env", "mcp__wrapped__env"].flatMap((name) => ["PLAIN_IN_PI", "SHEPHERD_MCP_SECRET_ONE", "SHEPHERD_MCP_SECRET_TWO", "OWN"].map((v) => tool(name, { name: v })))),
  }, async (pi) => {
    const turn = await pi.prompt("env");
    const texts = pi.toolEvents(turn.events).filter((e) => e.type === "tool_execution_end").map((e) => e.result.content[0].text);
    assert.deepEqual(texts.slice(0, 4), ["PLAIN_IN_PI=visible", "SHEPHERD_MCP_SECRET_ONE=one", "SHEPHERD_MCP_SECRET_TWO=two", "OWN="], "unwrapped: everything in pi's environment");
    assert.deepEqual(texts.slice(4), ["PLAIN_IN_PI=visible", "SHEPHERD_MCP_SECRET_ONE=", "SHEPHERD_MCP_SECRET_TWO=", "OWN=one"], "wrapped: only what its own env asked for");
  });
});

test("a changed mcp.json changes nothing in a running pi; /mcp reports this session's servers; /reload is not handled over RPC", { timeout: 120000 }, async (t) => {
  await withPi(t, { settings: { extensions: OFF }, args: AGENT_FLAGS, files: mcpFile({ first: server({}, { exposure: "direct" }) }) }, async (pi) => {
    await connected(pi, "first");
    const names = async () => mcpTools((await pi.promptSent("tools?")).tools).filter((n) => n.endsWith("__echo"));
    assert.deepEqual(await names(), ["mcp__first__echo"]);
    fs.writeFileSync(path.join(pi.home, "mcp.json"), JSON.stringify({ mcpServers: { first: server({}, { exposure: "direct" }), second: server({}, { exposure: "direct" }) } }));
    await sleep(1000);
    assert.deepEqual(await names(), ["mcp__first__echo"], "the new server is not picked up");
    const mark = pi.events.length;
    const status = await pi.request({ type: "prompt", message: "/mcp" });
    assert.equal(status.data.disposition, "handled");
    await sleep(100);
    assert.match(notices(pi, mark).join("\n"), /^first: connected, 6 tools \(direct\)$/m);
    const reload = await pi.request({ type: "prompt", message: "/reload" });
    assert.equal(reload.data.disposition, "started", "a prompt for the model, not a reload");
  });
});

test("pi mcp list --json reports each server's state, tools and error without a session", { timeout: 120000 }, async (t) => {
  const http = await startFakeMcpHttp();
  t.after(() => http.stop());
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-mcp-cli-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const home = path.join(dir, "home");
  fs.mkdirSync(home);
  fs.writeFileSync(path.join(home, "mcp.json"), JSON.stringify({ mcpServers: {
    local: server({}, { exposure: "deferred" }), web: { url: http.url, exposure: "direct" },
    broken: { command: "/nonexistent/binary", exposure: "deferred" }, off: server({}, { enabled: false, exposure: "deferred" }),
    sse: { url: "http://127.0.0.1:1/sse", type: "sse" },
  } }));
  const run = await runPiCli(home, ["mcp", "list", "--json"]);
  assert.equal(run.status, 1, "something is not connected");
  const report = JSON.parse(run.stdout);
  const by = Object.fromEntries(report.servers.map((s) => [s.name, s]));
  assert.equal(by.local.state, "connected");
  assert.deepEqual(by.local.tools.slice(0, 2), ["echo", "add"], "names only");
  assert.equal(by.local.exposure, "deferred");
  assert.equal(by.web.state, "connected");
  assert.equal(by.web.transport, http.url);
  assert.equal(by.broken.state, "failed");
  assert.match(by.broken.error, /ENOENT/);
  assert.equal(by.off.state, "disabled");
  assert.equal(by.off.enabled, false);
  assert.ok(!by.sse, "an SSE server is not run");
  assert.match(report.errors.join("\n"), /server "sse": legacy SSE transport is not supported/);
  const first = await runPiCli(home, ["-e", path.join(dir, "x.ts"), "mcp", "list", "--json"]);
  assert.notEqual(first.status, 0, "mcp is a subcommand only as pi's first argument");
});

test("pi mcp login signs in to an OAuth server with no terminal, and logout takes it back", { timeout: 120000 }, async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-mcp-oauth-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const auth = spawn("python3", [oauthServer], { stdio: ["pipe", "pipe", "inherit"] });
  t.after(() => auth.stdin.end());
  const port = await new Promise((resolve) => auth.stdout.once("data", (d) => resolve(String(d).trim())));
  const home = path.join(dir, "home");
  fs.mkdirSync(home);
  fs.writeFileSync(path.join(home, "mcp.json"), JSON.stringify({ mcpServers: { acme: { url: `http://127.0.0.1:${port}/mcp`, exposure: "deferred", oauth: { clientName: "Shepherd" } } } }));
  const env = { PATH: `${fakeBrowserBin(dir)}:${process.env.PATH}` };
  const state = async () => JSON.parse((await runPiCli(home, ["mcp", "list", "--json"], { env })).stdout).servers[0];
  assert.equal((await state()).state, "needs-auth");
  const login = await runPiCli(home, ["mcp", "login", "acme", "--timeout", "30"], { env });
  assert.equal(login.status, 0, login.stderr);
  const url = login.stdout.match(/^Sign in to MCP server "acme" in your browser:\n(http\S+)$/m)?.[1];
  assert.ok(url, `the URL is on stdout: ${login.stdout}`);
  assert.match(fs.readFileSync(path.join(dir, "opened.txt"), "utf8"), /\/auth\/authorize\?/, "pi opened the page itself");
  assert.equal(fs.statSync(path.join(home, "mcp-auth.json")).mode & 0o777, 0o600);
  const registered = await (await fetch(`http://127.0.0.1:${port}/log`)).json();
  assert.match(registered.find((r) => r.path === "/auth/register").body, /"client_name":"Shepherd"/, "oauth.clientName is what the server sees");
  assert.equal((await state()).state, "connected");
  assert.deepEqual((await state()).tools, ["list_issues", "create_issue"]);
  assert.equal((await runPiCli(home, ["mcp", "logout", "acme"], { env })).status, 0);
  assert.equal((await state()).state, "needs-auth");
  assert.deepEqual(Object.keys(JSON.parse(fs.readFileSync(path.join(home, "mcp-auth.json"), "utf8"))), [], "its credentials are deleted");
});

test("codemode's nested calls arrive as tool_execution events with a parentToolCallId, when codemode is switched on", { timeout: 120000 }, async (t) => {
  await withPi(t, {
    settings: { extensions: ["+builtin:mcp", "+builtin:tool-search", "+builtin:codemode"] },
    files: mcpFile({ fake: server({}) }),
    onRequest: script([tool("codemode", { code: "const a = await tools.mcp__fake__echo({text: 'one'}); const b = await tools.mcp__fake__add({a: 1, b: 2}); return JSON.stringify([a, b]);" })]),
  }, async (pi) => {
    await connected(pi, "fake");
    const turn = await pi.prompt("codemode");
    const events = pi.toolEvents(turn.events).filter((e) => e.type !== "tool_execution_update");
    const nested = events.filter((e) => e.parentToolCallId);
    assert.deepEqual(nested.map((e) => [e.type, e.toolCallId, e.parentToolCallId, e.toolName]), [
      ["tool_execution_start", "call_1/1", "call_1", "mcp__fake__echo"], ["tool_execution_end", "call_1/1", "call_1", "mcp__fake__echo"],
      ["tool_execution_start", "call_1/2", "call_1", "mcp__fake__add"], ["tool_execution_end", "call_1/2", "call_1", "mcp__fake__add"],
    ]);
    const parent = events.filter((e) => !e.parentToolCallId);
    assert.deepEqual(parent.map((e) => [e.type, e.toolCallId, e.toolName]), [["tool_execution_start", "call_1", "codemode"], ["tool_execution_end", "call_1", "codemode"]]);
  });
});

test("an extension can register a server for the session, and the file's server of the same name wins", { timeout: 120000 }, async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-mcp-reg-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const extension = path.join(dir, "register.ts");
  fs.writeFileSync(extension, `export default function (pi) {
    pi.registerMcpServer("registered", { command: ${JSON.stringify(process.execPath)}, args: [${JSON.stringify(stdio)}], exposure: "direct" });
    pi.registerMcpServer("shared", { command: "/nonexistent/binary", exposure: "direct" });
  }`);
  await withPi(t, {
    settings: { extensions: OFF }, args: [...AGENT_FLAGS, "-e", extension],
    files: mcpFile({ shared: server({}, { exposure: "direct" }) }),
    onRequest: script([tool("mcp__registered__echo", { text: "x" }), tool("mcp__shared__echo", { text: "y" })]),
  }, async (pi) => {
    const turn = await pi.prompt("both");
    const texts = pi.toolEvents(turn.events).filter((e) => e.type === "tool_execution_end").map((e) => e.result.content[0].text);
    assert.deepEqual(texts, ["echo: x", "echo: y"]);
  });
});
