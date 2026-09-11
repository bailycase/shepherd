import assert from "node:assert/strict";
import { test } from "node:test";
import * as net from "node:net";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { createRequire, stripTypeScriptTypes } from "node:module";
import { pathToFileURL } from "node:url";

// Use the same installed TypeBox as pi. Run with NODE_PATH="$(npm root -g)".
const piRequire = createRequire(`${process.env.NODE_PATH}/@earendil-works/pi-coding-agent/package.json`);
const source = stripTypeScriptTypes(await readFile(new URL("../../Extensions/shepherd-panes.ts", import.meta.url), "utf8"))
  .replace('from "typebox"', `from ${JSON.stringify(pathToFileURL(piRequire.resolve("typebox")).href)}`);
const { default: install } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);

test("live recipient read, control, cancellable wait and deletion request", async () => {
  const dir = await mkdtemp(`${tmpdir()}/sh-peer-`);
  process.env.SHEPHERD_SOCKET = `${dir}/s`;
  process.env.SHEPHERD_AGENT_ID = "recipient";
  const frames = [];
  let connection;
  let handle = () => {};
  const server = net.createServer((s) => {
    connection = s;
    let buffer = "";
    s.on("data", (chunk) => {
      buffer += chunk;
      let nl;
      while ((nl = buffer.indexOf("\n")) >= 0) {
        const frame = JSON.parse(buffer.slice(0, nl));
        buffer = buffer.slice(nl + 1);
        frames.push(frame);
        handle(frame);
      }
    });
  });
  await new Promise((resolve) => server.listen(process.env.SHEPHERD_SOCKET, resolve));
  const tools = new Map();
  const events = new Map();
  const sent = [];
  let aborted = 0;
  let idle = false;
  let pending = true;
  let branch = [
    { id: "u", type: "message", message: { role: "user", content: "hello" } },
    { id: "a", type: "message", message: { role: "assistant", content: [
      { type: "text", text: "answer" }, { type: "thinking", thinking: "PRIVATE" },
      { type: "image", data: "IMAGEPAYLOAD" }, { type: "toolCall", arguments: { secret: "ARGS" } },
    ] } },
    { id: "h", type: "custom_message", display: false, content: "HIDDEN" },
    { id: "c", type: "custom", data: "PRIVATE DATA" },
    { id: "t", type: "message", message: { role: "toolResult", content: [{ type: "text", text: "tool output" }] } },
    { id: "v", type: "custom_message", display: true, content: "visible custom" },
    { id: "b", type: "message", message: { role: "bashExecution", command: "pwd", output: "/tmp" } },
    { id: "s", type: "compaction", summary: "summary" },
  ];
  install({ registerTool: (t) => tools.set(t.name, t), on: (event, cb) => events.set(event, cb),
    sendUserMessage: (text, options) => sent.push({ text, options }) });
  const ctx = { sessionManager: { getBranch: () => branch, getSessionId: () => "session-1" },
    isIdle: () => idle, hasPendingMessages: () => pending, abort: () => aborted++ };
  const waitFor = async (predicate) => {
    const deadline = Date.now() + 3000;
    while (!predicate()) {
      assert.ok(Date.now() < deadline, "timed out waiting for socket behavior");
      await new Promise((r) => setTimeout(r, 5));
    }
  };
  let token = 0;
  const receive = async (request) => {
    const requestID = `server-token-${++token}`;
    connection.write(JSON.stringify({ type: "agentRequest", id: 0, targetAgentID: "recipient", requestID, request }) + "\n");
    await waitFor(() => frames.some((f) => f.requestID === requestID));
    return frames.find((f) => f.requestID === requestID).result;
  };
  const run = (tool, params, signal) => tools.get(tool).execute("call", params, signal);
  try {
    events.get("session_start")({}, ctx);
    await waitFor(() => frames.some((f) => f.type === "helloAgent"));
    let result = await receive({ operation: "read" });
    assert.equal(result.sessionID, "session-1");
    assert.doesNotMatch(result.text, /PRIVATE|IMAGEPAYLOAD|ARGS|HIDDEN/);
    let read = JSON.parse(result.text);
    assert.deepEqual(read.messages.map((m) => m.id), ["u", "a", "t", "v", "b", "s"]);
    assert.equal(read.messages[1].text, "answer");
    read = JSON.parse((await receive({ operation: "read", after: "a", limit: 2 })).text);
    assert.deepEqual(read.messages.map((m) => m.id), ["t", "v"]);
    assert.equal(read.nextCursor, "v");
    assert.equal(read.hasMore, true);
    assert.equal((await receive({ operation: "read", after: "other-branch" })).code, "recipient_error");
    read = JSON.parse((await receive({ operation: "read", limit: 1 })).text);
    assert.equal(read.messages[0].id, "s");
    assert.equal(read.omittedEarlier, true);
    branch = Array.from({ length: 110 }, (_, i) => ({ id: `big-${i}`, type: "message", message: { role: "user", content: "😀".repeat(10000) } }));
    result = await receive({ operation: "read", limit: 1000 });
    read = JSON.parse(result.text);
    assert.ok(Buffer.byteLength(result.text) < 50 * 1024);
    assert.ok(read.messages.length < 100);
    assert.equal(read.hasMore, true);
    assert.equal(read.messages[0].truncated, true);
    assert.ok(read.messages[0].text.length <= 4000);

    result = await receive({ operation: "steer", text: "change plan" });
    assert.match(result.text, /dispatch requested/);
    assert.deepEqual(sent[0], { text: "change plan", options: { deliverAs: "steer" } });
    connection.write(JSON.stringify({ type: "message", id: 0, text: "follow up" }) + "\n");
    await waitFor(() => sent.length === 2);
    assert.equal(sent[1].options.deliverAs, "followUp");
    assert.match((await receive({ operation: "interrupt" })).text, /not confirmed stopped/);
    assert.equal(aborted, 1);
    idle = true;
    assert.equal((await receive({ operation: "status" })).idle, false);
    pending = false;
    const initialStatus = await receive({ operation: "status" });
    assert.equal(initialStatus.idle, true);
    assert.equal(typeof initialStatus.connectionID, "string");
    assert.equal((await receive({ operation: "status" })).connectionID, initialStatus.connectionID);

    let polls = 0;
    handle = (f) => {
      if (f.type === "coordinateAgent") connection.write(JSON.stringify({ type: "agentResult", id: f.id,
        result: { text: "live", idle: ++polls >= 2, sessionID: "session-1" } }) + "\n");
    };
    assert.match((await run("agent_wait", { agentID: "other", timeoutSeconds: 2 })).content[0].text, /current activity settled/);
    assert.equal(polls, 2);
    polls = 0;
    handle = (f) => {
      if (f.type === "coordinateAgent") connection.write(JSON.stringify({ type: "agentResult", id: f.id,
        result: { text: "live", idle: ++polls > 1, sessionID: `session-${polls}` } }) + "\n");
    };
    await assert.rejects(run("agent_wait", { agentID: "other", timeoutSeconds: 2 }), /session changed/);
    polls = 0;
    handle = (f) => {
      if (f.type === "coordinateAgent") connection.write(JSON.stringify({ type: "agentResult", id: f.id,
        result: { text: "live", idle: ++polls > 1, sessionID: "session-1", connectionID: `connection-${polls}` } }) + "\n");
    };
    await assert.rejects(run("agent_wait", { agentID: "other", timeoutSeconds: 2 }), /connection changed/);
    assert.equal(polls, 2);
    await assert.rejects(run("agent_wait", { agentID: "recipient" }), /yourself/);
    handle = (f) => {
      if (f.type === "coordinateAgent") connection.write(JSON.stringify({ type: "agentResult", id: f.id,
        result: { text: "live", idle: false, sessionID: "session-1" } }) + "\n");
    };
    await assert.rejects(run("agent_wait", { agentID: "other", timeoutSeconds: 1 }), /timed out|timeout/);
    const controller = new AbortController();
    handle = (f) => { if (f.type === "coordinateAgent") controller.abort(); };
    await assert.rejects(run("agent_wait", { agentID: "other" }, controller.signal), /cancelled/);
    await waitFor(() => frames.some((f) => f.type === "cancelAgentRequest"));

    handle = (f) => {
      if (f.type === "coordinateAgent") {
        assert.equal(f.request.operation, "delete");
        assert.equal(f.confirmed, undefined);
        connection.write(JSON.stringify({ type: "agentResult", id: f.id,
          result: { text: "user cancelled deletion; agent kept", code: "cancelled" } }) + "\n");
      }
    };
    await assert.rejects(run("agent_delete", { agentID: "other", confirmed: true }), /cancelled/);
    // Close after the busy reply, during the 250 ms polling delay. A reconnect could succeed.
    polls = 0;
    handle = (f) => {
      if (f.type === "coordinateAgent") {
        connection.write(JSON.stringify({ type: "agentResult", id: f.id,
          result: { text: "live", idle: ++polls > 1, sessionID: "session-1" } }) + "\n");
        if (polls === 1) {
          const previous = connection;
          setTimeout(() => previous.destroy(), 50);
        }
      }
    };
    await assert.rejects(run("agent_wait", { agentID: "other", timeoutSeconds: 2 }), /disconnected/);
    assert.equal(polls, 1, "a disconnected wait must not reconnect for another poll");
    assert.match((await run("agent_wait", { agentID: "other", timeoutSeconds: 2 })).content[0].text, /current activity settled/);
    const reconnectedStatus = await receive({ operation: "status" });
    assert.equal(reconnectedStatus.sessionID, initialStatus.sessionID);
    assert.notEqual(reconnectedStatus.connectionID, initialStatus.connectionID);

    handle = (f) => { if (f.type === "coordinateAgent") connection.destroy(); };
    await assert.rejects(run("agent_wait", { agentID: "other" }), /disconnected/);
  } finally {
    events.get("session_shutdown")();
    connection?.destroy();
    await new Promise((r) => server.close(r));
    await rm(dir, { recursive: true, force: true });
  }
});
