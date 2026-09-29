// Live coordination against a local Shepherd socket; report/task semantics also run in real
// pi against a gated local fake provider, with an isolated home and no external services.
import assert from "node:assert/strict";
import { test } from "node:test";
import * as net from "node:net";
import * as path from "node:path";
import { mkdtemp, rm, mkdir, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import * as http from "node:http";
import { tmpdir } from "node:os";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const require = createRequire(path.join(pkg, "package.json"));
const { createJiti } = require("jiti");
const jiti = createJiti(import.meta.url, { alias: {
  "@earendil-works/pi-coding-agent": path.join(pkg, "dist/index.js"),
  typebox: path.join(pkg, "node_modules/typebox/build/index.mjs"),
} });
const { default: install } = await jiti.import(path.join(root, "Extensions/shepherd-panes.ts"));

test("live recipient read, control, cancellable wait and deletion request", async () => {
  const dir = await mkdtemp(`${tmpdir()}/sh-peer-`);
  const oldHome = process.env.HOME;
  process.env.HOME = dir;
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
  const reports = [];
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
    sendUserMessage: (text, options) => sent.push({ text, options }),
    sendMessage: (message, options) => reports.push({ message, options }) });
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

    handle = (f) => {
      if (f.type === "createAutomation") connection.write(JSON.stringify({ type: "ok", id: f.id }) + "\n");
    };
    await run("automation_create", { name: "watch", prompt: "Watch CI", cwd: dir, replyToCreator: true });
    const reporting = frames.findLast((f) => f.type === "createAutomation");
    assert.ok(reporting.prompt.startsWith("Watch CI\n\n"));
    assert.match(reporting.prompt, /agent_send with agentID "recipient", delivery "report"/);
    assert.match(reporting.prompt, /success, failure, or a blocked watch/);
    assert.match(reporting.prompt, /creator no longer exists/);
    await run("automation_create", { name: "plain", prompt: "Notify only", cwd: dir });
    assert.equal(frames.findLast((f) => f.type === "createAutomation").prompt, "Notify only");

    const automationTools = new Map();
    const automationEvents = new Map();
    const creatorConnection = connection;
    const previousAutomation = process.env.SHEPHERD_AUTOMATION;
    process.env.SHEPHERD_AUTOMATION = "1";
    process.env.SHEPHERD_AGENT_ID = "watcher";
    try {
      install({ registerTool: (t) => automationTools.set(t.name, t), on: (event, cb) => automationEvents.set(event, cb) });
      assert.ok(automationTools.has("agent_send"));
      assert.ok(!automationTools.has("automation_create"));
      const target = JSON.parse(reporting.prompt.match(/agent_send with agentID ("[^"]+")/)[1]);
      handle = (f) => {
        if (f.type !== "sendToAgent") return;
        assert.equal(f.agentID, "watcher");
        assert.equal(f.targetAgentID, "recipient");
        creatorConnection.write(JSON.stringify({ type: "message", id: 0, text: `[from: watcher] ${f.text}`, delivery: f.delivery }) + "\n");
        connection.write(JSON.stringify({ type: "ok", id: f.id }) + "\n");
      };
      const before = sent.length;
      const report = await automationTools.get("agent_send").execute("report", { agentID: target, text: "CI passed: https://example.test/run/1", delivery: "report" });
      assert.match(report.content[0].text, /report dispatch requested/);
      await waitFor(() => reports.length === 1);
      assert.deepEqual(reports[0], { message: { customType: "shepherd-peer-report", content: "[from: watcher] CI passed: https://example.test/run/1", display: false }, options: { triggerTurn: false } });
      assert.equal(sent.length, before, "reports never become user tasks");
      await automationTools.get("agent_send").execute("task", { agentID: target, text: "Fix CI" });
      await waitFor(() => sent.length === before + 1);
      assert.deepEqual(sent.at(-1), { text: "[from: watcher] Fix CI", options: { deliverAs: "followUp" } });
      assert.equal(frames.findLast((f) => f.type === "sendToAgent").delivery, "task");
      handle = (f) => {
        if (f.type === "sendToAgent") connection.write(JSON.stringify({ type: "error", id: f.id, code: "not_found", message: "Creator was deleted" }) + "\n");
      };
      await assert.rejects(automationTools.get("agent_send").execute("report", { agentID: target, text: "Failed", delivery: "report" }), /Creator was deleted/);
      assert.equal(reports.length, 1);
      assert.equal(sent.length, before + 1, "failed delivery must not reach another thread");
    } finally {
      automationEvents.get("session_shutdown")?.();
      connection = creatorConnection;
      process.env.SHEPHERD_AGENT_ID = "recipient";
      if (previousAutomation === undefined) delete process.env.SHEPHERD_AUTOMATION;
      else process.env.SHEPHERD_AUTOMATION = previousAutomation;
    }

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
    if (oldHome === undefined) delete process.env.HOME; else process.env.HOME = oldHome;
    await rm(dir, { recursive: true, force: true });
  }
});

test("real pi keeps reports as hidden context without extra turns, but tasks start idle pi", { timeout: 30000 }, async () => {
  const dir = await mkdtemp(`${tmpdir()}/sh-report-`);
  const requests = [];
  const events = [];
  const frames = [];
  let connection, child, release;
  let stderr = "";
  const until = async (predicate) => {
    const deadline = Date.now() + 10000;
    while (!predicate()) {
      assert.ok(Date.now() < deadline, `timed out: ${stderr}`);
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
  };
  const lines = (stream, consume) => {
    let buffer = "";
    stream.on("data", (chunk) => {
      buffer += chunk;
      let index;
      while ((index = buffer.indexOf("\n")) >= 0) {
        consume(JSON.parse(buffer.slice(0, index)));
        buffer = buffer.slice(index + 1);
      }
    });
  };
  const provider = http.createServer(async (req, res) => {
    let raw = "";
    for await (const chunk of req) raw += chunk;
    requests.push(JSON.parse(raw));
    if (requests.length === 1) await new Promise((resolve) => { release = resolve; });
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta: { content: "done" }, finish_reason: null }] })}\n\n`);
    res.end(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } })}\n\ndata: [DONE]\n\n`);
  });
  const server = net.createServer((socket) => { connection = socket; lines(socket, (frame) => frames.push(frame)); });
  try {
    await new Promise((resolve) => provider.listen(0, "127.0.0.1", resolve));
    await new Promise((resolve) => server.listen(`${dir}/s`, resolve));
    await mkdir(`${dir}/pi`);
    await writeFile(`${dir}/pi/models.json`, JSON.stringify({ providers: { fixture: {
      baseUrl: `http://127.0.0.1:${provider.address().port}/v1`, api: "openai-completions", apiKey: "local-fixture",
      models: [{ id: "fixture", name: "fixture", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 1024,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
    } } }));
    child = spawn(process.execPath, [path.join(pkg, "dist/cli.js"), "--mode", "rpc", "--no-extensions", "--no-skills",
      "--no-prompt-templates", "--no-themes", "--no-approve", "-e", path.join(root, "Extensions/shepherd-panes.ts"),
      "--session", `${dir}/session.jsonl`, "--model", "fixture/fixture", "--thinking", "off"], {
      cwd: dir, env: { HOME: dir, PATH: process.env.PATH, TMPDIR: dir, PI_CODING_AGENT_DIR: `${dir}/pi`,
        PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", SHEPHERD_AGENT_ID: "recipient", SHEPHERD_SOCKET: `${dir}/s` },
      stdio: ["pipe", "pipe", "pipe"],
    });
    lines(child.stdout, (event) => events.push(event));
    child.stderr.on("data", (data) => { stderr += data; });
    child.stdin.on("error", () => {});
    let sequence = 0;
    const rpc = async (type, fields = {}) => {
      const id = `rpc-${++sequence}`;
      child.stdin.write(JSON.stringify({ type, id, ...fields }) + "\n");
      await until(() => events.some((event) => event.type === "response" && event.id === id));
      const result = events.find((event) => event.type === "response" && event.id === id);
      assert.equal(result.success, true, JSON.stringify(result));
      return result.data;
    };
    const send = async (text, delivery) => {
      connection.write(JSON.stringify({ type: "message", id: 0, text, delivery }) + "\n");
      const requestID = `barrier-${++sequence}`;
      connection.write(JSON.stringify({ type: "agentRequest", id: 0, targetAgentID: "recipient", requestID, request: { operation: "status" } }) + "\n");
      await until(() => frames.some((frame) => frame.requestID === requestID));
    };
    await rpc("get_state");
    await until(() => frames.some((frame) => frame.type === "helloAgent"));
    await send("idle report", "report");
    let messages = (await rpc("get_messages")).messages;
    assert.ok(messages.some((message) => message.customType === "shepherd-peer-report" && message.content === "idle report" && message.display === false));
    assert.equal(requests.length, 0, "an idle report must not call the provider");

    await send("explicit task", "task");
    await until(() => release !== undefined);
    assert.equal((await rpc("get_state")).isStreaming, true);
    await send("busy report", "report");
    messages = (await rpc("get_messages")).messages;
    assert.ok(!messages.some((message) => message.content === "busy report"), "busy report waits for a safe boundary");
    release();
    await until(() => events.some((event) => event.type === "agent_settled"));
    messages = (await rpc("get_messages")).messages;
    assert.ok(messages.some((message) => message.customType === "shepherd-peer-report" && message.content === "busy report" && message.display === false));
    assert.equal(messages.filter((message) => message.role === "user").length, 1, "reports are never user turns");
    assert.equal(requests.length, 1, "a busy report must not queue another turn");
    assert.equal((await rpc("get_state")).isStreaming, false);

    const settled = events.filter((event) => event.type === "agent_settled").length;
    await send("legacy task");
    await until(() => events.filter((event) => event.type === "agent_settled").length > settled);
    assert.equal(requests.length, 2, "omitted delivery still wakes idle pi");
    const context = JSON.stringify(requests[1].messages);
    assert.match(context, /idle report/);
    assert.match(context, /busy report/);
    assert.match(context, /legacy task/);
  } finally {
    release?.();
    if (child && child.exitCode === null) {
      const exited = new Promise((resolve) => child.once("exit", resolve));
      child.kill("SIGKILL");
      await exited;
    }
    connection?.destroy();
    await new Promise((resolve) => server.close(resolve));
    provider.closeAllConnections();
    await new Promise((resolve) => provider.close(resolve));
    await rm(dir, { recursive: true, force: true });
  }
});
