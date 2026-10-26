// Private FAKE native providers exercise both shipped SDKs without credentials or network.
import test, { after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";
import { until } from "./fixtures/pi-rpc-harness.mjs";
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the verified patched engine");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "pi-resilient-"));
after(() => fs.rmSync(root, { recursive: true, force: true }));
for (const key of Object.keys(process.env)) if (!["PATH", "TMPDIR", "NODE_TEST_CONTEXT"].includes(key)) delete process.env[key];
Object.assign(process.env, { HOME: root, PI_CODING_AGENT_DIR: path.join(root, "home"), PI_OFFLINE: "1", PI_TELEMETRY: "0", PI_SKIP_VERSION_CHECK: "1" });
const { createAssistantMessageEventStream } = await import(pathToFileURL(path.join(pkg, "node_modules/@earendil-works/pi-ai/dist/utils/event-stream.js")));
const zero = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
async function fixture(t, entry, { answer = () => ({}), guidelines = false, retry = { enabled: true, baseDelayMs: 1 } } = {}) {
  const sdk = await import(pathToFileURL(path.join(pkg, entry)));
  const dir = fs.mkdtempSync(path.join(root, "case-"));
  const model = { id: "fake", name: "FAKE", provider: "resilient-fixture", api: "openai-completions", baseUrl: "http://127.0.0.1:1/unused",
    reasoning: true, input: ["text"], contextWindow: 64000, maxTokens: 4096, cost: zero.cost };
  const requests = [], events = [];
  let executions = 0, customPrompt;
  const stream = (_model, context) => {
    const index = requests.length;
    requests.push(structuredClone(context));
    const message = { role: "assistant", content: [{ type: "text", text: "finished" }], api: model.api, provider: model.provider,
      model: model.id, timestamp: index + 1, usage: zero, stopReason: "stop", ...answer(index) };
    const stream = createAssistantMessageEventStream();
    stream.push(message.stopReason === "error" ? { type: "error", reason: "error", error: message } : { type: "done", reason: message.stopReason, message });
    stream.end(); return stream;
  };
  const runtime = await sdk.ModelRuntime.create({ modelsPath: null, refreshOnCreate: false, credentials: {
    read: async () => undefined, list: async () => [], modify: async () => assert.fail(), delete: async () => assert.fail(),
  } });
  runtime.registerNativeProvider({ id: model.provider, name: "FAKE", getModels: () => [model], stream, streamSimple: stream,
    auth: { apiKey: { name: "FAKE", resolve: async () => ({ auth: { apiKey: "fake" } }) } } });
  await runtime.refresh({ providers: [model.provider], allowNetwork: false });
  const settings = sdk.SettingsManager.inMemory({ retry, compaction: { enabled: false }, cacheWarming: "off" });
  const loader = new sdk.DefaultResourceLoader({ cwd: dir, agentDir: dir, settingsManager: settings, noExtensions: true,
    noSkills: true, noThemes: true, noPromptTemplates: true, noContextFiles: true, systemPromptOverride: () => customPrompt,
    extensionFactories: guidelines ? [pi => pi.on("before_agent_start", event => { event.systemPromptOptions.promptGuidelines.push("FAKE unchanged guideline"); })] : [] });
  await loader.reload();
  const { session } = await sdk.createAgentSession({ cwd: dir, agentDir: dir, resourceLoader: loader, settingsManager: settings,
    sessionManager: sdk.SessionManager.inMemory(dir), modelRuntime: runtime, model, tools: ["once"],
    customTools: [{ name: "once", label: "once", description: "FAKE counter", parameters: { type: "object", properties: {} },
      async execute() { executions++; return { content: [{ type: "text", text: "completed once" }], details: undefined }; } }] });
  t.after(() => session.dispose());
  await session.bindExtensions({ mode: "rpc", onError: error => assert.fail(JSON.stringify(error)) });
  session.subscribe(event => events.push(event));
  return { session, requests, events, get executions() { return executions; },
    async changePrompt() { customPrompt = "FAKE changed configured prompt"; await session.reload(); } };
}
for (const entry of ["dist/index.js", "dist/bundle/index.js"]) {
  test(`${entry}: unchanged before_agent_start guidelines keep an exact recoverable checkpoint`, async t => {
    const f = await fixture(t, entry, { guidelines: true, retry: { enabled: false }, answer: i => i === 0 ? { stopReason: "error", errorMessage: "FAKE disconnect" } : {} });
    await f.session.prompt("original request");
    assert(f.requests[0].messages.some(m => JSON.stringify(m).includes("FAKE unchanged guideline")));
    const checkpoint = f.session.getRecoveryState().checkpoint;
    assert(checkpoint, JSON.stringify(f.session.getRecoveryState()));
    f.session.recoverCheckpoint(checkpoint.token, randomUUID());
    await until("recovery settles", () => f.requests.length === 2 && f.session.isIdle);
    assert.deepEqual(f.requests[1].messages, f.requests[0].messages, "recovery must retain the exact effective guideline context, not append a removing patch");
    assert.equal(f.requests[1].messages.filter(m => m.role === "user").length, 1);
  });
  test(`${entry}: changed configured prompt revokes a guideline checkpoint`, async t => {
    const f = await fixture(t, entry, { guidelines: true, retry: { enabled: false }, answer: () => ({ stopReason: "error", errorMessage: "FAKE disconnect" }) });
    await f.session.prompt("original request");
    const checkpoint = f.session.getRecoveryState().checkpoint;
    assert(checkpoint);
    await f.changePrompt();
    assert.equal(f.session.getRecoveryState().refusal, "recovery_context_changed");
    assert.throws(() => f.session.recoverCheckpoint(checkpoint.token, randomUUID()), /recovery_context_changed/);
    assert.equal(f.requests.length, 1);
  });
  for (const guidelines of [false, true]) for (const stopReason of ["stop", "length"]) for (const empty of [[], [{ type: "thinking", thinking: "private reasoning" }], [{ type: "text", text: "  " }]]) {
    test(`${entry}: ${stopReason} empty ${JSON.stringify(empty)} then success, extensions=${guidelines}`, async t => {
      const f = await fixture(t, entry, { guidelines, answer: i => i === 0 ? { content: empty, stopReason } : {} });
      await f.session.prompt("original request");
      assert.equal(f.requests.length, 2);
      assert.equal(f.events.filter(e => e.type === "auto_retry_start").length, 1);
      assert.equal(f.requests[1].messages.filter(m => m.role === "user").length, 1);
      assert(!f.requests[1].messages.some(m => m.stopReason === "error"));
    });
  }
  test(`${entry}: permanent empty uses the default three-retry bound`, async t => {
    const f = await fixture(t, entry, { answer: () => ({ content: [] }) });
    await f.session.prompt("original request");
    assert.equal(f.requests.length, 4);
    assert.deepEqual(f.events.filter(e => e.type === "auto_retry_start").map(e => e.attempt), [1, 2, 3]);
    assert.equal(f.events.findLast(e => e.type === "auto_retry_end").success, false);
    assert(f.session.getRecoveryState().checkpoint);
  });
  test(`${entry}: Stop during empty-response backoff never issues another request`, async t => {
    const f = await fixture(t, entry, { answer: () => ({ content: [] }), retry: { enabled: true, baseDelayMs: 60000 } });
    const run = f.session.prompt("original request");
    await until("retry backoff", () => f.session.isRetrying);
    await f.session.abort(); await run;
    assert.equal(f.requests.length, 1);
    assert.equal(f.events.findLast(e => e.type === "auto_retry_end").success, false);
  });
  for (const errorMessage of ["401 authentication failed", "403 permission denied", "insufficient_quota", "context length exceeded"]) test(`${entry}: ${errorMessage} is terminal`, async t => {
    const f = await fixture(t, entry, { answer: () => ({ content: [], stopReason: "error", errorMessage }) });
    await f.session.prompt("original request");
    assert.equal(f.requests.length, 1);
    assert.equal(f.events.filter(e => e.type === "auto_retry_start").length, 0);
  });
  test(`${entry}: partial toolCall plus a transient stream failure never executes or redelivers the tool`, async t => {
    const f = await fixture(t, entry, { answer: i => i === 0 ? { stopReason: "error", errorMessage: "connection lost during tool-call stream",
      content: [{ type: "toolCall", id: "unsafe-1", name: "once", arguments: {} }] } : {} });
    await f.session.prompt("original request");
    assert.equal(f.requests.length, 2);
    assert.equal(f.executions, 0);
    assert(!JSON.stringify(f.requests[1].messages).includes("unsafe-1"));
    assert.equal(f.session.getRecoveryTranscript().find(m => m.stopReason === "error").content[0].id, "unsafe-1");
  });
  test(`${entry}: tool calls and non-thinking output are never classified as empty`, async () => {
    const { normalizeEmptyCompletion } = await import(pathToFileURL(path.join(pkg, "dist/core/shepherd-checkpoint-recovery.js")));
    for (const stopReason of ["stop", "length"]) for (const part of [{ type: "toolCall", id: "partial-1", name: "once", arguments: {} }, { type: "image", data: "AA==", mimeType: "image/png" }, { type: "text", text: "answer" }]) {
      const message = { role: "assistant", stopReason, content: [part] };
      normalizeEmptyCompletion(message);
      assert.equal(message.stopReason, stopReason);
      assert.equal(message.errorMessage, undefined);
    }
  });
  test(`${entry}: a completed tool executes once across empty-response recovery`, async t => {
    const f = await fixture(t, entry, { answer: i => i === 0 ? { stopReason: "toolUse", content: [{ type: "toolCall", id: "once-1", name: "once", arguments: {} }] }
      : i === 1 ? { content: [] } : {} });
    await f.session.prompt("original request");
    assert.equal(f.requests.length, 3);
    assert.equal(f.executions, 1);
    assert.equal(f.requests[2].messages.filter(m => m.role === "user").length, 1);
    assert.equal(f.requests[2].messages.filter(m => m.role === "toolResult").length, 1);
  });
}
