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
  verdict, reason: "Run the remaining checks", evidence: [], blocker: "", ...extra,
} }] });
const proof = { role: "toolResult", toolName: "bash", toolCallId: "check", isError: false, content: [{ type: "text", text: "All 12 acceptance tests passed." }] };

function fixture({ entries = [], enabled = "1", models, auth = true, env = {} } = {}) {
  const handlers = new Map(), commands = new Map(), widgets = [], prompts = [], calls = [], stored = structuredClone(entries), bus = new Map(), customMessages = [];
  const options = { SHEPHERD_EXT_GOAL: enabled, SHEPHERD_GOAL_MODELS: "", ...env };
  const saved = Object.fromEntries(Object.keys(options).map((k) => [k, process.env[k]]));
  Object.assign(process.env, options);
  let index = 0, aborted = 0;
  try {
    install({ on: (name, fn) => handlers.set(name, fn), events: { on: (name, fn) => bus.set(name, fn) }, registerCommand: (name, value) => commands.set(name, value.handler),
      appendEntry: (customType, data) => stored.push({ id: `entry${++index}`, type: "custom", customType, data: structuredClone(data) }),
      sendUserMessage: () => { throw Error("Goal kickoff must be a hidden custom message"); }, sendMessage: (message, options) => {
        customMessages.push({ message, options });
        if (options.triggerTurn) prompts.push({ text: message.content, options });
      } });
  } finally { for (const [k, v] of Object.entries(saved)) v === undefined ? delete process.env[k] : process.env[k] = v; }
  const model = { provider: "fixture", id: "worker", contextWindow: 64000 };
  const ctx = { model, mode: "rpc", isIdle: () => false, hasPendingMessages: () => false,
    abort: () => { aborted++; }, ui: { setWidget: (key, lines) => { assert.equal(key, "shepherd.goal"); assert.equal(lines.length, 1); widgets.push(JSON.parse(lines[0].slice("SHEPHERD_GOAL:".length))); } },
    sessionManager: { getBranch: () => stored, getEntries: () => { throw Error("Must read active branch only"); }, getLeafId: () => stored.at(-1)?.id ?? null, getSessionId: () => "fixture-session" },
    modelRegistry: { getAvailable: () => models ?? [model], hasConfiguredAuth: () => auth,
      find: (provider, id) => (models ?? [model]).find((m) => m.provider === provider && m.id === id),
      complete: (model, context, options) => new Promise((resolve, reject) => calls.push({ model, context, options, resolve, reject })) } };
  const f = { handlers, commands, widgets, prompts, calls, ctx, stored, bus, customMessages,
    get goal() { return widgets.at(-1); }, get aborted() { return aborted; },
    emit: (event, value = {}) => handlers.get(event)?.(value, ctx),
    action: (value) => commands.get("shepherd-goal")(JSON.stringify(value), ctx),
    start: (text = "All acceptance tests pass", extra = {}) => f.action({ action: "set", text, ...extra }),
    check: (extra = {}) => f.emit("agent_before_settle", { entries: [], outcome: "completed", context: { contextEntries: stored.map((sourceEntry) => ({ sourceEntry, messages: sourceEntry.message ? [sourceEntry.message] : [] })) }, ...extra }),
    async work(tokens = 3) {
      const message = { role: "assistant", timestamp: 1, content: [{ type: "text", text: "Checked the implementation." }], usage: { totalTokens: tokens }, stopReason: "stop" };
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
    assert.equal(f.goal.state, "working");
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
    assert.equal(f.goal.state, "needsYou"); assert.match(f.goal.reason, /without new successful tool evidence/);
    assert.equal(f.stored.at(-1).data.consecutiveNoProgress, 3); assert.equal(f.stored.at(-1).data.lastEvidenceID, "proof");
    const restored = fixture({ entries: f.stored });
    assert.equal(restored.stored.at(-1).data.consecutiveNoProgress, 3); await restored.close();
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
    assert.match(f.goal.reason, /Answer received/);
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
    assert.match(f.goal.reason, /Repeated blocker/); assert.equal(f.stored.at(-1).data.blockerCount, 3);
  } finally { await f.close(); }
});

for (const [name, answer] of [
  ["prose", { content: [{ type: "text", text: '{"verdict":"met"}' }] }],
  ["unknown verdict", response("success")],
  ["missing reason", response("met", { reason: "" })],
  ["missing blocker", response("not_met", { blocker: undefined })],
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
  try { await unauth.start(); await unauth.work(); await unauth.check(); assert.equal(unauth.calls.length, 0); assert.equal(unauth.goal.state, "needsYou"); }
  finally { await unauth.close(); }
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
  let releaseEvaluation, evaluationNumber = 0;
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
      call = { name: "goal_verdict", arguments: JSON.stringify({ verdict: evaluationNumber < 3 ? "not_met" : "met", reason: "Acceptance result observed",
        evidence: citation ? [{ entryId: citation.entryId, quote: "All 12 acceptance tests passed." }] : [], blocker: "" }) };
    } else if (!body.messages.some((m) => m.role === "tool")) {
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
