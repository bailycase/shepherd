// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/native-children.test.mjs
// All child sessions/configuration use a temporary directory and a local fake provider.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as http from "node:http";
import * as net from "node:net";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { spawn, execFileSync } from "node:child_process";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
// Walk up from the resolved `pi` binary to the directory holding package.json (dist/cli.js
// in older layouts, dist/bundle/cli.js in 0.87+).
const pkg = process.env.PI_PACKAGE_DIR || (() => {
  let dir = path.dirname(fs.realpathSync(execFileSync("/usr/bin/which", ["pi"], { encoding: "utf8" }).trim()));
  while (!fs.existsSync(path.join(dir, "package.json")) && path.dirname(dir) !== dir) dir = path.dirname(dir);
  return dir;
})();
const require = createRequire(path.join(pkg, "package.json"));
const { createJiti } = require("jiti");
const jiti = createJiti(import.meta.url, { alias: {
  "@earendil-works/pi-coding-agent": path.join(pkg, "dist/index.js"),
  "@earendil-works/pi-tui": path.join(pkg, "node_modules/@earendil-works/pi-tui/dist/index.js"),
  "@earendil-works/pi-ai": path.join(pkg, "node_modules/@earendil-works/pi-ai/dist/index.js"),
  typebox: path.join(pkg, "node_modules/typebox/build/index.mjs"),
} });
const source = path.join(root, "Extensions/shepherd-children.ts");
const mod = await jiti.import(source);
const { SessionManager } = await import(path.join(pkg, "dist/index.js"));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, timeout = 15000) { const end = Date.now() + timeout; while (!fn()) { if (Date.now() > end) throw Error("Timed out waiting for condition"); await sleep(30); } }
const live = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
const usage = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const assistant = (content) => ({ role: "assistant", content, api: "openai-completions", provider: "fixture", model: "fixture", usage, stopReason: "stop", timestamp: Date.now() });

test("LF framing preserves fragmented UTF-8 and Unicode separators; malformed/oversize input fails boundedly", () => {
  const events = [], errors = [];
  const read = mod.jsonLines((e) => events.push(e), (e) => errors.push(e.message));
  const data = Buffer.from(JSON.stringify({ text: "🌱\u2028x\u2029y" }) + "\r\n");
  for (const byte of data) read(Buffer.from([byte]));
  assert.deepEqual(events, [{ text: "🌱\u2028x\u2029y" }]);
  read(Buffer.from("bad\n")); read(Buffer.from("{}\n")); assert.equal(errors.length, 1); assert.equal(events.length, 1);
  mod.jsonLines(() => assert.fail(), (e) => errors.push(e.message))(Buffer.alloc(8 * 1024 * 1024 + 1, 65));
  assert.match(errors.at(-1), /exceeds/);
});

test("fork extracts selected branch, omits incomplete tool batch, preserves parent identity and bytes", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-fork-"));
  try {
    const parent = SessionManager.create(dir, dir);
    parent.appendMessage({ role: "user", content: "active fact", timestamp: Date.now() });
    const leaf = parent.appendMessage(assistant([{ type: "text", text: "complete" }]));
    parent.appendMessage({ role: "user", content: "abandoned fact", timestamp: Date.now() });
    parent.branch(leaf);
    parent.appendMessage(assistant([{ type: "toolCall", id: "a", name: "read", arguments: {} }, { type: "toolCall", id: "b", name: "read", arguments: {} }]));
    parent.appendMessage({ role: "toolResult", toolCallId: "a", toolName: "read", content: [{ type: "text", text: "partial" }], timestamp: Date.now() });
    const before = fs.readFileSync(parent.getSessionFile()), id = parent.getSessionId(), file = parent.getSessionFile();
    const output = path.join(dir, "fork.jsonl");
    assert.equal(mod.forkSession(parent, dir, output).omittedInFlight, 2);
    assert.equal(parent.getSessionId(), id); assert.equal(parent.getSessionFile(), file); assert.deepEqual(fs.readFileSync(file), before);
    const fork = SessionManager.open(output);
    assert.notEqual(fork.getSessionId(), id);
    assert.equal(fork.getBranch().length, 2);
    assert(!fs.readFileSync(output, "utf8").includes("abandoned fact"));
    assert.equal(fork.getHeader().parentSession, file);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("bash operations preserve cwd/env/output, timeouts and abort kill normal descendants", async () => {
  const ops = mod.childBashOperations(), output = [];
  const completed = await ops.exec('printf "$MARKER:$PWD"', os.tmpdir(), { env: { MARKER: "ok" }, onData: (d) => output.push(d) });
  assert.equal(completed.exitCode, 0); assert(Buffer.concat(output).toString().startsWith("ok:"));
  assert.equal((await ops.exec('false', os.tmpdir(), { onData() {} })).exitCode, 1);
  assert.equal((await ops.exec('exit 7', os.tmpdir(), { onData() {} })).exitCode, 7);
  await assert.rejects(ops.exec("sleep 10", os.tmpdir(), { onData() {}, timeout: 0.05 }), /timeout/);
  const tail = []; await ops.exec('(sleep 0.05; printf tail) &', os.tmpdir(), { onData: (d) => tail.push(d) });
  assert.equal(Buffer.concat(tail).toString(), "tail");
  const burst = []; await ops.exec('head -c 200000 /dev/zero', os.tmpdir(), { onData: (d) => burst.push(d) });
  assert.equal(Buffer.concat(burst).length, 200000);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-abort-")), pidfile = path.join(dir, "pid");
  const controller = new AbortController();
  const promise = ops.exec(`sleep 30 >/dev/null 2>&1 & echo $! > '${pidfile}'`, dir, { onData() {}, signal: controller.signal });
  try { await until(() => fs.existsSync(pidfile)); const pid = Number(fs.readFileSync(pidfile)); controller.abort(); await assert.rejects(promise); await until(() => !live(pid)); }
  finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

function fixtureServer() {
  const requests = [];
  const server = http.createServer(async (req, res) => {
    let raw = ""; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw); requests.push(body);
    const messages = body.messages, last = messages.at(-1);
    const text = typeof last.content === "string" ? last.content : (last.content ?? []).map((p) => p.text ?? "").join("\n");
    const say = (delta, finish = "stop") => {
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta, finish_reason: null }] })}\n\n`);
      res.end(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: finish }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } })}\n\ndata: [DONE]\n\n`);
    };
    if (last.role === "user" && text.includes("SHELL:")) {
      const command = text.slice(text.indexOf("SHELL:") + 6);
      say({ tool_calls: [{ index: 0, id: "shell-call", type: "function", function: { name: "bash", arguments: JSON.stringify({ command }) } }] }, "tool_calls");
    } else if (last.role === "user" && text.includes("WRITE_THEN_EDIT:")) {
      const file = text.slice(text.indexOf("WRITE_THEN_EDIT:") + 16);
      say({ tool_calls: [
        { index: 0, id: "write-call", type: "function", function: { name: "write", arguments: JSON.stringify({ path: file, content: "one\ntwo\n" }) } },
        { index: 1, id: "edit-call", type: "function", function: { name: "edit", arguments: JSON.stringify({ path: file, oldText: "two", newText: "two\nthree\nfour" }) } },
      ] }, "tool_calls");
    } else if (last.role === "user" && text.includes("ASK_PARENT")) {
      say({ tool_calls: [{ index: 0, id: "parent-call", type: "function", function: { name: "shepherd_parent_message", arguments: JSON.stringify({ message: "Need a decision", needsReply: true, options: ["Replace everywhere", "Rename new ones"] }) } }] }, "tool_calls");
    } else {
      if (text.includes("SLOW")) await sleep(700);
      say({ content: last.role === "tool" ? "tool finished" : `reply:${text}` }, text.includes("TOKEN_LIMIT") ? "length" : "stop");
    }
  });
  return { server, requests };
}

async function harness(dir, entries = []) {
  const tools = new Map(), commands = new Map(), events = new Map(), messages = [], projections = [];
  const bus = new Map();
  const activeTools = ["read", "grep", "find", "ls", "bash", "edit", "write"];
  const pi = { registerCommand(name, command) { commands.set(name, command); }, registerEntryRenderer() {},
    getCommands: () => [...commands.keys()].map((name) => ({ name })), getAllTools: () => [...tools.values()],
    registerTool(tool) { tools.set(tool.name, tool); }, on(name, handler) { events.set(name, handler); },
    events: { on(name, fn) { bus.set(name, fn); return () => bus.delete(name); }, emit(name, data) { projections.push(data); bus.get(name)?.(data); } },
    getActiveTools: () => activeTools, appendEntry: (customType, data) => entries.push({ type: "custom", customType, data }),
    sendMessage: (message, options) => messages.push({ message, options }) };
  const ctx = { cwd: dir, thinkingLevel: "off", model: { provider: "fixture", id: "fixture" },
    modelRegistry: { getAll: () => [{ provider: "fixture", id: "fixture" }] },
    sessionManager: { getSessionId: () => "parent-fixture", getEntries: () => entries, getBranch: () => [], getSessionFile: () => undefined } };
  ctx.isProjectTrusted = () => true;
  mod.default(pi); await events.get("session_start")({}, ctx);
  return { tools, commands, events, messages, projections, entries, ctx, activeTools,
    call: async (name, p, signal) => (await tools.get(`shepherd_child_${name}`).execute("call", p, signal, undefined, ctx)).details,
    tool: async (name, p, signal) => (await tools.get(name).execute("call", p, signal, undefined, ctx)).details,
    shutdown: () => events.get("session_shutdown")() };
}

test("card helpers: tool preview follows the desktop rule and edit diffs cancel moved lines", () => {
  assert.equal(mod.toolPreview({ path: "Sources/A.swift", offset: 1 }, "ignored"), "Sources/A.swift");
  assert.equal(mod.toolPreview({ command: "swift build\necho done" }), "swift build");
  assert.equal(mod.toolPreview({ pattern: "needle" }), "needle");
  assert.equal(mod.toolPreview({}, "\n\nfirst useful line\nsecond"), "first useful line");
  assert.equal(mod.toolPreview(undefined, ""), undefined);
  assert.equal(mod.toolPreview({ path: "x".repeat(300) }).length, 120);
  assert.deepEqual(mod.editDiff({ oldText: "a\nb", newText: "b\na" }), { added: 0, removed: 0 });
  assert.deepEqual(mod.editDiff({ edits: [{ oldText: "a", newText: "a\nb\nc" }, { oldText: "x\ny", newText: "" }] }), { added: 2, removed: 2 });
  assert.deepEqual(mod.editDiff({ oldText: "one\ntwo\nthree", newText: "one\n2\nthree\nfour" }), { added: 2, removed: 1 });
  assert.equal(mod.editDiff({ command: "ls" }), undefined);
  // Ledger/RESULT summary: first two sentences, whitespace flattened, 240-char cap with an ellipsis.
  assert.equal(mod.summarize("Restyled the thread.\nAll 14 pass on macOS. Third sentence."), "Restyled the thread. All 14 pass on macOS.");
  assert.equal(mod.summarize("no punctuation"), "no punctuation");
  // A period inside a file name or version does not end the sentence.
  assert.equal(mod.summarize("Rows render in ThreadView.swift (RowView). v1.2 shipped. Third."), "Rows render in ThreadView.swift (RowView). v1.2 shipped.");
  assert.equal(mod.summarize(""), undefined);
  const long = mod.summarize("x".repeat(300) + ". y.");
  assert.equal(long.length, 240); assert(long.endsWith("…"));
});

test("merged projection prioritizes active native and legacy runs before terminal attention and history", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-merge-"));
  const saved = { ...process.env }, reports = [], handlers = new Map(), bus = new Map();
  const server = net.createServer((socket) => socket.on("data", mod.jsonLines((data) => reports.push(data.children), assert.fail)));
  process.env.SHEPHERD_AGENT_ID = "fixture"; process.env.SHEPHERD_SOCKET = path.join(dir, "s.sock");
  delete process.env.SHEPHERD_CHILD;
  await new Promise((r) => server.listen(process.env.SHEPHERD_SOCKET, r));
  try {
    const publisher = await jiti.import(path.join(root, "Extensions/shepherd-subagents.ts"));
    const emit = (name, data) => bus.get(name)?.(data);
    publisher.default({ on: (name, fn) => handlers.set(name, fn), events: { on: (name, fn) => bus.set(name, fn), emit } });
    handlers.get("session_start")({}, { hasUI: true, sessionManager: { getSessionId: () => "owner" } });
    emit("shepherd:children:v1", { owner: "owner", children: Array.from({ length: 20 }, (_, i) => ({ runID: `native-${i}`, state: "complete", needsAttention: i !== 0 })) });
    for (let i = 0; i < 20; i++) {
      emit("subagent:async-started", { id: `history-${i}` });
      emit("subagent:async-complete", { id: `history-${i}` });
    }
    emit("subagent:async-started", { id: "legacy-running" });
    await until(() => reports.at(-1)?.some((c) => c.runID === "legacy-running"));
    assert.equal(reports.at(-1).length, 20);
    assert.equal(reports.at(-1)[0].runID, "legacy-running");
    assert(reports.at(-1).slice(1).every((c) => c.needsAttention));
    bus.set("subagents:rpc:v1:request", (request) => emit(`subagents:rpc:v1:reply:${request.requestId}`, {
      success: true, data: { asyncSnapshot: { kind: "pi-subagents.async-status-snapshot", version: 1, runs: [
        ...Array.from({ length: 20 }, (_, i) => ({ id: `snapshot-history-${i}`, state: "complete" })),
        { id: "workflow", kind: "workflow", children: [{ state: "running" }, { state: "queued" }] },
      ] } },
    }));
    emit("subagents:rpc:v1:ready");
    handlers.get("tool_execution_end")({ toolName: "subagent" });
    await until(() => reports.at(-1)?.some((c) => c.runID === "workflow"));
    assert.deepEqual(reports.at(-1).slice(0, 2).map((c) => c.state), ["running", "queued"]);
    assert.equal(reports.at(-1).length, 20);
    assert(reports.at(-1).slice(2).every((c) => c.needsAttention));
  } finally {
    handlers.get("session_shutdown")?.();
    await new Promise((r) => server.close(r));
    for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key]; Object.assign(process.env, saved);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("an unchanged native children list is not republished", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-dedupe-"));
  const saved = { ...process.env }, reports = [], handlers = new Map(), bus = new Map();
  const server = net.createServer((socket) => socket.on("data", mod.jsonLines((data) => reports.push(data.children), assert.fail)));
  process.env.SHEPHERD_AGENT_ID = "fixture"; process.env.SHEPHERD_SOCKET = path.join(dir, "s.sock");
  delete process.env.SHEPHERD_CHILD;
  await new Promise((r) => server.listen(process.env.SHEPHERD_SOCKET, r));
  try {
    const publisher = await jiti.import(path.join(root, "Extensions/shepherd-subagents.ts"));
    const emit = (name, data) => bus.get(name)?.(data);
    publisher.default({ on: (name, fn) => handlers.set(name, fn), events: { on: (name, fn) => bus.set(name, fn), emit } });
    handlers.get("session_start")({}, { hasUI: true, sessionManager: { getSessionId: () => "owner" } });
    const row = { runID: "native-0", state: "running" };
    // The children extension re-emits the same list every second; only the first is news.
    for (let i = 0; i < 3; i++) {
      emit("shepherd:children:v1", { owner: "owner", children: [row] });
      await new Promise((r) => setTimeout(r, 600)); // past the 400ms publish debounce
    }
    assert.equal(reports.length, 1);
    emit("shepherd:children:v1", { owner: "owner", children: [{ ...row, state: "complete" }] });
    await until(() => reports.length >= 2);
    assert.equal(reports.at(-1)[0].state, "complete");
  } finally {
    handlers.get("session_shutdown")?.();
    await new Promise((r) => server.close(r));
    for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key]; Object.assign(process.env, saved);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("real Pi RPC lifecycle: parallel, role tools, isolation, messaging, wait, result, cancellation, continuation, inspector and late callbacks", { timeout: 120000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-native-"));
  const { server, requests } = fixtureServer();
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const saved = { ...process.env };
  process.env.HOME = dir; delete process.env.PI_SUBAGENT_EXTRA_AGENT_DIRS;
  process.env.PI_CODING_AGENT_DIR = path.join(dir, "config");
  process.env.PI_OFFLINE = "1";
  process.env.SHEPHERD_NATIVE_CHILDREN = "1"; process.env.SHEPHERD_AGENT_ID = "fixture";
  process.env.SHEPHERD_SOCKET = path.join(dir, "shepherd.sock"); process.env.SHEPHERD_EXT_CHILDREN = source;
  fs.mkdirSync(process.env.PI_CODING_AGENT_DIR);
  fs.writeFileSync(path.join(process.env.PI_CODING_AGENT_DIR, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: [{ id: "fixture", name: "fixture", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  // User extensions are inherited through Pi's filters; project extensions stay isolated.
  fs.mkdirSync(path.join(dir, ".pi", "extensions"), { recursive: true });
  fs.writeFileSync(path.join(dir, ".pi", "extensions", "poison.ts"), `throw new Error("project discovery escaped");`);
  // Stand-in for Shepherd's extension socket: accepts the children control channel (helloChildren)
  // and lets the test drive childCommand frames the way the native thread cards do.
  const control = { sockets: [], frames: [] };
  const controlServer = net.createServer((socket) => {
    socket.on("data", mod.jsonLines((frame) => { control.frames.push(frame); if (frame.type === "helloChildren") control.sockets.push(socket); }, () => {}));
    socket.on("error", () => {});
  });
  await new Promise((r) => controlServer.listen(process.env.SHEPHERD_SOCKET, r));
  let controlSequence = 0;
  const childCommand = async (fields) => {
    const id = ++controlSequence;
    control.sockets.at(-1).write(JSON.stringify({ type: "childCommand", id, ...fields }) + "\n");
    await until(() => control.frames.some((f) => f.type === "childCommandResult" && f.id === id));
    return control.frames.find((f) => f.type === "childCommandResult" && f.id === id);
  };
  let h;
  try {
    h = await harness(dir);
    await until(() => control.sockets.length === 1);
    assert.equal(control.frames[0].agentID, "fixture");
    // An arbitrary provider exists only in a configured user extension. Children must load
    // it without granting the unrelated tool that the same extension registers.
    const extensionDir = path.join(process.env.PI_CODING_AGENT_DIR, "extensions");
    fs.mkdirSync(extensionDir, { recursive: true });
    const providerFile = path.join(extensionDir, "provider.ts");
    fs.writeFileSync(providerFile, `export default function(pi) {
      pi.registerProvider("extension-fixture", {baseUrl:"http://127.0.0.1:${server.address().port}/v1",api:"openai-completions",apiKey:"local-fixture-not-secret",
        models:[{id:"extension-model",name:"extension-model",reasoning:false,input:["text"],contextWindow:64000,maxTokens:1024,cost:{input:0,output:0,cacheRead:0,cacheWrite:0}}]});
      pi.registerTool({name:"unexpected_tool",label:"unexpected",description:"Must not reach the child model",parameters:{type:"object",properties:{}},async execute(){throw Error("tool leaked");}});
    }`);
    const originalCatalog = h.ctx.modelRegistry.getAll;
    h.ctx.modelRegistry.getAll = () => [...originalCatalog(), {provider:"extension-fixture",id:"extension-model"}];
    const extensionChild = await h.call("start", {task:"extension provider child",role:"scout",model:"extension-fixture/extension-model"});
    const extensionDone = await h.call("wait", {ids:[extensionChild.id],all:true,timeoutSeconds:30});
    assert.equal(extensionDone[0].state, "complete");
    assert.match(extensionDone[0].output, /reply:extension provider child/);
    const extensionRequests = requests.filter((r) => r.model === "extension-model");
    assert(extensionRequests.length > 0, "extension-only provider was not called");
    assert(extensionRequests.every((r) => (r.tools ?? []).every((t) => ["read","grep","find","ls","shepherd_parent_message"].includes(t.function.name))), "extension tools exceeded the allowlist");
    await h.call("resume", {id:extensionChild.id,message:"resume extension provider child"});
    const extensionResumed = await h.call("wait", {ids:[extensionChild.id],all:true,timeoutSeconds:30});
    assert.equal(extensionResumed[0].state, "complete");
    fs.unlinkSync(providerFile);
    h.ctx.modelRegistry.getAll = originalCatalog;
    h.messages.length = 0;
    h.ctx.mode = "rpc"; h.ctx.hasUI = true; h.ctx.ui = { notify() {}, confirm: async () => false };
    assert(h.commands.has("run"));
    await h.commands.get("run").handler("scout slash foreground --fork", h.ctx);
    const slashReport = h.entries.filter((e) => e.customType === "shepherd-native-report").at(-1).data.text;
    assert.match(slashReport, /complete/);
    assert.equal(h.messages.length, 0, "slash launch must not trigger a parent turn");
    const slashChild = (await h.call("result", {})).at(-1);
    const slashResult = await h.call("result", {id: slashChild.id});
    assert.equal(slashResult.context, "fork"); assert.equal(slashResult.state, "complete");
    assert(Number.isFinite(slashResult.endedAt));
    const persisted = JSON.parse(fs.readFileSync(path.join(path.dirname(slashResult.sessionFile), "status.json")));
    assert.equal(persisted.endedAt, slashResult.endedAt);
    await h.commands.get("run").handler("scout slash background --bg", h.ctx);
    await until(() => h.entries.some((e) => e.customType === "shepherd-native-report" && e.data.text.includes("complete") && !e.data.text.includes(slashChild.id) && e.data.text.includes("background")));
    assert.equal(h.messages.length, 0);
    const pair = await Promise.all([h.call("start", { task: "SLOW one", role: "scout" }), h.call("start", { task: "SLOW two", role: "reviewer" })]);
    assert.notEqual(pair[0].id, pair[1].id);
    const done = await h.call("wait", { ids: pair.map((r) => r.id), all: true, timeoutSeconds: 30 });
    assert.deepEqual(done.map((r) => r.state), ["complete", "complete"], JSON.stringify(done));
    // Card projection for a finished background child: counters, summary, spawn call id.
    const doneCard = h.projections.at(-1).children.find((c) => c.runID === pair[0].id);
    assert.equal(doneCard.state, "complete"); assert.equal(doneCard.role, "scout"); assert.equal(doneCard.context, "background");
    assert.equal(doneCard.model, "fixture/fixture"); assert.equal(doneCard.toolCallID, "call"); assert.equal(doneCard.step, undefined);
    assert.equal(doneCard.turns, 1); assert.equal(doneCard.toolCalls, 0); assert.equal(doneCard.tokens, 2);
    assert.deepEqual(doneCard.result, { files: 0, added: 0, removed: 0, tools: 0, tokens: 2 });
    assert.match(doneCard.output, /reply:/); assert.equal(doneCard.task, "SLOW one"); assert.equal(doneCard.sessionFile, pair[0].sessionFile);
    assert.equal(doneCard.question, undefined); assert.equal(doneCard.exitReason, undefined);
    // Completed-run fields: summary from the output, the child's own session id, cwd; no files when none were touched.
    assert.equal(doneCard.summary, mod.summarize(doneCard.output)); assert.equal(doneCard.cwd, fs.realpathSync(dir)); assert.equal(doneCard.files, undefined);
    assert.equal(doneCard.sessionID, JSON.parse(fs.readFileSync(pair[0].sessionFile, "utf8").split("\n")[0]).id);
    assert(requests.every((r) => !r.tools?.some((t) => ["bash", "write", "edit", "shepherd_child_start"].includes(t.function.name))));
    assert.equal(h.messages.length, 2); assert(h.messages.every((m) => m.options.triggerTurn && m.options.deliverAs === "followUp"));
    const firstFile = pair[0].sessionFile;
    await h.call("resume", { id: pair[0].id, message: "continued" });
    await assert.rejects(h.call("resume", { id: pair[0].id, message: "double writer" }), /already active/);
    const resumed = (await h.call("wait", { ids: [pair[0].id], timeoutSeconds: 30 }))[0];
    assert.equal(resumed.state, "complete"); assert.equal(resumed.sessionFile, firstFile);
    assert(fs.readFileSync(firstFile, "utf8").includes("continued"));
    assert(requests.some((r) => r.messages.filter((m) => m.role === "user").length >= 2));
    const limited = await h.call("start", { task: "TOKEN_LIMIT", role: "scout" });
    const partial = (await h.call("wait", { ids: [limited.id], timeoutSeconds: 30 }))[0];
    assert.equal(partial.state, "failed"); assert.equal(partial.stopReason, "length"); assert.match(partial.error, /Incomplete/);
    const failedCard = h.projections.at(-1).children.find((c) => c.runID === limited.id);
    assert.match(failedCard.exitReason, /^Incomplete answer/); assert.equal(failedCard.result, undefined); assert.equal(failedCard.summary, undefined);
    const ask = await h.call("start", { task: "ASK_PARENT", role: "scout" });
    const asked = (await h.call("wait", { ids: [ask.id], timeoutSeconds: 30 }))[0];
    assert(asked.needsReply); assert(h.messages.some((m) => m.message.content.includes("Needs reply")));
    const askCard = h.projections.at(-1).children.find((c) => c.runID === ask.id);
    assert.deepEqual(askCard.question, { text: "Need a decision", options: ["Replace everywhere", "Rename new ones"] });
    assert.equal(askCard.lastActivity.tool, "shepherd_parent_message"); assert.equal(askCard.toolCalls, 1);
    assert(Number.isFinite(askCard.lastActivity.at));
    await h.shutdown();
    h = await harness(dir, h.entries);
    const restoredQuestion = await h.call("result", { id: ask.id });
    assert.equal(restoredQuestion.needsReply, true); assert.equal(restoredQuestion.stopReason, "stop");
    assert.equal((await h.call("result", { id: limited.id })).stopReason, "length");
    assert(h.projections.at(-1).children.some((c) => c.runID === ask.id && c.needsAttention));
    assert.deepEqual(h.projections.at(-1).children.find((c) => c.runID === ask.id).question.options, ["Replace everywhere", "Rename new ones"], "question options survive a parent restart");
    // The control channel reconnects with the new parent; a card answer resumes the settled child.
    await until(() => control.sockets.length === 2);
    assert.deepEqual(await childCommand({ runID: ask.id, action: "message", text: "card answer", mode: "steer" }), { type: "childCommandResult", id: 1 });
    await h.call("wait", { ids: [ask.id], timeoutSeconds: 30 });
    assert(fs.readFileSync(asked.sessionFile, "utf8").includes("card answer"));
    assert.equal((await h.call("result", { id: ask.id })).needsReply, false);
    assert.match((await childCommand({ runID: "native-missing", action: "cancel" })).error, /Unknown child id/);
    assert.match((await childCommand({ runID: ask.id, action: "message", text: "   " })).error, /Invalid child message/);
    assert.match((await childCommand({ runID: ask.id, action: "unsupported" })).error, /Unsupported/);
    let fleet;
    const fleetContext = { ...h.ctx, mode: "tui", hasUI: true, ui: { custom: async (factory) => {
      fleet = factory({ terminal: { rows: 36 }, requestRender() {} }, { fg: (_c, text) => text }, { matches: () => false, getKeys: () => ["esc"] }, () => {});
    } } };
    await h.commands.get("subagents-fleet").handler(ask.id, fleetContext);
    const uiReply = await fleet.runtime.send(pair[0].id, "fleet answer", "steer");
    assert.equal(uiReply.mode, "reply");
    await h.call("wait", { ids: [pair[0].id], timeoutSeconds: 30 });
    assert(fs.readFileSync(firstFile, "utf8").includes("fleet answer"));
    const askDir = path.dirname(asked.sessionFile), askStatus = () => JSON.parse(fs.readFileSync(path.join(askDir, "status.json")));
    fs.writeFileSync(path.join(askDir, "control", "steer-requests", "answer.json"), JSON.stringify({ message: "inspector answer" }));
    await until(() => askStatus().controlRequestID === "answer" && askStatus().controlNotice === "reply accepted or queued");
    await h.call("wait", { ids: [ask.id], timeoutSeconds: 30 });
    assert(fs.readFileSync(asked.sessionFile, "utf8").includes("inspector answer"));
    assert.equal((await h.call("result", {id: ask.id})).needsReply, false);
    // Resume saves running state before Pi acknowledges the new prompt.
    fs.writeFileSync(path.join(askDir, "control", "steer-requests", "second-answer.json"), JSON.stringify({ message: "second inspector answer" }));
    await until(() => askStatus().state === "running");
    assert.equal(askStatus().controlRequestID, "answer", "launch must not publish the new request ID with the previous acceptance");
    await until(() => askStatus().controlRequestID === "second-answer" && askStatus().controlNotice === "reply accepted or queued");
    await h.call("wait", { ids: [ask.id], timeoutSeconds: 30 });
    assert(fs.readFileSync(asked.sessionFile, "utf8").includes("second inspector answer"));
    const leaseDir = path.join(askDir, "writer"); fs.mkdirSync(leaseDir);
    fs.writeFileSync(path.join(leaseDir, "owner.json"), JSON.stringify({pid:process.pid,token:"fixture"}));
    await assert.rejects(fleet.runtime.send(ask.id, "lease must reject", "steer"), /Child session already has a live writer/);
    fs.writeFileSync(path.join(askDir, "control", "steer-requests", "lease.json"), JSON.stringify({ message: "lease must reject" }));
    await until(() => askStatus().controlRequestID === "lease" && askStatus().controlNotice === "control failed: Child session already has a live writer");
    fs.rmSync(leaseDir,{recursive:true});
    // Files touched by edit/write aggregate per path (write counts no lines, the edit adds two).
    const editor = await h.call("start", { task: `WRITE_THEN_EDIT:${path.join(dir, "touched.txt")}`, role: "worker" });
    assert.equal((await h.call("wait", { ids: [editor.id], timeoutSeconds: 30 }))[0].state, "complete");
    const editorCard = h.projections.at(-1).children.find((c) => c.runID === editor.id);
    assert.deepEqual(editorCard.files, [{ path: path.join(dir, "touched.txt"), added: 2, removed: 0 }]);
    assert.deepEqual(editorCard.result, { files: 1, added: 2, removed: 0, tools: 2, tokens: 4 });
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(path.dirname(editor.sessionFile), "status.json"))).files, editorCard.files);
    const shell = await h.call("start", { task: `SHELL:printf '%s' "$SHEPHERD_AGENT_ID:$SHEPHERD_SOCKET:$SHEPHERD_CHILD" > '${dir}/env'; sleep 20`, role: "worker" });
    await until(() => fs.existsSync(path.join(dir, "env"))); assert.equal(fs.readFileSync(path.join(dir, "env"), "utf8"), "::1");
    const shellCard = h.projections.at(-1).children.find((c) => c.runID === shell.id);
    assert.equal(shellCard.currentTool, "bash"); assert.equal(shellCard.state, "running");
    const receipt = await fleet.runtime.send(shell.id, "queued message", "followUp"); assert.equal(receipt.mode, "followUp"); assert.match(receipt.delivery, /accepted/);
    const timeout = await h.call("wait", { ids: [shell.id], timeoutSeconds: 0.05 }); assert.equal(timeout[0].state, "running");
    const runDir = path.dirname(shell.sessionFile);
    fs.writeFileSync(path.join(runDir, "control", "steer-requests", "fixture.json"), JSON.stringify({ message: "inspector message" }));
    await until(() => JSON.parse(fs.readFileSync(path.join(runDir, "status.json"))).controlNotice === "message accepted or queued");
    fs.writeFileSync(path.join(runDir, "control", "stop.json"), JSON.stringify({ id: "stop-fixture", type: "stop" }));
    const cancelled = (await h.call("wait", { ids: [shell.id], timeoutSeconds: 30 }))[0]; assert.equal(cancelled.state, "stopped");
    const stoppedCard = h.projections.at(-1).children.find((c) => c.runID === shell.id);
    assert.equal(stoppedCard.lastActivity.tool, "bash"); assert.match(stoppedCard.lastActivity.preview, /^printf/); assert.equal(stoppedCard.toolCalls, 1);
    const stopStatus = () => JSON.parse(fs.readFileSync(path.join(runDir, "status.json")));
    await until(() => stopStatus().controlRequestID === "stop-fixture");
    assert.equal(stopStatus().controlNotice, "stop accepted · stopped");
    assert(!requests.some((r) => r.messages.at(-1)?.content === "queued message"));
    h.activeTools.splice(h.activeTools.indexOf("bash"), 1);
    h.activeTools.splice(h.activeTools.indexOf("edit"), 1);
    h.activeTools.splice(h.activeTools.indexOf("write"), 1);
    await h.call("resume", { id: shell.id, message: "narrowed continuation" });
    await h.call("wait", { ids: [shell.id], timeoutSeconds: 30 });
    assert(!requests.at(-1).tools.some((t) => ["bash", "edit", "write"].includes(t.function.name)));
    h.activeTools.push("bash", "edit", "write");
    const aborted = new AbortController(); aborted.abort();
    const priorRuns = (await h.call("result", {})).length;
    await assert.rejects(h.call("start", { task: "never dispatched" }, aborted.signal));
    assert.equal((await h.call("result", {})).length, priorRuns);
    // Pause waits at the next provider-request boundary without cancelling the current tool.
    const pausing = await h.call("start", { task: "SHELL:sleep 1; echo pause-boundary", role: "worker" });
    const pauseReceipt = await childCommand({ runID: pausing.id, action: "pause" });
    assert.equal(pauseReceipt.error, undefined);
    await until(() => h.projections.at(-1).children.some((c) => c.runID === pausing.id && c.paused));
    await sleep(1500);
    const held = await h.call("result", { id: pausing.id });
    assert.equal(held.state, "running", "pause must not complete or kill the child");
    const continueReceipt = await childCommand({ runID: pausing.id, action: "continue" });
    assert.equal(continueReceipt.error, undefined);
    const unpaused = await h.call("wait", { ids: [pausing.id], all: true, timeoutSeconds: 30 });
    assert.equal(unpaused[0].state, "complete");
    const cancelPaused = await h.call("start", { task: "SHELL:sleep 1; echo cancel-paused", role: "worker" });
    assert.equal((await childCommand({ runID: cancelPaused.id, action: "pause" })).error, undefined);
    await sleep(1500);
    assert.equal((await childCommand({ runID: cancelPaused.id, action: "cancel" })).error, undefined);
    assert.equal((await h.call("result", { id: cancelPaused.id })).state, "stopped");

    const busy = await Promise.all(Array.from({ length: 4 }, (_, i) => h.call("start", { task: `SHELL:sleep 30 >/dev/null 2>&1 & echo $! > '${dir}/busy-${i}'`, role: "worker" })));
    await until(() => fs.existsSync(path.join(dir, "busy-3")));
    await assert.rejects(h.call("start", { task: "over capacity" }), /Four children/);
    await assert.rejects(fleet.runtime.send(ask.id, "cap must reject", "steer"), /Four children are already active; wait or cancel first/);
    fs.writeFileSync(path.join(askDir, "control", "steer-requests", "cap.json"), JSON.stringify({ message: "cap must reject" }));
    await until(() => askStatus().controlRequestID === "cap" && askStatus().controlNotice === "control failed: Four children are already active; wait or cancel first");
    // Card Stop goes through the same channel and waits for exit.
    assert.deepEqual(await childCommand({ runID: busy[0].id, action: "cancel" }), { type: "childCommandResult", id: controlSequence });
    assert.equal((await h.call("result", { id: busy[0].id })).state, "stopped");
    await Promise.all(busy.slice(1).map((r) => h.call("cancel", { id: r.id })));
    for (let i = 0; i < 4; i++) await until(() => !live(Number(fs.readFileSync(path.join(dir, `busy-${i}`)))));
    // Card Retry resumes with the original task.
    assert.deepEqual(await childCommand({ runID: limited.id, action: "resume" }), { type: "childCommandResult", id: controlSequence });
    await h.call("wait", { ids: [limited.id], timeoutSeconds: 30 });
    const userTurns = fs.readFileSync(partial.sessionFile, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)).filter((e) => e.message?.role === "user");
    assert(userTurns.length >= 2 && JSON.stringify(userTurns.at(-1).message.content).includes("TOKEN_LIMIT"), `resume re-sends the original task: ${JSON.stringify(userTurns.at(-1))}`);
    const priorCatalog = h.ctx.modelRegistry.getAll;
    h.ctx.modelRegistry.getAll = () => [...priorCatalog(), { provider: "parent-only", id: "unavailable" }, { provider: "fixture", id: "parent-only-model" }];
    const beforeUnsupported = requests.length;
    await assert.rejects(h.call("start", { task: "must not run", model: "parent-only/unavailable", role: "scout" }));
    assert.equal(requests.length, beforeUnsupported);
    await assert.rejects(h.call("start", { task: "must not run", model: "fixture/parent-only-model", role: "scout" }), /unavailable in isolated Pi/);
    assert.equal(requests.length, beforeUnsupported);
    h.ctx.modelRegistry.getAll = priorCatalog;
    // Even newer unanswered questions cannot hide a resumed running child.
    for (let i = 0; i < 20; i++) {
      const short = await h.call("start", { task: `ASK_PARENT history ${i}`, role: "scout" });
      await h.call("wait", { ids: [short.id], timeoutSeconds: 30 });
    }
    await h.call("resume", { id: pair[0].id, message: "SLOW old resumed child" });
    assert(h.projections.at(-1).children.some((c) => c.runID === pair[0].id && c.state === "running"));
    await h.call("wait", { ids: [pair[0].id], timeoutSeconds: 30 });
    // Hard parent death: a separate owner holds RPC stdin. Killing just that
    // owner must make real Pi observe EOF and stop its in-flight bash descendant.
    const ownerScript = path.join(dir, "owner.mjs");
    fs.writeFileSync(ownerScript, `import { spawn } from 'node:child_process'; import * as fs from 'node:fs';\nconst child = spawn(process.execPath, ${JSON.stringify([path.join(pkg, "dist/cli.js"), "--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-approve", "-e", source, "--session", path.join(dir, "hard-death.jsonl"), "--model", "fixture/fixture", "--tools", "bash"])}, { env: { ...process.env, SHEPHERD_CHILD: '1' }, stdio: ['pipe','pipe','pipe'], detached: false });\nfs.writeFileSync(${JSON.stringify(path.join(dir, "rpc-pid"))}, String(child.pid));\nchild.stdout.resume(); child.stderr.resume(); child.stdin.on('error',()=>{});\nchild.stdin.write(JSON.stringify({ type: 'prompt', message: ${JSON.stringify(`SHELL:sleep 30 & echo $! > '${dir}/descendant-pid'; wait`)} })+'\\n');\nsetInterval(()=>{},1000);`);
    const ownerProc = spawn(process.execPath, [ownerScript], { cwd: dir, env: process.env, detached: true, stdio: "ignore" });
    try {
      await until(() => fs.existsSync(path.join(dir, "descendant-pid")));
      const rpcPID = Number(fs.readFileSync(path.join(dir, "rpc-pid"))), descendantPID = Number(fs.readFileSync(path.join(dir, "descendant-pid")));
      ownerProc.kill("SIGKILL");
      await until(() => !live(rpcPID) && !live(descendantPID));
      // Shepherd's shutdown is a group SIGHUP immediately followed by SIGKILL.
      fs.unlinkSync(path.join(dir, "descendant-pid"));
      const groupOwner = spawn(process.execPath, [ownerScript], { cwd: dir, env: process.env, detached: true, stdio: "ignore" });
      try {
        await until(() => fs.existsSync(path.join(dir, "descendant-pid")));
        const childPID = Number(fs.readFileSync(path.join(dir, "rpc-pid"))), shellPID = Number(fs.readFileSync(path.join(dir, "descendant-pid")));
        process.kill(-groupOwner.pid, "SIGHUP"); try { process.kill(-groupOwner.pid, "SIGKILL"); } catch {}
        await until(() => !live(childPID) && !live(shellPID));
      } finally { try { process.kill(-groupOwner.pid, "SIGKILL"); } catch {} }
    } finally { try { process.kill(-ownerProc.pid, "SIGKILL"); } catch {} }
    // Exercise the real parent's runtime replacement, not just the harness hook.
    const driver = path.join(dir, "parent-driver.ts");
    fs.writeFileSync(driver, `import children from ${JSON.stringify(source)};\nexport default function(pi) { const tools = new Map(); children(new Proxy(pi, { get(target, key) { if (key === 'registerTool') return (tool) => { tools.set(tool.name, tool); target.registerTool(tool); }; return target[key]; } }));\npi.registerCommand('run', {description:'foreign run collision',handler:async()=>{}});\npi.registerCommand('fixture-start', { description:'fixture', handler: async (args, ctx) => { const data = await tools.get('shepherd_child_start').execute('fixture', { task: args, role:'worker' }, undefined, undefined, ctx); ctx.ui.notify(JSON.stringify(data.details)); } });\npi.registerCommand('fixture-reload', { description:'fixture reload', handler: async (_args, ctx) => { await ctx.reload(); } });\n}`);
    const actual = spawn(process.execPath, [path.join(pkg, "dist/cli.js"), "--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-approve", "-e", driver, "--session", path.join(dir, "actual-parent.jsonl"), "--model", "fixture/fixture"],
      { cwd: dir, env: process.env, stdio: ["pipe", "pipe", "pipe"] });
    const actualEvents = [], actualErrors = [];
    actual.stdout.on("data", mod.jsonLines((e) => actualEvents.push(e), (e) => actualErrors.push(e.message)));
    actual.stderr.on("data", (d) => actualErrors.push(d.toString())); actual.stdin.on("error", () => {});
    let sequence = 0;
    const rpc = async (type, fields = {}) => { const id = `actual-${++sequence}`; actual.stdin.write(JSON.stringify({ id, type, ...fields }) + "\n"); await until(() => actualEvents.some((e) => e.id === id && e.type === "response"), 30000); const response = actualEvents.find((e) => e.id === id && e.type === "response"); assert(response.success, JSON.stringify(response)); return response.data; };
    try {
      await rpc("get_state");
      const registered = (await rpc("get_commands")).commands;
      assert(registered.some((c) => c.name === "run"));
      assert(registered.some((c) => c.name === "shepherd-run"));
      assert(!registered.some((c) => /^run:/.test(c.name)));
      const reportsBefore = requests.length;
      await rpc("prompt", {message:"/shepherd-subagents-doctor"});
      assert.equal(requests.length, reportsBefore, "doctor never calls a provider");
      await rpc("prompt", { message: `/fixture-start SHELL:sleep 30 >/dev/null 2>&1 & echo $! > '${dir}/switch-child'` });
      await until(() => fs.existsSync(path.join(dir, "switch-child")));
      const switchPID = Number(fs.readFileSync(path.join(dir, "switch-child")));
      const replacement = await rpc("new_session"); assert.equal(replacement.cancelled, false);
      await until(() => !live(switchPID));
      const state = await rpc("get_state"); assert.equal(state.messageCount, 0);
      await rpc("prompt", { message: `/fixture-start SHELL:sleep 30 >/dev/null 2>&1 & echo $! > '${dir}/reload-child'` });
      await until(() => fs.existsSync(path.join(dir, "reload-child")));
      const reloadPID = Number(fs.readFileSync(path.join(dir, "reload-child")));
      await rpc("prompt", { message: "/fixture-reload" });
      await until(() => !live(reloadPID));
      const messagesAfter = await rpc("get_messages");
      assert(!messagesAfter.messages.some((m) => m.customType === "shepherd-child"));
    } finally { actual.stdin.end(); await until(() => actual.exitCode !== null || actual.signalCode !== null).catch(() => actual.kill("SIGKILL")); }
    fs.mkdirSync(path.join(dir, ".pi", "agents"), { recursive: true });
    const profilePath = path.join(dir, ".pi", "agents", "minimal.md");
    fs.writeFileSync(profilePath, '---\nname: minimal\ndescription: minimal profile\nmodel: inherit\n---\nPROFILE_MARKER\n');
    h.activeTools.push("pane_open");
    const minimal = await h.call("start", { task: "minimal profile test", agent: "minimal", mission: false });
    await h.call("wait", { ids: [minimal.id], timeoutSeconds: 30 });
    assert.equal(minimal.missionId, undefined);
    assert.deepEqual(minimal.tools, ["read", "bash", "edit", "write"]);
    h.activeTools.splice(h.activeTools.indexOf("pane_open"), 1);
    fs.writeFileSync(profilePath, '---\nname: minimal\ndescription: minimal profile\nmodel: fixture:high\nthinking: low\ntools: read\ndefaultContext: fresh\n---\nPROFILE_MARKER\n');
    const custom = await h.call("start", { task: "profile precedence", agent: "minimal", thinking: "off", mission: false });
    assert.equal(custom.thinking, "off"); assert.equal(custom.model, "fixture/fixture");
    await h.call("wait", { ids: [custom.id], timeoutSeconds: 30 });
    fs.writeFileSync(profilePath, '---\nname: minimal\ndescription: changed profile\ntools: read, bash, edit, write\n---\nnew role\n');
    h.activeTools.splice(h.activeTools.indexOf("read"), 1);
    await h.call("resume", { id: custom.id, message: "narrow across restart" });
    await h.call("wait", { ids: [custom.id], timeoutSeconds: 30 });
    h.activeTools.push("read");
    await h.shutdown();
    process.env.SHEPHERD_CHILD_CONCURRENCY = "2"; process.env.SHEPHERD_CHILD_THINKING = "high";
    process.env.SHEPHERD_CHILD_MODEL = "fixture/fixture"; process.env.SHEPHERD_CHILD_CONTEXT = "fork";
    h = await harness(dir, h.entries);
    const defaultsRun = await h.call("start", { task: "configured defaults", role: "scout", mission: false });
    assert.equal(defaultsRun.thinking, "high"); assert.equal(defaultsRun.context, "fork"); assert.equal(defaultsRun.model, "fixture/fixture");
    await h.call("wait", { ids: [defaultsRun.id], timeoutSeconds: 30 });
    const configuredProfile = await h.call("start", { task: "profile overrides defaults", agent: "minimal", mission: false });
    await h.call("wait", { ids: [configuredProfile.id], timeoutSeconds: 30 });
    const continued = await h.call("resume", { id: custom.id, message: "must not regain tools after reload" });
    assert.deepEqual(continued.tools, []);
    await h.call("wait", { ids: [custom.id], timeoutSeconds: 30 });
    const workflow = await h.tool("shepherd_workflow", { async: false, task: "fixture workflow", workflowScript: `
      const scan = await runs.run("scan", { agent: "scout", task: "workflow scan" });
      await state.set("scan", scan.output);
      if (!scan.output.includes("scan")) throw Error("missing scan");
      const pair = await runs.all([{ key: "a", agent: "reviewer", task: scan.output }, { key: "b", agent: "scout", task: "parallel review" }]);
      return { outputs: pair.map(r => r.output), stored: await state.get("scan") };
    ` });
    assert.equal(workflow.state, "complete", JSON.stringify(workflow));
    assert.equal(workflow.output.outputs.length, 2);
    // Workflow children carry their step and the enclosing workflow call; a synchronous workflow is still "background".
    const scanRun = await h.call("result", { id: workflow.children.find((k) => k.key === "scan").id });
    assert.equal(scanRun.stepIndex, 1); assert.equal(scanRun.toolCallID, "call");
    assert.equal((await h.call("result", { id: workflow.children.find((k) => k.key === "b").id })).stepIndex, 3);
    assert.match(workflow.output.stored, /workflow scan/);
    const mission = await h.tool("shepherd_mission", { action: "show", id: workflow.missionId });
    assert.equal(mission.runs.length, 3); assert.equal(mission.status, "waiting");
    await h.tool("shepherd_mission", { action: "attachment", id: mission.id, attachment: { title: "proof", uri: "https://example.invalid/proof" } });
    await h.tool("shepherd_mission", { action: "close", id: mission.id, summary: "verified" });
    assert.equal((await h.tool("shepherd_mission", { action: "show", id: mission.id })).attachments.length, 1);
    const steering = await h.tool("shepherd_workflow", { async: false, mission: false, workflowScript: `
      const writer = runs.run("writer", {agent:"worker",task:"SHELL:sleep 2"});
      await runs.run("evidence", {agent:"scout",task:"steering evidence"});
      const receipt = await runs.steer("writer", "apply steering evidence", {mode:"follow_up"});
      return { writer: await writer, receipt };
    ` });
    assert.equal(steering.state, "complete", JSON.stringify(steering));
    assert.match(steering.output.receipt.delivery, /accepted/);
    const unawaited = await h.tool("shepherd_workflow", { async: false, mission: false, workflowScript: 'runs.run("loose", {agent:"worker",task:"SHELL:sleep 30"}); return 1;' });
    assert.equal(unawaited.state, "failed"); assert.match(unawaited.error, /pending|unfinished/);
    assert(unawaited.children.every((c) => !["running", "queued"].includes(c.state)));
    const ephemeral = await h.tool("shepherd_workflow", { async: false, mission: false, workflowScript: 'return typeof state;' });
    assert.equal(ephemeral.output, "undefined"); assert.equal(ephemeral.missionId, undefined);
    const invalid = await h.tool("shepherd_workflow", { async: false, mission: false, workflowScript: 'return runs.run("bad", {agent:"worker", task:"never", worktree:true});' });
    assert.equal(invalid.state, "failed"); assert.match(invalid.error, /Validation/);
    const scriptFailure = await h.tool("shepherd_workflow", { async: false, mission: false, workflowScript: 'throw Error("intentional");' });
    assert.equal(scriptFailure.state, "failed"); assert.match(scriptFailure.error, /intentional/);
    const slowWorkflow = await h.tool("shepherd_workflow", { mission: false, workflowScript: `return runs.run("slow", {agent:"worker", task:"SHELL:sleep 30"});` });
    await until(() => h.projections.at(-1).children.some((c) => c.label.includes("SHELL:sleep 30") && c.state === "running"));
    const owned = h.projections.at(-1).children.find((c) => c.label.includes("SHELL:sleep 30") && c.state === "running");
    assert.equal(owned.context, "async"); assert.deepEqual(owned.step, { index: 1, total: 1 });
    const cancelling = h.tool("shepherd_workflow", { action: "cancel", id: slowWorkflow.id });
    await assert.rejects(h.call("resume", { id: owned.runID, message: "must reject without detaching" }), /owned|already active/);
    const stoppedWorkflow = await cancelling;
    assert.equal(stoppedWorkflow.state, "stopped");
    assert(stoppedWorkflow.children.every((c) => c.state === "stopped"));
    const siblings = await h.tool("shepherd_workflow", { mission: false, workflowScript: `return await Promise.all([
      runs.run("one", {agent:"worker",task:"SHELL:sleep 30"}), runs.run("two", {agent:"worker",task:"SHELL:sleep 30"})]);` });
    let siblingStatus;
    await until(() => { siblingStatus = h.entries.filter((e) => e.customType === "shepherd-child" && e.data.workflowId === siblings.id); return siblingStatus.length === 2; });
    // Wait for both run keys to be registered, not just process admission.
    for (;;) { siblingStatus = await h.tool("shepherd_workflow", {action:"status",id:siblings.id}); if (siblingStatus.children.length === 2) break; await sleep(30); }
    const victim = siblingStatus.children[0].id;
    let confirmation;
    await h.commands.get("subagents-stop").handler(victim, { ...h.ctx, mode:"rpc",hasUI:true,ui:{notify(){},confirm:async(_title,text)=>{confirmation=text;return true;}} });
    assert(confirmation.includes(siblings.id)); assert(confirmation.includes("may cancel workflow siblings"));
    let endedSiblings = await h.tool("shepherd_workflow", {action:"wait",id:siblings.id,timeoutSeconds:30});
    const cleanupDeadline = Date.now()+15000;
    while (endedSiblings.children.some((c)=>c.state!=="stopped")) {
      assert(Date.now()<cleanupDeadline,"workflow sibling cleanup timed out"); await sleep(30);
      endedSiblings = await h.tool("shepherd_workflow", {action:"status",id:siblings.id});
    }
    assert.equal(endedSiblings.state,"failed"); assert.equal(endedSiblings.children.length,2);
    assert(endedSiblings.children.every((c)=>c.state==="stopped"), JSON.stringify(endedSiblings));
    const interrupted = await h.call("start", { task: "restore interrupted ledger", role: "scout" });
    await h.call("wait", { ids: [interrupted.id], timeoutSeconds: 30 });
    await h.shutdown();
    const statusFile = path.join(path.dirname(interrupted.sessionFile), "status.json");
    const interruptedStatus = JSON.parse(fs.readFileSync(statusFile)); interruptedStatus.state = "running";
    fs.writeFileSync(statusFile, JSON.stringify(interruptedStatus));
    h = await harness(dir, h.entries);
    const restoredMission = await h.tool("shepherd_mission", { action: "show", id: interrupted.missionId });
    assert.equal(restoredMission.runs.find((r) => r.id === interrupted.id).state, "stopped");
    assert.equal(restoredMission.status, "needs_decision");
    for (const withChild of [false, true]) {
      const ledger = await h.tool("shepherd_mission", { action: "create", title: withChild ? "last child finished" : "no child yet" });
      if (withChild) {
        const completedChild = await h.call("start", { task: "finished before script return", role: "scout", missionId: ledger.id });
        await h.call("wait", { ids: [completedChild.id], timeoutSeconds: 30 });
      }
      const { missionStore } = await jiti.import(path.join(root, "Extensions/shepherd-missions.ts"));
      missionStore(path.join(dir, "shepherd-native"), dir).update(ledger.id, (m) => { m.workflow = { id: `workflow-interrupted-${withChild}`, state: "running" }; });
      h.entries.push({ type: "custom", customType: "shepherd-workflow", data: { owner: "parent-fixture", ownerPID: process.pid, id: `workflow-interrupted-${withChild}`, missionId: ledger.id } });
      await h.shutdown(); h = await harness(dir, h.entries);
      const recovered = await h.tool("shepherd_mission", { action: "show", id: ledger.id });
      assert.equal(recovered.workflow.state, "stopped"); assert.equal(recovered.status, "needs_decision");
    }
    const last = await h.call("start", { task: "SLOW late completion", role: "scout" });
    const count = h.messages.length; await h.shutdown(); await sleep(900); assert.equal(h.messages.length, count);
    assert.equal((await h.call("result", { id: last.id })).state, "stopped");
    assert(h.projections.some((p) => p.children?.some((c) => c.runID === last.id && c.state === "running")));
    console.log(`Real Pi ${JSON.parse(fs.readFileSync(path.join(pkg, "package.json"))).version}: ${requests.length} local-provider requests, zero external model calls`);
  } finally {
    await h?.shutdown(); server.closeAllConnections(); await new Promise((r) => server.close(r));
    for (const socket of control.sockets) socket.destroy();
    await new Promise((r) => controlServer.close(r));
    for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key]; Object.assign(process.env, saved);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
