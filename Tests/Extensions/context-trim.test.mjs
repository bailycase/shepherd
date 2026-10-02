// Context clearing (Extensions/shepherd-context.ts): the old, bulky parts of a long run stay out of what the model
// is sent, and stay in the thread. The pure rules first, then the handler against a stand-in pi that grows a
// session of hundreds of calls from one user message, then a real pi in RPC mode on a fake provider that records
// every request: the request shrinks, the session file keeps every result, a run with the switch off sends the same
// bytes as a run without the extension, and compaction, /new, a restart and a branch all work.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/context-trim.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { createRequire } from "node:module";
import { root, scriptedBashCalls, startThread } from "./context-harness.mjs";

const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const source = path.join(root, "Extensions/shepherd-context.ts");
const { createJiti } = createRequire(path.join(pkg, "package.json"))("jiti");
const ext = await createJiti(import.meta.url).import(source);
const { clip, clipMarker, trimContext, planBatch, callsSince, limitsFrom, resultStub, imageStub, customStub, argumentStub, DEFAULTS, ENTRY } = ext;

const same = (a, b, message) => assert.ok(JSON.stringify(a) === JSON.stringify(b), message);

// MARK: building a conversation

let clock = 1_790_000_000_000;
const tick = () => (clock += 10);
const text = (value) => [{ type: "text", text: value }];
const user = (value = "go") => ({ role: "user", content: text(value), timestamp: tick() });
const big = (tokens, fill = "y") => fill.repeat(tokens * 4);
let serial = 0;

// One model call and its result: the assistant message (with a reasoning payload when asked), then the tool result.
function round({ tool = "read", args = { path: `src/file${serial}.swift` }, result = big(3000), reasoning = 0, api = "openai-responses", images = 0 } = {}) {
  const n = ++serial;
  const id = `call_${n}|fc_${n}`;
  const content = [];
  if (reasoning) content.push({ type: "thinking", thinking: "", thinkingSignature: JSON.stringify({ type: "reasoning", id: `rs_${n}`, encrypted_content: "e".repeat(reasoning) }) });
  content.push({ type: "toolCall", id, name: tool, arguments: args });
  const assistant = { role: "assistant", content, api, provider: "openai", model: "gpt-6-sol", usage: { input: 1, output: 1, totalTokens: 2 }, stopReason: "toolUse", timestamp: tick() };
  const blocks = text(result);
  for (let i = 0; i < images; i++) blocks.push({ type: "image", data: "AAAA", mimeType: "image/png" });
  return [assistant, { role: "toolResult", toolCallId: id, toolName: tool, content: blocks, isError: false, timestamp: tick() }];
}

const rounds = (count, options) => Array.from({ length: count }, () => round(options)).flat();
const clearedIn = (message) => /removed from context/.test(JSON.stringify(message));

// MARK: the clip

test("a result under the ceiling is left as it is, and the very same list comes back", () => {
  const messages = [user(), ...round({ result: "small" })];
  assert.equal(trimContext(messages), messages);
});

test("a result over the ceiling keeps its head and its tail around a marker that says how much went and what to do", () => {
  const lines = (n) => Array.from({ length: n }, (_, i) => `line ${i + 1} ${"x".repeat(40)}`).join("\n");
  const out = clip(lines(2000), 24_000);
  assert.ok(out.length <= 24_000, `${out.length} chars`);
  assert.ok(out.startsWith("line 1 "), "the head");
  assert.ok(out.trimEnd().endsWith(`line 2000 ${"x".repeat(40)}`), "the tail");
  const marker = out.match(/\[output trimmed in context: (\d+) lines\. Re-run with a narrower command, or read the part you need\.\]/);
  assert.ok(marker, "the marker");
  const kept = out.split("\n").filter((l) => l.startsWith("line ")).length;
  assert.equal(Number(marker[1]) + kept, 2000, "the marker counts exactly the lines that went");
  assert.equal(clipMarker("3 lines"), "[output trimmed in context: 3 lines. Re-run with a narrower command, or read the part you need.]");
});

test("a result that is one enormous line is cut by characters, and the marker says characters", () => {
  const out = clip("z".repeat(100_000), 24_000);
  assert.ok(out.length <= 24_000);
  assert.match(out, /\[output trimmed in context: \d+ characters\. /);
});

test("the clip applies to every result, the newest too, and changes only that result", () => {
  const first = round({ result: big(10_000) });
  const second = round({ result: "small" });
  const messages = [user(), ...first, ...second];
  const before = JSON.stringify(messages);
  const out = trimContext(messages);
  assert.equal(JSON.stringify(messages), before, "the input is untouched");
  assert.ok(out[2].content[0].text.length <= DEFAULTS.clipTokens * 4);
  assert.equal(out[2].toolCallId, first[1].toolCallId);
  for (const index of [0, 1, 3, 4]) assert.equal(out[index], messages[index], "an untouched message is the same object");
});

// MARK: what is old

test("everything older than the boundary becomes one line naming what it was; everything newer stays whole", () => {
  const messages = [user("start"), ...rounds(10, { result: big(2000) })];
  const boundary = messages[11].timestamp; // the 6th call and after stay
  const out = trimContext(messages, boundary);
  const results = out.filter((m) => m.role === "toolResult");
  assert.deepEqual(results.map((m) => /^\[read src\/file\d+\.swift output removed from context: about 2k tokens\./.test(m.content[0].text)), [true, true, true, true, true, false, false, false, false, false]);
  assert.equal(results[0].content[0].text, resultStub("read", messages[1].content[0].arguments.path, 2000));
  assert.equal(out[11], messages[11], "from the boundary on the same objects");
  assert.equal(out.length, messages.length);
  for (const [i, message] of out.entries()) if (message.role === "user" || message.role === "assistant") assert.ok(!message.content.some((b) => b.type === "text" && clearedIn(b)), `message ${i}`);
});

test("a result that is small stays even when it is old, and a bash result is named by its command", () => {
  const messages = [user(), ...round({ result: "ok" }), ...round({ tool: "bash", args: { command: "rg -n 'goal' Sources\nmore" }, result: big(500) }), ...rounds(3)];
  const out = trimContext(messages, messages.at(-5).timestamp);
  assert.equal(out[2], messages[2], "small and old: kept");
  assert.equal(out[4].content[0].text, resultStub("bash", "rg -n 'goal' Sources", 500));
});

test("images in an old result go, and the text next to them is kept when it is small", () => {
  const messages = [user(), ...round({ tool: "read", args: { path: "design.png" }, result: "(image)", images: 2 }), ...rounds(2)];
  const out = trimContext(messages, messages.at(-3).timestamp);
  assert.equal(out[2].content.filter((b) => b.type === "image").length, 0);
  assert.deepEqual(out[2].content.map((b) => b.text), ["(image)", imageStub(2)]);
});

test("the big strings in an old call's arguments go, and the call, its name and its path stay", () => {
  const contents = "let x = 1\n".repeat(900);
  const messages = [user(), ...round({ tool: "write", args: { path: "a/b.swift", content: contents } }),
    ...round({ tool: "edit", args: { path: "c.swift", edits: [{ oldText: "a".repeat(400), newText: "b".repeat(500) }, { oldText: "short", newText: "tiny" }] } }), ...rounds(3)];
  const out = trimContext(messages, messages.at(-5).timestamp);
  const [write] = out[1].content;
  assert.deepEqual(write.arguments, { path: "a/b.swift", content: argumentStub(contents.length) });
  assert.equal(write.name, "write");
  assert.equal(write.id, messages[1].content[0].id, "no reasoning went: the call keeps its id");
  const edit = out[3].content[0].arguments;
  assert.equal(edit.path, "c.swift");
  assert.deepEqual(edit.edits, [{ oldText: argumentStub(400), newText: argumentStub(500) }, { oldText: "short", newText: "tiny" }]);
});

test("an old reasoning payload goes with its calls' item ids, in the calls and in their results; the newest calls keep their own", () => {
  const messages = [user("go"), ...round({ reasoning: 9000 }), ...round({ reasoning: 9000 }), ...round({ reasoning: 9000 }), ...round({ reasoning: 9000 })];
  const out = trimContext(messages, messages[5].timestamp); // the first two calls are old
  const early = out[1];
  assert.ok(!early.content.some((b) => b.type === "thinking"), "the payload is gone");
  assert.equal(early.content[0].id, `call_${serial - 3}`, "the call's id is the call id alone");
  assert.equal(out[2].toolCallId, early.content[0].id, "and so is its result's, so they still pair");
  assert.ok(out.slice(5).every((m) => m.role !== "assistant" || m.content.some((b) => b.type === "thinking")), "the newest calls keep their reasoning");
  assert.ok(out.slice(5).every((m) => m.role !== "assistant" || m.content.at(-1).id.includes("|")), "and their ids");
});

test("reasoning is cleared only for the APIs that send it back and pair it with the call's item id", () => {
  const messages = [user("first"), ...round({ reasoning: 9000, api: "anthropic-messages" }), ...rounds(2)];
  const out = trimContext(messages, messages.at(-1).timestamp + 1);
  assert.ok(out[1].content.some((b) => b.type === "thinking"), "another API's thinking stays");
});

test("a hidden custom message of the past becomes one line, and the other roles are never touched", () => {
  const custom = { role: "custom", customType: "lsp-diagnostics", content: big(800), display: false, timestamp: tick() };
  const summary = { role: "compactionSummary", summary: big(9000), tokensBefore: 1, timestamp: tick() };
  const bash = { role: "bashExecution", command: "ls", output: big(9000), exitCode: 0, cancelled: false, truncated: false, timestamp: tick() };
  const thinking = { role: "assistant", content: [{ type: "thinking", thinking: big(2000) }, { type: "text", text: big(2000) }], api: "openai-responses", timestamp: tick() };
  const messages = [summary, user(big(5000)), custom, bash, thinking, ...rounds(2)];
  const out = trimContext(messages, messages.at(-1).timestamp + 1);
  assert.equal(out[2].content, customStub("lsp-diagnostics", 800));
  for (const index of [0, 1, 3, 4]) assert.equal(out[index], messages[index], `message ${index} is the same object`);
});

test("a message with no timestamp is never cleared", () => {
  const messages = [user(), ...round({ result: big(2000) })];
  delete messages[2].timestamp;
  assert.equal(trimContext(messages, Infinity)[2], messages[2]);
});

test("the same conversation and boundary always give the same bytes", () => {
  const messages = [user(), ...rounds(30, { result: big(2500), reasoning: 5000 }), user("again"), ...rounds(4)];
  const boundary = messages[40].timestamp;
  same(trimContext(messages, boundary), trimContext(structuredClone(messages), boundary), "pure");
});

// MARK: deciding on a batch

test("a batch takes the oldest first until the target is met and never reaches into the last calls", () => {
  const messages = [user(), ...rounds(60, { result: big(3000) })];
  const used = 150_000, window = 272_000;
  const plan = planBatch(messages, used, window);
  assert.ok(plan, "a plan");
  const need = used - (window * DEFAULTS.targetPercent) / 100;
  assert.ok(plan.saved >= need && plan.saved < need + 3500, `freed ${plan.saved} for ${Math.round(need)} needed`);
  const reach = messages.filter((m) => m.role === "assistant").at(-DEFAULTS.keepCalls).timestamp;
  assert.ok(plan.before <= reach, "never past the last 8 calls");
  const out = trimContext(messages, plan.before);
  const lastEight = messages.filter((m) => m.timestamp >= reach);
  assert.equal(lastEight.length, 16);
  for (const message of lastEight) assert.equal(out[messages.indexOf(message)], message, "the last 8 calls and their results are untouched");
  assert.ok(clearedIn(out[2]), "the oldest result went");
});

test("nothing is planned when the request is already under the target, when there are too few calls, or when little is clearable", () => {
  const messages = [user(), ...rounds(60, { result: big(3000) })];
  assert.equal(planBatch(messages, 80_000, 272_000), undefined, "under the target");
  assert.equal(planBatch([user(), ...rounds(DEFAULTS.keepCalls)], 200_000, 272_000), undefined, "only protected calls");
  assert.equal(planBatch([user(), ...rounds(40, { result: "tiny" })], 200_000, 272_000), undefined, "nothing clearable frees enough");
});

test("what a batch frees counts images, reasoning payloads and arguments as well as text", () => {
  const messages = [user("a"), ...rounds(20, { result: "tiny", reasoning: 124_000, images: 1, args: { path: "p", content: big(1000) } }), user("b"), ...rounds(10)];
  const plan = planBatch(messages, 200_000, 272_000);
  assert.ok(plan.saved > 10 * 20 * 1000 / 4, `${plan.saved}`);
});

test("the calls since a batch count the assistant messages after it", () => {
  const messages = [user(), ...rounds(10)];
  assert.equal(callsSince(messages), 10);
  assert.equal(callsSince(messages, { before: 0, at: messages[10].timestamp }), 5);
});

test("the three share numbers and the call counts come from the environment, and a nonsense value falls back", () => {
  assert.deepEqual(limitsFrom({}), DEFAULTS);
  assert.deepEqual(limitsFrom({ SHEPHERD_CONTEXT_CLIP_TOKENS: "1500", SHEPHERD_CONTEXT_TRIGGER_PERCENT: "40", SHEPHERD_CONTEXT_TARGET_PERCENT: "20", SHEPHERD_CONTEXT_KEEP_CALLS: "3", SHEPHERD_CONTEXT_GAP_CALLS: "5" }),
    { clipTokens: 1500, triggerPercent: 40, targetPercent: 20, keepCalls: 3, gapCalls: 5 });
  assert.deepEqual(limitsFrom({ SHEPHERD_CONTEXT_CLIP_TOKENS: "abc", SHEPHERD_CONTEXT_KEEP_CALLS: "0", SHEPHERD_CONTEXT_GAP_CALLS: "-4" }), DEFAULTS);
  assert.deepEqual(limitsFrom({ SHEPHERD_CONTEXT_TRIGGER_PERCENT: "30", SHEPHERD_CONTEXT_TARGET_PERCENT: "60" }), DEFAULTS, "a target above the trigger is ignored");
});

// MARK: the handler, against a session of hundreds of calls from one user message

// A stand-in pi: its session holds `entries` (custom entries are kept, as pi keeps them), its usage is what the last request cost plus
// what came since, and each `request()` runs the handler on a copy of the conversation, as pi does before every model call.
function standIn(options = {}) {
  const { window = 272_000, base = 22_000, env = {} } = options;
  const prior = { ...process.env };
  Object.assign(process.env, { SHEPHERD_EXT_CONTEXT: "1", ...env });
  const entries = [];
  let handler;
  const pi = { on: (name, fn) => { if (name === "context") handler = fn; }, appendEntry: (customType, data) => { if (options.appendFails) throw Error("no"); entries.push({ type: "custom", customType, data }); } };
  ext.default(pi);
  for (const key of Object.keys(process.env)) if (!(key in prior)) delete process.env[key];
  Object.assign(process.env, prior);
  const estimate = (list) => list.reduce((sum, m) => {
    let t = 0;
    for (const b of Array.isArray(m.content) ? m.content : []) {
      if (b.type === "text") t += Math.ceil(b.text.length / 4);
      else if (b.type === "image") t += 2100;
      else if (b.type === "toolCall") t += Math.ceil(JSON.stringify(b.arguments).length / 4) + 15;
      else if (b.type === "thinking") t += Math.ceil((b.thinkingSignature?.length ?? 0) / 12.4);
    }
    if (typeof m.content === "string") t += Math.ceil(m.content.length / 4);
    return sum + t;
  }, 0);
  const messages = [];
  let last = { sent: [], count: 0 };
  const ctx = {
    sessionManager: { getBranch: () => (options.branchFails ? (() => { throw Error("no"); })() : [...entries]) },
    getContextUsage: () => ({ tokens: base + estimate(last.sent) + estimate(messages.slice(last.count)), contextWindow: window }),
  };
  return {
    entries, messages, estimate, base, window,
    push: (...more) => messages.push(...more),
    request() {
      const before = JSON.stringify(messages);
      const result = handler({ type: "context", messages: structuredClone(messages) }, ctx);
      assert.equal(JSON.stringify(messages), before, "the session's own messages are never touched");
      const sent = result?.messages ?? messages;
      last = { sent, count: messages.length };
      return sent;
    },
    sentTokens: (sent) => base + estimate(sent),
  };
}

test("one user message that starts 400 calls: batches come about every 25 calls, the request never reaches the compaction mark, and between batches it only grows at the end", () => {
  const session = standIn();
  session.push(user("do the whole thing"));
  const sizes = [], batchesAt = [], without = [];
  let raw = session.base;
  let previous = [];
  let wouldCompact = 0;
  for (let call = 1; call <= 400; call++) {
    const pair = round({ result: big(2500 + (call % 7) * 400), reasoning: call % 3 === 0 ? 20_000 : 0, images: call % 40 === 0 ? 1 : 0, args: call % 5 === 0 ? { path: "w.swift", content: big(1500) } : { path: "r.swift" } });
    session.push(...pair);
    raw += session.estimate(pair);
    if (raw > 272_000 - 16_384) { wouldCompact++; raw = session.base + 70_000; }
    const entriesBefore = session.entries.length;
    const sent = session.request();
    const tokens = session.sentTokens(sent);
    sizes.push(tokens);
    without.push(raw);
    if (session.entries.length > entriesBefore) batchesAt.push(call);
    else if (previous.length) {
      // Between batches the request only grows at its end: what was sent before is a prefix of what is sent now.
      for (let i = 0; i < previous.length; i++) assert.ok(JSON.stringify(previous[i]) === JSON.stringify(sent[i]), `call ${call}: message ${i} changed without a batch`);
    }
    previous = sent;
    assert.ok(tokens < 272_000 - 16_384, `call ${call}: ${tokens} tokens is past the compaction mark`);
  }
  assert.ok(wouldCompact >= 2, `without clearing it would have compacted ${wouldCompact} times`);
  assert.ok(batchesAt.length >= 8 && batchesAt.length <= 25, `${batchesAt.length} batches: ${batchesAt}`);
  for (let i = 1; i < batchesAt.length; i++) assert.ok(batchesAt[i] - batchesAt[i - 1] >= DEFAULTS.gapCalls, `batches ${batchesAt[i - 1]} and ${batchesAt[i]} are closer than ${DEFAULTS.gapCalls} calls`);
  // After a batch the request is back near the target share.
  for (const call of batchesAt) assert.ok(sizes[call - 1] <= 272_000 * DEFAULTS.targetPercent / 100 + 6000, `after the batch at call ${call}: ${sizes[call - 1]}`);
  // Each batch is remembered as an append-only entry that only moves forward.
  assert.equal(session.entries.length, batchesAt.length);
  assert.ok(session.entries.every((e) => e.customType === ENTRY && e.data.v === 1 && e.data.freed > 0), "each entry says what it freed");
  for (let i = 1; i < session.entries.length; i++) assert.ok(session.entries[i].data.before > session.entries[i - 1].data.before);
});

test("a fresh handler on the same session sends the same bytes: the boundary is the session's, not the process's", () => {
  const first = standIn();
  first.push(user("go"));
  for (let call = 1; call <= 120; call++) { first.push(...round({ result: big(3000) })); first.request(); }
  assert.ok(first.entries.length >= 2);
  const second = standIn();
  second.entries.push(...first.entries);
  second.push(...first.messages);
  same(second.request(), first.request(), "after a restart");
  const branched = standIn();
  branched.entries.push(first.entries[0]);
  branched.push(...first.messages);
  assert.ok(JSON.stringify(branched.request()) !== JSON.stringify(first.request()), "a branch that holds only the first batch clears less");
});

test("a session that cannot be read or written leaves the conversation as it was, clipped, and does not throw", () => {
  for (const options of [{ branchFails: true }, { appendFails: true }]) {
    const session = standIn(options);
    session.push(user());
    for (let call = 1; call <= 60; call++) { session.push(...round({ result: big(3000) })); const sent = session.request(); assert.ok(!clearedIn(sent), "nothing cleared that is not remembered"); }
  }
  const handlers = {};
  const prior = process.env.SHEPHERD_EXT_CONTEXT;
  process.env.SHEPHERD_EXT_CONTEXT = "1";
  try { ext.default({ on: (name, handler) => { handlers[name] = handler; } }); } finally { if (prior === undefined) delete process.env.SHEPHERD_EXT_CONTEXT; else process.env.SHEPHERD_EXT_CONTEXT = prior; }
  for (const event of [undefined, {}, { messages: null }, { messages: [null, undefined, 3, { role: "toolResult" }, { role: "toolResult", content: 5 }, { role: "assistant", content: 5 }] }]) {
    assert.doesNotThrow(() => handlers.context(event, undefined));
    assert.doesNotThrow(() => handlers.context(event, {}));
  }
  assert.equal(handlers.context({ messages: [user()] }, {}), undefined, "nothing to do: no result");
});

test("without its environment the extension registers nothing", () => {
  const registered = [];
  const prior = process.env.SHEPHERD_EXT_CONTEXT;
  delete process.env.SHEPHERD_EXT_CONTEXT;
  try { ext.default({ on: (name) => registered.push(name), registerTool: (t) => registered.push(t.name), appendEntry: () => registered.push("entry") }); } finally { if (prior !== undefined) process.env.SHEPHERD_EXT_CONTEXT = prior; }
  assert.deepEqual(registered, []);
});

// MARK: pi, for real

const requestTokens = (request) => Math.ceil(JSON.stringify(request.body).length / 4);
const inputsOf = (request) => request.body.input.map((item) => JSON.stringify(item));
const resultTexts = (request) => request.body.input.filter((item) => item.type === "function_call_output").map((item) => String(item.output));
const isPrefix = (a, b) => a.length <= b.length && a.every((item, i) => b[i] === item);

// Numbered lines of about 58 characters. `outputTokens` of them: 800 lines is 46 KB, the most pi's bash tool returns whole (it
// keeps the last 2,000 lines or 50 KB of a command's output, whichever is smaller).
const LINE = "lorem ipsum dolor sit amet consectetur adipiscing elit";
const lines = (lineCount, tag = "") => `awk 'BEGIN{for(i=1;i<=${lineCount};i++) printf "%d ${LINE} ${tag}%d\\n", i, i}'`;
const SEQ = lines(800);

async function lone(t, options = {}) {
  const thread = await startThread({ extensions: ["status", "context"], mcp: false, skills: false, instructions: false, project: false, needsName: false, ...options });
  t.after(() => thread.stop());
  return thread;
}

const sessionEntries = (thread) => fs.readFileSync(thread.sessionFile(), "utf8").trim().split("\n").map((line) => JSON.parse(line));

test("pi sends a clipped result, the session file keeps the whole of it, and so do the thread's messages", { timeout: 120000 }, async (t) => {
  const thread = await lone(t, { onRequest: scriptedBashCalls([[SEQ]]) });
  await thread.turn("print a lot");
  const requests = thread.mainRequests();
  assert.equal(requests.length, 2, "the call, then the answer");
  const [sent] = resultTexts(requests[1]);
  assert.ok(/\[output trimmed in context: \d+ lines\. Re-run with a narrower command, or read the part you need\.\]/.test(sent), "the marker");
  assert.ok(sent.length < 24_000, `${sent.length} chars went to the model`);
  assert.ok(sent.startsWith(`1 ${LINE} 1\n2 `), "the head");
  assert.ok(sent.trimEnd().endsWith(`800 ${LINE} 800`), "the tail");
  const messages = await thread.messages();
  const stored = messages.find((m) => m.role === "toolResult").content.map((b) => b.text ?? "").join("");
  assert.ok(stored.length > 40_000 && stored.includes(`\n400 ${LINE} 400\n`) && stored.trimEnd().endsWith(`800 ${LINE} 800`), "the thread's message is whole");
  assert.ok(fs.readFileSync(thread.sessionFile(), "utf8").includes(`\\n400 ${LINE} 400\\n`), "the session file is whole");
  assert.ok(!thread.events.some((e) => e.type === "extension_error"), JSON.stringify(thread.events.filter((e) => e.type === "extension_error")));
});

test("with the switch off the requests are byte for byte what pi sends without the extension", { timeout: 180000 }, async (t) => {
  const plan = [[SEQ], [SEQ], ["echo hi"]];
  const run = async (options) => {
    const thread = await lone(t, { onRequest: scriptedBashCalls(plan), ...options });
    for (const word of ["one", "two", "three"]) await thread.turn(word);
    // The scratch folder's name is in the prompt (cwd) and differs from one launch to the next.
    return thread.mainRequests().map((r) => JSON.stringify(r.body).replaceAll(thread.dir, "<scratch>"));
  };
  const without = await run({ extensions: ["status"] });
  same(await run({ trim: false }), without, "the app's switch off: the extension is not loaded");
  same(await run({ trim: "inert" }), without, "loaded without its variable: it registers nothing");
  assert.ok(JSON.stringify(await run({})) !== JSON.stringify(without), "and with it on the requests differ");
});

// One user message that starts `calls` tool calls, each printing about `tokens` tokens.
const longRun = (calls, tokens, extra = {}) => scriptedBashCalls(() => Array.from({ length: calls }, (_, i) => ({ command: lines(Math.round(tokens * 4 / 60), `${i}.`), ...extra })));

// A 272k window (the one in the Context card's example), pi's own compaction on (its default), and each reply reporting what its request cost.
const WINDOW = 272_000;
const small = { contextWindow: WINDOW, settings: { compaction: { enabled: true } }, usage: (entry) => ({ input: Math.ceil(JSON.stringify(entry.body).length / 4), output: 40 }) };

test("a run of 150 calls from one user message: pi compacts without clearing and never with it; the request stays under the target after a batch, and only grows at its end between batches", { timeout: 300000 }, async (t) => {
  const run = async (options) => {
    const thread = await lone(t, { onRequest: longRun(150, 3000), ...small, ...options });
    await thread.turn("work through everything", 240000);
    return thread;
  };
  const without = await run({ extensions: ["status"] });
  const compactionsWithout = without.events.filter((e) => e.type === "compaction_start").length;
  assert.ok(compactionsWithout >= 3, `without clearing pi compacted ${compactionsWithout} times`);

  const thread = await run({});
  assert.equal(thread.events.filter((e) => e.type === "compaction_start").length, 0, "with clearing pi never had to compact");
  const requests = thread.mainRequests();
  assert.ok(requests.length >= 150);
  const entries = sessionEntries(thread).filter((e) => e.type === "custom" && e.customType === ENTRY);
  assert.ok(entries.length >= 3, `${entries.length} batches`);
  const sizes = requests.map(requestTokens);
  assert.ok(Math.max(...sizes) < WINDOW - 16_384, `the biggest request is ${Math.max(...sizes)}`);
  // The request after each batch is near the target; the one before it is not.
  let batches = 0;
  for (let i = 1; i < requests.length; i++) {
    const now = inputsOf(requests[i]), then = inputsOf(requests[i - 1]);
    if (!isPrefix(then, now)) {
      batches++;
      assert.ok(sizes[i] < sizes[i - 1], "a batch makes the request smaller");
      assert.ok(sizes[i] <= WINDOW * 0.33 + 9000, `after a batch: ${sizes[i]}`);
      const first = then.findIndex((item, j) => item !== now[j]);
      assert.ok(first > 0, "the start of the request does not change");
    }
  }
  assert.equal(batches, entries.length, "the request changes exactly at the batches the session remembers");
  // Everything is still in the thread, in the session file, and the file holds no stub.
  const messages = await thread.messages();
  assert.equal(messages.filter((m) => m.role === "toolResult").length, 150);
  assert.ok(messages.filter((m) => m.role === "toolResult").every((m) => !/removed from context|trimmed in context/.test(JSON.stringify(m))), "the thread's results are whole");
  const file = fs.readFileSync(thread.sessionFile(), "utf8");
  assert.ok(!file.includes("removed from context"), "no cleared stub was written to the session");
  assert.ok(!thread.events.some((e) => e.type === "extension_error"), JSON.stringify(thread.events.filter((e) => e.type === "extension_error")));
});

test("an old reasoning payload is not sent again, its calls and results still pair, and the newest call keeps its own", { timeout: 180000 }, async (t) => {
  const plan = [[{ command: "echo first", reasoning: 60_000 }, { command: "echo second", reasoning: 60_000 }, { command: "echo third", reasoning: 60_000 }, { command: "echo fourth", reasoning: 60_000 }]];
  const run = async (options) => {
    const thread = await lone(t, { onRequest: scriptedBashCalls(plan), env: { SHEPHERD_CONTEXT_KEEP_CALLS: "1", SHEPHERD_CONTEXT_GAP_CALLS: "1", SHEPHERD_CONTEXT_TRIGGER_PERCENT: "10", SHEPHERD_CONTEXT_TARGET_PERCENT: "5" },
      contextWindow: 20_000, usage: (entry) => ({ input: Math.ceil(JSON.stringify(entry.body).length / 4), output: 40 }), ...options });
    await thread.turn("one");
    return thread.mainRequests().at(-1).body.input;
  };
  const kept = await run({ trim: "inert" });
  assert.equal(kept.filter((item) => item.type === "reasoning").length, 4, "without the extension every payload is sent");
  const input = await run({});
  assert.equal(input.filter((item) => item.type === "reasoning").length, 1, "only the newest call's payload is sent");
  const calls = input.filter((item) => item.type === "function_call"), outputs = input.filter((item) => item.type === "function_call_output");
  assert.equal(calls.length, 4);
  assert.deepEqual(calls.map((c) => c.call_id), outputs.map((o) => o.call_id), "every call is still answered, by its own result");
  assert.deepEqual(calls.map((c) => c.id === undefined), [true, true, true, false], "a call whose reasoning went carries no item id; the newest keeps it");
  assert.ok(!JSON.stringify(input).includes("No result provided"), "pi inserted no stand-in result");
});

test("a restarted pi sends what the first one sent, markers and all, and makes no batch of its own", { timeout: 300000 }, async (t) => {
  const first = await lone(t, { onRequest: longRun(100, 3000), ...small });
  await first.turn("go", 240000);
  const batches = sessionEntries(first).filter((e) => e.type === "custom" && e.customType === ENTRY);
  assert.ok(batches.length >= 2, `${batches.length} batches`);
  const sent = inputsOf(first.mainRequests().at(-1));
  // The same session file in a new process, asked one more thing.
  const second = await lone(t, { onRequest: longRun(0, 3000), ...small });
  const file = first.sessionFile();
  const target = path.join(second.dir, "sessions", path.relative(path.join(first.dir, "sessions"), path.dirname(file)));
  fs.mkdirSync(target, { recursive: true });
  fs.copyFileSync(file, path.join(target, path.basename(file)));
  await second.request({ type: "switch_session", sessionPath: path.join(target, path.basename(file)) });
  await second.turn("keep going", 120000);
  const resumed = inputsOf(second.mainRequests()[0]);
  assert.ok(isPrefix(sent, resumed), "everything the first pi sent last, the second sends first: the same conversation, cleared the same way");
  assert.ok(resumed.some((item) => item.includes("removed from context")), "and the stubs are there");
  assert.equal(sessionEntries(second).filter((e) => e.type === "custom" && e.customType === ENTRY).length, batches.length, "the session already said where it stopped: no new batch");
});

test("compaction, a new session and /compact still work with the extension on", { timeout: 240000 }, async (t) => {
  const thread = await lone(t, { onRequest: scriptedBashCalls([[SEQ], [SEQ]]) });
  await thread.turn("one");
  await thread.turn("two");
  const compacted = await thread.request({ type: "compact" });
  assert.equal(compacted.success, true, JSON.stringify(compacted));
  await thread.turn("three");
  const after = thread.mainRequests().at(-1);
  assert.ok(after.body.input.some((item) => JSON.stringify(item).includes("summary")), "the summary is in the next request");
  const fresh = await thread.request({ type: "new_session" });
  assert.equal(fresh.success, true);
  await thread.turn("again");
  const input = thread.mainRequests().at(-1).body.input;
  assert.equal(input.filter((item) => item.role === "user").length, 1, "a new session carries nothing of the old one");
  assert.ok(!thread.events.some((e) => e.type === "extension_error"));
});
