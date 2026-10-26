// FAKE loopback provider only. Run with PI_PACKAGE_DIR pointing at the verified patched SDK.
import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import { withPi, until } from "./fixtures/pi-rpc-harness.mjs";

const options = { args: ["-ne", "-ns", "-np", "-nc", "--no-themes"], settings: { retry: { enabled: false }, compaction: { enabled: false } } };
const entries = async pi => (await pi.request({ type: "get_entries" })).data.entries;
const users = list => list.filter(e => e.type === "message" && e.message.role === "user");
const recovery = async pi => (await pi.request({ type: "get_state" })).data.checkpointRecovery;
function assertRecordedRefusal(after, before, reason) {
  assert.deepEqual(after.slice(0, before.length), before, "all prior entries remain immutable");
  assert.equal(after.length, before.length + 1);
  assert.equal(after.at(-1).type, "custom");
  assert.equal(after.at(-1).data.state, "refused");
  assert.equal(after.at(-1).data.error, reason);
  assert.deepEqual(users(after), users(before));
}
async function recover(pi, checkpoint, operationID = randomUUID()) {
  const mark = pi.events.length;
  const response = await pi.request({ type: "recover_checkpoint", token: checkpoint.token, operationID });
  if (response.success && response.data.state === "accepted") await until("recovery settles", () => pi.events.slice(mark).some(e => e.type === "agent_settled"));
  return { response, operationID };
}

for (const api of ["openai-completions", "openai-responses"]) test(`${api}: recovery keeps user identity, completed work, original failure and exact-operation receipt`, { timeout: 60000 }, async t => {
  await withPi(t, { ...options, api, onRequest: ({ index }) => index === 0
    ? { tool: { name: "write", arguments: { path: "completed.txt", content: "done" } } }
    : index === 1 ? { status: 400, text: "stream disconnected before completion: stream closed before response completed" } : {} }, async pi => {
    await pi.prompt("Do the work, then explain it.");
    const before = await entries(pi);
    const failure = before.find(e => e.message?.stopReason === "error");
    assert(failure);
    const checkpoint = (await recovery(pi)).checkpoint;
    assert.equal(checkpoint.failedEntryID, failure.id);
    const { response, operationID } = await recover(pi, checkpoint);
    assert.equal(response.success, true, JSON.stringify(response));
    const after = await entries(pi);
    assert.deepEqual(users(after), users(before), "no durable user entry is added or rewritten");
    assert.deepEqual(after.filter(e => before.some(b => b.id === e.id)), before, "all original entries are immutable");
    assert.equal(pi.events.filter(e => e.type === "tool_execution_start").length, 1);
    assert(JSON.stringify(pi.provider.requests[2].body).includes("completed.txt"));
    assert.equal((await pi.request({ type: "get_messages", history: true })).data.messages.filter(m => m.stopReason === "error").length, 1);
    const count = pi.provider.requests.length;
    const replay = await pi.request({ type: "recover_checkpoint", token: checkpoint.token, operationID });
    assert.equal(replay.success, true);
    assert.equal(replay.data.state, "settled");
    assert.equal(pi.provider.requests.length, count);
    assert.equal((await pi.request({ type: "get_recovery_operation", operationID })).data.receipt.token, checkpoint.token);
    const duplicate = await pi.request({ type: "recover_checkpoint", token: checkpoint.token, operationID: randomUUID() });
    assert.equal(duplicate.success, false);
    assert.equal(pi.provider.requests.length, count);
    const conflict = await pi.request({ type: "recover_checkpoint", token: "0".repeat(64), operationID });
    assert.match(conflict.error, /conflict/);
  });
});

test("restart RPC continues the reopened session without synthetic input or tool redelivery", { timeout: 60000 }, async t => {
  await withPi(t, { ...options, onRequest: ({ index }) => index === 0
    ? { tool: { name: "write", arguments: { path: "completed.txt", content: "done" } } }
    : index === 1 ? { status: 400, text: "FAKE interrupted stream" } : {} }, async pi => {
    await pi.prompt("Finish my actual task");
    const before = await entries(pi);
    const state = (await pi.request({ type: "get_state" })).data;
    const reserved = (await pi.request({ type: "get_restart_recovery" })).data.checkpoint;
    const operationID = randomUUID();
    fs.writeFileSync(path.join(pi.work, "host-reservation.json"), JSON.stringify({ operationID, ...reserved }));
    await pi.reopen(state.sessionFile);
    assert.equal((await pi.request({ type: "get_recovery_operation", operationID })).data.receipt, null);
    const checkpoint = (await pi.request({ type: "get_restart_recovery" })).data.checkpoint;
    assert(checkpoint);
    const intent = JSON.parse(fs.readFileSync(path.join(pi.work, "host-reservation.json"), "utf8"));
    assert.equal(checkpoint.fence, intent.fence);
    assert.notEqual(checkpoint.token, intent.token, "new process, newly sealed executable authority");
    const mark = pi.events.length;
    const response = await pi.request({ type: "resume_session", token: checkpoint.token, operationID });
    assert.equal(response.success, true, JSON.stringify(response));
    await until("restarted turn settled", () => pi.events.slice(mark).some(e => e.type === "agent_settled"));
    const after = await entries(pi);
    assert.deepEqual(users(after), users(before));
    assert.equal(after.filter(e => e.type === "custom_message").length, 0);
    assert.equal((await pi.request({ type: "get_state" })).data.sessionId, state.sessionId);
    assert.equal(pi.provider.requests.length, 3);
    assert.equal(fs.readFileSync(path.join(pi.work, "completed.txt"), "utf8"), "done");
    const count = pi.provider.requests.length;
    assert.equal((await pi.request({ type: "resume_session", token: checkpoint.token, operationID })).data.state, "settled");
    assert.equal(pi.provider.requests.length, count);
  });
});

test("steering and attachment identities remain unchanged across recovery", { timeout: 60000 }, async t => {
  let release;
  const first = new Promise(resolve => { release = resolve; });
  t.after(() => release({}));
  await withPi(t, { ...options, input: ["text", "image"], onRequest: ({ index }) => index === 0 ? first
    : index === 1 ? { status: 400, text: "FAKE failure after steering" } : {} }, async pi => {
    const original = pi.prompt("original");
    await until("the held FAKE request", () => pi.provider.requests.length === 1);
    const image = { type: "image", data: "AA==", mimeType: "image/png" };
    assert.equal((await pi.request({ type: "steer", message: "FAKE steer identity", images: [image] })).success, true);
    release({ tool: { name: "write", arguments: { path: "completed.txt", content: "done" } } });
    await original;
    const before = await entries(pi);
    assert.equal(users(before).length, 2);
    assert.deepEqual(users(before)[1].message.content.find(p => p.type === "image"), image);
    const checkpoint = (await recovery(pi)).checkpoint;
    assert(checkpoint, JSON.stringify(await recovery(pi)));
    assert.equal((await recover(pi, checkpoint)).response.success, true);
    assert.deepEqual(users(await entries(pi)), users(before));
    assert.equal(pi.events.filter(e => e.type === "tool_execution_start").length, 1);
    assert.equal(pi.provider.requests.length, 3);
    assert(JSON.stringify(pi.provider.requests[2].body).includes("FAKE steer identity"));
    assert(JSON.stringify(pi.provider.requests[2].body).includes("data:image/png;base64,AA=="));
  });
});

test("stale checkpoints and successful tails refuse without a provider request", { timeout: 60000 }, async t => {
  await withPi(t, { ...options, onRequest: ({ index }) => index === 0 ? { status: 400, text: "fixture failure" } : {} }, async pi => {
    await pi.prompt("first");
    const checkpoint = (await recovery(pi)).checkpoint;
    assert(checkpoint);
    const stale = await pi.request({ type: "recover_checkpoint", token: "0".repeat(64), operationID: randomUUID() });
    assert.match(stale.error, /stale/);
    await pi.prompt("ordinary second turn");
    const refused = await pi.request({ type: "recover_checkpoint", token: checkpoint.token, operationID: randomUUID() });
    assert.match(refused.error, /not_failed/);
    assert.equal(pi.provider.requests.length, 2);
    assert.equal(users(await entries(pi)).length, 2, "ordinary chat still adds ordinary messages");
  });
});

for (const api of ["openai-completions", "openai-responses"]) test(`${api}: an empty reply not marked failed is not silently reclassified for recovery`, { timeout: 60000 }, async t => {
  await withPi(t, { ...options, api, onRequest: ({ index }) => index === 0 ? { outputText: "" } : {} }, async pi => {
    await pi.prompt("empty failure");
    const before = await entries(pi);
    assert(before.some(e => e.message?.role === "assistant" && e.message.stopReason === "stop"));
    assert.equal((await recovery(pi)).refusal, "recovery_not_failed");
    assert.equal((await pi.request({ type: "recover_checkpoint", token: "a".repeat(64), operationID: randomUUID() })).success, false);
    assertRecordedRefusal(await entries(pi), before, "recovery_not_failed");
    assert.equal(pi.provider.requests.length, 1);
  });
});

test("partial provider prose remains inspectable after recovery and process reopen", { timeout: 60000 }, async t => {
  await withPi(t, { ...options, onRequest: ({ index }) => index === 0
    ? { outputText: "Partial analysis", streamError: "stream closed before response completed" } : {} }, async pi => {
    await pi.prompt("retain the partial answer");
    const before = await entries(pi);
    const failed = before.find(e => e.message?.stopReason === "error");
    assert.equal(failed.message.content[0].text, "Partial analysis");
    const checkpoint = (await recovery(pi)).checkpoint;
    const { operationID } = await recover(pi, checkpoint);
    const sessionFile = (await pi.request({ type: "get_state" })).data.sessionFile;
    const state = await pi.reopen(sessionFile);
    assert.equal(state.success, true);
    assert.deepEqual(users(await entries(pi)), users(before));
    const history = (await pi.request({ type: "get_messages", history: true })).data.messages;
    assert(history.some(m => m.errorMessage === failed.message.errorMessage && m.content[0].text === "Partial analysis"));
    assert.equal((await pi.request({ type: "get_recovery_operation", operationID })).data.receipt.state, "settled");
    const count = pi.provider.requests.length;
    assert.equal((await pi.request({ type: "recover_checkpoint", token: checkpoint.token, operationID })).data.state, "settled");
    assert.equal(pi.provider.requests.length, count);
  });
});

for (const kind of ["partial-call", "failed-tool"]) test(`${kind}: uncertain work refuses instead of redelivering`, { timeout: 60000 }, async t => {
  await withPi(t, { ...options, settings: { ...options.settings, compaction: { enabled: false, keepRecentTokens: 1, reserveTokens: 1024 } },
    onRequest: ({ index }) => index === 0
    ? { tool: { name: "read", arguments: { path: "missing-file" } }, ...(kind === "partial-call" ? { streamError: "connection lost mid-tool-call" } : {}) }
    : index === 1 ? { status: 400, text: "fixture provider failure" } : { text: "FAKE summary: uncertain work is not permission" } }, async pi => {
    await pi.prompt("uncertain operation");
    const before = await entries(pi);
    const state = await recovery(pi);
    assert.equal(state.refusal, "recovery_uncertain_tool");
    const count = pi.provider.requests.length;
    const response = await pi.request({ type: "recover_checkpoint", token: "a".repeat(64), operationID: randomUUID() });
    assert.equal(response.success, false);
    assert.match(response.error, /uncertain_tool/);
    assert.equal(pi.provider.requests.length, count);
    assertRecordedRefusal(await entries(pi), before, "recovery_uncertain_tool");
    assert.equal(pi.events.filter(e => e.type === "tool_execution_start").length, kind === "partial-call" ? 0 : 1);
    if (kind === "failed-tool") {
      const compacted = await pi.request({ type: "compact" });
      assert.equal(compacted.success, true, JSON.stringify(compacted));
      assert.equal((await recovery(pi)).refusal, "recovery_uncertain_tool", "a summary cannot erase uncertainty");
      assert.deepEqual(users(await entries(pi)), users(before));
      assert.equal(pi.events.filter(e => e.type === "tool_execution_start").length, 1);
    }
  });
});

test("accepted Project-style child assignment and question proof remain one completed tool checkpoint", { timeout: 60000 }, async t => {
  await withPi(t, { ...options,
    args: [...options.args, "-e", "./accepted-assignment.ts"],
    project: (_dir, work) => fs.writeFileSync(path.join(work, "accepted-assignment.ts"), `
      import { appendFileSync } from "node:fs";
      export default pi => pi.registerTool({name: "project_assign", label: "Fixture assignment", description: "FAKE accepted assignment, no child is started",
        parameters: {type: "object", properties: {}, additionalProperties: false},
        execute: async () => {
          appendFileSync("accepted.txt", "accepted\\n");
          pi.appendEntry("fixture.accepted-child", { operationID: "child-operation-1", worker: "fake-child-1" });
          return {content: [{type: "text", text: "Accepted fake-child-1, operation child-operation-1"}],
            details: {operationID: "child-operation-1", accepted: true, questionID: "q-fixture", humanSubmitted: "proof-fixture", replyID: "reply-fixture"}};
        }});
    `),
    onRequest: ({ index }) => index === 0 ? { tool: { name: "project_assign", arguments: {} } }
      : index === 1 ? { status: 400, text: "provider failed after the assignment was accepted" } : {},
  }, async pi => {
    await pi.prompt("accept this fixture assignment");
    const before = await entries(pi);
    const proof = before.find(e => e.message?.role === "toolResult").message.details;
    const child = before.find(e => e.customType === "fixture.accepted-child");
    assert(child);
    await recover(pi, (await recovery(pi)).checkpoint);
    assert.equal(fs.readFileSync(path.join(pi.work, "accepted.txt"), "utf8"), "accepted\n");
    const after = await entries(pi);
    assert.deepEqual(after.find(e => e.customType === "fixture.accepted-child"), child);
    assert.deepEqual(after.find(e => e.message?.role === "toolResult").message.details, proof);
    assert.equal(pi.events.filter(e => e.type === "tool_execution_start").length, 1);
    assert.deepEqual(users(after), users(before));
    assert(JSON.stringify(pi.provider.requests[2].body).includes("child-operation-1"));
  });
});

test("busy, duplicate, reconnect and process death reconcile one exact operation", { timeout: 60000 }, async t => {
  let release;
  const held = new Promise(resolve => { release = resolve; });
  t.after(() => release({}));
  await withPi(t, { ...options, onRequest: ({ index }) => index === 0 ? { status: 400, text: "settled failure" } : held }, async pi => {
    await pi.prompt("original");
    const before = await entries(pi);
    const checkpoint = (await recovery(pi)).checkpoint;
    const operationID = randomUUID();
    const response = await pi.request({ type: "recover_checkpoint", token: checkpoint.token, operationID });
    assert.equal(response.success, true);
    await until("new fake request begins", () => pi.provider.requests.length === 2);
    assert.equal((await recovery(pi)).refusal, "recovery_busy");
    const duplicate = await pi.request({ type: "recover_checkpoint", token: checkpoint.token, operationID });
    assert.equal(duplicate.success, true, "exact replay reads the live receipt");
    assert.equal(duplicate.data.state, "accepted");
    assert.equal((await pi.request({ type: "recover_checkpoint", token: checkpoint.token, operationID: randomUUID() })).success, false);
    assert.equal(pi.provider.requests.length, 2);
    const file = (await pi.request({ type: "get_state" })).data.sessionFile;
    await pi.reopen(file);
    const interrupted = await pi.request({ type: "get_recovery_operation", operationID });
    assert.equal(interrupted.data.receipt.state, "unknown");
    const replay = await pi.request({ type: "recover_checkpoint", token: checkpoint.token, operationID });
    assert.equal(replay.data.state, "unknown");
    assert.equal(pi.provider.requests.length, 2, "reopen and replay cannot resume unattended");
    assert.deepEqual(users(await entries(pi)), users(before));
    assert((await pi.request({ type: "get_messages", history: true })).data.messages.some(m => m.stopReason === "error"));
  });
});

test("Stop does not revive a request; only a fresh explicit continuation of its abort checkpoint can run", { timeout: 60000 }, async t => {
  let release;
  const held = new Promise(resolve => { release = resolve; });
  t.after(() => release({}));
  await withPi(t, { ...options, onRequest: ({ index }) => index === 0 ? { status: 400, text: "original failure" } : held }, async pi => {
    try {
      await pi.prompt("original");
      const before = await entries(pi);
      const checkpoint = (await recovery(pi)).checkpoint;
      const operationID = randomUUID();
      assert.equal((await pi.request({ type: "recover_checkpoint", token: checkpoint.token, operationID })).success, true);
      await until("the fake recovery request", () => pi.provider.requests.length === 2);
      const busyID = randomUUID();
      const busy = await pi.request({ type: "recover_checkpoint", token: checkpoint.token, operationID: busyID });
      assert.equal(busy.success, false);
      assert.match(busy.error, /recovery_busy/);
      assert.equal((await pi.request({ type: "abort" })).success, true);
      await until("the stopped run has a settled abort checkpoint", async () => (await recovery(pi)).checkpoint != null);
      const aborted = (await recovery(pi)).checkpoint;
      assert.notEqual(aborted.failedEntryID, checkpoint.failedEntryID);
      const noRevival = await pi.request({ type: "recover_checkpoint", token: checkpoint.token, operationID: busyID });
      assert.equal(noRevival.data.state, "refused", "a replay of busy remains the original refusal, even after idle");
      assert.equal((await pi.request({ type: "recover_checkpoint", token: checkpoint.token, operationID })).data.state, "settled");
      assert.equal(pi.provider.requests.length, 2);
      release({ text: "FAKE explicitly continued" });
      assert.equal((await recover(pi, aborted)).response.success, true);
      assert.equal(pi.provider.requests.length, 3);
      assert.deepEqual(users(await entries(pi)), users(before));
      const transcript = (await pi.request({ type: "get_messages", history: true })).data.messages;
      assert(transcript.some(m => m.stopReason === "error" && m.errorMessage.includes("original failure")));
      assert(transcript.some(m => m.stopReason === "aborted"));
    } finally { release?.({}); }
  });
});

test("model/thinking/leaf/new-session fences invalidate a captured checkpoint", { timeout: 60000 }, async t => {
  await withPi(t, { ...options, reasoning: true, onRequest: () => ({ status: 400, text: "failure" }) }, async pi => {
    await pi.prompt("original");
    const state = (await pi.request({ type: "get_state" })).data;
    const checkpoint = state.checkpointRecovery.checkpoint;
    const changed = await pi.request({ type: "set_thinking_level", level: "high" });
    assert.equal(changed.success, true);
    assert.equal((await recovery(pi)).refusal, "recovery_context_changed");
    assert.equal((await pi.request({ type: "set_thinking_level", level: state.thinkingLevel })).success, true);
    const afterThinking = (await recovery(pi)).checkpoint;
    assert.notEqual(afterThinking.token, checkpoint.token);
    assert.equal((await pi.request({ type: "recover_checkpoint", token: checkpoint.token, operationID: randomUUID() })).success, false);
    const fresh = await pi.reopen(state.sessionFile);
    assert.equal(fresh.data.checkpointRecovery.refusal, "recovery_context_changed",
      "a replacement tool runtime cannot prove the old executable closures' authority");
    assert.equal((await pi.request({ type: "recover_checkpoint", token: afterThinking.token, operationID: randomUUID() })).success, false);
    assert.equal(pi.provider.requests.length, 1, "restart and stale recovery issue no request");
    await pi.prompt("fresh explicit failure in the replacement runtime");
    const freshCheckpoint = (await recovery(pi)).checkpoint;
    assert(freshCheckpoint);
    assert.equal((await recover(pi, freshCheckpoint)).response.success, true, "the new runtime admits its own fresh failure");
    assert.equal((await pi.request({ type: "new_session" })).success, true);
    const refused = await pi.request({ type: "recover_checkpoint", token: freshCheckpoint.token, operationID: randomUUID() });
    assert.equal(refused.success, false);
    assert.equal(pi.provider.requests.length, 3);
    assert.equal(users(await entries(pi)).length, 0);
  });
});
