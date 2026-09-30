// pi's events while the model writes a tool call, against pi's real runtime and a local fake
// provider that streams a `write` call slowly. Shepherd's thread shows the call as a row from
// `toolcall_start` (RPCThreadState.streamToolCall) and depends on exactly these shapes:
//   toolcall_start  {contentIndex, id, toolName}
//   toolcall_delta  {contentIndex, delta}          the next fragment of the arguments' JSON text
//   toolcall_end    {contentIndex, toolCall}       the finished call
// then message_end, then tool_execution_start; a request that is stopped ends `aborted` with the
// call still in its message and runs nothing.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/tool-call-stream.test.mjs
// Everything runs in a temporary HOME against a local fake provider.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as http from "node:http";
import { spawn } from "node:child_process";

const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, fn, timeout = 30000) {
  const end = Date.now() + timeout;
  while (!fn()) { if (Date.now() > end) throw Error(`Timed out waiting for ${what}`); await sleep(20); }
}

// The call the model writes, cut into the fragments a provider streams it in.
const CALL = { path: "src/big.txt", content: "line one\nline two\nline three" };
const PIECES = ['{"pa', 'th":"src/big', '.txt","con', 'tent":"line one\\nline ', 'two\\nline three"}'];

// pi in RPC mode with no extensions, and a provider whose first reply is the slow call (held
// open after `holdAfter` fragments when given) and whose second is a line of text.
async function startPi(dir, { holdAfter } = {}) {
  const chunk = (delta, finish = null, usage) => `data: ${JSON.stringify({ id: "f", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta, finish_reason: finish }], ...(usage ? { usage } : {}) })}\n\n`;
  const usage = { prompt_tokens: 100, completion_tokens: 10, total_tokens: 110 };
  const server = http.createServer(async (req, res) => {
    let raw = ""; for await (const c of req) raw += c;
    const body = JSON.parse(raw);
    res.writeHead(200, { "content-type": "text/event-stream" });
    if (body.messages.at(-1).role === "tool") {
      res.write(chunk({ content: "Done." }));
      res.end(chunk({}, "stop", usage) + "data: [DONE]\n\n");
      return;
    }
    res.write(chunk({ role: "assistant", content: "I'll write the file." }));
    await sleep(60);
    res.write(chunk({ tool_calls: [{ index: 0, id: "call_abc", type: "function", function: { name: "write", arguments: "" } }] }));
    await sleep(60);
    for (const [i, piece] of PIECES.entries()) {
      // Held open until the test stops pi; an unref'd timer never keeps node alive.
      if (holdAfter !== undefined && i === holdAfter) { await new Promise((r) => setTimeout(r, 60000).unref()); return; }
      res.write(chunk({ tool_calls: [{ index: 0, function: { arguments: piece } }] }));
      await sleep(60);
    }
    res.end(chunk({}, "tool_calls", usage) + "data: [DONE]\n\n");
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const config = path.join(dir, "config");
  fs.mkdirSync(config);
  fs.writeFileSync(path.join(config, "settings.json"), JSON.stringify({ retry: { enabled: false } }));
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: [{ id: "fixture", name: "fixture", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  const env = { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1" };
  const child = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--session-dir", path.join(dir, "sessions"),
    "-ne", "-ns", "-np", "--model", "fixture/fixture"], { cwd: dir, env, stdio: ["pipe", "pipe", "pipe"] });
  const events = [];
  let out = "", err = "", next = 0;
  child.stdout.on("data", (chunk) => {
    out += chunk;
    for (let nl; (nl = out.indexOf("\n")) >= 0; out = out.slice(nl + 1)) {
      try { events.push(JSON.parse(out.slice(0, nl))); } catch {}
    }
  });
  child.stderr.on("data", (chunk) => { err += chunk; });
  return {
    events,
    get stderr() { return err; },
    send(command) { child.stdin.write(JSON.stringify({ id: `r${++next}`, ...command }) + "\n"); },
    updates: (type) => events.filter((e) => e.type === "message_update" && e.assistantMessageEvent.type === type).map((e) => e.assistantMessageEvent),
    async stop() {
      child.kill();
      await new Promise((r) => child.once("exit", r));
      server.closeAllConnections?.();
      server.close();
    },
  };
}

const position = (events, match) => events.findIndex(match);

test("real Pi RPC: a tool call is named, streamed as JSON fragments, ended, then executed", { timeout: 120000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-toolcall-"));
  const pi = await startPi(dir);
  try {
    pi.send({ type: "prompt", message: "write the big file" });
    await until("the run to settle", () => pi.events.some((e) => e.type === "agent_settled"), 60000);

    const [started] = pi.updates("toolcall_start");
    assert.deepEqual(Object.keys(started).sort(), ["contentIndex", "id", "toolName", "type"], "the call is named by its id and tool, nothing more");
    assert.equal(started.id, "call_abc");
    assert.equal(started.toolName, "write");

    // Each delta is the next fragment of the JSON text, not the text so far.
    const deltas = pi.updates("toolcall_delta");
    assert(deltas.length >= PIECES.length, "the arguments arrive in pieces");
    for (const d of deltas) {
      assert.equal(typeof d.delta, "string");
      assert.equal(d.contentIndex, started.contentIndex);
      assert.deepEqual(Object.keys(d).sort(), ["contentIndex", "delta", "type"]);
    }
    assert.deepEqual(JSON.parse(deltas.map((d) => d.delta).join("")), CALL, "the fragments, joined, are the arguments");

    const [ended] = pi.updates("toolcall_end");
    assert.equal(ended.contentIndex, started.contentIndex);
    assert.deepEqual(ended.toolCall, { type: "toolCall", id: "call_abc", name: "write", arguments: CALL });

    // The order the thread relies on: the call's row exists before its arguments finish, and the
    // reply ends before the call runs.
    const at = (match) => position(pi.events, match);
    const update = (type) => (e) => e.type === "message_update" && e.assistantMessageEvent.type === type;
    const reply = pi.events.find((e) => e.type === "message_end" && e.message.role === "assistant");
    assert.equal(reply.message.stopReason, "toolUse");
    assert.deepEqual(reply.message.content.filter((b) => b.type === "toolCall"), [ended.toolCall], "the reply still carries the call");
    const order = [at(update("toolcall_start")), at(update("toolcall_delta")), at(update("toolcall_end")),
      at((e) => e.type === "message_end" && e.message.role === "assistant"),
      at((e) => e.type === "tool_execution_start" && e.toolCallId === "call_abc")];
    assert(order.every((i) => i >= 0) && order.every((i, k) => k === 0 || order[k - 1] < i), `events out of order: ${order}`);
    const executing = pi.events.find((e) => e.type === "tool_execution_start");
    assert.equal(executing.toolName, "write");
    assert.deepEqual(executing.args, CALL, "the execution starts with the complete arguments");
    assert(!pi.events.some((e) => e.type === "extension_error"));
  } catch (error) {
    error.message += `\npi stderr:\n${pi.stderr}`;
    throw error;
  } finally {
    await pi.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("real Pi RPC: a request stopped while the call is written ends aborted with the call in its message and runs nothing", { timeout: 120000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-toolcall-abort-"));
  const pi = await startPi(dir, { holdAfter: 2 });
  try {
    pi.send({ type: "prompt", message: "write the big file" });
    await until("two fragments", () => pi.updates("toolcall_delta").filter((d) => d.delta !== "").length >= 2);
    pi.send({ type: "abort" });
    await until("the run to settle", () => pi.events.some((e) => e.type === "agent_settled"), 60000);

    const ended = pi.updates("toolcall_end");
    assert.equal(ended.length, 1, "pi ends the call it was writing");
    assert.equal(ended[0].toolCall.id, "call_abc");
    assert.deepEqual(ended[0].toolCall.arguments, { path: "src/big" }, "with what it parsed so far");
    const reply = pi.events.find((e) => e.type === "message_end" && e.message.role === "assistant");
    assert.equal(reply.message.stopReason, "aborted");
    assert.deepEqual(reply.message.content.filter((b) => b.type === "toolCall").map((b) => b.id), ["call_abc"], "the aborted message still carries the call");
    assert(!pi.events.some((e) => e.type === "tool_execution_start"), "nothing runs");
    const order = pi.events.filter((e) => ["message_end", "agent_end", "agent_settled"].includes(e.type) && (e.type !== "message_end" || e.message.role === "assistant")).map((e) => e.type);
    assert.deepEqual(order, ["message_end", "agent_end", "agent_settled"]);
  } catch (error) {
    error.message += `\npi stderr:\n${pi.stderr}`;
    throw error;
  } finally {
    await pi.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
