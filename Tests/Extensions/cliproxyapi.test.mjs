// Actual extension, bundled metadata and stream implementations; no network or user configuration.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR");
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const ai = path.join(pkg, "node_modules/@earendil-works/pi-ai/dist");
const { createJiti } = createRequire(path.join(pkg, "package.json"))("jiti");
const jiti = createJiti(import.meta.url, { alias: {
  "@earendil-works/pi-ai/providers/all": path.join(ai, "providers/all.js"),
  "@earendil-works/pi-ai/compat": path.join(ai, "compat.js"),
} });
const { default: install } = await jiti.import(path.join(root, "Extensions/shepherd-cliproxyapi.ts"));
const { getBuiltinProviders, getBuiltinModels } = await import(pathToFileURL(path.join(ai, "providers/all.js")));
const { createModels } = await import(pathToFileURL(path.join(ai, "models.js")));
const catalog = getBuiltinProviders().flatMap(getBuiltinModels);
const base = { enabled: true, baseURL: "http://127.0.0.1:8317/v1", apiKey: "fixture-key", updatedAt: 1,
  models: [{ id: "openai/gpt-5.5" }] };
const context = { messages: [{ role: "system", content: "Be concise", timestamp: 0, toolsAdded: [{ name: "lookup", description: "Look up",
  parameters: { type: "object", properties: { requiredValue: { type: "string" }, optional: { type: "string" } }, required: ["requiredValue"] } }] },
  { role: "user", content: "Hello", timestamp: 1 }] };

function fixture(t, config = base) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-cliproxy-"));
  const configPath = path.join(dir, "config.json");
  const write = (value) => fs.writeFileSync(configPath, typeof value === "string" ? value : JSON.stringify(value));
  if (config !== null) write(config);
  const handlers = new Map(), registrations = [], refreshes = [];
  let idle = true, selected;
  let selectForRecovery = () => assert.fail("An already selected model must not append transcript records");
  const ctx = { isIdle: () => idle, sessionManager: { getBranch: () => [] }, get model() { return selected; }, modelRegistry: {
    refresh: async (options) => { refreshes.push(options); return { aborted: false, errors: new Map() }; },
    find: (provider, id) => registrations.at(-1)?.getModels().find((model) => model.provider === provider && model.id === id),
  } };
  const saved = process.env.SHEPHERD_CLIPROXYAPI_CONFIG;
  process.env.SHEPHERD_CLIPROXYAPI_CONFIG = configPath;
  try {
    assert.equal(install({
      on: (event, handler) => handlers.set(event, handler),
      registerProvider: (provider) => {
        registrations.push(provider);
        // AgentSession's registration hook refreshes the current model without setModel.
        selected = provider.getModels().find((model) => model.id === selected?.id) ?? selected;
      },
      setModel: (model) => selectForRecovery(model),
    }), undefined, "factory is synchronous");
  } finally {
    if (saved === undefined) delete process.env.SHEPHERD_CLIPROXYAPI_CONFIG;
    else process.env.SHEPHERD_CLIPROXYAPI_CONFIG = saved;
  }
  t.after(() => { handlers.get("session_shutdown")?.(); fs.rmSync(dir, { recursive: true, force: true }); });
  return { dir, configPath, write, ctx, registrations, refreshes, handlers,
    get provider() { return registrations.at(-1); },
    get models() { return this.provider?.getModels() ?? []; },
    get selected() { return selected; },
    select(model) { selected = model; },
    recoverWith(select) { selectForRecovery = select; },
    idle(value) { idle = value; },
    emit(event) { return handlers.get(event)?.({}, ctx); },
  };
}

function capture(error = "fixture response") {
  const calls = [];
  return { calls, fetch: async (url, init) => {
    calls.push({ url: String(url), headers: new Headers(init.headers), body: JSON.parse(init.body) });
    return new Response(JSON.stringify({ error: { message: error, type: "invalid_request_error" } }),
      { status: 400, headers: { "Content-Type": "application/json" } });
  } };
}

function assertCapabilities(model, native) {
  for (const key of ["reasoning", "input", "thinkingLevelMap", "inputLimits", "cost", "contextWindow", "maxTokens"])
    assert.deepEqual(model[key], native[key], key);
  assert.equal(model.headers, undefined);
  assert.equal(model.promptCache, undefined);
  assert.equal(model.baseUrl, base.baseURL);
  assert.equal(model.provider, "cliproxyapi");
  assert.equal(model.compat.supportsStrictMode, false);
}

test("factory is inert without settings, registers synchronously when enabled, and never starts a watcher", (t) => {
  const watcher = t.mock.method(fs, "watchFile", () => assert.fail("factory must not start a watcher"));
  const saved = process.env.SHEPHERD_CLIPROXYAPI_CONFIG;
  delete process.env.SHEPHERD_CLIPROXYAPI_CONFIG;
  try { install({ on: () => assert.fail("no path is inert"), registerProvider: () => assert.fail("no config") }); }
  finally { if (saved !== undefined) process.env.SHEPHERD_CLIPROXYAPI_CONFIG = saved; }
  for (const config of [null, { ...base, enabled: false }, "{bad json", { ...base, baseURL: "https://user:secret@example.com/v1" },
    { ...base, baseURL: "file:///tmp/models" }, { ...base, models: [{ id: "" }] }, { ...base, models: [{ id: "x" }, { id: "x" }] },
    { ...base, apiKey: "invalid\nsecret" }, { ...base, apiKey: "" }, { ...base, models: [] },
    { ...base, models: Array.from({ length: 10001 }, (_, i) => ({ id: `model-${i}` })) },
    { ...base, models: [{ id: "a".repeat(1025) }] }, { ...base, models: [{ id: "hidden\u007fcontrol" }] },
    { ...base, models: [{ id: "hidden\u0085control" }] }]) {
    assert.equal(fixture(t, config).registrations.length, 0);
  }
  const f = fixture(t);
  assert.equal(f.provider.id, "cliproxyapi");
  assert.equal(f.models.length, 1);
  assert.equal(watcher.mock.callCount(), 0);
  assert.equal(f.provider.refreshModels, undefined, "discovery belongs to Swift");
});

test("metadata matches exact routes, canonical owners and unique suffixes without importing transports", (t) => {
  const suffixCounts = new Map();
  for (const model of catalog) { const suffix = model.id.split("/").at(-1); suffixCounts.set(suffix, (suffixCounts.get(suffix) ?? 0) + 1); }
  const unique = catalog.find((model) => suffixCounts.get(model.id.split("/").at(-1)) === 1);
  assert.ok(unique);
  const codex = catalog.find((model) => model.provider === "openai-codex" && model.id.includes("codex"));
  assert.ok(codex);
  const entries = [
    { id: "~anthropic/claude-sonnet-4-6" },
    { id: "gpt-5.5", owned_by: "openai" },
    { id: "openai-codex/gpt-5.3-codex-spark" },
    { id: `route/${unique.id.split("/").at(-1)}` },
    { id: "gpt-5.5" },
    { id: "not-a-known-model", owned_by: "openai" },
    { id: "gpt-5.5", owned_by: "unknown" },
    { id: codex.id },
    { id: "custom-route/claude-sonnet-4-6", owned_by: "anthropic" },
  ];
  for (const [index, entry] of entries.entries()) {
    const model = fixture(t, { ...base, models: [entry] }).models[0];
    assert.equal(model.id, entry.id, "never rewrite the routed request ID");
    const native = index === 7 ? codex : [0, 8].includes(index) ? catalog.find((m) => m.provider === "anthropic" && m.id === "claude-sonnet-4-6") :
      index === 2 ? catalog.find((m) => m.provider === "openai-codex" && m.id === "gpt-5.3-codex-spark") :
      index === 3 ? unique : [1, 4].includes(index) ? catalog.find((m) => m.provider === "openai" && m.id === "gpt-5.5") : undefined;
    if (native) {
      assertCapabilities(model, native);
      assert.equal(model.api, native.api.includes("responses") ? "openai-responses" : "openai-completions");
    } else {
      assert.equal(model.reasoning, false);
      assert.deepEqual(model.input, ["text"]);
      assert.equal(model.contextWindow, 128000);
      assert.equal(model.maxTokens, 16384);
      assert.deepEqual(model.cost, { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });
      assert.equal(model.api, "openai-completions");
    }
  }
});

test("a release newer than the catalog borrows its family's latest capabilities, never its name", (t) => {
  const family = (id) => id.replace(/\d+(?:\.\d+)*/g, "#");
  const numbers = (id) => id.match(/\d+/g).map(Number);
  const newer = (a, b) => { for (let i = 0; i < Math.max(a.length, b.length); i++) if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0); return false; };
  const openai = catalog.filter((m) => m.provider === "openai" && /\d/.test(m.id) && !/\d{8}/.test(m.id));
  const latest = openai.find((m) => m.reasoning && m.thinkingLevelMap &&
    !openai.some((other) => other !== m && family(other.id) === family(m.id) && !newer(numbers(m.id), numbers(other.id))));
  assert.ok(latest, "the catalog holds an OpenAI reasoning family");
  const bumped = latest.id.replace(/(\d+)(?!.*\d)/, (digits) => String(Number(digits) + 50));
  assert.equal(catalog.some((m) => m.id === bumped), false, "the bumped release is unknown to the catalog");
  const f = fixture(t, { ...base, models: [{ id: bumped, owned_by: "openai" }, { id: `openai/${bumped}` },
    { id: bumped.replace(/\d/, "9") + "-20990101", owned_by: "openai" }, { id: "mystery-9", owned_by: "nobody" }] });
  const [owned, routed, dated, unknown] = f.models;
  for (const model of [owned, routed]) {
    assertCapabilities(model, latest);
    assert.equal(model.name, model.id, "a borrowed sibling lends capabilities, not its name");
  }
  for (const model of [dated, unknown]) {
    assert.equal(model.reasoning, false, "a dated release or an unknown owner borrows nothing");
    assert.equal(model.thinkingLevelMap, undefined);
  }
});

test("a key a request header can't carry fails with its cause before any request", async (t) => {
  for (const key of ["sk-smart\u2019quote", "sk-ellipsis\u2026"]) {
    const f = fixture(t, { ...base, apiKey: key });
    const wire = capture();
    const message = await f.provider.streamSimple(f.models[0], context, { fetch: wire.fetch }).result();
    assert.equal(message.stopReason, "error");
    assert.match(message.errorMessage, /can't carry/);
    assert.equal(message.errorMessage.includes(key), false, "the key never appears in the error");
    assert.equal(wire.calls.length, 0);
  }
});

test("literal keys ignore interpolation, commands, stored auth and request overrides", async (t) => {
  for (const key of ["$HOME", "${TOKEN}", "!touch should-never-run", "$!literal", "plain-key"]) {
    const f = fixture(t, { ...base, apiKey: key });
    const runtime = createModels({ credentials: {
      read: async () => ({ type: "api_key", key: "!throw imported secret", env: { OPENAI_API_KEY: "wrong" } }),
      list: async () => [], modify: async () => assert.fail("no stored credential writes"), delete: async () => assert.fail(),
    } });
    runtime.setProvider(f.provider);
    assert.equal((await runtime.getAuth("cliproxyapi")).auth.apiKey, key);
    assert.equal((await runtime.getAuth("cliproxyapi", { apiKey: "request override" })).auth.apiKey, key);
    const wire = capture();
    const response = await runtime.streamSimple(f.models[0], context, { fetch: wire.fetch, apiKey: "wrong",
      headers: { Authorization: "Bearer imported", authorization: "Bearer lowercase-imported", "X-Test": "kept" } }).result();
    assert.equal(response.stopReason, "error");
    assert.equal(wire.calls.length, 1);
    assert.equal(wire.calls[0].headers.get("authorization"), key ? `Bearer ${key}` : null);
    assert.equal(wire.calls[0].headers.get("x-test"), "kept");
  }
});

test("built-in APIs preserve optional schemas, route Responses and apply DeepSeek compatibility only by owner", async (t) => {
  const f = fixture(t, { ...base, models: [
    { id: "openai/gpt-5.5" }, { id: "openai-codex/gpt-5.3-codex-spark" },
    { id: "deepseek/deepseek-v4-pro", owned_by: "My DeepSeek upstream" },
    { id: "deepseek-v4-pro", owned_by: "openrouter" },
    { id: "unknown" },
  ] });
  for (const model of f.models) {
    const wire = capture();
    let responseHook = 0;
    const message = await f.provider.streamSimple(model, context, { fetch: wire.fetch, reasoning: "high",
      onResponse: () => { responseHook++; }, onPayload: (payload) => ({ ...payload, fixture: true }) }).result();
    assert.equal(message.stopReason, "error");
    const call = wire.calls[0], responses = model.api === "openai-responses";
    assert.equal(call.url, `${base.baseURL}/${responses ? "responses" : "chat/completions"}`);
    assert.equal(call.body.model, model.id);
    assert.equal(call.body.fixture, true, "preserve caller payload hook");
    const tool = responses ? call.body.tools[0] : call.body.tools[0].function;
    assert.equal(tool.strict, responses ? null : undefined);
    assert.deepEqual(tool.parameters.required, ["requiredValue"], "optional properties must stay optional");
    if (model.id === "deepseek/deepseek-v4-pro") {
      assert.equal(call.body.store, undefined);
      assert.equal(call.body.messages[0].role, "system");
      assert.equal(call.body.max_completion_tokens, undefined);
      assert.ok(call.body.max_tokens > 0);
      assert.deepEqual(call.body.thinking, { type: "enabled" });
      assert.equal(model.compat.requiresReasoningContentOnAssistantMessages, true);
    } else assert.equal(model.compat.thinkingFormat, undefined);
    assert.equal(responseHook, 0, "SDK HTTP failures precede onResponse");
  }
});

test("stream and streamSimple retain success events and response hooks through the built-in API", async (t) => {
  const f = fixture(t, { ...base, models: [{ id: "unknown" }] });
  for (const method of ["stream", "streamSimple"]) {
    let observed = false;
    const fetch = async () => new Response([
      { id: "fixture", choices: [{ index: 0, delta: { role: "assistant", content: "Hello 🌍" }, finish_reason: null }] },
      { id: "fixture", choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 2, completion_tokens: 3, total_tokens: 5 } },
    ].map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } });
    const stream = f.provider[method](f.models[0], context, { fetch, onResponse: () => { observed = true; } });
    const events = [];
    for await (const event of stream) events.push(event.type);
    const result = await stream.result();
    assert.equal(result.content[0].text, "Hello 🌍");
    assert.equal(result.usage.totalTokens, 5);
    assert.equal(result.stopReason, "stop");
    assert.equal(events[0], "start");
    assert.equal(events.at(-1), "done");
    assert.equal(observed, true);
  }
});

test("updates wait for idle, re-resolve selected models, and disable refuses stale requests", async (t) => {
  const f = fixture(t);
  let change, watched = false;
  t.mock.method(fs, "watchFile", (file, options, listener) => {
    assert.equal(file, f.configPath); assert.equal(options.persistent, false); change = listener; watched = true;
  });
  t.mock.method(fs, "unwatchFile", (_file, listener) => { if (listener === change) watched = false; });
  f.select(f.models[0]);
  const old = f.selected;
  await f.emit("session_start");
  assert.equal(watched, true);
  f.idle(false); await f.emit("agent_start");
  f.write({ ...base, baseURL: "http://127.0.0.1:9999/v1", apiKey: "rotated", updatedAt: 2 });
  change(); await f.emit("input");
  assert.equal(f.registrations.length, 1);
  assert.equal(f.selected, old);
  f.idle(true); // agent_end may briefly look idle; only agent_settled ends this run.
  change(); await f.emit("input");
  assert.equal(f.registrations.length, 1);
  await f.emit("agent_settled");
  assert.equal(f.registrations.length, 2);
  assert.notEqual(f.selected, old);
  assert.equal(f.selected.baseUrl, "http://127.0.0.1:9999/v1");
  assert.deepEqual(f.refreshes.at(-1), { providers: ["cliproxyapi"], allowNetwork: false });
  const wire = capture();
  await f.provider.streamSimple(old, context, { fetch: wire.fetch }).result();
  assert.equal(wire.calls[0].url, "http://127.0.0.1:9999/v1/responses");
  assert.equal(wire.calls[0].headers.get("authorization"), "Bearer rotated");
  f.write({ ...base, enabled: false, updatedAt: 3 });
  await f.emit("input");
  assert.deepEqual(f.models, []);
  assert.equal(await f.provider.auth.apiKey.resolve({}), undefined);
  const blocked = await f.provider.streamSimple(old, context, { fetch: () => assert.fail("disabled must never send") }).result();
  assert.match(blocked.errorMessage, /disabled/);
  f.write({ ...base, models: [{ id: "different" }], updatedAt: 4 });
  await f.emit("input");
  const removed = await f.provider.streamSimple(old, context, { fetch: () => assert.fail("removed model must never send") }).result();
  assert.match(removed.errorMessage, /no longer available/);
  await f.emit("session_shutdown");
  assert.equal(watched, false);
  f.write(base); change();
  assert.equal(f.models[0].id, "different", "shutdown ends watcher ownership");
});

test("a session notices creation and atomic replacement, and malformed updates fail closed without leaking secrets", async (t) => {
  const f = fixture(t, null);
  await f.emit("session_start");
  const registered = new Promise((resolve) => {
    // A real watcher catches Swift's atomic rename even when the path was initially absent.
    t.mock.method(f.ctx.modelRegistry, "refresh", async () => { resolve(); return { errors: new Map() }; });
  });
  fs.writeFileSync(path.join(f.dir, "next"), JSON.stringify(base));
  fs.renameSync(path.join(f.dir, "next"), f.configPath);
  await Promise.race([registered, new Promise((_, reject) => {
    // Not unref'd: the watcher is (persistent: false), so on a busy machine nothing else keeps the loop alive
    // for the poll that sees the rename, and the runner ends the test "event loop already resolved".
    const timer = setTimeout(() => reject(Error("watchFile did not publish")), 5000);
    t.after(() => clearTimeout(timer));
  })]);
  const old = f.models[0];
  f.write('{"enabled":true,"apiKey":"secret-do-not-log');
  await f.emit("input");
  assert.equal(f.models.length, 0);
  const failure = await f.provider.streamSimple(old, context).result();
  assert.equal(JSON.stringify(failure).includes("secret-do-not-log"), false);
});

test("the real model runtime lists the provider, streams tools and rejects a removed selected model", async (t) => {
  const { ModelRuntime } = await import(pathToFileURL(path.join(pkg, "dist/core/model-runtime.js")));
  const f = fixture(t, { ...base, models: [{ id: "unknown" }] });
  const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false, credentials: {
    read: async () => undefined, list: async () => [], modify: async () => assert.fail(), delete: async () => assert.fail(),
  } });
  runtime.registerNativeProvider(f.provider);
  await runtime.refresh({ providers: ["cliproxyapi"], allowNetwork: false });
  assert.equal(runtime.getAvailableSnapshot().some((model) => model.provider === "cliproxyapi"), true);
  const selected = runtime.getModel("cliproxyapi", "unknown");
  const fetch = async (_url, init) => {
    const tool = JSON.parse(init.body).tools[0].function;
    assert.deepEqual(tool.parameters.required, ["requiredValue"]);
    assert.equal(tool.strict, undefined);
    return new Response([
      { choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: "call-1", type: "function",
        function: { name: "lookup", arguments: '{"requiredValue":' } }] }, finish_reason: null }] },
      { choices: [{ index: 0, delta: { tool_calls: [{ index: 0, function: { arguments: '"hello"}' } }] }, finish_reason: "tool_calls" }] },
    ].map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } });
  };
  const result = await runtime.streamSimple(selected, context, { fetch }).result();
  assert.equal(result.stopReason, "toolUse");
  assert.deepEqual(result.content[0].arguments, { requiredValue: "hello" });
  assert.equal(result.content[0].name, "lookup");
  f.write({ ...base, enabled: false });
  await f.emit("input");
  runtime.registerNativeProvider(f.provider);
  await runtime.refresh({ providers: ["cliproxyapi"], allowNetwork: false });
  assert.equal(runtime.getAvailableSnapshot().some((model) => model.provider === "cliproxyapi"), false);
  const blocked = await runtime.streamSimple(selected, context, { fetch: () => assert.fail("disabled runtime cannot send") }).result();
  assert.equal(blocked.stopReason, "error");
});

test("restoring a missing managed model never sends its conversation to an authenticated fallback", async (t) => {
  const { createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager } =
    await import(pathToFileURL(path.join(pkg, "dist/index.js")));
  const { createAssistantMessageEventStream } = await import(pathToFileURL(path.join(ai, "utils/event-stream.js")));
  for (const [name, config, legacy] of [["forgotten", null, false], ["disabled", { ...base, enabled: false }, false],
    ["removed", { ...base, models: [{ id: "different" }] }, false], ["legacy", null, true]]) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-cliproxy-restore-"));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    const configPath = path.join(dir, "config.json");
    if (config) fs.writeFileSync(configPath, JSON.stringify(config));
    let requests = 0;
    const fallback = { ...getBuiltinModels("openai")[0], provider: "fixture-fallback", id: "fixture", baseUrl: "http://unused.invalid" };
    const stream = () => {
      requests++;
      const events = createAssistantMessageEventStream();
      events.push({ type: "done", reason: "stop", message: { role: "assistant", content: [{ type: "text", text: "Allowed" }],
        api: fallback.api, provider: fallback.provider, model: fallback.id, timestamp: 1, stopReason: "stop",
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } } });
      events.end(); return events;
    };
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false, credentials: {
      read: async () => undefined, list: async () => [], modify: async () => assert.fail(), delete: async () => assert.fail(),
    } });
    runtime.registerNativeProvider({ id: fallback.provider, name: "Fallback", getModels: () => [fallback], stream, streamSimple: stream,
      auth: { apiKey: { name: "fixture", resolve: async () => ({ auth: { apiKey: "fixture" } }) } } });
    await runtime.refresh({ providers: [fallback.provider], allowNetwork: false });
    const settings = SettingsManager.inMemory({ defaultProvider: fallback.provider, defaultModel: fallback.id,
      compaction: { enabled: false }, retry: { enabled: false } });
    const loader = new DefaultResourceLoader({ cwd: dir, agentDir: dir, settingsManager: settings,
      noExtensions: true, noSkills: true, noThemes: true, noPromptTemplates: true, noContextFiles: true,
      extensionFactories: [install] });
    const saved = process.env.SHEPHERD_CLIPROXYAPI_CONFIG;
    process.env.SHEPHERD_CLIPROXYAPI_CONFIG = configPath;
    try { await loader.reload(); }
    finally { if (saved === undefined) delete process.env.SHEPHERD_CLIPROXYAPI_CONFIG; else process.env.SHEPHERD_CLIPROXYAPI_CONFIG = saved; }
    const manager = SessionManager.create(dir, path.join(dir, "sessions"));
    if (!legacy) manager.appendModelChange("cliproxyapi", "saved-model");
    manager.appendMessage({ role: "user", content: "Private restored conversation", timestamp: 1 });
    manager.appendMessage({ role: "assistant", content: [{ type: "text", text: "Private answer" }],
      api: "openai-completions", provider: "cliproxyapi", model: "saved-model", timestamp: 2, stopReason: "stop",
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } });
    const restored = SessionManager.open(manager.getSessionFile(), path.join(dir, "sessions"));
    await runtime.refresh({ allowNetwork: false });
    assert.equal(runtime.hasConfiguredAuth(fallback.provider), true);
    const { session, modelFallbackMessage } = await createAgentSession({ cwd: dir, agentDir: dir,
      settingsManager: settings, sessionManager: restored, resourceLoader: loader, modelRuntime: runtime, noTools: "all" });
    const notices = [], errors = [];
    try {
      assert.equal(session.model.provider, fallback.provider, `${name}: reproduce Pi's silent fallback`);
      assert.match(modelFallbackMessage, /Could not restore model/);
      assert.equal(restored.getBranch().some((entry) => entry.type === "model_change" && entry.provider === fallback.provider), false);
      await session.bindExtensions({ mode: "rpc", onError: (error) => errors.push(error),
        uiContext: { hasUI: true, notify: (message) => notices.push(message) } });
      await session.prompt("Do not send this to fallback");
      assert.equal(requests, 0, `${name}: input must not reach fallback`);
      assert.equal((await session.extensionRunner.emit({ type: "session_before_compact" })).cancel, true);
      assert.equal((await session.extensionRunner.emit({ type: "session_before_tree", preparation: { userWantsSummary: true } })).cancel, true);
      assert.equal(requests, 0, `${name}: summaries must not reach fallback`);
      assert.ok(notices.some((message) => message.includes("CLIProxyAPI model is unavailable")));
      assert.deepEqual(errors, []);
      if (name === "removed") {
        // The proxy stays unchanged; its exact model becomes available in the local catalog.
        fs.writeFileSync(configPath, JSON.stringify({ ...base, models: [{ id: "saved-model" }], updatedAt: 2 }));
        const sent = [];
        const fetch = t.mock.method(globalThis, "fetch", async (url, init) => {
          sent.push({ url: String(url), body: JSON.parse(init.body) });
          return new Response('data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Recovered"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
            { headers: { "content-type": "text/event-stream" } });
        });
        try { await session.prompt("Send only to the recovered exact model"); }
        finally { fetch.mock.restore(); }
        assert.equal(session.model.provider, "cliproxyapi");
        assert.equal(session.model.id, "saved-model");
        assert.equal(requests, 0, "recovery never sends to the fallback");
        assert.equal(sent.length, 1, "the original prompt is sent once, never replayed");
        assert.equal(sent[0].url, base.baseURL + "/chat/completions");
        assert.equal(sent[0].body.model, "saved-model");
        assert.equal(session.getLastAssistantText(), "Recovered");
        assert.deepEqual(errors, []);
      }
      // Even selecting the already-active fallback is an explicit, persisted consent.
      await session.setModel(fallback);
      await session.prompt("Now I explicitly consent to fallback");
      assert.equal(requests, 1);
    } finally {
      await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
      session.dispose();
    }
  }
});

test("an idle restored session recovers only its exact saved model on input, not at startup", async (t) => {
  const f = fixture(t);
  const branch = [{ type: "message", message: { role: "assistant", provider: "cliproxyapi", model: "openai/gpt-5.5" } }];
  f.ctx.sessionManager.getBranch = () => branch;
  f.select({ provider: "other-provider", id: "openai/gpt-5.5" });
  const selected = [];
  f.recoverWith(async (model) => {
    selected.push(`${model.provider}/${model.id}`);
    f.select(model);
    branch.push({ type: "model_change", provider: model.provider, modelId: model.id });
    return true;
  });
  await f.emit("session_start");
  assert.deepEqual(selected, [], "a restart never resumes recovery or model work");
  assert.equal(await f.emit("input"), undefined);
  assert.deepEqual(selected, ["cliproxyapi/openai/gpt-5.5"]);
  assert.equal(f.refreshes.length, 1);
  assert.equal(f.refreshes[0].allowNetwork, false);
  assert.deepEqual(f.refreshes[0].providers, ["cliproxyapi"]);
  assert.ok(f.refreshes[0].signal instanceof AbortSignal);
  assert.equal(await f.emit("input"), undefined);
  assert.equal(selected.length, 1, "subsequent inputs need no extra selection or transcript entry");
});

test("a missing exact model never recovers to a similarly named model or another provider", async (t) => {
  const f = fixture(t, { ...base, models: [{ id: "gpt-5.5", owned_by: "openai" }] });
  f.ctx.sessionManager.getBranch = () => [{ type: "model_change", provider: "cliproxyapi", modelId: "openai/gpt-5.5" }];
  f.select({ provider: "other-provider", id: "openai/gpt-5.5" });
  assert.deepEqual(await f.emit("input"), { action: "handled" });
  assert.equal(f.refreshes.length, 0);
});

test("failed recovery tries selection only once and does not leak the registry error", async (t) => {
  for (const failure of ["refresh", "aborted", "selection"]) {
    const f = fixture(t);
    f.ctx.sessionManager.getBranch = () => [{ type: "model_change", provider: "cliproxyapi", modelId: "openai/gpt-5.5" }];
    f.select({ provider: "other-provider", id: "fallback" });
    const notices = [];
    f.ctx.hasUI = true;
    f.ctx.ui = { notify: (message) => notices.push(message) };
    let selections = 0;
    f.recoverWith(async () => { selections++; throw Error("secret-credential"); });
    if (failure === "refresh") f.ctx.modelRegistry.refresh = async () => { throw Error("secret-credential"); };
    if (failure === "aborted") f.ctx.modelRegistry.refresh = async () => ({ aborted: true, errors: new Map() });
    assert.deepEqual(await f.emit("input"), { action: "handled" });
    assert.equal(selections, failure === "selection" ? 1 : 0);
    assert.equal(f.selected.provider, "other-provider");
    assert.equal(notices.length, 1);
    assert.equal(notices[0].includes("secret-credential"), false);
  }
});

test("a stalled local registry reaches the recovery abort bound without selecting a model", async (t) => {
  const f = fixture(t);
  f.ctx.sessionManager.getBranch = () => [{ type: "model_change", provider: "cliproxyapi", modelId: "openai/gpt-5.5" }];
  f.select({ provider: "other-provider", id: "fallback" });
  let selections = 0;
  f.recoverWith(async () => { selections++; return true; });
  // AbortSignal.timeout is unref'd. Keep this test alive until its real deadline fires.
  const keepAlive = setTimeout(() => {}, 7000);
  t.after(() => clearTimeout(keepAlive));
  let signal;
  f.ctx.modelRegistry.refresh = (options) => new Promise((resolve) => {
    signal = options.signal;
    signal.addEventListener("abort", () => resolve({ aborted: true, errors: new Map() }), { once: true });
  });
  assert.deepEqual(await f.emit("input"), { action: "handled" });
  assert.equal(signal.aborted, true);
  assert.equal(signal.reason.name, "TimeoutError");
  assert.equal(selections, 0);
});

test("recovery never changes a running turn or overrides a selection made during refresh", async (t) => {
  const f = fixture(t);
  const branch = [{ type: "model_change", provider: "cliproxyapi", modelId: "openai/gpt-5.5" }];
  f.ctx.sessionManager.getBranch = () => branch;
  f.select({ provider: "other-provider", id: "fallback" });
  f.idle(false);
  assert.deepEqual(await f.emit("input"), { action: "handled" });
  assert.equal(f.refreshes.length, 0);
  f.idle(true);
  f.ctx.modelRegistry.refresh = async () => {
    branch.push({ type: "model_change", provider: "user-choice", modelId: "chosen" });
    f.select({ provider: "user-choice", id: "chosen" });
    return { aborted: false, errors: new Map() };
  };
  assert.equal(await f.emit("input"), undefined);
  assert.equal(f.selected.provider, "user-choice");
});

test("a turn starting or a session changing during recovery cancels the selection", async (t) => {
  for (const event of ["agent_start", "session_start", "session_shutdown"]) {
    const f = fixture(t);
    f.ctx.sessionManager.getBranch = () => [{ type: "model_change", provider: "cliproxyapi", modelId: "openai/gpt-5.5" }];
    f.select({ provider: "other-provider", id: "fallback" });
    let selections = 0;
    f.recoverWith(async () => { selections++; return true; });
    f.ctx.modelRegistry.refresh = async () => {
      await f.emit(event);
      return { aborted: false, errors: new Map() };
    };
    assert.deepEqual(await f.emit("input"), { action: "handled" }, event);
    assert.equal(selections, 0, event);
  }
});

test("an explicit launch identity wins over older model entries during recovery", async (t) => {
  const argv = process.argv;
  process.argv = [argv[0], argv[1], "--model", "cliproxyapi/openai/gpt-5.5"];
  let f;
  try { f = fixture(t); } finally { process.argv = argv; }
  f.ctx.sessionManager.getBranch = () => [{ type: "model_change", provider: "cliproxyapi", modelId: "old-model" }];
  f.select(f.models[0]);
  assert.equal(await f.emit("input"), undefined, "the explicitly requested exact model is already selected");
  assert.equal(f.refreshes.length, 0);
});

test("a fresh explicit managed model cannot silently fall back before session startup", async (t) => {
  const saved = process.argv;
  process.argv = [saved[0], saved[1], "--model", "cliproxyapi/missing"];
  let h;
  try { h = fixture(t, null); } finally { process.argv = saved; }
  h.select({ provider: "fixture", id: "fallback" });
  assert.deepEqual(await h.emit("input"), { action: "handled" });
  h.handlers.get("model_select")({ source: "set" }, h.ctx);
  assert.equal(await h.emit("input"), undefined);
});

test("provider failures redact literal, JSON-escaped and URL-encoded credentials", async (t) => {
  const key = 'secret/with"quotes';
  const f = fixture(t, { ...base, apiKey: key });
  const wire = capture(`Bad credential ${key} ${encodeURIComponent(key)} ${JSON.stringify(key).slice(1, -1)}`);
  const result = await f.provider.streamSimple(f.models[0], context, { fetch: wire.fetch }).result();
  assert.equal(result.stopReason, "error");
  assert.match(result.errorMessage, /redacted/);
  for (const secret of [key, encodeURIComponent(key), JSON.stringify(key).slice(1, -1)])
    assert.equal(result.errorMessage.includes(secret), false);
  const thrown = await f.provider.streamSimple(f.models[0], context, { onPayload: () => { throw Error(key); } }).result();
  assert.equal(thrown.errorMessage.includes(key), false);
});
