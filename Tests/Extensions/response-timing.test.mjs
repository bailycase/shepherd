// The status extension's response timing (Shepherd's "Waiting for response" and a reply's
// Response timing), against pi's real runtime and a local fake provider that holds its headers
// and then its first event back. For each model request the extension writes exactly four
// lines to Shepherd's socket, in order: sent, headers, firstEvent and a message timestamp link, each only {type, agentID, seq,
// mark, at}: never the payload, a header or a credential. Its stream listener is gone after the
// first event, so the rest of the stream runs with no handler of Shepherd's on it.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/response-timing.test.mjs
// Everything runs in a temporary HOME against a local fake provider.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as http from "node:http";
import * as net from "node:net";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const statusSource = path.join(root, "Extensions/shepherd-status.ts");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, fn, timeout = 30000) {
  const end = Date.now() + timeout;
  while (!fn()) { if (Date.now() > end) throw Error(`Timed out waiting for ${what}`); await sleep(20); }
}

const HEADERS_AFTER = 150;
const FIRST_EVENT_AFTER = 250;

test("real Pi RPC: each request reports its send, headers and first event, once, in order, and nothing else", { timeout: 120000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-timing-"));
  // Shepherd's socket: every line the extension writes.
  const lines = [];
  const socketPath = path.join(dir, "s.sock");
  const socketServer = net.createServer((socket) => {
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      for (let nl; (nl = buffer.indexOf("\n")) >= 0; buffer = buffer.slice(nl + 1)) lines.push(JSON.parse(buffer.slice(0, nl)));
    });
  });
  await new Promise((r) => socketServer.listen(socketPath, r));

  // A provider that answers a tool call, then words, holding its headers and its first event back.
  const chunk = (delta, finish = null) => `data: ${JSON.stringify({ id: "f", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta, finish_reason: finish }], ...(finish ? { usage: { prompt_tokens: 120, completion_tokens: 12, total_tokens: 132 } } : {}) })}\n\n`;
  const provider = http.createServer(async (req, res) => {
    let raw = ""; for await (const c of req) raw += c;
    const body = JSON.parse(raw);
    await sleep(HEADERS_AFTER);
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.flushHeaders();
    await sleep(FIRST_EVENT_AFTER);
    if (body.messages.at(-1).role === "tool") {
      res.write(chunk({ role: "assistant", content: "Done." }));
      res.end(chunk({}, "stop") + "data: [DONE]\n\n");
      return;
    }
    res.write(chunk({ role: "assistant", tool_calls: [{ index: 0, id: "call_ls", type: "function", function: { name: "ls", arguments: "" } }] }));
    for (const piece of ['{"pa', 'th":"."}']) { await sleep(20); res.write(chunk({ tool_calls: [{ index: 0, function: { arguments: piece } }] })); }
    res.end(chunk({}, "tool_calls") + "data: [DONE]\n\n");
  });
  await new Promise((r) => provider.listen(0, "127.0.0.1", r));
  const config = path.join(dir, "config");
  fs.mkdirSync(config);
  fs.writeFileSync(path.join(config, "settings.json"), JSON.stringify({ retry: { enabled: false } }));
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${provider.address().port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: [{ id: "fixture", name: "fixture", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  const env = { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1", SHEPHERD_AGENT_ID: "fixture", SHEPHERD_SOCKET: socketPath };
  const child = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--session-dir", path.join(dir, "sessions"),
    "-ne", "-ns", "-np", "--model", "fixture/fixture", "-e", statusSource], { cwd: dir, env, stdio: ["pipe", "pipe", "pipe"] });
  const events = [];
  let out = "", err = "";
  child.stdout.on("data", (data) => {
    out += data;
    for (let nl; (nl = out.indexOf("\n")) >= 0; out = out.slice(nl + 1)) { try { events.push(JSON.parse(out.slice(0, nl))); } catch {} }
  });
  child.stderr.on("data", (data) => { err += data; });
  try {
    await until("the extension to connect", () => lines.some((l) => l.type === "setAgentStatus"));
    child.stdin.write(JSON.stringify({ id: "r1", type: "prompt", message: "list the folder" }) + "\n");
    await until("the run to settle", () => events.some((e) => e.type === "agent_settled"), 60000);
    await sleep(100);

    const timing = lines.filter((l) => l.type === "responseTiming");
    assert.equal(events.filter((e) => e.type === "message_start" && e.message.role === "assistant").length, 2, `two requests (${err})`);
    assert.deepEqual(timing.filter((l) => l.mark !== "message").map((l) => `${l.seq}:${l.mark}`),
      ["1:sent", "1:headers", "1:firstEvent", "2:sent", "2:headers", "2:firstEvent"], "each request's three moments, once each, in order");
    assert.deepEqual(timing.filter((l) => l.mark === "message").map((l) => l.at),
      events.filter((e) => e.type === "message_start" && e.message.role === "assistant").map((e) => e.message.timestamp),
      "the timestamp links each request to its assistant, regardless of socket/stdout ordering");
    for (const line of timing) {
      assert.deepEqual(Object.keys(line).sort(), ["agentID", "at", "mark", "seq", "type"], "only the moment, never the payload or a header");
      assert.equal(line.agentID, "fixture");
    }
    for (const seq of [1, 2]) {
      const at = Object.fromEntries(timing.filter((l) => l.seq === seq).map((l) => [l.mark, l.at]));
      assert(at.headers - at.sent >= HEADERS_AFTER - 20, `headers ${at.headers - at.sent}ms after the send`);
      assert(at.firstEvent - at.headers >= FIRST_EVENT_AFTER - 20, `the first event ${at.firstEvent - at.headers}ms after the headers: headers are not a model event`);
    }
    assert(!events.some((e) => e.type === "extension_error"), "the hooks never throw into pi");
  } finally {
    child.kill();
    await new Promise((r) => child.once("exit", r));
    provider.closeAllConnections?.();
    provider.close();
    socketServer.close();
  }
});
