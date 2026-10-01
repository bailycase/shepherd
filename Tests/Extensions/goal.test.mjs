// Goal controller against gated completions and the pinned pi RPC runtime. No external models.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as http from "node:http";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const { createJiti } = createRequire(path.join(pkg, "package.json"))("jiti");
const jiti = createJiti(import.meta.url, { alias: { typebox: path.join(pkg, "node_modules/typebox/build/index.mjs") } });
const source = path.join(root, "Extensions/shepherd-goal.ts");
const { default: install } = await jiti.import(source);
const turn = () => new Promise((resolve) => setImmediate(resolve));
const response = (verdict = "not_met", extra = {}) => ({ stopReason: "toolUse", usage: { totalTokens: 7 }, content: [{ type: "toolCall", name: "goal_verdict", arguments: {
  verdict, reason: "Run the remaining checks", summary: "remaining checks needed", evidence: [], blocker: "", ...extra,
} }] });
const proof = { role: "toolResult", toolName: "bash", toolCallId: "call-check-1", isError: false, content: [{ type: "text", text: "All 12 acceptance tests passed." }] };

function assertShortPublishedGoal(goal, entries = []) {
  if (!goal) return;
  const ids = [goal.id, ...entries.flatMap((e) => [e.id, e.message?.toolCallId,
    ...(Array.isArray(e.message?.content) ? e.message.content.filter((c) => c.type === "toolCall").map((c) => c.id) : [])])].filter(Boolean);
  for (const value of [goal.reason, goal.summary].filter((v) => v !== undefined)) {
    assert(value.length <= 40, `long card text: ${value}`);
    assert(!/[\t\r\n\u2028\u2029"`]/.test(value), `non-human card text: ${value}`);
    for (const id of ids) assert(!new RegExp(`(?<![\\w-])${id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?![\\w-])`).test(value), `card leaked ID ${id}`);
  }
  if (goal.state === "needsYou" && goal.reason) assert.equal(goal.reason, goal.reason.toLowerCase());
  if (goal.state === "paused") assert.equal(goal.reason, "paused by you · the clock stops");
}

function fixture({ entries = [], enabled = "1", models, auth = true, env = {} } = {}) {
  const handlers = new Map(), commands = new Map(), commandMetadata = [], widgets = [], prompts = [], calls = [], stored = structuredClone(entries), bus = new Map(), customMessages = [];
  const options = { SHEPHERD_EXT_GOAL: enabled, SHEPHERD_GOAL_MODELS: "", ...env };
  const saved = Object.fromEntries(Object.keys(options).map((k) => [k, process.env[k]]));
  Object.assign(process.env, options);
  let index = 0, aborted = 0;
  try {
    install({ on: (name, fn) => handlers.set(name, fn), events: { on: (name, fn) => bus.set(name, fn) }, registerCommand: (name, value) => {
        commands.set(name, value.handler); commandMetadata.push({ name, description: value.description });
      },
      appendEntry: (customType, data) => stored.push({ id: `entry${++index}`, type: "custom", customType, data: structuredClone(data) }),
      sendUserMessage: () => { throw Error("Goal kickoff must be a hidden custom message"); }, sendMessage: (message, options) => {
        customMessages.push({ message, options });
        if (options.triggerTurn) prompts.push({ text: message.content, options });
      } });
  } finally { for (const [k, v] of Object.entries(saved)) v === undefined ? delete process.env[k] : process.env[k] = v; }
  const model = { provider: "fixture", id: "worker", contextWindow: 64000 };
  const ctx = { model, mode: "rpc", isIdle: () => false, hasPendingMessages: () => false,
    abort: () => { aborted++; }, ui: { setWidget: (key, lines) => {
      assert.equal(key, "shepherd.goal"); assert.equal(lines.length, 1);
      const goal = JSON.parse(lines[0].slice("SHEPHERD_GOAL:".length));
      assertShortPublishedGoal(goal, stored);
      widgets.push(goal);
    } },
    sessionManager: { getBranch: () => stored, getEntries: () => { throw Error("Must read active branch only"); }, getLeafId: () => stored.at(-1)?.id ?? null, getSessionId: () => "fixture-session" },
    modelRegistry: { getAvailable: () => models ?? [model], hasConfiguredAuth: () => auth,
      find: (provider, id) => (models ?? [model]).find((m) => m.provider === provider && m.id === id),
      complete: (model, context, options) => new Promise((resolve, reject) => calls.push({ model, context, options, resolve, reject })) } };
  const f = { handlers, commands, commandMetadata, widgets, prompts, calls, ctx, stored, bus, customMessages,
    get goal() { return widgets.at(-1); }, get aborted() { return aborted; },
    emit: (event, value = {}) => handlers.get(event)?.(value, ctx),
    action: (value) => commands.get("shepherd-goal")(JSON.stringify(value), ctx),
    start: (text = "All acceptance tests pass", extra = {}) => f.action({ action: "set", text, ...extra }),
    check: (extra = {}) => f.emit("agent_before_settle", { entries: [], outcome: "completed", context: { contextEntries: stored.map((sourceEntry) => ({ sourceEntry, messages: sourceEntry.message ? [sourceEntry.message] : [] })) }, ...extra }),
    async work(tokens = 3) {
      const message = { role: "assistant", timestamp: 1, content: [{ type: "text", text: "Checked the implementation." },
        { type: "toolCall", id: "call-check-1", name: "bash", arguments: { command: "go test ./... && go vet ./..." } }], usage: { totalTokens: tokens }, stopReason: "stop" };
      await f.emit("message_start", { message });
      stored.push({ type: "message", id: `work${++index}`, message });
      await f.emit("message_end", { message });
      stored.push({ type: "message", id: "proof", message: structuredClone(proof) });
    },
    close: () => f.emit("session_shutdown"),
  };
  f.emit("session_start");
  return f;
}

test("inert without the agent flag; startup always advertises capability with null", async () => {
  const off = fixture({ enabled: "0" });
  assert.equal(off.commands.size, 0); assert.equal(off.handlers.size, 0);
  const f = fixture();
  assert.deepEqual(f.widgets, [null]); assert.equal(f.calls.length, 0);
  await f.close();
});

test("slash goal preserves its full condition, parses budgets, and starts a hidden data-marked prompt", async () => {
  const f = fixture();
  try {
    await f.commands.get("goal")("--for 30m --tokens 100000 First condition\n  and ALL other conditions", f.ctx);
    assert.equal(f.goal.text, "First condition\n  and ALL other conditions");
    assert.equal(f.goal.timeLimitSeconds, 1800); assert.equal(f.goal.tokenLimit, 100000);
    assert.match(f.goal.id, /^[0-9a-f-]{36}$/); assert.equal(f.goal.revision, 1);
    assert.match(f.prompts[0].text, /SHEPHERD_GOAL_DATA:/);
    assert.deepEqual(f.prompts[0].options, { deliverAs: "followUp", triggerTurn: true });
    assert.equal(f.customMessages[1].message.customType, "shepherd.goal.start"); assert.equal(f.customMessages[1].message.display, false);
    assert.equal(f.customMessages[0].message.customType, "shepherd.goal.set");
    assert.equal(f.customMessages[0].message.content, "Goal set\n" + f.goal.text);
    assert.equal(f.customMessages[0].message.display, true); assert.equal(f.customMessages[0].options.triggerTurn, false);
    assert.equal(f.stored.at(-1).customType, "shepherd.goal");
    assert.deepEqual(f.stored.at(-1).data.goal, f.widgets[1]);
    const before = structuredClone(f.goal);
    for (const args of ["--for -1m Bad", "--tokens -3 Bad", "--for 0s Bad", "--for 2d Bad", "--tokens 1.2 Bad", "--for 2m"]) {
      await assert.rejects(f.commands.get("goal")(args, f.ctx));
      assert.deepEqual(f.goal, before);
    }
    await f.commands.get("goal")("status", f.ctx);
    assert.equal(f.goal.id, before.id);
  } finally { await f.close(); }
});

test("native optimistic fences reject stale commands without mutating or cancelling the check", async () => {
  const f = fixture();
  try {
    await f.start(); await f.work(); const check = f.check(), before = structuredClone(f.goal), count = f.stored.length;
    for (const action of ["pause", "resume", "clear", "edit"]) {
      for (const fence of [{ expectedGoalID: "stale" }, { expectedGoalRevision: before.revision - 1 }]) {
        await assert.rejects(f.action({ action, text: "New text", ...fence }), /changed/);
        assert.deepEqual(f.goal, before); assert.equal(f.stored.length, count); assert(!f.calls[0].options.signal.aborted);
      }
    }
    f.calls[0].resolve(response("met", { evidence: [{ entryId: "proof", quote: "All 12 acceptance tests passed." }] }));
    await check; assert.equal(f.goal.state, "met");
    await f.action({ action: "pause", expectedGoalID: f.goal.id, expectedGoalRevision: f.goal.revision });
    assert.equal(f.goal.state, "paused");
  } finally { await f.close(); }
});

for (const action of ["pause", "edit", "clear", "set"]) test(`${action} during a nested check invalidates it immediately; a late success cannot overwrite the command`, async () => {
  const f = fixture();
  try {
    await f.start(); await f.work(); const check = f.check();
    assert.equal(f.goal.state, "checking");
    await f.action({ action, text: "Different complete objective" });
    const commanded = structuredClone(f.goal);
    const result = await check;
    assert(!result.continue); assert(f.calls[0].options.signal.aborted);
    f.calls[0].resolve(response("met", { evidence: [{ entryId: "proof", quote: "All 12 acceptance tests passed." }] }));
    await turn();
    assert.equal(f.goal?.id, commanded?.id); assert.equal(f.goal?.text, commanded?.text); assert.equal(f.goal?.state, commanded?.state);
    if (action === "pause" || action === "edit") assert.equal(f.goal.tokensUsed, 10, "already incurred nested usage still belongs to this goal");
    assert.equal(f.aborted, 0, "pausing/changing only cancels the evaluator, not worker tools");
  } finally { await f.close(); }
});

test("a yielded check logs its verdict but does not continue; next before_agent_start resets yield", async () => {
  const f = fixture();
  try {
    await f.start(); await f.work(); const check = f.check();
    await f.action({ action: "yield" }); f.calls[0].resolve(response());
    const result = await check;
    assert.equal(f.goal.state, "working"); assert.equal(result.continue, false);
    assert.equal(result.entries[0].type, "custom_message"); assert.equal(result.entries[0].display, true);
    assert.equal(result.entries[0].customType, "shepherd.goal.check");
    await f.emit("agent_settled"); await f.emit("before_agent_start", { prompt: "Queued user message" });
    const next = f.check(); f.calls[1].resolve(response());
    const continued = await next;
    assert.equal(continued.continue, true);
    assert.match(continued.entries.at(-1).content, /SHEPHERD_GOAL_DATA:/);
    assert.equal(continued.entries.at(-1).display, false);
    assert(continued.entries.at(-1).content.includes(f.goal.text));
  } finally { await f.close(); }
});

test("active edit restarts work after cancelling a check or while idle, but paused edit never restarts", async () => {
  const f = fixture();
  try {
    await f.start(); await f.work(); const check = f.check();
    await f.action({ action: "edit", text: "Replacement condition" }); await check;
    assert.equal(f.prompts.length, 2); assert(f.prompts[1].text.includes("Replacement condition"));
    assert.equal(f.goal.state, "checking");
    await f.emit("before_agent_start"); assert.equal(f.goal.state, "checking");
    await f.emit("agent_start"); assert.equal(f.goal.state, "working");
    f.ctx.isIdle = () => true;
    await f.action({ action: "edit", text: "New idle condition" }); assert.equal(f.prompts.length, 3);
    await f.action({ action: "pause" });
    await f.action({ action: "edit", text: "Paused condition" }); assert.equal(f.prompts.length, 3); assert.equal(f.goal.state, "paused");
  } finally { await f.close(); }
});

test("three checks without new successful tool evidence stop even with empty/changing blocker keys", async () => {
  const f = fixture();
  try {
    await f.start(); await f.work();
    for (let i = 0; i < 4; i++) {
      const check = f.check(); f.calls[i].resolve(response("not_met", { blocker: i % 2 ? "" : `changing-${i}` }));
      const result = await check; assert.equal(result.continue, i !== 3);
    }
    assert.equal(f.goal.state, "needsYou"); assert.equal(f.goal.reason, "no new tool evidence after 3 checks");
    assert.equal(f.stored.at(-1).data.consecutiveNoProgress, 3); assert.equal(f.stored.at(-1).data.lastEvidenceID, "proof");
    const restored = fixture({ entries: f.stored });
    assert.equal(restored.stored.at(-1).data.consecutiveNoProgress, 3); await restored.close();
  } finally { await f.close(); }
});

test("editing preserves offered states and reasons; identical text is a no-op, and met conditions cannot change without a new goal", async () => {
  for (const state of ["working", "checking", "met", "paused", "needsYou"]) {
    const f = fixture();
    try {
      await f.start(); await f.work();
      let check;
      if (["checking", "met", "needsYou"].includes(state)) {
        check = f.check();
        if (state !== "checking") {
          f.calls[0].resolve(response(state === "met" ? "met" : "needs_you", { reason: "Waiting for permission",
            summary: "12 tests passed", evidence: [{ entryId: "proof", quote: "All 12 acceptance tests passed." }] }));
          await check;
        }
      } else if (state === "paused") await f.action({ action: "pause" });
      const before = structuredClone(f.goal), counts = [f.stored.length, f.widgets.length, f.prompts.length];
      await f.action({ action: "edit", text: before.text });
      assert.deepEqual(f.goal, before); assert.deepEqual([f.stored.length, f.widgets.length, f.prompts.length], counts);
      if (state === "checking") assert(!f.calls[0].options.signal.aborted);
      if (state === "met") {
        await assert.rejects(f.action({ action: "edit", text: before.text + " and lint is clean" }), /Set a new goal/);
        assert.deepEqual(f.goal, before); assert.deepEqual([f.stored.length, f.widgets.length, f.prompts.length], counts);
        continue;
      }
      await f.action({ action: "edit", text: before.text + " and lint is clean" });
      assert.equal(f.goal.state, before.state); assert.equal(f.goal.reason, before.reason);
      assert.equal(f.goal.revision, before.revision + 1);
      assert.equal(f.goal.tokensUsed, before.tokensUsed);
      if (state === "checking") {
        await check; assert(f.calls[0].options.signal.aborted);
        await f.emit("before_agent_start"); assert.equal(f.goal.state, "checking");
        await f.emit("agent_start"); assert.equal(f.goal.state, "working"); await f.work();
        const fresh = f.check();
        assert.equal(JSON.parse(f.calls[1].context.messages[0].content[0].text).objective, before.text + " and lint is clean");
        f.calls[1].resolve(response("met", { summary: "12 tests passed", evidence: [{ entryId: "proof", quote: "All 12 acceptance tests passed." }] }));
        await fresh; assert.equal(f.goal.state, "met");
      }
    } finally { await f.close(); }
  }
});

test("checking names only commands whose tool results the evaluator actually reads, with explicit unresolved fallbacks", async () => {
  for (const kind of ["complete", "omitted", "missing-call", "quoted", "control-syntax", "read", "unsafe-read", "non-shell", "none"]) {
    const f = fixture();
    try {
      await f.start(); if (kind !== "none") await f.work();
      if (kind !== "none") {
        const worker = f.stored.find((e) => e.type === "message" && e.message.role === "assistant");
        worker.message.content.push({ type: "toolCall", id: "unread-call", name: "bash", arguments: { command: "go fmt ./..." } });
        if (kind === "missing-call") worker.message.content = [];
        if (kind === "quoted") worker.message.content[1].arguments.command = "echo 'go test && go vet'";
        if (kind === "control-syntax") worker.message.content[1].arguments.command = "if go test ./...; then go vet ./...; fi";
        if (["read", "unsafe-read", "non-shell"].includes(kind)) worker.message.content[1].name = f.stored.at(-1).message.toolName = "read";
        if (kind === "read") worker.message.content[1].arguments = { path: "/private/full/path/LedgerTests.swift" };
        if (kind === "unsafe-read") worker.message.content[1].arguments = { path: "/private/full/path/call-check-1" };
      }
      const extra = kind === "omitted" ? { context: { contextEntries: f.stored.filter((e) => e.id !== "proof").map((sourceEntry) => ({ sourceEntry, messages: sourceEntry.message ? [sourceEntry.message] : [] })) } } : {};
      const check = f.check(extra);
      assert.equal(f.goal.reason, kind === "complete" ? "checking go test, go vet"
        : kind === "read" ? "checking read LedgerTests.swift"
        : ["none", "omitted"].includes(kind) ? "checking · no tool results to read" : "checking · commands unavailable");
      assert(f.goal.reason.length <= 40); assert(!f.goal.reason.includes("/private/"));
      assert(!f.goal.reason.includes("go fmt"));
      f.calls[0].resolve(response()); await check;
    } finally { await f.close(); }
  }
});

test("short human headers never expose model IDs, quotes or layout; details keep full feedback and errors", async () => {
  const f = fixture();
  try {
    await f.start(); await f.work(); const check = f.check();
    const reason = "Waiting\tfor permission entryId proof\nDetailed feedback\twith call-check-1 and raw proof.";
    const summary = "41\ttests passed proof\nraw";
    f.calls[0].resolve(response("needs_you", { reason, summary, evidence: [{ entryId: "proof", quote: "All 12 acceptance tests passed." }] }));
    const result = await check;
    assert.equal(f.goal.reason, "waiting for permission"); assert.equal(f.goal.summary, "41 tests passed");
    assert.equal(result.entries[0].details.verdict.reason, reason); assert.equal(result.entries[0].details.verdict.summary, summary);
    assert.equal(result.entries[0].content, "Goal needs you · waiting for permission\n\nDetails:\nEvaluator feedback:\n" + reason + "\n\nTool evidence:\nproof: All 12 acceptance tests passed.");
    await f.action({ action: "resume" }); await f.work(); const failed = f.check();
    const error = "Provider failed\tentryId proof\nFull diagnostic call-check-1";
    f.calls[1].reject(Error(error)); const stopped = await failed;
    assert.equal(f.goal.reason, "goal check failed · try again");
    assert.equal(stopped.entries[0].details.error, error);
    assert(!stopped.entries[0].content.split("\n\nDetails:\n")[0].includes("proof"));
    assert.equal(stopped.entries[0].content.split("\n\nDetails:\n")[1], error);
  } finally { await f.close(); }
});

test("interrupted settlement and missing user answers publish exact short reasons, and 30m limits stay human", async (t) => {
  let now = 0; t.mock.method(performance, "now", () => now);
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const f = fixture();
  try {
    await f.start(); await f.emit("agent_settled");
    assert.equal(f.goal.reason, "work stopped before the goal check");
    await f.action({ action: "resume" });
    const stopped = await f.check({ outcome: "aborted" });
    assert.equal(f.goal.reason, "work stopped or failed"); assert.equal(stopped.entries[0].details.outcome, "aborted");
    await f.action({ action: "resume" }); await f.work(); const check = f.check();
    await f.emit("agent_settled"); await check;
    assert.equal(f.goal.reason, "goal check interrupted");
    assert(f.calls[0].options.signal.aborted);
    await f.emit("tool_execution_start", { toolName: "ask_user", toolCallId: "ask-1" });
    await f.start(); assert.equal(f.goal.reason, "waiting for your answer");
    await f.emit("tool_execution_end", { toolName: "ask_user", toolCallId: "ask-1" });
    await f.start("Finish", { timeLimitSeconds: 1800 }); now = 1800000; t.mock.timers.tick(1800000);
    assert.equal(f.goal.reason, "hit the 30m time limit");
  } finally { await f.close(); }
});

test("long feedback is word-bounded for cards but remains complete in the check and worker continuation", async () => {
  const f = fixture();
  try {
    await f.start(); await f.work(); const check = f.check();
    const reason = "remaining permission checks ".repeat(20).trim();
    f.calls[0].resolve(response("not_met", { reason })); const result = await check;
    assert(reason.startsWith(f.goal.reason)); assert(f.goal.reason.length <= 40);
    assert(reason[f.goal.reason.length] === " ", "short text ends on a word boundary");
    assert.equal(result.entries[0].details.verdict.reason, reason);
    assert.equal(JSON.parse(result.entries[1].content.split("SHEPHERD_GOAL_DATA:")[1]).feedback, reason);
  } finally { await f.close(); }
});

test("met puts a structured summary first and preserves full feedback and every proof quote in Details beyond the widget bound", async () => {
  const f = fixture();
  try {
    await f.start(); await f.work();
    const quote = "41 tests passed\t" + "proof detail\n".repeat(140);
    const evidence = Array.from({ length: 8 }, (_, i) => ({ entryId: `full-proof-${i}`, quote }));
    for (const e of evidence) f.stored.push({ type: "message", id: e.entryId, message: { ...proof, content: e.quote } });
    const check = f.check(); f.calls[0].resolve(response("met", { reason: "All checks passed", summary: "41 tests passed", evidence }));
    const result = await check, full = evidence.map((e) => `${e.entryId}: ${e.quote}`).join("\n");
    assert.equal(f.goal.summary, "41 tests passed"); assert.equal(f.goal.evidence.length, 8192);
    assert.equal(result.entries[0].content, "Goal met · 41 tests passed\n\nDetails:\nEvaluator feedback:\n" + result.entries[0].details.verdict.reason + "\n\nTool evidence:\n" + full);
    assert.deepEqual(result.entries[0].details.verdict.evidence, evidence);
    assert(full.length > 8192);
  } finally { await f.close(); }
});

test("clock widgets tick each active second without durable writes or revision churn; cleanup stops ticks", async (t) => {
  let now = 0; t.mock.method(performance, "now", () => now);
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const f = fixture();
  try {
    await f.start(); const count = f.stored.length, revision = f.goal.revision;
    now = 1000; t.mock.timers.tick(1000); assert.equal(f.goal.elapsedSeconds, 1);
    now = 2000; t.mock.timers.tick(1000); assert.equal(f.goal.elapsedSeconds, 2);
    assert.equal(f.stored.length, count); assert.equal(f.goal.revision, revision);
    await f.action({ action: "pause", expectedGoalRevision: revision });
    const widgets = f.widgets.length; now = 10000; t.mock.timers.tick(8000);
    assert.equal(f.widgets.length, widgets); assert.equal(f.goal.elapsedSeconds, 2);
  } finally { await f.close(); }
});

test("live children defer goal evaluation, child attention needs the user, and earlier boundary continuations are preserved", async () => {
  const f = fixture();
  try {
    await f.start(); await f.work();
    assert.equal(await f.check({ continue: true }), undefined); assert.equal(f.calls.length, 0);
    const publish = f.bus.get("shepherd:children:v1");
    publish({ owner: "fixture-session", children: [{ runID: "child", state: "running", tokens: 5 }] });
    assert.equal(await f.check(), undefined); assert.equal(f.calls.length, 0); assert.equal(f.goal.tokensUsed, 8);
    publish({ owner: "fixture-session", children: [{ runID: "child", state: "running", tokens: 5, needsAttention: true }] });
    assert.equal(f.goal.state, "working"); // The child asks its parent, never the user.
    assert.equal(await f.check(), undefined);
    assert.equal(f.calls.length, 0);
  } finally { await f.close(); }
});

test("a parent's actual user question stops goal automation without aborting the tool", async () => {
  const f = fixture();
  try {
    await f.start();
    await f.emit("tool_execution_start", { toolName: "ask_user", toolCallId: "question" });
    assert.equal(f.goal.state, "needsYou");
    assert.match(f.goal.reason, /your answer/);
    assert.equal(f.aborted, 0);
    assert.equal(await f.check(), undefined);
    await assert.rejects(f.action({ action: "resume" }), /Answer the question/);
    await f.emit("tool_execution_end", { toolName: "ask_user", toolCallId: "question" });
    assert.equal(f.goal.reason, "answer received · resume to continue");
    await f.action({ action: "resume" });
    assert.equal(f.goal.state, "working");
  } finally { await f.close(); }
});

test("report-only children completing while idle wake an active goal exactly once", async () => {
  const f = fixture();
  try {
    await f.emit("session_start"); await f.start();
    const publish = f.bus.get("shepherd:children:v1");
    publish({ owner: "fixture-session", children: [{ runID: "child", state: "running", tokens: 0 }] });
    assert.equal(await f.check(), undefined);
    f.ctx.isIdle = () => true;
    const before = f.prompts.length;
    publish({ owner: "fixture-session", children: [{ runID: "child", state: "complete", tokens: 5 }] });
    assert.equal(f.prompts.length, before + 1);
    publish({ owner: "fixture-session", children: [{ runID: "child", state: "complete", tokens: 5 }] });
    assert.equal(f.prompts.length, before + 1);
    await f.action({ action: "pause" });
    publish({ owner: "fixture-session", children: [{ runID: "child2", state: "running", tokens: 0 }] });
    publish({ owner: "fixture-session", children: [{ runID: "child2", state: "complete", tokens: 0 }] });
    assert.equal(f.prompts.length, before + 1);
  } finally { await f.close(); }
});

test("user messages never resume a paused goal and paused idle time is not charged", async (t) => {
  let now = 0; t.mock.method(performance, "now", () => now);
  const f = fixture();
  try {
    await f.start(); now = 3000; await f.action({ action: "pause" });
    assert.equal(f.goal.elapsedSeconds, 3); assert.equal(f.aborted, 0);
    now = 9000; await f.emit("before_agent_start", { prompt: "Please do another task" });
    await f.emit("agent_start"); await f.work(); assert.equal(await f.check(), undefined);
    assert.equal(f.goal.state, "paused"); assert.equal(f.goal.elapsedSeconds, 3);
    await f.action({ action: "resume" }); now = 11000; await f.action({ action: "pause" });
    assert.equal(f.goal.elapsedSeconds, 5);
  } finally { await f.close(); }
});

test("provider usage, including nested tool usage, enforces the token limit before evaluation", async () => {
  const f = fixture();
  try {
    await f.start("Finish", { tokenLimit: 10 });
    await f.emit("message_start", { message: { role: "assistant" } });
    const message = { role: "assistant", usage: { totalTokens: 6 }, stopReason: "stop" };
    await f.emit("message_update", { message }); await f.emit("message_end", { message });
    assert.equal(f.goal.tokensUsed, 6, "cumulative usage is not double charged");
    await f.emit("message_end", { message: { ...proof, usage: { totalTokens: 4 } } });
    assert.equal(f.goal.tokensUsed, 10); assert.equal(f.goal.state, "needsYou"); assert.match(f.goal.reason, /token limit/);
    await f.check(); assert.equal(f.calls.length, 0); assert.equal(f.aborted, 1);
    await f.action({ action: "resume" }); assert.equal(f.goal.state, "needsYou"); assert.equal(f.prompts.length, 1);
  } finally { await f.close(); }
});

test("nested evaluator usage reaching a limit cannot declare met or continue", async () => {
  const f = fixture();
  try {
    await f.start("Finish", { tokenLimit: 10 }); await f.work(3); const check = f.check();
    f.calls[0].resolve(response("met", { evidence: [{ entryId: "proof", quote: "All 12 acceptance tests passed." }] }));
    const result = await check;
    assert.equal(f.goal.tokensUsed, 10); assert.equal(f.goal.state, "needsYou"); assert(!result.continue); assert.match(f.goal.reason, /token limit/);
  } finally { await f.close(); }
});

test("time limit marks blocked work at runtime and stops only at a tool-safe turn boundary", async (t) => {
  let now = 0; t.mock.method(performance, "now", () => now);
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const f = fixture();
  try {
    await f.start("Finish", { timeLimitSeconds: 2 });
    now = 2000; t.mock.timers.tick(2000);
    assert.equal(f.goal.state, "needsYou"); assert.match(f.goal.reason, /time limit/); assert.equal(f.aborted, 0);
    assert.equal(f.goal.elapsedSeconds, 2); await f.check(); assert.equal(f.calls.length, 0);
    await f.emit("turn_end"); assert.equal(f.aborted, 1);
  } finally { await f.close(); }
});

test("nested calls time out even when a provider ignores AbortSignal; no stale verdict after timeout", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const f = fixture();
  try {
    await f.start(); await f.work(); const check = f.check();
    t.mock.timers.tick(60000); const result = await check;
    assert(f.calls[0].options.signal.aborted); assert.equal(f.goal.state, "needsYou"); assert(!result.continue); assert.match(f.goal.reason, /timed out/);
    f.calls[0].resolve(response("met", { evidence: [{ entryId: "proof", quote: "All 12 acceptance tests passed." }] })); await turn();
    assert.equal(f.goal.state, "needsYou");
  } finally { await f.close(); }
});

test("time budget expiring inside the evaluator takes precedence over a met verdict", async (t) => {
  let now = 0; t.mock.method(performance, "now", () => now);
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const f = fixture();
  try {
    await f.start("Finish", { timeLimitSeconds: 3 }); await f.work(); const check = f.check();
    now = 3000; t.mock.timers.tick(3000); const result = await check;
    assert.equal(f.goal.state, "needsYou"); assert(!result.continue); assert(f.calls[0].options.signal.aborted);
  } finally { await f.close(); }
});

test("exactly three consecutive identical blockers need the user; changing or empty blockers resets the count", async () => {
  const f = fixture();
  try {
    await f.start(); await f.work();
    for (const [i, blocker] of ["first", "first", "", "first", "changed", "changed", "changed"].entries()) {
      f.stored.push({ type: "message", id: `fresh-proof-${i}`, message: structuredClone(proof) });
      const check = f.check(); f.calls[i].resolve(response("not_met", { blocker }));
      const result = await check;
      assert.equal(f.goal.state, i === 6 ? "needsYou" : "working"); assert.equal(result.continue, i !== 6);
    }
    assert.equal(f.goal.reason, "the same blocker repeated 3 times"); assert.equal(f.stored.at(-1).data.blockerCount, 3);
  } finally { await f.close(); }
});

for (const [name, answer] of [
  ["prose", { content: [{ type: "text", text: '{"verdict":"met"}' }] }],
  ["unknown verdict", response("success")],
  ["missing reason", response("met", { reason: "" })],
  ["missing blocker", response("not_met", { blocker: undefined })],
  ["missing summary", response("met", { summary: undefined })],
  ["oversized summary", response("met", { summary: "x".repeat(41) })],
  ["missing evidence", response("met")],
  ["fabricated quote", response("met", { evidence: [{ entryId: "proof", quote: "Everything passed." }] })],
  ["assistant citation", response("met", { evidence: [{ entryId: "work2", quote: "Checked the implementation." }] })],
  ["provider error", { ...response("met"), stopReason: "error" }],
]) test(`${name} cannot establish met`, async () => {
  const f = fixture();
  try {
    await f.start(); await f.work(); const check = f.check(); f.calls[0].resolve(answer);
    const result = await check; assert.equal(f.goal.state, "needsYou"); assert(!result.continue);
  } finally { await f.close(); }
});

test("met requires successful exact tool evidence, and a read-only evaluator receives the whole objective", async () => {
  const f = fixture();
  try {
    const objective = "x".repeat(6000) + "\nAND verify the final condition.";
    await f.start(objective); await f.work(); const check = f.check();
    const call = f.calls[0];
    assert.equal(JSON.parse(call.context.messages[0].content[0].text).objective, objective);
    assert.deepEqual(call.context.tools.map((t) => t.name), ["goal_verdict"]);
    assert(!f.handlers.has("agent_end"));
    call.resolve(response("met", { reason: "All requirements verified", evidence: [{ entryId: "proof", quote: "All 12 acceptance tests passed." }] }));
    const result = await check;
    assert.equal(f.goal.state, "met"); assert.match(f.goal.evidence, /proof: All 12/); assert(!result.continue);
    assert.equal(f.goal.tokensUsed, 10); assert.equal(result.entries[0].details.usage.totalTokens, 7);
  } finally { await f.close(); }
});

for (const kind of ["cap", "truncated", "error", "old"]) test(`${kind} tool evidence cannot establish met`, async () => {
  const f = fixture();
  try {
    await f.start(); await f.work();
    if (kind === "cap") f.stored.push({ type: "message", id: "oversized", message: { role: "user", content: "x".repeat(150000) } });
    if (kind === "truncated") f.stored.at(-1).message.details = { truncation: { truncated: true } };
    if (kind === "error") f.stored.at(-1).message.isError = true;
    if (kind === "old") await f.action({ action: "edit", text: "Different objective" });
    const check = f.check(); f.calls[0].resolve(response("met", { evidence: [{ entryId: "proof", quote: "All 12 acceptance tests passed." }] }));
    await check; assert.equal(f.goal.state, "needsYou");
  } finally { await f.close(); }
});

test("only branch state restores, active goals pause without starting, and durable clear survives restart", async () => {
  const f = fixture();
  try {
    await f.start(); await f.work(); const durable = structuredClone(f.stored);
    const restored = fixture({ entries: durable });
    assert.equal(restored.goal.id, f.goal.id); assert.equal(restored.goal.state, "paused");
    assert.equal(restored.goal.tokensUsed, 3); assert.equal(restored.prompts.length, 0); assert.equal(restored.calls.length, 0);
    await restored.action({ action: "clear" });
    const cleared = fixture({ entries: restored.stored });
    assert.equal(cleared.goal, null); await cleared.close(); await restored.close();
    const malformed = fixture({ entries: [...durable, { type: "custom", customType: "shepherd.goal", data: { goal: { state: "working" } } }] });
    assert.equal(malformed.goal, null); await malformed.close();
  } finally { await f.close(); }
});

test("shutdown and session switches cancel pending evaluators and discard late results", async () => {
  const f = fixture();
  await f.start(); await f.work(); const check = f.check(); const previous = f.goal.id;
  await f.close(); await check;
  f.stored.length = 0; await f.emit("session_start");
  await f.start("New session objective"); assert.notEqual(f.goal.id, previous);
  f.calls[0].resolve(response("met")); await turn();
  assert.equal(f.goal.tokensUsed, 0); assert.equal(f.goal.state, "working"); await f.close();
});

test("worker abort/error and evaluator errors stop automation instead of evaluating/continuing", async () => {
  for (const stopReason of ["aborted", "error"]) {
    const f = fixture();
    await f.start(); await f.emit("message_start", { message: { role: "assistant" } });
    await f.emit("message_end", { message: { role: "assistant", stopReason } });
    await f.emit("agent_settled"); assert.equal(f.goal.state, "needsYou"); assert.equal(f.calls.length, 0); await f.close();
  }
  const f = fixture();
  try {
    await f.start(); await f.work(); const check = f.check(); f.calls[0].reject(Error("Local fixture failure"));
    const result = await check; assert.equal(f.goal.state, "needsYou"); assert(!result.continue);
  } finally { await f.close(); }
});

test("model selection respects configured authenticated small models and requires auth", async () => {
  const small = { provider: "fixture", id: "small", contextWindow: 64000 };
  const f = fixture({ models: [small], env: { SHEPHERD_GOAL_MODELS: "missing/nope,fixture/small" } });
  try {
    await f.start(); await f.work(); const check = f.check(); assert.deepEqual(f.calls[0].model, small);
    f.calls[0].resolve(response("needs_you", { reason: "Need permission", blocker: "permission" })); await check; assert.equal(f.goal.state, "needsYou");
  } finally { await f.close(); }
  const unauth = fixture({ auth: false });
  try {
    await unauth.start(); await unauth.work(); const result = await unauth.check();
    assert.equal(unauth.calls.length, 0); assert.equal(unauth.goal.state, "needsYou");
    assert.equal(result.entries[0].content.split("\n\nDetails:\n")[1], "No authenticated goal evaluator model is available.");
  }
  finally { await unauth.close(); }
});

test("runtime snapshots generate the five board states from actual publications", async (t) => {
  t.mock.method(performance, "now", () => 0);
  const condition = "Ledger tests pass and go vet is clean, without changing the consumer package.";
  const seed = (id) => [{ id: "fixture-seed", type: "custom", customType: "shepherd.goal", data: { goal: {
    id, revision: 1, text: condition, state: "paused", elapsedSeconds: 400, tokensUsed: 71000,
  } } }];
  const f = fixture({ entries: seed("00000000-0000-0000-0000-000000000001") });
  const blocked = fixture({ entries: seed("00000000-0000-0000-0000-000000000002") });
  const fresh = fixture();
  try {
    const goals = { paused: structuredClone(f.goal) }, records = [];
    await f.action({ action: "resume" }); goals.working = structuredClone(f.goal);
    await f.work(0); f.stored.at(-1).message.content = "41 tests passed\tgo vet is clean\nFull ledger proof.";
    const check = f.check(); goals.checking = structuredClone(f.goal);
    f.calls[0].resolve({ ...response("met", { reason: "Ledger tests and vet passed", summary: "41 tests passed",
      evidence: [{ entryId: "proof", quote: "41 tests passed\tgo vet is clean\nFull ledger proof." }] }), usage: { totalTokens: 33000 } });
    records.push((await check).entries[0]); goals.met = structuredClone(f.goal);
    await fresh.start(condition);
    const { customType, display, content } = fresh.customMessages[0].message;
    records.push({ customType, display, content }); // Omit only its randomized bookkeeping ID.
    await blocked.action({ action: "resume" });
    for (let i = 0; i < 3; i++) {
      await blocked.work(0);
      const quote = "ledger test failed\tmissing consumer guard\nFull failure output.";
      blocked.stored.at(-1).message.content = quote; blocked.stored.at(-1).message.isError = true;
      const check = blocked.check(); blocked.calls[i].resolve(response("not_met", { reason: "The ledger test failed", summary: "ledger test failed", blocker: "ledger-test",
        evidence: [{ entryId: "proof", quote }] }));
      const result = await check; if (i === 0 || i === 2) records.push(result.entries[0]);
    }
    goals.needsYou = structuredClone(blocked.goal);
    await blocked.action({ action: "resume" }); await blocked.work(0);
    const decision = blocked.check();
    blocked.calls.at(-1).resolve(response("needs_you", { reason: "choose a deployment target\nChoose staging or production; do not deploy until the user decides.", summary: "deployment needs a decision" }));
    records.push((await decision).entries[0]);
    await blocked.action({ action: "resume" }); await blocked.work(0);
    blocked.ctx.modelRegistry.hasConfiguredAuth = () => false;
    records.push((await blocked.check()).entries[0]);
    assert.equal(goals.working.tokensUsed, 71000); assert.equal(goals.checking.reason, "checking go test, go vet");
    assert.equal(goals.met.tokensUsed, 104000); assert.equal(goals.met.summary, "41 tests passed");
    assert.equal(goals.paused.reason, "paused by you · the clock stops");
    assert.equal(goals.needsYou.reason, "the same test failed 3 times in a row");
    assert.deepEqual(new Set(Object.values(goals).map((g) => g.state)), new Set(["working", "checking", "met", "paused", "needsYou"]));
    const file = path.join(root, "Tests/Extensions/goal-runtime-fixtures.json");
    const commands = fresh.commandMetadata.filter((c) => c.name === "goal");
    assert.equal(commands.length, 1); assert(commands[0].description.includes("<condition>"));
    for (const record of records) {
      const line = record.content.split("\n")[0];
      assert(!/[\t\r]/.test(line)); assert(!line.includes("proof") && !line.includes("00000000-0000"));
    }
    const json = JSON.stringify({ goals: ["working", "checking", "met", "paused", "needsYou"].map((state) => goals[state]), records, commands }, null, 2) + "\n";
    if (process.argv.includes("--update-fixtures")) fs.writeFileSync(file, json);
    assert.equal(fs.readFileSync(file, "utf8"), json, "Runtime fixtures changed; run node Tests/Extensions/goal.test.mjs --update-fixtures and review the diff");
  } finally { await f.close(); await blocked.close(); await fresh.close(); }
});

async function until(what, fn, timeout = 15000) {
  const end = Date.now() + timeout;
  while (!fn()) {
    if (Date.now() > end) throw Error(`Timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}

// Local HTTP provider verifies the actual pi boundary, registry.complete, immediate commands,
// RPC widgets, and durable session entries together. The worker calls read; the evaluator only returns a tool verdict.
async function realPi(dir) {
  const requests = [];
  let releaseEvaluation, evaluationNumber = 0, workerNumber = 0;
  const server = http.createServer(async (req, res) => {
    let raw = ""; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw); requests.push(body);
    const evaluator = body.tools?.some((t) => t.function?.name === "goal_verdict");
    let call;
    if (evaluator) {
      evaluationNumber++;
      if (evaluationNumber === 1) await new Promise((resolve) => { releaseEvaluation = resolve; });
      const content = body.messages.filter((m) => m.role === "user").at(-1).content;
      const payload = JSON.parse(typeof content === "string" ? content : content.filter((c) => c.type === "text").map((c) => c.text).join("\n"));
      const citation = payload.transcript.find((e) => e.role === "toolResult");
      call = { name: "goal_verdict", arguments: JSON.stringify({ verdict: evaluationNumber < 3 ? "not_met" : "met", reason: "Acceptance result observed", summary: "12 acceptance tests passed",
        evidence: citation ? [{ entryId: citation.entryId, quote: "All 12 acceptance tests passed." }] : [], blocker: "" }) };
    } else if (++workerNumber % 2 === 1) {
      call = { name: "read", arguments: JSON.stringify({ path: "acceptance.txt" }) };
    }
    const chunk = (delta, finish = null) => ({ id: "fixture", object: "chat.completion.chunk", created: 1, model: body.model,
      choices: [{ index: 0, delta, finish_reason: finish }] });
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(`data: ${JSON.stringify(chunk(call ? { tool_calls: [{ index: 0, id: `call${requests.length}`, type: "function", function: call }] } : { content: "Worker finished its check." }))}\n\n`);
    res.end(`data: ${JSON.stringify({ ...chunk({}, call ? "tool_calls" : "stop"), usage: { prompt_tokens: 2, completion_tokens: 3, total_tokens: 5 } })}\n\ndata: [DONE]\n\n`);
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const config = path.join(dir, "config"), sessions = path.join(dir, "sessions"); fs.mkdirSync(config);
  fs.writeFileSync(path.join(dir, "acceptance.txt"), "All 12 acceptance tests passed.\n");
  fs.writeFileSync(path.join(config, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }));
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: ["worker", "small"].map((id) => ({ id, name: id, reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 2048, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } })),
  } } }));
  const child = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--session-dir", sessions,
    "-ne", "-ns", "-np", "--model", "fixture/worker", "-e", source], { cwd: dir, stdio: ["pipe", "pipe", "pipe"], env: {
      PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1", SHEPHERD_EXT_GOAL: "1", SHEPHERD_GOAL_MODELS: "fixture/small",
    } });
  const events = []; let output = "", stderr = "", counter = 0;
  child.stdout.on("data", (chunk) => {
    output += chunk;
    for (let nl; (nl = output.indexOf("\n")) >= 0; output = output.slice(nl + 1)) {
      try { events.push(JSON.parse(output.slice(0, nl))); } catch { }
    }
  });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const pi = { events, requests, sessions,
    get stderr() { return stderr; },
    goal: () => {
      const widget = events.filter((e) => e.type === "extension_ui_request" && e.method === "setWidget" && e.widgetKey === "shepherd.goal").at(-1);
      return widget ? JSON.parse(widget.widgetLines[0].slice("SHEPHERD_GOAL:".length)) : undefined;
    },
    async request(command) {
      const id = `req${++counter}`; child.stdin.write(JSON.stringify({ id, ...command }) + "\n");
      await until(`response to ${command.type}`, () => events.some((e) => e.type === "response" && e.id === id));
      return events.find((e) => e.type === "response" && e.id === id);
    },
    settled: () => events.filter((e) => e.type === "agent_settled").length,
    release: () => releaseEvaluation?.(),
    async stop() {
      releaseEvaluation?.(); child.kill();
      if (child.exitCode === null && child.signalCode === null) await new Promise((r) => child.once("exit", r));
      server.closeAllConnections(); await new Promise((r) => server.close(r));
    },
  };
  return pi;
}

test("real pinned pi: editing checking retains its header, cancels stale evaluation and completes fresh work without getting stuck", { timeout: 60000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-goal-edit-"));
  const pi = await realPi(dir);
  try {
    await until("goal capability", () => pi.goal() === null);
    await pi.request({ type: "prompt", message: "/goal Verify acceptance.txt contains the full acceptance result" });
    await until("checking", () => pi.goal()?.state === "checking");
    const before = pi.goal();
    await pi.request({ type: "prompt", message: `/shepherd-goal ${JSON.stringify({ action: "edit", text: before.text })}` });
    assert.equal(pi.goal().revision, before.revision); assert.equal(pi.goal().reason, before.reason);
    const text = before.text + " with complete tool proof";
    await pi.request({ type: "prompt", message: `/shepherd-goal ${JSON.stringify({ action: "edit", text })}` });
    pi.release();
    await until("edited goal met", () => pi.goal()?.state === "met" && pi.settled() >= 1);
    const widgets = pi.events.filter((e) => e.type === "extension_ui_request" && e.method === "setWidget" && e.widgetKey === "shepherd.goal")
      .map((e) => JSON.parse(e.widgetLines[0].slice("SHEPHERD_GOAL:".length))).filter(Boolean);
    const edited = widgets.find((g) => g.text === text);
    assert.equal(edited.state, "checking"); assert.equal(edited.reason, before.reason); assert.equal(edited.revision, before.revision + 1);
    assert(!widgets.some((g) => g.state === "needsYou"));
    assert.equal(pi.goal().text, text); assert.equal(pi.goal().summary, "12 acceptance tests passed");
    assert.equal(pi.events.filter((e) => e.type === "extension_error").length, 0);
  } catch (error) { error.message += `\npi stderr:\n${pi.stderr}`; throw error; }
  finally { await pi.stop(); fs.rmSync(dir, { recursive: true, force: true }); }
});

test("real pinned pi: immediate controls, structured nested checks, boundary continuation and durable state", { timeout: 60000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-goal-"));
  const pi = await realPi(dir);
  try {
    await until("goal capability", () => pi.goal() === null);
    const commands = (await pi.request({ type: "get_commands" })).data.commands;
    assert(commands.some((c) => c.name === "goal"));
    assert.equal((await pi.request({ type: "prompt", message: "/goal --tokens 1000 Verify acceptance.txt contains the full acceptance result" })).success, true);
    await until("checking with nested provider gated", () => pi.goal()?.state === "checking");
    const first = pi.goal();
    const stale = await pi.request({ type: "prompt", message: `/shepherd-goal ${JSON.stringify({ action: "pause", expectedGoalRevision: first.revision - 1 })}` });
    // Pinned pi catches command throws and reports extension_error, while acknowledging dispatch.
    assert.equal(stale.success, true); assert.equal(pi.goal().state, "checking");
    assert(pi.events.some((e) => e.type === "extension_error" && e.extensionPath === "command:shepherd-goal" && /changed/.test(e.error)));
    assert.equal((await pi.request({ type: "prompt", message: `/shepherd-goal ${JSON.stringify({ action: "pause", expectedGoalID: first.id, expectedGoalRevision: first.revision })}` })).success, true);
    await until("paused run settled", () => pi.settled() === 1);
    assert.equal(pi.goal().state, "paused"); pi.release();
    const paused = pi.goal();
    assert.equal((await pi.request({ type: "prompt", message: `/shepherd-goal ${JSON.stringify({ action: "edit", text: paused.text + ", with complete proof" })}` })).success, true);
    assert.equal(pi.goal().state, "paused"); assert.equal(pi.goal().reason, "paused by you · the clock stops");
    assert.equal((await pi.request({ type: "prompt", message: "/goal resume" })).success, true);
    await until("goal met after boundary continuation", () => pi.goal()?.state === "met" && pi.settled() === 2);
    assert(pi.goal().tokensUsed >= 20); assert.match(pi.goal().evidence, /All 12 acceptance tests passed/);
    const evaluatorCalls = pi.requests.filter((r) => r.model === "small");
    assert.equal(evaluatorCalls.length, 3); assert(evaluatorCalls.every((r) => r.tools.length === 1 && r.tools[0].function.name === "goal_verdict"));
    const entries = (await pi.request({ type: "get_entries" })).data.entries;
    assert(entries.some((e) => e.type === "custom" && e.customType === "shepherd.goal" && e.data.goal?.state === "met"));
    assert(entries.some((e) => e.type === "custom_message" && e.customType === "shepherd.goal.set" && e.display && e.content.startsWith("Goal set\n")));
    assert(entries.some((e) => e.type === "custom_message" && e.customType === "shepherd.goal.continue"));
    assert(entries.some((e) => e.type === "custom_message" && e.customType === "shepherd.goal.check" && e.display));
    assert.equal(pi.events.filter((e) => e.type === "extension_error").length, 1, "only the deliberate stale-command rejection, no boundary or handler errors");
  } catch (error) { error.message += `\npi stderr:\n${pi.stderr}`; throw error; }
  finally { await pi.stop(); fs.rmSync(dir, { recursive: true, force: true }); }
});
