import assert from "node:assert/strict";
import { test } from "node:test";
import net from "node:net";
import { once } from "node:events";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import shepherdNative from "../../Extensions/shepherd-native.ts";

const fixtures = JSON.parse(await readFile(new URL("native-thread-wire.json", import.meta.url)));

test("native same-process bridge snapshots, actions, dialogs and reconnect", { timeout: 15000 }, async () => {
  const dir = await mkdtemp("/tmp/sh-native-");
  const path = `${dir}/s`;
  const oldEnv = [process.env.SHEPHERD_AGENT_ID, process.env.SHEPHERD_SOCKET];
  delete process.env.SHEPHERD_AGENT_ID;
  shepherdNative({ on() { assert.fail("must be inert without env"); } });
  process.env.SHEPHERD_AGENT_ID = "agent";
  process.env.SHEPHERD_SOCKET = path;
  const handlers = new Map();
  const sent = [];
  let aborted = 0, sessionID = "session", idle = true;
  let branch = Array.from({ length: 65 }, (_, i) => ({ type: "message", id: `e${i}`, message: { role: "user", content: [{ type: "text", text: `line${i}` }] } }));
  const ctx = { ui: {}, sessionManager: { getSessionId: () => sessionID, getBranch: () => branch, getLeafId: () => branch.at(-1)?.id ?? null }, isIdle: () => idle, abort: () => aborted++, model: { provider: "p", id: "m" } };
  const pi = { on: (name, fn) => handlers.set(name, fn), sendUserMessage: (...args) => { sent.push(args); }, getThinkingLevel: () => "high" };
  const server = net.createServer();
  server.listen(path);
  await once(server, "listening");
  let peer, lines = [], readers = [];
  server.on("connection", (s) => {
    peer = s;
    let buffer = "";
    s.on("error", () => {});
    s.on("data", (chunk) => {
      buffer += chunk;
      let index;
      while ((index = buffer.indexOf("\n")) >= 0) {
        const frame = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
        if (readers.length) readers.shift()(frame); else lines.push(frame);
      }
    });
  });
  const next = () => lines.length ? Promise.resolve(lines.shift()) : new Promise((resolve) => readers.push(resolve));
  let id = 0;
  async function request(command) {
    peer.write(JSON.stringify({ type: "nativeThreadCommand", id: ++id, request: command }) + "\n");
    const frame = await next();
    assert.equal(frame.type, "nativeThreadResult"); assert.equal(frame.id, id);
    return frame.result;
  }
  const emit = (name, event = {}) => handlers.get(name)?.(event, ctx);
  try {
    shepherdNative(pi); emit("session_start");
    assert.deepEqual(await next(), fixtures.find((f) => f.type === "helloNativeAgent"));
    let snapshot = (await request(fixtures[0].request)).snapshot.value;
    assert.equal(snapshot.messages.length, 50); assert.equal(snapshot.olderCursor, "e15");
    assert.equal(snapshot.dialogsSupported, false);
    const binding = { expectedSessionID: sessionID, generation: snapshot.generation };
    assert.equal((await request({ snapshot: { afterRevision: snapshot.revision } })).unchanged.revision, snapshot.revision);
    const older = (await request({ snapshot: { beforeEntryID: snapshot.olderCursor } })).snapshot.value;
    assert.equal(older.messages.length, 15); assert.equal(older.olderCursor, undefined);
    assert.equal((await request({ snapshot: { beforeEntryID: "gone", afterRevision: snapshot.revision } })).failure.code, "stale_cursor");
    const send = { send: { ...fixtures[2].request.send, ...binding } };
    assert.deepEqual(await request(send), fixtures[5].result);
    assert.deepEqual(await request(send), fixtures[5].result); assert.equal(sent.length, 1);
    assert.equal((await request({ send: { ...send.send, text: "changed" } })).failure.code, "operation_conflict");
    assert.equal((await request({ send: { ...send.send, operationID: randomUUID(), generation: "stale" } })).failure.code, "stale_session");
    await request({ send: { ...send.send, operationID: randomUUID(), delivery: "steer" } });
    assert.deepEqual(sent[1], ["Continue", { deliverAs: "steer" }]);
    const abort = { abort: { ...binding, operationID: randomUUID() } };
    await request(abort); await request(abort); assert.equal(aborted, 1);
    assert.equal((await request({ answer: { ...binding, operationID: randomUUID(), dialogID: "d", answer: { cancel: {} } } })).failure.code, "dialogs_unsupported");
    assert.equal((await request({ send: { ...send.send, operationID: randomUUID(), text: "x".repeat(16385) } })).failure.code, "invalid");

    idle = false;
    const assistant = { role: "assistant", timestamp: 123, content: [{ type: "thinking", thinking: "plan" }, { type: "text", text: "partial" }] };
    emit("message_start", { message: assistant }); emit("message_update", { message: assistant });
    for (const toolCallId of ["t1", "t2"]) emit("tool_execution_update", { toolCallId, toolName: "bash", args: { command: "ls" }, partialResult: { content: [{ type: "text", text: toolCallId }] } });
    snapshot = (await request({ snapshot: {} })).snapshot.value;
    assert.equal(snapshot.provisional.length, 3); assert.equal(snapshot.running, true);
    emit("message_end", { message: assistant });
    assert.equal((await request({ snapshot: {} })).snapshot.value.provisional.length, 3);
    const rewritten = { ...assistant, timestamp: 456, content: [{ type: "text", text: "authoritative replacement" }] };
    branch.push({ type: "message", id: "persisted", message: rewritten });
    branch.push({ type: "message", id: "tool-done", message: { role: "toolResult", toolCallId: "t1", content: [] } });
    snapshot = (await request({ snapshot: {} })).snapshot.value;
    assert.equal(snapshot.provisional.length, 1); assert.equal(snapshot.provisional[0].toolCallID, "t2");
    assert.equal(snapshot.messages.filter((m) => m.role === "assistant").length, 1);
    assert.equal(snapshot.messages.find((m) => m.entryID === "persisted").blocks[0].text, "authoritative replacement");
    // An old persisted assistant with identical content/timestamp cannot consume a new projection.
    emit("message_start", { message: rewritten }); emit("message_end", { message: rewritten });
    assert.equal((await request({ snapshot: {} })).snapshot.value.provisional.filter((m) => m.role === "assistant").length, 1);
    branch.push({ type: "message", id: "persisted-next", message: { ...rewritten, content: [{ type: "text", text: "second replacement" }] } });
    snapshot = (await request({ snapshot: {} })).snapshot.value;
    assert.equal(snapshot.provisional.filter((m) => m.role === "assistant").length, 0);
    const beforePersistenceRevision = snapshot.revision;
    branch.push({ type: "compaction", id: "summary", summary: "Summary" });
    snapshot = (await request({ snapshot: { afterRevision: beforePersistenceRevision } })).snapshot.value;
    assert.equal(snapshot.messages.at(-1).role, "compaction");

    branch = [{ type: "custom_message", id: "hidden", display: false, content: "secret hidden" }, ...Array.from({ length: 50 }, (_, i) => ({ type: "message", id: `huge${i}`, message: { role: "user", content: [{ type: "text", text: "😀".repeat(20000) }, { type: "image", data: "base64-secret" }] } }))];
    snapshot = (await request({ snapshot: {} })).snapshot.value;
    assert.ok(Buffer.byteLength(JSON.stringify(snapshot)) < 256 * 1024); assert.ok(snapshot.clipped);
    assert.ok(snapshot.messages.length > 0); assert.ok(snapshot.messages[0].truncated);
    assert.ok(!JSON.stringify(snapshot).includes("base64-secret")); assert.ok(!JSON.stringify(snapshot).includes("secret hidden"));
    branch = [{ type: "message", id: "image", message: { role: "user", content: [{ type: "image", data: "base64-secret" }] } }];
    assert.equal((await request({ snapshot: {} })).snapshot.value.messages[0].blocks[0].kind, "unsupportedImage");

    let dialogs = [{ id: "d", kind: "editor", title: "Edit", prefill: "draft", unavailable: "external-editor" }], dialogListener;
    ctx.ui = { getPendingDialogs: () => dialogs, onDialog: (fn) => { dialogListener = fn; return () => { dialogListener = undefined; }; }, resolveDialog: (id, answer) => {
      if (!dialogs.some((d) => d.id === id)) return "stale";
      if (dialogs[0].unavailable) return "unavailable";
      if (answer.kind !== "editor" || typeof answer.value !== "string") return "invalid";
      dialogs = []; dialogListener?.({ type: "closed", id }); return "accepted";
    } };
    emit("session_start"); snapshot = (await request({ snapshot: {} })).snapshot.value;
    assert.equal(snapshot.dialogsSupported, true); assert.equal(snapshot.dialogs[0].unavailable, "external-editor");
    const answer = { expectedSessionID: sessionID, generation: snapshot.generation, operationID: randomUUID(), dialogID: "d", answer: { editor: { value: "" } } };
    assert.equal((await request({ answer })).failure.code, "dialog_unavailable");
    delete dialogs[0].unavailable; dialogListener({ type: "updated", dialog: dialogs[0] });
    const answered = await request({ answer: { ...answer, operationID: randomUUID() } }); assert.ok(answered.accepted);
    assert.equal((await request({ snapshot: {} })).snapshot.value.dialogs.length, 0);
    assert.equal((await request({ answer: { ...answer, operationID: randomUUID() } })).failure.code, "dialog_stale");
    for (const [kind, value] of [["select", "choice"], ["confirm", false], ["input", ""], ["cancel", undefined]]) {
      dialogs = [{ id: "standard", kind: kind === "cancel" ? "input" : kind, title: "Question" }];
      let resolved;
      ctx.ui.resolveDialog = (id, answer) => { assert.equal(id, "standard"); resolved = answer; dialogs = []; return "accepted"; };
      const action = { ...answer, operationID: randomUUID(), dialogID: "standard", answer: { [kind]: kind === "cancel" ? {} : { value } } };
      assert.ok((await request({ answer: action })).accepted);
      assert.deepEqual(resolved, kind === "cancel" ? { kind } : { kind, value });
    }
    let dispatchAttempts = 0;
    pi.sendUserMessage = () => { dispatchAttempts++; throw new Error("expected synchronous failure"); };
    const rejectedSend = { send: { ...send.send, generation: snapshot.generation, operationID: randomUUID() } };
    assert.equal((await request(rejectedSend)).failure.code, "dispatch_failed");
    assert.equal((await request(rejectedSend)).failure.code, "dispatch_failed");
    assert.equal(dispatchAttempts, 1);
    sessionID = "new-session"; emit("session_start", { reason: "new" });
    assert.equal((await request(send)).failure.code, "stale_session");
    assert.equal((await request({ snapshot: { expectedSessionID: "session" } })).failure.code, "stale_session");
    snapshot = (await request({ snapshot: {} })).snapshot.value;
    peer.destroy(); await next();
    assert.equal((await request({ snapshot: {} })).snapshot.value.generation, snapshot.generation);
    peer.write('{"type":"nativeThreadCommand","id":9,"request":{"snapshot":{}}}\r\n');
    await once(peer, "close"); await next();
    peer.write(Buffer.alloc(1024 * 1024 + 1, 65)); await once(peer, "close"); await next();
    // A split LF frame is held until complete, then correlated normally.
    peer.write('{"type":"nativeThreadCommand","id":999,"request":');
    peer.write('{"snapshot":{}}}\n'); assert.equal((await next()).id, 999);
  } finally {
    emit("session_shutdown"); peer?.destroy(); server.close();
    for (const [i, key] of ["SHEPHERD_AGENT_ID", "SHEPHERD_SOCKET"].entries()) {
      if (oldEnv[i] == null) delete process.env[key]; else process.env[key] = oldEnv[i];
    }
    await rm(dir, { recursive: true, force: true });
  }
});
