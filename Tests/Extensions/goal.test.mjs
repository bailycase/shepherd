// Goal controller restore, fences and queue yield against a fake extension host. No processes.
import test from "node:test";
import assert from "node:assert/strict";
import * as path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const { createJiti } = createRequire(path.join(pkg, "package.json"))("jiti");
const jiti = createJiti(import.meta.url, { alias: { typebox: path.join(pkg, "node_modules/typebox/build/index.mjs") } });
const { default: install } = await jiti.import(path.join(root, "Extensions/shepherd-goal.ts"));
const ID = "00000000-0000-0000-0000-000000000001";

function fixture({ entries = [], env = {} } = {}) {
  const handlers = new Map(), commands = new Map(), tools = new Map(), widgets = [], prompts = [], stored = structuredClone(entries);
  let active = ["read", "bash"], idle = true, index = 0;
  const options = { SHEPHERD_EXT_GOAL: "1", SHEPHERD_GOALS_ENABLED: "1", ...env };
  const saved = Object.fromEntries(Object.keys(options).map((k) => [k, process.env[k]]));
  Object.assign(process.env, options);
  try {
    install({ on: (name, fn) => handlers.set(name, fn), events: { on: () => {} },
      registerCommand: (name, value) => commands.set(name, value.handler), registerTool: (tool) => tools.set(tool.name, tool),
      getActiveTools: () => active, setActiveTools: (names) => { active = names; },
      appendEntry: (customType, data) => stored.push({ id: `entry${++index}`, type: "custom", customType, data: structuredClone(data) }),
      sendMessage: (message, options) => { if (options.triggerTurn) prompts.push(message); } });
  } finally { for (const [k, v] of Object.entries(saved)) v === undefined ? delete process.env[k] : process.env[k] = v; }
  const ctx = { isIdle: () => idle, hasPendingMessages: () => false,
    ui: { setWidget: (_key, lines) => widgets.push(lines && JSON.parse(lines[0].slice("SHEPHERD_GOAL:".length))) },
    sessionManager: { getBranch: () => stored, getLeafId: () => stored.at(-1)?.id ?? null, getSessionId: () => "s" } };
  const f = { tools, prompts, stored, ctx,
    get goal() { return widgets.at(-1); }, get active() { return active; }, set idle(v) { idle = v; },
    emit: (event, value = {}) => handlers.get(event)?.(value, ctx),
    action: (value) => commands.get("shepherd-goal")(JSON.stringify(value), ctx),
    finish: (outcome, summary) => tools.get("goal_finish").execute("call", { outcome, summary }, undefined, undefined, ctx),
  };
  f.emit("session_start");
  return f;
}
const legacy = (goal) => [{ id: "seed", type: "custom", customType: "shepherd.goal", data: { goal: {
  id: ID, revision: 3, text: "Acceptance passes", elapsedSeconds: 60, tokensUsed: 900, ...goal } } }];

test("restore pauses legacy Working/Checking goals and strips checker fields; Resume works from a legacy confirm state", async () => {
  for (const state of ["working", "checking"]) {
    const f = fixture({ entries: legacy({ state, checkCount: 4, checkedBy: "x/y", tokenLimit: 1 }) });
    assert.equal(f.goal.state, "paused"); assert.equal(f.prompts.length, 0);
    for (const key of ["checkCount", "checkedBy", "tokenLimit", "confirmationRequired"]) assert(!Object.hasOwn(f.goal, key));
    assert(!f.active.includes("goal_finish"));
  }
  const f = fixture({ entries: legacy({ state: "needsYou", reason: "looks met, evidence incomplete, confirm", confirmationRequired: true }) });
  assert(!Object.hasOwn(f.goal, "confirmationRequired"));
  await assert.rejects(f.action({ action: "confirm" }), /Unknown goal action/);
  await f.action({ action: "resume" });
  assert.equal(f.goal.state, "working"); assert.equal(f.prompts.length, 1); assert(f.active.includes("goal_finish"));
});

test("goal_finish ends only an active goal and the tool leaves the active set", async () => {
  const f = fixture();
  await assert.rejects(f.finish("met", "done"), /no active goal/);
  await f.action({ action: "set", text: "Acceptance passes" });
  assert(f.active.includes("goal_finish"));
  await f.finish("met", "41 tests passed\nwith details");
  assert.equal(f.goal.state, "met"); assert.equal(f.goal.summary, "41 tests passed");
  assert(!f.active.includes("goal_finish"));
  assert.equal(await f.emit("agent_before_settle", { entries: [], outcome: "completed" }), undefined);
  await assert.rejects(f.action({ action: "resume" }), /clear-only/);
});

test("fences reject stale controls; edit while paused never restarts work", async () => {
  const f = fixture();
  await f.action({ action: "set", text: "Acceptance passes" });
  const { id, revision } = f.goal;
  await assert.rejects(f.action({ action: "pause", expectedGoalID: id, expectedGoalRevision: revision + 1 }), /Goal changed/);
  await f.action({ action: "pause", expectedGoalID: id, expectedGoalRevision: revision, expectedGoalState: "working" });
  const prompts = f.prompts.length;
  await f.action({ action: "edit", text: "Acceptance and lint pass" });
  assert.equal(f.goal.state, "paused"); assert.equal(f.goal.text, "Acceptance and lint pass"); assert.equal(f.prompts.length, prompts);
});

test("a yielded settle does not continue, and unyield on an idle goal kicks it off once", async () => {
  const f = fixture();
  await f.action({ action: "set", text: "Acceptance passes" });
  await f.emit("before_agent_start"); await f.emit("tool_execution_start", { toolName: "read", toolCallId: "1" });
  await f.action({ action: "yield" });
  assert.equal(await f.emit("agent_before_settle", { entries: [], outcome: "completed" }), undefined);
  assert.equal(f.goal.state, "working");
  const prompts = f.prompts.length;
  await f.action({ action: "unyield" }); await f.action({ action: "unyield" });
  assert.equal(f.prompts.length, prompts + 1);
});

test("a question stops the goal on the user and Resume waits for the answer", async () => {
  const f = fixture();
  await f.action({ action: "set", text: "Acceptance passes" });
  await f.emit("tool_execution_start", { toolName: "ask_user", toolCallId: "q" });
  assert.equal(f.goal.state, "needsYou"); assert.equal(f.goal.reason, "waiting for your answer");
  await assert.rejects(f.action({ action: "resume" }), /Answer the question/);
  await f.emit("tool_execution_end", { toolCallId: "q" });
  assert.equal(f.goal.reason, "answer received · resume to continue");
  await f.action({ action: "resume" }); assert.equal(f.goal.state, "working");
});

test("the goal reminder leads the request so the conversation prompt cache survives each turn", async () => {
  const f = fixture();
  await f.action({ action: "set", text: "Acceptance passes" });
  const history = [{ role: "user", content: "a" }, { role: "assistant", content: [] }, { role: "toolResult", content: [] }];
  const { messages } = f.emit("context", { messages: history });
  assert.match(messages[0].content[0].text, /SHEPHERD_GOAL_CURRENT_DATA/);
  assert.deepEqual(messages.slice(1), history);
});
