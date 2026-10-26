// Real staged modular and bundled SDKs, reopened sessions and a local FAKE provider. No network/spend.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";
import { until } from "./fixtures/pi-rpc-harness.mjs";
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the verified patched SDK");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "pi-restart-sdk-"));
for (const key of Object.keys(process.env)) if (!["PATH", "TMPDIR", "NODE_TEST_CONTEXT"].includes(key)) delete process.env[key];
Object.assign(process.env, { HOME: root, PI_CODING_AGENT_DIR: path.join(root, "home"), PI_OFFLINE: "1", PI_TELEMETRY: "0", PI_SKIP_VERSION_CHECK: "1" });
const { createAssistantMessageEventStream } = await import(pathToFileURL(path.join(pkg, "node_modules/@earendil-works/pi-ai/dist/utils/event-stream.js")));
const zero = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
for (const entry of ["dist/index.js", "dist/bundle/index.js"]) test(`${entry}: restart continues saved work without new input or replaying completed tools`, { timeout: 30000 }, async t => {
  const sdk = await import(pathToFileURL(path.join(pkg, entry)));
  const dir = fs.mkdtempSync(path.join(root, "session-"));
  const model = { id: "restart", name: "FAKE restart", provider: "restart-fixture", api: "openai-completions",
    baseUrl: "http://127.0.0.1:1/unused", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 4096, cost: zero.cost };
  const requests = [];
  let executions = 0;
  const stream = (_model, context) => {
    const index = requests.length;
    requests.push(structuredClone(context));
    const events = createAssistantMessageEventStream();
    const message = { role: "assistant", content: index === 0 ? [{ type: "toolCall", id: "completed-call", name: "effect", arguments: {} }]
      : [{ type: "text", text: index === 1 ? "partial progress" : "finished" }], api: model.api,
      provider: model.provider, model: model.id, timestamp: 100 + index, usage: zero,
      stopReason: index === 0 ? "toolUse" : index === 1 ? "error" : "stop", ...(index === 1 ? { errorMessage: "FAKE disconnect" } : {}) };
    events.push(index === 1 ? { type: "error", reason: "error", error: message } : { type: "done", reason: message.stopReason, message });
    events.end(); return events;
  };
  const runtime = await sdk.ModelRuntime.create({ modelsPath: null, refreshOnCreate: false, credentials: {
    read: async () => undefined, list: async () => [], modify: async () => assert.fail(), delete: async () => assert.fail(),
  } });
  runtime.registerNativeProvider({ id: model.provider, name: "FAKE", getModels: () => [model], stream, streamSimple: stream,
    auth: { apiKey: { name: "FAKE", resolve: async () => ({ auth: { apiKey: "not-a-credential" } }) } } });
  await runtime.refresh({ providers: [model.provider], allowNetwork: false });
  const settings = sdk.SettingsManager.inMemory({ retry: { enabled: false }, compaction: { enabled: false }, cacheWarming: "off" });
  async function open(manager, toolParameters = { type: "object", properties: {} }) {
    const loader = new sdk.DefaultResourceLoader({ cwd: dir, agentDir: dir, settingsManager: settings,
      noExtensions: true, noSkills: true, noThemes: true, noPromptTemplates: true, noContextFiles: true,
      extensionFactories: [pi => pi.registerTool({ name: "effect", label: "effect", description: "FAKE durable side effect",
        parameters: toolParameters, async execute() {
          executions++; return { content: [{ type: "text", text: "already completed" }], details: undefined };
        } })] });
    await loader.reload();
    const { session } = await sdk.createAgentSession({ cwd: dir, agentDir: dir, sessionManager: manager,
      settingsManager: settings, resourceLoader: loader, modelRuntime: runtime, model, tools: ["effect"] });
    await session.bindExtensions({ mode: "rpc", onError: e => assert.fail(JSON.stringify(e)) });
    t.after(() => session.dispose());
    return session;
  }
  let session = await open(sdk.SessionManager.create(dir, path.join(dir, "sessions")));
  await session.prompt("Finish my authorized task");
  assert.equal(executions, 1);
  const file = session.sessionManager.getSessionFile();
  const sessionID = session.sessionId;
  const before = JSON.parse(JSON.stringify(session.sessionManager.getEntries().filter(e => e.type === "message")));
  const reservation = session.getRestartRecoveryState().checkpoint;
  assert(reservation);
  const reservedID = randomUUID();
  const intentFile = path.join(dir, "host-intent.json");
  fs.writeFileSync(intentFile, JSON.stringify({ operationID: reservedID, ...reservation }));
  session.dispose();
  session = await open(sdk.SessionManager.open(file));
  assert.equal(session.getRecoveryState().refusal, "recovery_context_changed", "manual Continue's executable identity seal remains strict across runtime replacement");
  const state = session.getRestartRecoveryState();
  assert(state.checkpoint, JSON.stringify(state));
  const intent = JSON.parse(fs.readFileSync(intentFile, "utf8"));
  assert.equal(session.getRecoveryOperation(intent.operationID), undefined, "crash occurred before engine acceptance");
  assert.equal(state.checkpoint.fence, intent.fence, "actual branch and declarative authority survive reopening");
  assert.notEqual(state.checkpoint.token, intent.token, "executable authority is reacquired in the new runtime, not weakened");
  const id = intent.operationID;
  assert.equal(session.resumeSession(state.checkpoint.token, id).state, "accepted");
  await until("message-free restarted turn", () => session.getRecoveryOperation(id)?.state === "settled");
  assert.equal(session.sessionId, sessionID);
  assert.equal(executions, 1, "completed tool effects are not redelivered");
  assert.equal(requests.length, 3);
  assert.deepEqual(session.sessionManager.getEntries().filter(e => e.type === "message").slice(0, before.length), before,
    "original history and failed assistant attempt remain inspectable");
  assert.equal(session.sessionManager.getEntries().filter(e => e.type === "message" && e.message.role === "user").length, 1);
  assert.equal(session.sessionManager.getEntries().filter(e => e.type === "custom_message").length, 0);
  assert.equal(requests[2].messages.filter(m => m.role === "user").length, 1);
  assert(!JSON.stringify(requests[2]).includes("Shepherd restarted"));
  assert.equal(session.resumeSession(state.checkpoint.token, id).state, "settled");
  assert.equal(requests.length, 3, "operation receipt is idempotent");
  assert.equal(session.getRestartRecoveryState().refusal, "recovery_completed");

  // Hard crash before any assistant result: resume from the existing user, not a new prompt.
  const manager = sdk.SessionManager.create(dir, path.join(dir, "new-sessions"));
  manager.appendMessage({ role: "user", content: "Continue this actual input", timestamp: 900 });
  let fresh = await open(manager);
  const next = fresh.getRestartRecoveryState();
  assert(next.checkpoint);
  const nextID = randomUUID();
  fresh.resumeSession(next.checkpoint.token, nextID);
  await until("saved user continuation", () => fresh.getRecoveryOperation(nextID)?.state === "settled");
  assert.equal(manager.getEntries().filter(e => e.type === "message" && e.message.role === "user").length, 1);

  const uncertain = sdk.SessionManager.create(dir, path.join(dir, "uncertain"));
  uncertain.appendMessage({ role: "user", content: "perform a change", timestamp: 1000 });
  const call = { role: "assistant", content: [{ type: "toolCall", id: "unknown", name: "effect", arguments: {} }],
    api: model.api, provider: model.provider, model: model.id, timestamp: 1001, usage: zero, stopReason: "toolUse" };
  uncertain.appendMessage(call);
  const unsafe = await open(uncertain);
  assert.equal(unsafe.getRestartRecoveryState().refusal, "recovery_uncertain_tool");
  uncertain.appendMessage({ role: "user", content: "Fresh input does not settle a missing tool result", timestamp: 1001.5 });
  assert.equal(unsafe.getRestartRecoveryState().refusal, "recovery_uncertain_tool");
  uncertain.appendMessage({ role: "toolResult", toolCallId: "unknown", toolName: "effect", content: [{ type: "text", text: "failed after possible effect" }], isError: true, timestamp: 1002 });
  assert.equal(unsafe.getRestartRecoveryState().refusal, "recovery_uncertain_tool");
  uncertain.appendMessage({ ...call, content: [{ type: "toolCall", id: "handled", name: "effect", arguments: {} }], timestamp: 1003 });
  assert.equal(unsafe.getRestartRecoveryState().refusal, "recovery_uncertain_tool", "a later decision does not excuse an unresolved call");
  uncertain.appendMessage({ role: "toolResult", toolCallId: "handled", toolName: "effect", content: [{ type: "text", text: "completed" }], isError: false, timestamp: 1004 });
  assert(unsafe.getRestartRecoveryState().checkpoint, "an earlier tool error already handled by a later model decision must not block restart");
  assert.equal(executions, 1);

  // An accepted operation persisted before a crash must never be implicitly replayed.
  const unknown = sdk.SessionManager.create(dir, path.join(dir, "unknown"));
  unknown.appendMessage({ role: "user", content: "unfinished", timestamp: 2000 });
  const unknownID = randomUUID();
  unknown.appendCustomEntry("shepherd.checkpoint-recovery.v1", { operationID: unknownID, token: "a".repeat(64),
    sessionID: unknown.getSessionId(), kind: "restart", state: "accepted", failedEntryID: unknown.getLeafId() });
  const blocked = await open(sdk.SessionManager.open(unknown.getSessionFile()));
  assert.equal(blocked.getRecoveryOperation(unknownID)?.state, "unknown");
  assert.equal(blocked.getRestartRecoveryState().refusal, "recovery_unknown");
  blocked.sessionManager.appendMessage({ role: "user", content: "New explicit work after checking the interrupted operation", timestamp: 2001 });
  blocked.dispose();
  const authorized = await open(sdk.SessionManager.open(unknown.getSessionFile()));
  const authorizedCheckpoint = authorized.getRestartRecoveryState().checkpoint;
  assert(authorizedCheckpoint, "an old unknown receipt must not poison work explicitly authorized afterward");
  assert.equal(authorized.getRecoveryOperation(unknownID)?.state, "unknown");
  assert.throws(() => authorized.resumeSession(authorizedCheckpoint.token, unknownID), /recovery_operation_conflict/,
    "new input never authorizes replaying the old operation");
  assert.equal(requests.length, 4);
  const authorizedID = randomUUID();
  authorized.resumeSession(authorizedCheckpoint.token, authorizedID);
  await until("fresh authorized work", () => authorized.getRecoveryOperation(authorizedID)?.state === "settled");
  assert.equal(requests.length, 5);
  assert.equal(requests.at(-1).messages.filter(m => m.role === "user").at(-1).content,
    "New explicit work after checking the interrupted operation");

  // Durable authority is not merely a leaf id or permission to accept any new runtime token.
  const changed = sdk.SessionManager.create(dir, path.join(dir, "changed"));
  changed.appendMessage({ role: "user", content: "original request", timestamp: 3000 });
  let changing = await open(changed);
  const reserved = changing.getRestartRecoveryState().checkpoint;
  assert(reserved);
  const changedFile = changed.getSessionFile();
  changing.dispose();
  const changedLines = fs.readFileSync(changedFile, "utf8").trim().split("\n").map(JSON.parse);
  changedLines.find(e => e.type === "message" && e.message.role === "user").message.content = "changed durable branch context";
  fs.writeFileSync(changedFile, changedLines.map(e => JSON.stringify(e)).join("\n") + "\n");
  const changedManager = sdk.SessionManager.open(changedFile);
  assert.equal(changedManager.getLeafId(), reserved.leafID, "test preserves the leaf identity while changing branch contents");
  changing = await open(changedManager);
  const replacement = changing.getRestartRecoveryState().checkpoint;
  assert(replacement);
  assert.notEqual(replacement.fence, reserved.fence, "changed branch contents cannot inherit saved host authorization even with the same leaf");
  assert.throws(() => changing.resumeSession(reserved.token, randomUUID()), /recovery_stale/);
  const schemaManager = sdk.SessionManager.create(dir, path.join(dir, "schema"));
  schemaManager.appendMessage({ role: "user", content: "authorized under original tools", timestamp: 4000 });
  let schemas = await open(schemaManager);
  const originalSchema = schemas.getRestartRecoveryState().checkpoint;
  const schemaFile = schemaManager.getSessionFile();
  schemas.dispose();
  schemas = await open(sdk.SessionManager.open(schemaFile), { type: "object", properties: { extraAuthority: { type: "string" } } });
  const changedSchema = schemas.getRestartRecoveryState().checkpoint;
  assert.equal(changedSchema.leafID, originalSchema.leafID);
  assert.notEqual(changedSchema.fence, originalSchema.fence, "declarative tool authority is also part of the durable fence");
  assert.equal(requests.length, 5);
});
