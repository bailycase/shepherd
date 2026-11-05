// The goal controller on the real pinned pi RPC runtime with a loopback fake model only.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { realPi, until, finish } from "./goal-runtime-provider.mjs";

const read = { call: { name: "read", arguments: { path: "acceptance.txt" } } };
const widgetGoals = (pi) => pi.events.filter((e) => e.type === "extension_ui_request" && e.method === "setWidget" && e.widgetKey === "shepherd.goal")
  .filter((e) => e.widgetLines).map((e) => JSON.parse(e.widgetLines[0].slice("SHEPHERD_GOAL:".length))).filter(Boolean);
async function withPi(options, body) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-goal-"));
  const pi = await realPi(dir, options);
  try {
    await until("goal controller", () => pi.events.some((e) => e.type === "extension_ui_request" && e.widgetKey === "shepherd.goal"));
    await body(pi);
    if (!options.allowErrors) assert.equal(pi.events.filter((e) => e.type === "extension_error").length, 0, "extension errors");
  }
  catch (error) { error.message += `\npi stderr:\n${pi.stderr}\nevents: ${pi.events.map((e) => e.type).join(", ")}`; throw error; }
  finally { await pi.stop(); fs.rmSync(dir, { recursive: true, force: true }); }
}
const entries = async (pi) => (await pi.request({ type: "get_entries" })).data.entries;

test("the worker finishes the goal itself; goal_finish is offered only while the goal is active", { timeout: 60000 }, async () => {
  const seen = [];
  const script = (_body, { workerNumber, tools }) => {
    seen.push(tools);
    return workerNumber === 1 ? read : workerNumber === 2 ? { call: finish() } : { text: "All done." };
  };
  await withPi({ script }, async (pi) => {
    await pi.request({ type: "prompt", message: "/goal Verify acceptance result" });
    await until("met", () => pi.goal()?.state === "met" && pi.settled() === 1);
    assert.equal(pi.goal().summary, "12 acceptance tests passed");
    assert(seen.slice(0, 2).every((tools) => tools.includes("goal_finish")));
    assert(!seen[2].includes("goal_finish"), "the closing reply after Met no longer sees the tool");
    // After Met, an ordinary turn no longer sees the tool and the goal does not continue it.
    await pi.request({ type: "prompt", message: "Say hi" });
    await until("ordinary turn", () => pi.settled() === 2);
    assert(!seen.at(-1).includes("goal_finish"));
    assert.equal(pi.goal().state, "met");
    assert(!widgetGoals(pi).some((g) => g.state === "checking"));
  });
});

test("an active goal keeps continuing across settles until the worker finishes it", { timeout: 60000 }, async () => {
  const script = (_body, { workerNumber }) => [read, { text: "Read it." }, read, { text: "Read again." }, { call: finish() }][workerNumber - 1] ?? { text: "Done." };
  await withPi({ script }, async (pi) => {
    await pi.action({ action: "set", text: "Verify acceptance result" });
    await until("met", () => pi.goal()?.state === "met");
    await until("settled", () => pi.settled() === 1);
    const continues = (await entries(pi)).filter((e) => e.customType === "shepherd.goal.continue");
    assert.equal(continues.length, 2);
    // Continuations never repeat the objective in the durable transcript.
    assert(continues.every((e) => !JSON.stringify(e).includes("Verify acceptance result")));
  });
});

test("blocked stops on the user with the worker's reason", { timeout: 60000 }, async () => {
  const script = (_body, { workerNumber }) => workerNumber === 1 ? { call: finish("blocked", "Need the staging API key") } : { text: "I need the key." };
  await withPi({ script }, async (pi) => {
    await pi.action({ action: "set", text: "Deploy to staging" });
    await until("needs you", () => pi.goal()?.state === "needsYou" && pi.settled() === 1);
    assert.equal(pi.goal().reason, "need the staging api key");
  });
});

test("a worker that only talks stops after three turns instead of looping", { timeout: 60000 }, async () => {
  await withPi({ script: () => ({ text: "I think it is done." }) }, async (pi) => {
    await pi.action({ action: "set", text: "Verify acceptance result" });
    await until("stalled", () => pi.goal()?.state === "needsYou" && pi.settled() === 1);
    assert.equal(pi.goal().reason, "no progress in 3 turns");
    assert.equal(pi.requests.length, 3);
  });
});

test("pause during work stops continuation and a later ordinary turn never resumes the goal", { timeout: 60000 }, async () => {
  const script = (_body, { workerNumber }) => workerNumber === 1 ? read : workerNumber === 2 ? { gate: "turn", text: "Read it." } : { text: "Hi." };
  await withPi({ script }, async (pi) => {
    await pi.action({ action: "set", text: "Verify acceptance result" });
    await until("second request in flight", () => pi.requests.length === 2);
    await pi.action({ action: "pause" });
    pi.release("turn");
    await until("settled", () => pi.settled() === 1);
    assert.equal(pi.goal().state, "paused"); assert.equal(pi.goal().runningSince, undefined);
    await pi.request({ type: "prompt", message: "Say hi" });
    await until("ordinary turn", () => pi.settled() === 2);
    assert.equal(pi.goal().state, "paused"); assert.equal(pi.requests.length, 3);
    assert(!pi.requests[2].tools.some((t) => t.function?.name === "goal_finish"));
  });
});

test("goals default off: commands reject with Settings guidance and live enable only publishes availability", { timeout: 60000 }, async () => {
  await withPi({ env: { SHEPHERD_GOALS_ENABLED: "0" }, allowErrors: true }, async (pi) => {
    assert.equal(pi.goal(), undefined);
    const rejected = await pi.request({ type: "prompt", message: "/goal Verify acceptance result" });
    assert.match(JSON.stringify(rejected) + pi.stderr + JSON.stringify(pi.events.slice(-3)), /Settings > Experiments > Goals/);
    await pi.action({ action: "configure", enabled: true });
    await until("availability", () => pi.goal() === null);
    assert.equal(pi.requests.length, 0);
  });
});
