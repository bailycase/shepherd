// Shepherd's Retry: the status extension's `/shepherd-retry <ms>` against pi's real runtime.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/retry.test.mjs
// Everything runs in a temporary HOME against a local fake provider.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as http from "node:http";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { withPi } from "./fixtures/pi-rpc-harness.mjs";
import { projectConfigHost } from "./fixtures/project-config-host.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const statusSource = path.join(root, "Extensions/shepherd-status.ts");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, fn, timeout = 30000) {
  const end = Date.now() + timeout;
  while (!fn()) { if (Date.now() > end) throw Error(`Timed out waiting for ${what}`); await sleep(20); }
}
// A 1×1 PNG.
const PIXEL = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

// pi in RPC mode with the status extension, a provider that fails its first request and answers
// the rest, and a session file in `dir`.
async function startPi(dir) {
  const requests = [];
  const server = http.createServer(async (req, res) => {
    let raw = ""; for await (const chunk of req) raw += chunk;
    requests.push(JSON.parse(raw));
    if (requests.length === 1) {
      res.writeHead(400, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { message: "Bad request from the fixture", type: "invalid_request_error" } }));
      return;
    }
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(`data: ${JSON.stringify({ id: "f", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta: { content: "Recovered." }, finish_reason: null }] })}\n\n`);
    res.end(`data: ${JSON.stringify({ id: "f", object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } })}\n\ndata: [DONE]\n\n`);
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const config = path.join(dir, "config");
  fs.mkdirSync(config);
  fs.writeFileSync(path.join(config, "settings.json"), JSON.stringify({ retry: { enabled: false } }));
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: [{ id: "fixture", name: "fixture", reasoning: false, input: ["text", "image"], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  const sessions = path.join(dir, "sessions");
  const env = { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1",
    SHEPHERD_AGENT_ID: "fixture", SHEPHERD_SOCKET: path.join(dir, "absent.sock") };
  const child = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--session-dir", sessions,
    "-ne", "-ns", "-np", "--model", "fixture/fixture", "-e", statusSource], { cwd: dir, env, stdio: ["pipe", "pipe", "pipe"] });
  const events = [];
  let out = "", err = "", next = 0;
  child.stdout.on("data", (chunk) => {
    out += chunk;
    for (let nl; (nl = out.indexOf("\n")) >= 0; out = out.slice(nl + 1)) {
      try { events.push(JSON.parse(out.slice(0, nl))); } catch {}
    }
  });
  child.stderr.on("data", (chunk) => { err += chunk; });
  const pi = {
    events, requests, sessions,
    get stderr() { return err; },
    send(command) { const id = `r${++next}`; child.stdin.write(JSON.stringify({ id, ...command }) + "\n"); return id; },
    async request(command) {
      const id = pi.send(command);
      await until(`the answer to ${command.type}`, () => events.some((e) => e.type === "response" && e.id === id));
      return events.find((e) => e.type === "response" && e.id === id);
    },
    settled: () => events.filter((e) => e.type === "agent_settled").length,
    async stop() {
      child.kill();
      await new Promise((r) => child.once("exit", r));
      server.close();
    },
  };
  return pi;
}

function userMessages(messages) { return messages.filter((m) => m.role === "user"); }

test("Retry after a provider error retains completed work and running children without starting them again", { timeout: 120000 }, async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-retry-children-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const socket = path.join(dir, "host.sock");
  const host = await projectConfigHost(socket);
  t.after(() => host.close());
  const childrenSource = path.join(root, "Extensions/shepherd-children.ts");
  let releaseChild;
  const heldChild = new Promise((resolve) => { releaseChild = resolve; });
  t.after(() => releaseChild());
  let pi, parentCalls = 0, childCalls = 0, completed, running, resumedContext;
  const textOf = (message) => typeof message.content === "string" ? message.content : JSON.stringify(message.content);
  const starts = () => pi.events.filter((e) => e.type === "tool_execution_end" && e.toolName === "shepherd_child_start")
    .map((e) => JSON.parse(e.result.content[0].text));
  const readStatus = (run) => JSON.parse(fs.readFileSync(path.join(path.dirname(run.sessionFile), "status.json"), "utf8"));
  const tool = (name, args = {}) => ({ tool: { name, arguments: args } });
  await withPi(t, {
    settings: { compaction: { enabled: false } },
    args: ["-ne", "-ns", "-np", "-e", statusSource, "-e", childrenSource],
    env: { SHEPHERD_NATIVE_CHILDREN: "1", SHEPHERD_AGENT_ID: "parent", SHEPHERD_SOCKET: socket, SHEPHERD_EXT_CHILDREN: childrenSource },
    onRequest: async ({ body }) => {
      const messages = body.messages ?? [];
      if (messages.some((m) => ["system", "developer"].includes(m.role) && textOf(m).includes("You are a Shepherd child"))) {
        childCalls++;
        if (messages.some((m) => m.role === "user" && textOf(m).includes("held child"))) await heldChild;
        return {};
      }
      switch (++parentCalls) {
        case 1: return tool("shepherd_child_start", { agent: "scout", task: "completed child", delivery: "report" });
        case 2: return tool("shepherd_child_start", { agent: "scout", task: "held child", delivery: "report" });
        case 3:
          [completed, running] = starts();
          await until("the first child to finish", () => readStatus(completed).state === "complete");
          return tool("shepherd_child_result", { id: completed.id });
        case 4: return { status: 400, text: "Connection failed after the children started" };
        case 5:
          resumedContext = messages;
          return tool("shepherd_child_result");
        default: return {};
      }
    },
  }, async (handle) => {
    pi = handle;
    await pi.prompt("Start two scouts, read the first result, then finish using their work.");
    const before = (await pi.request({ type: "get_messages" })).data.messages;
    assert.equal(before.at(-1).stopReason, "error");
    assert.equal(starts().length, 2);
    assert.equal(readStatus(completed).state, "complete");
    assert.equal(readStatus(running).state, "running");
    const completedResult = before.find((m) => m.role === "toolResult" && m.toolName === "shepherd_child_result");
    assert(completedResult, "the parent read the completed child's work before failing");
    const [prompt] = userMessages(before);
    const retried = await pi.prompt(`/shepherd-retry ${Math.trunc(prompt.timestamp)}`);
    assert.equal(retried.reply.success, true);
    assert(resumedContext.some((m) => m.role === "tool" && textOf(m).includes(completed.id)), "the retry knows the completed child");
    assert(resumedContext.some((m) => m.role === "tool" && textOf(m).includes(running.id)), "the retry knows the running child");
    const after = (await pi.request({ type: "get_messages" })).data.messages;
    assert(after.some((m) => m.role === "toolResult" && m.toolCallId === completedResult.toolCallId
      && JSON.stringify(m.content) === JSON.stringify(completedResult.content)), "completed work stays on the active branch");
    assert.equal(starts().length, 2, "Retry does not launch replacement children");
    const resultEvents = pi.events.filter((e) => e.type === "tool_execution_end" && e.toolName === "shepherd_child_result");
    const retained = JSON.parse(resultEvents.at(-1).result.content[0].text);
    assert.equal(retained.length, 2);
    assert.equal(retained.find((run) => run.id === completed.id).state, "complete");
    assert.equal(retained.find((run) => run.id === running.id).state, "running");
    assert.equal(readStatus(running).state, "running");
    releaseChild();
    await until("the original running child to finish", () => readStatus(running).state === "complete");
    assert.equal(childCalls, 2);
    assert(!pi.events.some((e) => e.type === "extension_error"));
  });
});

test("Retry retains a consumed child notice when its no-tool continuation fails", { timeout: 120000 }, async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-retry-notice-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const extension = path.join(dir, "notice.ts");
  const notice = "Child native-scout: completed work; Needs reply: Which database? questionID: attempt/question";
  await withPi(t, {
    settings: { compaction: { enabled: false } },
    args: ["-ne", "-ns", "-np", "-e", statusSource, "-e", extension],
    env: { SHEPHERD_AGENT_ID: "parent", SHEPHERD_SOCKET: path.join(dir, "absent.sock") },
    files: () => ({ [extension]: `export default function (pi) {
      let delivered = false;
      pi.on("agent_before_settle", (event) => {
        if (delivered || event.outcome !== "completed") return;
        delivered = true;
        return { entries: [...event.entries, { type: "custom_message", customType: "shepherd-child",
          content: ${JSON.stringify(notice)}, display: false, details: { backgroundReport: true } }], continue: true };
      });
    }` }),
    onRequest: ({ index }) => index === 1 ? { status: 400, text: "Connection failed while reading the child notice" } : {},
  }, async (pi) => {
    await pi.prompt("Continue the interrupted turn.");
    const before = (await pi.request({ type: "get_messages" })).data.messages;
    assert.equal(before.at(-1).stopReason, "error");
    assert(!before.some((m) => m.role === "toolResult"), "the notice arrived without a tool result");
    assert(before.some((m) => m.role === "custom" && m.content === notice));
    const [prompt] = userMessages(before);
    const retried = await pi.prompt(`/shepherd-retry ${Math.trunc(prompt.timestamp)}`);
    assert.equal(retried.reply.success, true);
    assert(JSON.stringify(retried.requests[0].messages).includes(notice), "a consumed child result/question stays in the retry's context");
    const after = (await pi.request({ type: "get_messages" })).data.messages;
    assert(after.some((m) => m.role === "custom" && m.content === notice), "the notice remains on the active branch");
    assert.equal(after.at(-1).stopReason, "stop");
  });
});

test("real Pi RPC: Retry navigates back and resends, leaving one copy with its images", { timeout: 120000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-retry-"));
  const pi = await startPi(dir);
  try {
    const image = { type: "image", data: PIXEL, mimeType: "image/png" };
    assert.equal((await pi.request({ type: "prompt", message: "Describe this", images: [image] })).success, true);
    await until("the failed turn to settle", () => pi.settled() === 1);
    let messages = (await pi.request({ type: "get_messages" })).data.messages;
    const failed = messages.at(-1);
    assert.equal(failed.role, "assistant");
    assert.equal(failed.stopReason, "error", "the first request fails");
    const [prompt] = userMessages(messages);

    const retry = await pi.request({ type: "prompt", message: `/shepherd-retry ${Math.trunc(prompt.timestamp)}` });
    assert.equal(retry.success, true);
    await until("the retried turn to settle", () => pi.settled() === 2);

    messages = (await pi.request({ type: "get_messages" })).data.messages;
    const users = userMessages(messages);
    assert.equal(users.length, 1, "the active branch holds the prompt once");
    assert.deepEqual(users[0].content.filter((p) => p.type === "text").map((p) => p.text), ["Describe this"]);
    assert.deepEqual(users[0].content.filter((p) => p.type === "image").map((p) => [p.mimeType, p.data]), [["image/png", PIXEL]]);
    assert(users[0].timestamp > prompt.timestamp, "a new message, not the old one");
    assert(!messages.some((m) => m.role === "assistant" && m.stopReason === "error"), "the failed reply left the branch");
    assert.deepEqual(messages.at(-1).content, [{ type: "text", text: "Recovered." }]);

    // The model saw the prompt once, with its image.
    const sent = pi.requests[1].messages.filter((m) => m.role === "user");
    assert.equal(sent.length, 1);
    assert(JSON.stringify(sent[0].content).includes(PIXEL), "the image went again");
    assert(!pi.requests[1].messages.some((m) => m.role === "assistant"), "nothing of the failed turn went");

    // The failed turn stays in the session file, off the active branch.
    const [file] = fs.readdirSync(pi.sessions, { recursive: true }).filter((f) => String(f).endsWith(".jsonl"));
    const entries = fs.readFileSync(path.join(pi.sessions, String(file)), "utf8").trim().split("\n").map((l) => JSON.parse(l));
    const stored = entries.filter((e) => e.type === "message" && e.message.role === "user");
    assert.equal(stored.length, 2, "both copies are in the file");
    assert.equal(stored[1].parentId, stored[0].parentId, "the retry is a sibling of the failed prompt");
    assert(entries.some((e) => e.type === "message" && e.message.stopReason === "error"));
    assert(!pi.events.some((e) => e.type === "extension_error"), "the command never throws into pi");
  } catch (error) {
    error.message += `\npi stderr:\n${pi.stderr}`;
    throw error;
  } finally {
    await pi.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("real Pi RPC: Retry of a message that isn't on the branch changes nothing and says so", { timeout: 120000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-retry-miss-"));
  const pi = await startPi(dir);
  try {
    await pi.request({ type: "prompt", message: "First" });
    await until("the turn to settle", () => pi.settled() === 1);
    const before = (await pi.request({ type: "get_messages" })).data.messages;
    assert.equal((await pi.request({ type: "prompt", message: "/shepherd-retry 12345" })).success, true);
    await until("the notice", () => pi.events.some((e) => e.type === "extension_ui_request" && e.method === "notify"));
    const notice = pi.events.find((e) => e.type === "extension_ui_request" && e.method === "notify");
    assert.match(notice.message, /no longer in this conversation/);
    assert.deepEqual((await pi.request({ type: "get_messages" })).data.messages, before);
    assert.equal(pi.requests.length, 1, "nothing went to the model");
    assert.equal(pi.settled(), 1);
  } catch (error) {
    error.message += `\npi stderr:\n${pi.stderr}`;
    throw error;
  } finally {
    await pi.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
