// Both public SDK entry points, with a native FAKE provider. No HTTP or default resources.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";
import { until } from "./fixtures/pi-rpc-harness.mjs";

const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the verified private patched SDK");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "pi-recovery-sdk-"));
for (const key of Object.keys(process.env)) if (!["PATH", "TMPDIR", "NODE_TEST_CONTEXT"].includes(key)) delete process.env[key];
Object.assign(process.env, { HOME: root, PI_CODING_AGENT_DIR: path.join(root, "home"), PI_OFFLINE: "1", PI_TELEMETRY: "0", PI_SKIP_VERSION_CHECK: "1" });
const { createAssistantMessageEventStream } = await import(pathToFileURL(path.join(pkg, "node_modules/@earendil-works/pi-ai/dist/utils/event-stream.js")));
const zero = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const userEntries = manager => manager.getEntries().filter(e => e.type === "message" && e.message.role === "user");

for (const entry of ["dist/index.js", "dist/bundle/index.js"]) test(`${entry}: tool replacements revoke a failed checkpoint without redelivery`, { timeout: 30000 }, async t => {
  const sdk = await import(pathToFileURL(path.join(pkg, entry)));
  const dir = fs.mkdtempSync(path.join(root, "tools-"));
  const model = { id: "tools", name: "FAKE tools", provider: "tool-fixture", api: "openai-completions",
    baseUrl: "http://127.0.0.1:1/unused", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 4096, cost: zero.cost };
  let requests = 0, executions = 0, replace;
  const stream = () => {
    requests++;
    const events = createAssistantMessageEventStream();
    const message = { role: "assistant", content: [{ type: "text", text: "original partial" }], api: model.api,
      provider: model.provider, model: model.id, timestamp: requests, usage: zero, stopReason: "error", errorMessage: "FAKE disconnect" };
    events.push({ type: "error", reason: "error", error: message }); events.end(); return events;
  };
  const runtime = await sdk.ModelRuntime.create({ modelsPath: null, refreshOnCreate: false, credentials: {
    read: async () => undefined, list: async () => [], modify: async () => assert.fail(), delete: async () => assert.fail(),
  } });
  runtime.registerNativeProvider({ id: model.provider, name: "FAKE", getModels: () => [model], stream, streamSimple: stream,
    auth: { apiKey: { name: "FAKE", resolve: async () => ({ auth: { apiKey: "not-a-credential" } }) } } });
  await runtime.refresh({ providers: [model.provider], allowNetwork: false });
  const settings = sdk.SettingsManager.inMemory({ retry: { enabled: false }, compaction: { enabled: false }, cacheWarming: "off" });
  const loader = new sdk.DefaultResourceLoader({ cwd: dir, agentDir: dir, settingsManager: settings,
    noExtensions: true, noSkills: true, noThemes: true, noPromptTemplates: true, noContextFiles: true,
    extensionFactories: [pi => {
      replace = (schema, exposure = "direct") => pi.registerTool({ name: "x", label: "x", description: "FAKE x", exposure,
        parameters: schema, async execute() { executions++; return { content: [{ type: "text", text: "executed" }], details: undefined }; } });
      replace({ type: "object", properties: {} });
    }] });
  await loader.reload();
  const { session } = await sdk.createAgentSession({ cwd: dir, agentDir: dir, resourceLoader: loader, settingsManager: settings,
    sessionManager: sdk.SessionManager.inMemory(dir), modelRuntime: runtime, model, tools: ["x"] });
  t.after(() => session.dispose());
  await session.bindExtensions({ mode: "rpc", onError: e => assert.fail(JSON.stringify(e)) });
  for (const [schema, exposure] of [
    [{ type: "object", properties: { changed: { type: "string" } } }, "direct"],
    [{ type: "object", properties: { changed: { type: "string" } } }, "direct"],
    [{ type: "object", properties: { changed: { type: "string" } } }, "deferred"],
  ]) {
    await session.prompt("FAKE failed request");
    const checkpoint = session.getRecoveryState().checkpoint;
    assert(checkpoint, JSON.stringify(session.getRecoveryState()));
    assert.deepEqual(session.getRecoveryState().checkpoint, checkpoint, "unchanged definitions retain their checkpoint");
    const before = requests;
    const history = structuredClone(userEntries(session.sessionManager));
    replace(schema, exposure);
    assert.deepEqual(session.getToolDefinition("x").parameters, schema, "the replacement reached the SDK registry");
    assert.equal(session.getRecoveryState().refusal, "recovery_context_changed");
    assert.throws(() => session.recoverCheckpoint(checkpoint.token, randomUUID()), /recovery_context_changed/);
    assert.equal(requests, before, "a stale definition must not issue a provider request");
    assert.equal(executions, 0);
    assert.deepEqual(userEntries(session.sessionManager), history);
  }
});

for (const entry of ["dist/index.js", "dist/bundle/index.js"]) test(`${entry}: direct SDK recovery survives compaction and reopen without changing users or failures`, { timeout: 30000 }, async t => {
  const sdk = await import(pathToFileURL(path.join(pkg, entry)));
  const dir = path.join(root, entry.includes("bundle") ? "bundle" : "modular");
  fs.mkdirSync(dir, { recursive: true });
  const model = { id: "checkpoint", name: "FAKE checkpoint", provider: "recovery-fixture", api: "openai-completions",
    baseUrl: "http://127.0.0.1:1/unused", reasoning: false, input: ["text", "image"], contextWindow: 64000, maxTokens: 4096, cost: zero.cost };
  const requests = [];
  let failNext = false, forcePrompt = false;
  const stream = (_model, context) => {
    const index = requests.length;
    requests.push(structuredClone(context));
    const events = createAssistantMessageEventStream();
    const failed = index === 1 || failNext;
    failNext = false;
    const message = { role: "assistant", content: [{ type: "text", text: failed ? "partial checkpoint" : index === 2 || index === 3 ? "FAKE compaction summary" : "finished" }],
      api: model.api, provider: model.provider, model: model.id, timestamp: 100 + index, usage: zero,
      stopReason: failed ? "error" : "stop", ...(failed ? { errorMessage: "FAKE stream disconnected" } : {}) };
    events.push(failed ? { type: "error", reason: "error", error: message } : { type: "done", reason: "stop", message });
    events.end(); return events;
  };
  const runtime = await sdk.ModelRuntime.create({ modelsPath: null, refreshOnCreate: false, credentials: {
    read: async () => undefined, list: async () => [], modify: async () => assert.fail("no credential writes"), delete: async () => assert.fail(),
  } });
  runtime.registerNativeProvider({ id: model.provider, name: "FAKE", getModels: () => [model], stream, streamSimple: stream,
    auth: { apiKey: { name: "FAKE", resolve: async () => ({ auth: { apiKey: "not-a-credential" } }) } } });
  await runtime.refresh({ providers: [model.provider], allowNetwork: false });
  const settings = sdk.SettingsManager.inMemory({ defaultProvider: model.provider, defaultModel: model.id,
    cacheWarming: "off", retry: { enabled: false }, compaction: { enabled: false, reserveTokens: 1024, keepRecentTokens: 1 } });
  const loader = new sdk.DefaultResourceLoader({ cwd: dir, agentDir: dir, settingsManager: settings,
    noExtensions: true, noSkills: true, noThemes: true, noPromptTemplates: true, noContextFiles: true,
    extensionFactories: [pi => pi.on("before_agent_start", () => forcePrompt ? { systemPrompt: "FAKE ephemeral override" } : undefined)] });
  await loader.reload();
  const sessions = path.join(dir, "sessions");
  let manager = sdk.SessionManager.create(dir, sessions);
  const make = async (sessionManager = manager, cwd = dir) => {
    const { session } = await sdk.createAgentSession({ cwd, agentDir: dir, settingsManager: settings,
      sessionManager, resourceLoader: loader, modelRuntime: runtime, model, noTools: "all" });
    await session.bindExtensions({ mode: "rpc", onError: e => assert.fail(JSON.stringify(e)) });
    return session;
  };
  let session = await make();
  t.after(() => session.dispose());
  await session.prompt("prior context");
  await session.prompt("original failed request", { images: [{ type: "image", data: "AA==", mimeType: "image/png" }] });
  const originalUsers = structuredClone(userEntries(manager));
  const failure = structuredClone(manager.getEntries().find(e => e.message?.stopReason === "error"));
  const beforeNavigation = session.getRecoveryState().checkpoint;
  const failedLeaf = manager.getLeafId();
  const earlier = manager.getBranch().find(e => e.message?.role === "assistant" && e.message.stopReason === "stop");
  await session.navigateTree(earlier.id);
  await session.navigateTree(failedLeaf);
  assert.throws(() => session.recoverCheckpoint(beforeNavigation.token, randomUUID()), /recovery_stale/,
    "restoring a previous leaf cannot revive a previous generation grant");
  const stale = session.getRecoveryState().checkpoint;
  assert(stale, JSON.stringify(session.getRecoveryState()));
  const oldFile = path.join(dir, "old-failure.jsonl");
  const legacyLines = fs.readFileSync(manager.getSessionFile(), "utf8").trimEnd().split("\n");
  const failureLine = legacyLines.findIndex(line => JSON.parse(line).id === failure.id);
  assert(failureLine > 0);
  fs.writeFileSync(oldFile, legacyLines.slice(0, failureLine + 1).join("\n") + "\n");
  const oldSession = await make(sdk.SessionManager.open(oldFile, sessions));
  try {
    assert.equal(oldSession.getRecoveryState().refusal, "recovery_checkpoint_unavailable");
    assert.throws(() => oldSession.recoverCheckpoint(stale.token, randomUUID()), /recovery_checkpoint_unavailable/);
    assert.deepEqual(oldSession.sessionManager.getEntry(failure.id), failure);
  } finally { oldSession.dispose(); }
  const movedCwd = path.join(dir, "different-working-directory"); fs.mkdirSync(movedCwd);
  const moved = await make(sdk.SessionManager.open(manager.getSessionFile(), sessions), movedCwd);
  try {
    assert.equal(moved.getRecoveryState().refusal, "recovery_context_changed");
    assert.throws(() => moved.recoverCheckpoint(stale.token, randomUUID()), /recovery_context_changed/);
  } finally { moved.dispose(); }
  await session.setModel({ ...model, baseUrl: "http://127.0.0.1:2/changed" });
  assert.equal(session.getRecoveryState().refusal, "recovery_context_changed");
  assert.throws(() => session.recoverCheckpoint(stale.token, randomUUID()), /recovery_context_changed/);
  await session.setModel(model);
  assert.equal(requests.length, 2);
  const compacted = await session.compact("FAKE summary only");
  assert(compacted.summary.includes("FAKE compaction summary"));
  assert(compacted.summary.includes("Turn Context (split turn)"));
  assert.equal(requests.length, 4, "compaction summarizes history and the split-turn prefix separately");
  assert.equal(manager.getEntries().filter(e => e.type === "compaction").length, 1);
  assert.deepEqual(userEntries(manager), originalUsers);
  assert.deepEqual(manager.getEntry(failure.id), failure);
  const file = manager.getSessionFile();
  const beforeDispose = fs.readFileSync(file, "utf8");
  session.dispose();
  assert.throws(() => session.recoverCheckpoint(stale.token, randomUUID()), /recovery_stale/);
  assert.equal(fs.readFileSync(file, "utf8"), beforeDispose, "a stale SDK object cannot append to a switched thread");
  manager = sdk.SessionManager.open(file, sessions);
  session = await make();
  assert.throws(() => session.recoverCheckpoint(stale.token, randomUUID()), /recovery_stale/);
  const checkpoint = session.getRecoveryState().checkpoint;
  assert(checkpoint, JSON.stringify(session.getRecoveryState()));
  const operationID = randomUUID();
  const settled = new Promise(resolve => { const off = session.subscribe(e => { if (e.type === "agent_settled") { off(); resolve(); } }); });
  const receipt = session.recoverCheckpoint(checkpoint.token, operationID);
  assert.equal(receipt.state, "accepted");
  assert.equal(receipt.failedEntryID, failure.id);
  assert.equal(typeof receipt.leafID, "string");
  assert.equal(typeof receipt.generation, "string");
  console.log(JSON.stringify({ sdk: entry, sessionFile: file, sessionID: receipt.sessionID, failedEntryID: receipt.failedEntryID,
    leafID: receipt.leafID, generation: receipt.generation, operationID: receipt.operationID }));
  await settled;
  await until("the operation's durable terminal receipt", () => session.getRecoveryOperation(operationID)?.state === "settled");
  assert.equal(session.getRecoveryOperation(operationID).state, "settled");
  assert.equal(session.recoverCheckpoint(checkpoint.token, operationID.toUpperCase()).state, "settled");
  assert.equal(requests.length, 5, "two turns, two explicit summaries, one manual recovery");
  assert.deepEqual(userEntries(manager), originalUsers);
  assert.deepEqual(manager.getEntry(failure.id), failure);
  assert(session.getRecoveryTranscript().some(m => m.errorMessage === "FAKE stream disconnected"));
  assert(session.getRecoveryTranscript().some(m => m.content?.some?.(p => p.text === "partial checkpoint")));
  assert(!requests[4].messages.some(m => m.stopReason === "error"), "only provider context omits the error");
  session.dispose();
  manager = sdk.SessionManager.open(file, sessions);
  session = await make();
  assert.equal(session.getRecoveryOperation(operationID).state, "settled");
  assert.deepEqual(userEntries(manager), originalUsers);
  assert.deepEqual(manager.getEntry(failure.id), failure);
  const fork = await make(sdk.SessionManager.forkFrom(file, dir, sessions));
  try {
    assert.notEqual(fork.sessionId, receipt.sessionID);
    assert.equal(fork.getRecoveryOperation(operationID), undefined, "a fork cannot claim the original session\'s receipt");
    assert.throws(() => fork.recoverCheckpoint(stale.token, operationID), /recovery_(not_failed|context_unavailable|stale)/);
    assert.equal(requests.length, 5);
  } finally { fork.dispose(); }
  forcePrompt = true; failNext = true;
  await session.prompt("FAKE turn with an unpersisted forced prompt");
  assert.equal(session.getRecoveryState().refusal, "recovery_context_changed");
  assert.throws(() => session.recoverCheckpoint(stale.token, randomUUID()), /recovery_context_changed/);
  assert.equal(requests.length, 6, "a forced-prompt refusal cannot silently change context or issue another request");

  forcePrompt = false; failNext = true;
  await session.prompt("FAKE independent turn before an uncertain recovery delivery");
  const uncertainCheckpoint = session.getRecoveryState().checkpoint;
  assert(uncertainCheckpoint);
  const beforeUncertainUsers = userEntries(manager);
  const uncertainID = randomUUID();
  failNext = true;
  session.recoverCheckpoint(uncertainCheckpoint.token, uncertainID);
  session.setThinkingLevel(session.thinkingLevel);
  await until("a settled provider request with an unconfirmed operation receipt", () =>
    session.isIdle && session.getRecoveryOperation(uncertainID)?.state === "unknown");
  const requestsAfterUncertain = requests.length;
  assert.throws(() => session.recoverCheckpoint(uncertainCheckpoint.token, randomUUID()), /recovery_unknown/);
  assert.equal(session.getRecoveryState().refusal, "recovery_unknown");
  assert.equal(session.recoverCheckpoint(uncertainCheckpoint.token, uncertainID).state, "unknown");
  assert.equal(requests.length, requestsAfterUncertain);
  assert.deepEqual(userEntries(manager), beforeUncertainUsers);
  session.dispose();
  manager = sdk.SessionManager.open(file, sessions);
  session = await make();
  assert.equal(session.getRecoveryOperation(uncertainID).state, "unknown");
  assert.equal(session.getRecoveryState().refusal, "recovery_unknown");
  assert.deepEqual(userEntries(manager), beforeUncertainUsers);
});
