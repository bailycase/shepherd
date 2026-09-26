// The MCP extension and its client: the mcp tool and direct tools against a scripted stdio server
// (fixtures/fake-mcp-stdio.mjs) and an in-test HTTP server (Streamable HTTP, legacy SSE, 401 and
// 403), credentials over a stand-in Shepherd socket, idle stop, a server that can't start, the
// duplicate `mcp` name, children killed when pi exits, and the probe the app runs. No network
// beyond 127.0.0.1, only temporary files.
import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as http from "node:http";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const require = createRequire(path.join(pkg, "package.json"));
const { createJiti } = require("jiti");
const aliases = {
  "@earendil-works/pi-coding-agent": path.join(pkg, "dist/index.js"),
  "@earendil-works/pi-ai": path.join(pkg, "node_modules/@earendil-works/pi-ai/dist/index.js"),
  typebox: path.join(pkg, "node_modules/typebox/build/index.mjs"),
};
const jiti = createJiti(import.meta.url, { alias: aliases });
const extensionFile = path.join(root, "Extensions/shepherd-mcp.ts");
const clientFile = path.join(root, "Extensions/shepherd-mcp-client.mjs");
const { default: install, directToolName, projectConfigPath, parseSettings } = await jiti.import(extensionFile);
const client = await import(clientFile);
const fixture = path.join(root, "Tests/Extensions/fixtures/fake-mcp-stdio.mjs");

const KEYS = ["SHEPHERD_EXT_MCP", "SHEPHERD_AGENT_ID", "SHEPHERD_SOCKET", "SHEPHERD_EXT_MCP_CONFIG",
  "SHEPHERD_EXT_MCP_CACHE", "SHEPHERD_EXT_MCP_PROJECT"];

function withEnv(values, body) {
  const saved = KEYS.map((key) => process.env[key]);
  for (const key of KEYS) {
    if (values[key] === undefined) delete process.env[key]; else process.env[key] = values[key];
  }
  try {
    return body();
  } finally {
    KEYS.forEach((key, index) => {
      if (saved[index] === undefined) delete process.env[key]; else process.env[key] = saved[index];
    });
  }
}

async function eventually(what, check, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`never happened: ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** A pi stand-in: handlers, registered tools, the active set, and tools other sources own. */
function fakePi(others = []) {
  delete globalThis[Symbol.for("shepherd.mcp.proxyName")];
  const handlers = {};
  const tools = new Map();
  let active = new Set(others.map((tool) => tool.name));
  return {
    handlers, tools,
    active: () => active,
    async emit(name, event = {}, ctx = {}) {
      let last;
      for (const handler of handlers[name] ?? []) last = await handler({ type: name, ...event }, ctx);
      return last;
    },
    api: {
      on: (name, handler) => { (handlers[name] ??= []).push(handler); },
      registerTool: (tool) => {
        const isNew = !tools.has(tool.name);
        tools.set(tool.name, tool);
        if (isNew) active.add(tool.name);
      },
      getAllTools: () => [
        ...others.map((tool) => ({ name: tool.name, description: "", parameters: {}, sourceInfo: { path: tool.path } })),
        ...[...tools.values()].map((tool) => ({ name: tool.name, description: tool.description, parameters: tool.parameters,
          sourceInfo: { path: extensionFile } })),
      ],
      getActiveTools: () => [...active],
      setActiveTools: (names) => { active = new Set(names); },
    },
  };
}

/** Runs `body` with the extension against a stand-in Shepherd socket; `answer(frame)` replies to requests. */
async function withMCP({ servers, cache, answer = () => null, others = [], project, cwd }, body) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-mcp-"));
  const socketPath = path.join(dir, "s");
  const configPath = path.join(dir, "mcp.json");
  const cachePath = path.join(dir, "tools.json");
  fs.writeFileSync(configPath, JSON.stringify({ mcpServers: servers, other: { kept: true } }));
  if (cache) fs.writeFileSync(cachePath, JSON.stringify(cache));
  const frames = [];
  const sockets = new Set();
  const app = net.createServer((socket) => {
    sockets.add(socket);
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      buffer += chunk;
      let index;
      while ((index = buffer.indexOf("\n")) >= 0) {
        const frame = JSON.parse(buffer.slice(0, index));
        buffer = buffer.slice(index + 1);
        frames.push(frame);
        const reply = answer(frame);
        if (reply) socket.write(JSON.stringify({ id: frame.id, ...reply }) + "\n");
      }
    });
    socket.on("error", () => {});
  });
  await new Promise((resolve) => app.listen(socketPath, resolve));
  const pi = fakePi(others);
  withEnv({
    SHEPHERD_EXT_MCP: extensionFile, SHEPHERD_AGENT_ID: "a1", SHEPHERD_SOCKET: socketPath,
    SHEPHERD_EXT_MCP_CONFIG: configPath, SHEPHERD_EXT_MCP_CACHE: cachePath,
    SHEPHERD_EXT_MCP_PROJECT: project ? "1" : undefined,
  }, () => install(pi.api));
  const reports = () => frames.filter((frame) => frame.type === "mcpReport").map((frame) => frame.report);
  const call = (name, params, signal) => pi.tools.get(name).execute(`call-${Math.random()}`, params, signal, undefined, {});
  try {
    await pi.emit("session_start", { reason: "startup" }, { cwd: cwd ?? dir });
    await body({ pi, frames, reports, call, dir, configPath });
  } finally {
    await pi.emit("session_shutdown", { reason: "quit" });
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => app.close(resolve));
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

const stdioServer = (extra = {}) => ({ command: process.execPath, args: [fixture], ...extra });

function text(result) {
  return result.content.filter((item) => item.type === "text").map((item) => item.text).join("\n");
}

test("the extension is inert without its environment", () => {
  const pi = fakePi();
  withEnv({}, () => install(pi.api));
  assert.equal(Object.keys(pi.handlers).length, 0);
  assert.equal(pi.tools.size, 0);
});

test("settings default when missing, and a direct tool's name is sanitized and capped", () => {
  assert.deepEqual(parseSettings({}), { enabled: true, start: "whenUsed", idleMinutes: 10, exposure: "proxy", tools: undefined, timeoutSeconds: 30 });
  assert.equal(parseSettings({ shepherd: { enabled: false } }).enabled, false);
  assert.equal(directToolName("My-Server.io", "list issues"), "my_server_io_list_issues");
  const long = directToolName("s".repeat(40), "t".repeat(40));
  assert.equal(long.length, 64);
  assert.match(long, /^s{40}_t{14}_[0-9a-f]{8}$/);
});

test("variables expand from the environment; keychain references wait for the app", () => {
  const spec = client.resolveEntry("gh", {
    type: "http", url: "https://example.test/${PATH_PART:-mcp}",
    headers: { Authorization: "Bearer ${GITHUB_TOKEN}", "X-Key": "${keychain:gh/API_KEY}" },
  }, { GITHUB_TOKEN: "t0k" });
  assert.equal(spec.kind, "http");
  assert.equal(spec.url, "https://example.test/mcp");
  assert.equal(spec.headers.Authorization, "Bearer t0k");
  assert.deepEqual(spec.missingSecrets, ["API_KEY"]);
  const resolved = client.resolveEntry("gh", { url: "https://x.test", headers: { Authorization: "Bearer ${NOPE}" } }, {});
  assert.deepEqual(resolved.headers, {}, "an empty bearer is dropped rather than sent");
  assert.deepEqual(resolved.missingVariables, ["NOPE"]);
  assert.equal(client.transportKind({ type: "sse", url: "https://x" }), "sse");
  assert.equal(client.transportKind({ type: "streamableHttp", url: "https://x" }), "http");
  assert.equal(client.transportKind({ command: "uvx" }), "stdio");
  assert.deepEqual(client.challengeScopes('Bearer error="insufficient_scope", scope="issues:write read"'), ["issues:write", "read"]);
});

test("the mcp tool searches, describes and calls a stdio server's tools", async () => {
  await withMCP({ servers: { fake: stdioServer() } }, async ({ pi, call, reports }) => {
    assert.ok(pi.tools.has("mcp"));
    assert.match(pi.tools.get("mcp").description, /\(fake\)/);
    assert.match(text(await call("mcp", { action: "search", query: "" })), /fake — idle, tools not listed yet/);
    assert.equal(reports().length, 0, "a whenUsed server doesn't start until it's used");

    const found = text(await call("mcp", { action: "search", query: "echo" }));
    assert.match(found, /fake\/echo — Echo the text back\./);
    const described = text(await call("mcp", { action: "describe", server: "fake", tool: "echo" }));
    assert.match(described, /"required": \[\n\s+"text"/);

    const echoed = await call("mcp", { action: "call", server: "fake", tool: "echo", arguments: { text: "hi" } });
    assert.equal(text(echoed), "echo: hi");
    assert.deepEqual(echoed.details, { mcp: { server: "fake", tool: "echo", outcome: "done" } });
    assert.match(text(await call("mcp", { action: "call", server: "fake", tool: "add", arguments: { a: 2, b: 3 } })), /"sum": 5/);

    const failing = pi.tools.get("mcp").execute("failing-call", { action: "call", server: "fake", tool: "fail" }, undefined, undefined, {});
    await assert.rejects(failing, /the database is down/);
    assert.deepEqual(await pi.emit("tool_result", { toolCallId: "failing-call", isError: true }),
      { details: { mcp: { server: "fake", tool: "fail", outcome: "failed" } } });

    const connected = reports().find((report) => report.status.state === "connected");
    assert.equal(connected.server, "fake");
    assert.equal(connected.transport, "stdio");
    assert.equal(connected.serverName, "Fake MCP");
    assert.deepEqual(connected.tools.map((tool) => tool.name), ["echo", "add", "fail", "slow", "env", "grow"], "every page is listed");
    assert.equal(reports()[0].status.state, "starting");
  });
});

test("a tools/list_changed notification lists again and reports the new tools", async () => {
  await withMCP({ servers: { fake: stdioServer() } }, async ({ call, reports }) => {
    await call("mcp", { action: "call", server: "fake", tool: "grow" });
    await eventually("the grown tool reported", () => reports().some((report) => report.tools?.some((tool) => tool.name === "grown")));
    assert.equal(text(await call("mcp", { action: "call", server: "fake", tool: "grown" })), "hello from grown");
  });
});

test("cancelling a call sends notifications/cancelled", async () => {
  const log = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "sh-mcp-log-")), "log");
  await withMCP({ servers: { fake: stdioServer({ env: { FAKE_MCP_LOG: log } }) } }, async ({ call }) => {
    await call("mcp", { action: "search", query: "slow" });
    const controller = new AbortController();
    const pending = call("mcp", { action: "call", server: "fake", tool: "slow", arguments: { ms: 10_000 } }, controller.signal);
    setTimeout(() => controller.abort(), 50);
    await assert.rejects(pending, /cancelled/);
    await eventually("the server heard the cancellation", () => fs.readFileSync(log, "utf8").includes('"cancelled"'));
  });
});

test("direct tools come from the cache without starting the server, and a taken name is skipped", async () => {
  const pidfile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "sh-mcp-pid-")), "pid");
  const entry = stdioServer({ env: { FAKE_MCP_PIDFILE: pidfile } });
  const servers = { fake: { ...entry, shepherd: { exposure: "direct", tools: ["echo", "add", "env"] } } };
  const cache = { fake: { entry, listedAtMs: 1, tools: [
    { name: "echo", description: "Echo the text back.", inputSchema: { $schema: "x", type: "object", properties: { text: { type: "string" } } } },
    { name: "add", description: "Add two numbers.", inputSchema: { type: "object" } },
    { name: "env", description: "Reads a variable.", inputSchema: { type: "string" } },
    { name: "fail", description: "Not chosen.", inputSchema: { type: "object" } },
  ] } };
  await withMCP({ servers, cache, others: [{ name: "fake_add", path: "/elsewhere/other.ts" }] }, async ({ pi, reports }) => {
    assert.ok(pi.tools.has("fake_echo"));
    assert.ok(!pi.tools.has("fake_add"), "a name another extension owns is left alone");
    assert.ok(!pi.tools.has("fake_fail"), "only the chosen tools");
    assert.ok(!pi.tools.has("mcp"), "no proxy without a proxy server");
    assert.deepEqual(pi.tools.get("fake_echo").parameters, { type: "object", properties: { text: { type: "string" } } });
    assert.deepEqual(pi.tools.get("fake_env").parameters, { type: "object", additionalProperties: true });
    assert.equal(fs.existsSync(pidfile), false, "the cache is enough to register");

    const result = await pi.tools.get("fake_echo").execute("c1", { text: "direct" }, undefined, undefined, {});
    assert.equal(text(result), "echo: direct");
    assert.deepEqual(result.details.mcp, { server: "fake", tool: "echo", outcome: "done" });
    await eventually("the skip is reported", () =>
      reports().some((report) => /skipped 1 tools whose names are taken/.test(report.status.message ?? "")));
  });
});

test("a direct server with no cache connects at session start and registers its tools", async () => {
  await withMCP({ servers: { fake: { ...stdioServer(), shepherd: { exposure: "direct", tools: ["echo"] } } } }, async ({ pi }) => {
    await eventually("fake_echo registered", () => pi.tools.has("fake_echo"));
    assert.ok(pi.active().has("fake_echo"));
  });
});

test("the proxy is shepherd_mcp when another extension already has mcp", async () => {
  await withMCP({ servers: { fake: stdioServer() }, others: [{ name: "mcp", path: "/Users/someone/.pi/agent/extensions/mcp.ts" }] },
    async ({ pi, call }) => {
      assert.ok(pi.tools.has("shepherd_mcp"));
      assert.ok(!pi.tools.has("mcp"), "the user's own mcp is never shadowed");
      assert.match(text(await call("shepherd_mcp", { action: "search", query: "" })), /fake/);
    });
});

test("a whenUsed server stops after its idle time", async () => {
  const pidfile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "sh-mcp-pid-")), "pid");
  const servers = { fake: { ...stdioServer({ env: { FAKE_MCP_PIDFILE: pidfile } }), shepherd: { idleMinutes: 0.004 } } };
  await withMCP({ servers }, async ({ call, reports }) => {
    await call("mcp", { action: "call", server: "fake", tool: "echo", arguments: { text: "x" } });
    const pid = Number(fs.readFileSync(pidfile, "utf8"));
    assert.ok(alive(pid));
    await eventually("the idle report", () => reports().at(-1)?.status.state === "idle");
    await eventually("the server process gone", () => !alive(pid));
    assert.equal(text(await call("mcp", { action: "call", server: "fake", tool: "echo", arguments: { text: "again" } })), "echo: again");
  });
});

test("a server that can't start fails the call with why, and reports an error", async () => {
  const servers = {
    missing: { command: "shepherd-no-such-mcp-server" },
    crashing: stdioServer({ env: { FAKE_MCP_CRASH: "1" } }),
  };
  await withMCP({ servers }, async ({ call, reports }) => {
    await assert.rejects(call("mcp", { action: "call", server: "missing", tool: "x" }), /shepherd-no-such-mcp-server isn't installed/);
    await assert.rejects(call("mcp", { action: "call", server: "crashing", tool: "x" }), /can't read its config/);
    await assert.rejects(call("mcp", { action: "call", server: "nope", tool: "x" }), /no MCP server named "nope"/);
    await eventually("both errors reported", () => reports().filter((report) => report.status.state === "error").length >= 2);
    const errors = reports().filter((report) => report.status.state === "error").map((report) => report.server);
    assert.deepEqual(errors.sort(), ["crashing", "missing"]);
  });
});

test("keychain references ask the app at connect, and SHEPHERD_ variables never reach the server", async () => {
  const servers = { fake: stdioServer({ env: { SECRET_TOKEN: "${keychain:fake/SECRET_TOKEN}" } }) };
  const answer = (frame) => frame.type === "mcpCredentials"
    ? { type: "mcpCredentials", credentials: { headers: {}, env: { SECRET_TOKEN: "s3cret" } } }
    : null;
  await withMCP({ servers, answer }, async ({ call, frames }) => {
    assert.equal(text(await call("mcp", { action: "call", server: "fake", tool: "env", arguments: { name: "SECRET_TOKEN" } })), "SECRET_TOKEN=s3cret");
    assert.equal(text(await call("mcp", { action: "call", server: "fake", tool: "env", arguments: { name: "SHEPHERD_SOCKET" } })), "SHEPHERD_SOCKET=");
    const asked = frames.find((frame) => frame.type === "mcpCredentials");
    assert.deepEqual({ ...asked, id: 0 }, { type: "mcpCredentials", agentID: "a1", server: "fake", reason: "connect", id: 0 });
  });
});

test("a missing secret says so in the agent's words", async () => {
  const servers = { grafana: stdioServer({ env: { GRAFANA_SERVICE_ACCOUNT_TOKEN: "${keychain:grafana/GRAFANA_SERVICE_ACCOUNT_TOKEN}" } }) };
  const answer = (frame) => frame.type === "mcpCredentials"
    ? { type: "error", code: "missing_secret", message: "grafana's GRAFANA_SERVICE_ACCOUNT_TOKEN isn't set: add it in Settings ▸ MCP servers." }
    : null;
  await withMCP({ servers, answer }, async ({ call }) => {
    await assert.rejects(call("mcp", { action: "call", server: "grafana", tool: "echo" }), /GRAFANA_SERVICE_ACCOUNT_TOKEN isn't set/);
  });
});

test("a repo's .mcp.json is read only when allowed, and the search stops at the repository", async () => {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "sh-mcp-repo-"));
  fs.mkdirSync(path.join(repo, ".git"));
  fs.mkdirSync(path.join(repo, "src"));
  fs.writeFileSync(path.join(repo, ".mcp.json"), JSON.stringify({ mcpServers: { repo: stdioServer(), fake: { command: "overridden" } } }));
  assert.equal(projectConfigPath(path.join(repo, "src")), path.join(repo, ".mcp.json"));
  await withMCP({ servers: { fake: stdioServer() }, project: true, cwd: path.join(repo, "src") }, async ({ call, reports }) => {
    assert.equal(text(await call("mcp", { action: "call", server: "repo", tool: "echo", arguments: { text: "r" } })), "echo: r");
    assert.equal(text(await call("mcp", { action: "call", server: "fake", tool: "echo", arguments: { text: "g" } })), "echo: g", "global wins");
    assert.ok(!reports().some((report) => report.server === "repo"), "repo servers aren't reported to Settings");
  });
  await withMCP({ servers: { fake: stdioServer() }, cwd: path.join(repo, "src") }, async ({ call }) => {
    await assert.rejects(call("mcp", { action: "call", server: "repo", tool: "echo" }), /no MCP server named "repo"/);
  });
  fs.rmSync(repo, { recursive: true, force: true });
});

test("a changed config removes a server and its connection", async () => {
  await withMCP({ servers: { fake: stdioServer(), other: stdioServer() } }, async ({ pi, call, configPath }) => {
    await call("mcp", { action: "call", server: "fake", tool: "echo", arguments: { text: "1" } });
    fs.writeFileSync(configPath, JSON.stringify({ mcpServers: { other: stdioServer() } }));
    fs.utimesSync(configPath, new Date(), new Date(Date.now() + 5_000));
    await assert.rejects(call("mcp", { action: "call", server: "fake", tool: "echo" }), /no MCP server named "fake"/);
    assert.match(pi.tools.get("mcp").description, /\(other\)/);
  });
});

// ---- HTTP ---------------------------------------------------------------------------------------

/** An MCP server on 127.0.0.1: `streamable` (JSON, or SSE for tools/call), `sse` (legacy), and auth modes. */
async function httpServer({ mode = "streamable", token, scopeNeeded } = {}) {
  const seen = [];
  const streams = new Set();
  let legacy;
  const handle = (message) => {
    if (message.method === "initialize") {
      return { jsonrpc: "2.0", id: message.id, result: { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "remote" } } };
    }
    if (message.method === "tools/list") {
      return { jsonrpc: "2.0", id: message.id, result: { tools: [{ name: "whoami", description: "Who you are.", inputSchema: { type: "object" } }] } };
    }
    if (message.method === "tools/call") {
      return { jsonrpc: "2.0", id: message.id, result: { content: [{ type: "text", text: `you are ${seen.at(-1).auth ?? "nobody"}` }] } };
    }
    return undefined;
  };
  const server = http.createServer((req, res) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", () => {
      const auth = req.headers.authorization;
      seen.push({ method: req.method, url: req.url, auth, session: req.headers["mcp-session-id"], version: req.headers["mcp-protocol-version"] });
      if (token && auth !== `Bearer ${token}`) {
        res.writeHead(401, { "WWW-Authenticate": `Bearer resource_metadata="http://127.0.0.1/.well-known/oauth-protected-resource"` });
        return res.end();
      }
      const message = body ? JSON.parse(body) : undefined;
      if (scopeNeeded && message?.method === "tools/call") {
        res.writeHead(403, { "WWW-Authenticate": `Bearer error="insufficient_scope", scope="${scopeNeeded}"` });
        return res.end();
      }
      if (mode === "sse") {
        if (req.method === "GET" && req.url === "/mcp") {
          res.writeHead(200, { "Content-Type": "text/event-stream" });
          res.write("event: endpoint\ndata: /messages?session=1\n\n");
          legacy = res;
          streams.add(res);
          return;
        }
        if (req.method === "POST" && req.url.startsWith("/messages")) {
          res.writeHead(202);
          res.end();
          const reply = handle(message);
          if (reply) legacy.write(`event: message\ndata: ${JSON.stringify(reply)}\n\n`);
          return;
        }
        res.writeHead(405);
        return res.end();
      }
      if (req.method === "GET") {
        res.writeHead(405);
        return res.end();
      }
      if (req.method === "DELETE") {
        res.writeHead(200);
        return res.end();
      }
      const reply = handle(message);
      if (!reply) {
        res.writeHead(202);
        return res.end();
      }
      const headers = message.method === "initialize" ? { "Mcp-Session-Id": "sess-1" } : {};
      if (message.method === "tools/call") {
        res.writeHead(200, { "Content-Type": "text/event-stream", ...headers });
        res.write(": keep-alive\n\n");
        res.end(`event: message\ndata: ${JSON.stringify(reply)}\n\n`);
        return;
      }
      res.writeHead(200, { "Content-Type": "application/json", ...headers });
      res.end(JSON.stringify(reply));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    url: `http://127.0.0.1:${server.address().port}/mcp`,
    seen,
    close: () => new Promise((resolve) => {
      for (const stream of streams) stream.destroy();
      server.closeAllConnections?.();
      server.close(resolve);
    }),
  };
}

test("Streamable HTTP: a 401 asks the app for credentials and retries with the bearer", async () => {
  const remote = await httpServer({ token: "good" });
  const answer = (frame) => frame.type === "mcpCredentials"
    ? { type: "mcpCredentials", credentials: { bearer: "good", headers: {}, env: {}, expiresAtMs: Date.now() + 3_600_000 } }
    : null;
  try {
    await withMCP({ servers: { linear: { type: "http", url: remote.url } }, answer }, async ({ call, frames, reports }) => {
      const result = await call("mcp", { action: "call", server: "linear", tool: "whoami" });
      assert.equal(text(result), "you are Bearer good", "an SSE-framed reply to tools/call is read");
      const asked = frames.filter((frame) => frame.type === "mcpCredentials");
      assert.equal(asked.length, 1);
      assert.equal(asked[0].reason, "unauthorized");
      assert.match(asked[0].challenge, /resource_metadata=/);
      const called = remote.seen.find((request) => request.method === "POST" && request.version);
      assert.equal(called.session, "sess-1", "Mcp-Session-Id is sent after initialize");
      assert.equal(called.version, "2025-06-18");
      assert.equal(reports().find((report) => report.status.state === "connected").transport, "streamableHTTP");
    });
    await eventually("the session ended on stop", () => remote.seen.some((request) => request.method === "DELETE"));
  } finally {
    await remote.close();
  }
});

test("Streamable HTTP: the app's needs_sign_in becomes the call's failure and the row's state", async () => {
  const remote = await httpServer({ token: "good" });
  const answer = (frame) => frame.type === "mcpCredentials"
    ? { type: "error", code: "needs_sign_in", message: "notion needs you to sign in: Settings ▸ MCP servers." }
    : null;
  try {
    await withMCP({ servers: { notion: { type: "http", url: remote.url } }, answer }, async ({ pi, reports }) => {
      const pending = pi.tools.get("mcp").execute("signin-call", { action: "call", server: "notion", tool: "whoami" }, undefined, undefined, {});
      await assert.rejects(pending, /notion needs you to sign in/);
      assert.deepEqual(await pi.emit("tool_result", { toolCallId: "signin-call" }),
        { details: { mcp: { server: "notion", tool: "whoami", outcome: "needsSignIn" } } });
      await eventually("the needsSignIn report", () => reports().at(-1)?.status.state === "needsSignIn");
    });
  } finally {
    await remote.close();
  }
});

test("Streamable HTTP: 403 insufficient_scope asks again and reports the missing scopes", async () => {
  const remote = await httpServer({ scopeNeeded: "issues:write" });
  const answer = (frame) => frame.type === "mcpCredentials"
    ? { type: "error", code: "needs_scopes", message: "linear needs more access (issues:write): sign in again in Settings ▸ MCP servers." }
    : null;
  try {
    await withMCP({ servers: { linear: { url: remote.url } }, answer }, async ({ call, frames, reports }) => {
      await assert.rejects(call("mcp", { action: "call", server: "linear", tool: "whoami" }), /needs more access \(issues:write\)/);
      assert.equal(frames.find((frame) => frame.type === "mcpCredentials").reason, "forbidden");
      const last = await eventually("the needsScopes report", () => reports().find((report) => report.status.state === "needsScopes"));
      assert.deepEqual(last.status.scopes, ["issues:write"]);
    });
  } finally {
    await remote.close();
  }
});

test("a server that refuses the Streamable POST falls back to legacy HTTP+SSE", async () => {
  const remote = await httpServer({ mode: "sse" });
  try {
    await withMCP({ servers: { old: { url: remote.url } } }, async ({ call, reports }) => {
      assert.equal(text(await call("mcp", { action: "call", server: "old", tool: "whoami" })), "you are nobody");
      assert.equal(reports().find((report) => report.status.state === "connected").transport, "sse");
    });
  } finally {
    await remote.close();
  }
});

// ---- process lifetime and the probe -------------------------------------------------------------

test("stdio servers die with pi", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-mcp-exit-"));
  const pidfile = path.join(dir, "pid");
  const config = path.join(dir, "mcp.json");
  fs.writeFileSync(config, JSON.stringify({ mcpServers: { fake: stdioServer({ env: { FAKE_MCP_PIDFILE: pidfile, FAKE_MCP_LINGER: "1" } }) } }));
  const script = path.join(dir, "pi.mjs");
  fs.writeFileSync(script, `
    import { createRequire } from "node:module";
    const require = createRequire(${JSON.stringify(path.join(pkg, "package.json"))});
    const { createJiti } = require("jiti");
    const jiti = createJiti(import.meta.url, { alias: ${JSON.stringify(aliases)} });
    const { default: install } = await jiti.import(${JSON.stringify(extensionFile)});
    const tools = new Map();
    const handlers = {};
    setInterval(() => {}, 1000); // pi itself keeps the process alive; the extension never does
    install({ on: (n, h) => (handlers[n] ??= []).push(h), registerTool: (t) => tools.set(t.name, t),
      getAllTools: () => [], getActiveTools: () => [...tools.keys()], setActiveTools: () => {} });
    for (const h of handlers.session_start) await h({}, { cwd: ${JSON.stringify(dir)} });
    await tools.get("mcp").execute("c", { action: "call", server: "fake", tool: "echo", arguments: { text: "x" } });
    process.exit(0);
  `);
  const child = spawn(process.execPath, [script], {
    env: { ...process.env, SHEPHERD_EXT_MCP: extensionFile, SHEPHERD_AGENT_ID: "a1", SHEPHERD_SOCKET: path.join(dir, "none"),
      SHEPHERD_EXT_MCP_CONFIG: config },
    stdio: ["ignore", "ignore", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const code = await new Promise((resolve) => child.on("exit", resolve));
  assert.equal(code, 0, stderr);
  const pid = Number(fs.readFileSync(pidfile, "utf8"));
  await eventually("the server killed with pi", () => !alive(pid), 3_000);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("the probe lists a server's tools as one JSON line", async () => {
  const run = (input) => new Promise((resolve) => {
    const child = spawn(process.execPath, [clientFile, "probe"], { stdio: ["pipe", "pipe", "inherit"] });
    let out = "";
    child.stdout.on("data", (chunk) => { out += chunk; });
    child.on("exit", () => resolve(JSON.parse(out)));
    child.stdin.end(JSON.stringify(input));
  });
  const listed = await run({ name: "fake", entry: stdioServer(), timeoutSeconds: 10 });
  assert.equal(listed.ok, true);
  assert.equal(listed.transport, "stdio");
  assert.equal(listed.serverName, "Fake MCP");
  assert.equal(listed.tools.length, 6);

  const remote = await httpServer({ token: "good" });
  try {
    const refused = await run({ name: "linear", entry: { type: "http", url: remote.url }, timeoutSeconds: 10 });
    assert.equal(refused.ok, false);
    assert.equal(refused.status.state, "needsSignIn");
    assert.match(refused.challenge, /resource_metadata/);
  } finally {
    await remote.close();
  }
  const missing = await run({ name: "x", entry: { command: "shepherd-no-such-mcp-server" }, timeoutSeconds: 5 });
  assert.deepEqual(missing.status, { state: "error", scopes: [], message: "shepherd-no-such-mcp-server isn't installed (not found on PATH)" });
});

// Real pi in RPC mode, with a user extension that already registers `mcp`: pi loads Shepherd's
// `-e` extension first, so registering `mcp` at load would shadow the user's. Ours becomes
// shepherd_mcp at session start, both reach the model, pi reports no conflict, and a call runs.
test("real Pi RPC: beside a user's own mcp tool, Shepherd's is shepherd_mcp and calls through", { timeout: 120000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-mcp-pi-"));
  const requests = [];
  const provider = http.createServer(async (req, res) => {
    let raw = ""; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw); requests.push(body);
    const last = body.messages.at(-1);
    const delta = last.role === "tool" ? { content: "Noted." } : { tool_calls: [{ index: 0, id: "mcp-call", type: "function", function: {
      name: "shepherd_mcp", arguments: JSON.stringify({ action: "call", server: "fake", tool: "echo", arguments: { text: "from pi" } }) } }] };
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(`data: ${JSON.stringify({ id: "f", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta, finish_reason: null }] })}\n\n`);
    res.end(`data: ${JSON.stringify({ id: "f", object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: delta.tool_calls ? "tool_calls" : "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } })}\n\ndata: [DONE]\n\n`);
  });
  await new Promise((resolve) => provider.listen(0, "127.0.0.1", resolve));
  const socketPath = path.join(dir, "s.sock");
  const frames = [];
  const shepherd = net.createServer((socket) => {
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      for (let nl; (nl = buffer.indexOf("\n")) >= 0; buffer = buffer.slice(nl + 1)) frames.push(JSON.parse(buffer.slice(0, nl)));
    });
    socket.on("error", () => {});
  });
  await new Promise((resolve) => shepherd.listen(socketPath, resolve));
  const config = path.join(dir, "config");
  fs.mkdirSync(config);
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${provider.address().port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: [{ id: "fixture", name: "fixture", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  const mcpConfig = path.join(dir, "mcp.json");
  fs.writeFileSync(mcpConfig, JSON.stringify({ mcpServers: { fake: stdioServer() } }));
  const theirs = path.join(dir, "their-mcp.ts");
  fs.writeFileSync(theirs, `export default function (pi) {
      pi.registerTool({ name: "mcp", label: "their mcp", description: "The user's own MCP adapter.",
        parameters: { type: "object", properties: {} }, async execute() { return { content: [{ type: "text", text: "theirs" }] }; } });
    }`);
  const env = { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1", SHEPHERD_AGENT_ID: "fixture",
    SHEPHERD_SOCKET: socketPath, SHEPHERD_EXT_MCP: extensionFile, SHEPHERD_EXT_MCP_CONFIG: mcpConfig,
    SHEPHERD_EXT_MCP_CACHE: path.join(dir, "tools.json") };
  const pi = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--no-session", "-ne", "-ns", "-np",
    "--model", "fixture/fixture", "-e", extensionFile, "-e", theirs], { cwd: dir, env, stdio: ["pipe", "pipe", "pipe"] });
  const events = [];
  let out = "", err = "";
  pi.stdout.on("data", (chunk) => {
    out += chunk;
    for (let nl; (nl = out.indexOf("\n")) >= 0; out = out.slice(nl + 1)) {
      try { events.push(JSON.parse(out.slice(0, nl))); } catch {}
    }
  });
  pi.stderr.on("data", (chunk) => { err += chunk; });
  try {
    pi.stdin.write(JSON.stringify({ type: "prompt", message: "go" }) + "\n");
    await eventually("the turn to settle", () => events.some((e) => e.type === "agent_settled"), 60_000);
    const offered = requests[0].tools.map((tool) => tool.function.name);
    assert.ok(offered.includes("mcp") && offered.includes("shepherd_mcp"), `both tools reach the model: ${offered}`);
    assert.equal(requests[0].tools.find((tool) => tool.function.name === "mcp").function.description, "The user's own MCP adapter.");
    const end = events.find((e) => e.type === "tool_execution_end" && e.toolName === "shepherd_mcp");
    assert.equal(end.isError, false, JSON.stringify(end.result));
    assert.equal(end.result.content[0].text, "echo: from pi");
    assert.deepEqual(end.result.details, { mcp: { server: "fake", tool: "echo", outcome: "done" } });
    assert.doesNotMatch(err + JSON.stringify(events), /conflicts with/, "pi reports no clash");
    await eventually("the connected report", () => frames.some((f) => f.type === "mcpReport" && f.report.status.state === "connected"));
  } catch (error) {
    error.message += `\npi stderr:\n${err}`;
    throw error;
  } finally {
    pi.kill();
    await new Promise((resolve) => pi.once("exit", resolve));
    provider.close(); shepherd.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// Shepherd stops an agent's pi by SIGTERMing its process group (RPCSession.kill), and a closed
// terminal sends SIGHUP. A withSession server that ignores stdin closing still dies with pi.
for (const signal of ["SIGTERM", "SIGHUP"]) {
  test(`real Pi RPC: a stdio server dies when pi gets ${signal}`, { timeout: 60000 }, async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-mcp-sig-"));
    const pidfile = path.join(dir, "pid");
    const mcpConfig = path.join(dir, "mcp.json");
    fs.mkdirSync(path.join(dir, "config"));
    fs.writeFileSync(mcpConfig, JSON.stringify({ mcpServers: { fake: {
      ...stdioServer({ env: { FAKE_MCP_PIDFILE: pidfile, FAKE_MCP_LINGER: "1" } }), shepherd: { start: "withSession" } } } }));
    const env = { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: path.join(dir, "config"), PI_OFFLINE: "1",
      SHEPHERD_AGENT_ID: "fixture", SHEPHERD_SOCKET: path.join(dir, "none"), SHEPHERD_EXT_MCP: extensionFile,
      SHEPHERD_EXT_MCP_CONFIG: mcpConfig };
    const pi = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--no-session", "-ne", "-ns", "-np",
      "-e", extensionFile], { cwd: dir, env, stdio: ["pipe", "ignore", "pipe"] });
    let err = "";
    pi.stderr.on("data", (chunk) => { err += chunk; });
    try {
      await eventually("the server started with the session", () => fs.existsSync(pidfile) && fs.readFileSync(pidfile, "utf8"), 30_000);
      const pid = Number(fs.readFileSync(pidfile, "utf8"));
      assert.ok(alive(pid));
      pi.kill(signal);
      await new Promise((resolve) => pi.once("exit", resolve));
      await eventually(`the server gone after ${signal}`, () => !alive(pid), 5_000);
    } catch (error) {
      error.message += `\npi stderr:\n${err}`;
      throw error;
    } finally {
      if (pi.exitCode === null && pi.signalCode === null) pi.kill("SIGKILL");
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
}
