// Offline serialization/stream parity with unmodified pi-anthropic-oauth v0.3.4.
// PI_PACKAGE_DIR=<patched pinned package> node --test Tests/Extensions/anthropic-oauth.test.mjs
import test, { after } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { createHash } from "node:crypto";
import { stripTypeScriptTypes, syncBuiltinESMExports } from "node:module";
import http from "node:http";
import { EventEmitter } from "node:events";
import { pathToFileURL } from "node:url";
import { withPi, pkg } from "./fixtures/pi-rpc-harness.mjs";

const load = relative => import(pathToFileURL(path.join(pkg, relative)).href);
const { buildSystemPrompt } = await load("dist/core/system-prompt.js");
const patch = JSON.parse(fs.readFileSync(new URL("../../scripts/pi-engine-patches/skills.json", import.meta.url)));
const providers = [
  ["modular", "node_modules/@earendil-works/pi-ai/dist/api/anthropic-messages.js"],
  ["bundle", patch.files.find(f => f.path.startsWith("dist/bundle/chunks/anthropic-messages-")).path],
];
const sourceDir = new URL("../../scripts/pi-engine-patches/anthropic-oauth/upstream/", import.meta.url);
const pin = JSON.parse(fs.readFileSync(new URL("pin.json", sourceDir)));
// Compile the original source independently, resolving only its existing SDK imports
// from the isolated engine package. No production port helpers enter the oracle.
const oracleDir = fs.mkdtempSync(path.join(pkg, ".oauth-oracle-"));
after(() => fs.rmSync(oracleDir, { recursive: true, force: true }));
for (const [name, hash] of Object.entries(pin.sha256)) {
  const bytes = fs.readFileSync(new URL(name, sourceDir));
  assert.equal(createHash("sha256").update(bytes).digest("hex"), hash, name);
  if (name.endsWith(".ts") && name !== "index.ts") {
    fs.writeFileSync(path.join(oracleDir, name.replace(/\.ts$/, ".js")),
      stripTypeScriptTypes(bytes.toString(), { mode: name === "auth.ts" ? "transform" : "strip" }));
  }
}
const oracle = await import(pathToFileURL(path.join(oracleDir, "stream.js")).href);
const oracleAuth = await import(pathToFileURL(path.join(oracleDir, "auth.js")).href);
const oraclePrompt = await import(pathToFileURL(path.join(oracleDir, "prompt.js")).href);
const model = { id: "claude-opus-5-5", name: "fixture", api: "anthropic-messages", provider: "anthropic",
  baseUrl: "https://offline.invalid", reasoning: true, input: ["text", "image"], contextWindow: 1000000, maxTokens: 64000,
  cost: { input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25 } };
const oauth = "sk-ant-oat-offline-fixture";
const instructions = 'Keep /tmp/pi/project/.pi/AGENTS.md and C:\\pi\\file intact. 😀\n\nRead @earendil-works/pi-coding-agent and badlogic/pi-mono.\n\nRun /Applications/Shepherd.app/Contents/Resources/pi-engine/dist/cli.js.';
const tools = [
  { name: "read", description: instructions, parameters: { type: "object", properties: { path: { type: "string" } }, required: ["path"], additionalProperties: false } },
  { name: "shepherd_parent_message", description: "Ask the parent", parameters: { type: "object", properties: {} } },
  { name: "mcp__web__search", description: "Existing MCP tool", parameters: { type: "object", properties: {} } },
  { name: "skill", description: "Not in upstream's canonical tool set", parameters: { type: "object", properties: {} } },
];
const prompt = buildSystemPrompt({ cwd: "/tmp/pi/project", contextFiles: [{ path: "/tmp/pi/AGENTS.md", content: instructions }],
  appendSystemPrompt: instructions, selectedTools: ["read"], toolSnippets: { read: "Read files" } });
const transcript = (text = prompt) => ({ messages: [
  { role: "system", content: text, toolsAdded: structuredClone(tools), timestamp: 0 },
  { role: "user", content: instructions, timestamp: 1 },
] });
const assistant = (content, extra = {}) => ({ role: "assistant", api: model.api, provider: model.provider, model: model.id,
  stopReason: "toolUse", timestamp: 2, content, ...extra });
const toolResult = (id, content, isError = false) => ({ role: "toolResult", toolCallId: id, toolName: "shepherd_parent_message", content, isError, timestamp: 3 });

function events(name, stopReason = "tool_use") {
  return [
    { type: "message_start", message: { id: "fixture", model: model.id, usage: { input_tokens: 5, output_tokens: 1, cache_read_input_tokens: 2, cache_creation_input_tokens: 3 } } },
    { type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "", signature: "" } },
    { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: "Choose a tool" } },
    { type: "content_block_delta", index: 0, delta: { type: "signature_delta", signature: "fixture-signature" } },
    { type: "content_block_stop", index: 0 },
    { type: "content_block_start", index: 1, content_block: { type: "text", text: "" } },
    { type: "content_block_delta", index: 1, delta: { type: "text_delta", text: "Using the tool" } },
    { type: "content_block_stop", index: 1 },
    { type: "content_block_start", index: 2, content_block: { type: "tool_use", id: "call_fixture", name, input: {} } },
    { type: "content_block_delta", index: 2, delta: { type: "input_json_delta", partial_json: '{"path":' } },
    { type: "content_block_delta", index: 2, delta: { type: "input_json_delta", partial_json: '"/tmp/pi/project/.pi/AGENTS.md"}' } },
    { type: "content_block_stop", index: 2 },
    { type: "message_delta", delta: { stop_reason: stopReason, stop_details: { explanation: "fixture explanation" } },
      usage: { input_tokens: 7, output_tokens: 11, cache_read_input_tokens: 13, cache_creation_input_tokens: 17, output_tokens_details: { thinking_tokens: 4 } } },
    { type: "message_stop" },
  ];
}

// Use the SDK's real serialization and SSE decoder. Upstream intentionally does
// not implement Pi's options.fetch; replace global fetch only within each check.
async function request(stream, { key = oauth, context = transcript(), requestModel = model,
  responseName = key === oauth ? "Read" : "read", stopReason, ...options } = {}) {
  let wire;
  const fetch = async (url, init) => {
    wire = { url: String(url), headers: Object.fromEntries(new Headers(init.headers)), body: JSON.parse(init.body) };
    return new Response(events(responseName, stopReason).map(e => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join(""),
      { headers: { "content-type": "text/event-stream", "x-fixture": "yes" } });
  };
  const original = globalThis.fetch;
  const before = JSON.stringify(context);
  const emitted = [];
  let result;
  try {
    globalThis.fetch = fetch;
    const s = stream(requestModel, context, { apiKey: key, fetch, maxRetries: 0, ...options });
    for await (const e of s) emitted.push(e.type);
    result = await s.result();
  } finally { globalThis.fetch = original; }
  assert.equal(JSON.stringify(context), before, "stored transcript must remain byte-for-byte unchanged");
  assert.ok(wire, result?.errorMessage);
  return { wire, result, emitted };
}
const normalized = value => JSON.parse(JSON.stringify(value).replace(/cc_prompt_id=[0-9a-f-]{36}/g, "cc_prompt_id=UUID"));
const stableResult = ({ timestamp, ...message }) => message;
async function parity(stream, options) {
  const expected = await request(oracle.streamAnthropicOAuth, options);
  const actual = await request(stream, options);
  assert.deepEqual(normalized(actual.wire), normalized(expected.wire), "serialized body and headers must match unmodified pinned upstream");
  assert.deepEqual(stableResult(actual.result), stableResult(expected.result));
  assert.deepEqual(actual.emitted, expected.emitted);
  return actual;
}
function assertOAuth({ headers, body }) {
  headers = new Headers(headers);
  assert.equal(headers.get("authorization"), `Bearer ${oauth}`);
  assert.equal(headers.get("x-api-key"), null);
  assert.equal(headers.get("user-agent"), "claude-cli/2.1.280 (external, cli)");
  assert.equal(headers.get("x-app"), "cli");
  assert.equal(headers.get("anthropic-beta"), "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14");
  assert.match(body.system[0].text, /^x-anthropic-billing-header: cc_version=2\.1\.280; cc_entrypoint=cli; cch=00000; cc_prompt_id=[0-9a-f-]{36}$/);
  assert.equal(body.system[1].text, "You are a Claude agent, built on Anthropic's Claude Agent SDK.");
  assert.equal(body.system[0].cache_control, undefined);
  assert.equal(body.system[1].cache_control, undefined);
}

test("vendored runtime is an unmodified transpilation of all five pinned upstream modules", () => {
  assert.equal(pin.revision, "44efe694a3e81a62742cdb3e7ba9da858e191a81");
  for (const name of ["auth", "convert", "prompt", "stream", "version"]) {
    const runtime = fs.readFileSync(new URL(`../../scripts/pi-engine-patches/anthropic-oauth/${name}.js`, import.meta.url), "utf8");
    const expected = fs.readFileSync(path.join(oracleDir, `${name}.js`), "utf8");
    assert.ok(runtime.endsWith(expected), name);
    assert.ok(runtime.includes("Copyright (c) 2026 Leo Henon"));
  }
});

for (const [name, relative] of providers) {
  const api = await load(relative);
  const providerPatch = patch.files.find(f => f.path === relative);
  let pristine = fs.readFileSync(path.join(pkg, relative), "utf8");
  for (const edit of [...providerPatch.edits].reverse()) pristine = pristine.replace(edit.new, edit.old);
  assert.equal(createHash("sha256").update(pristine).digest("hex"), providerPatch.before);
  const pristineFile = path.join(path.dirname(path.join(pkg, relative)), `.oauth-native-${process.pid}.js`);
  fs.writeFileSync(pristineFile, pristine);
  after(() => fs.rmSync(pristineFile, { force: true }));
  const native = await import(pathToFileURL(pristineFile).href);
  test(`${name}: generated prompt, Opus 5.5 reasoning, headers and complete stream equal upstream`, async () => {
    for (const method of ["stream", "streamSimple"]) {
      const { wire, result } = await parity(api[method], { reasoning: "xhigh" });
      assertOAuth(wire);
      assert.equal(wire.body.model, "claude-opus-5-5");
      assert.equal(wire.body.max_tokens, Math.floor(model.maxTokens / 3));
      assert.deepEqual(wire.body.thinking, { type: "adaptive", display: "summarized" });
      assert.deepEqual(wire.body.output_config, { effort: "xhigh" });
      assert.deepEqual(wire.body.tools.map(t => t.name), ["Read", "mcp__pi__shepherd_parent_message", "mcp__pi__mcp__web__search", "mcp__pi__skill"]);
      assert.deepEqual(result.content[2].arguments, { path: "/tmp/pi/project/.pi/AGENTS.md" });
      assert.equal(result.content[2].name, "read");
      // This destructive text behavior is upstream's, not a Shepherd path-safe approximation.
      assert.equal(wire.body.system[2].text, oraclePrompt.sanitizeSystemText(prompt));
      assert.ok(wire.body.system[2].text.includes("/tmp/Claude Code"));
      assert.ok(!wire.body.system[2].text.includes("badlogic/pi-mono"));
      assert.equal(wire.body.messages[0].content[0].text, instructions, "user messages are never rewritten");
      assert.equal(wire.body.tools[0].description, instructions, "tool descriptions are never rewritten");
    }
  });

  test(`${name}: history, signatures, orphan calls, ID collisions, images and system/tool updates equal upstream`, async () => {
    const context = transcript();
    context.messages.push(
      assistant([{ type: "thinking", thinking: "signed", thinkingSignature: "valid-signature" },
        { type: "thinking", thinking: "", thinkingSignature: "redacted-signature", redacted: true },
        { type: "toolCall", id: "a.b", name: "shepherd_parent_message", arguments: { text: "quotes\"\n😀" } },
        { type: "toolCall", id: "a_b", name: "mcp__web__search", arguments: {} }]),
      toolResult("a.b", [{ type: "text", text: "prior result\ud800" }, { type: "image", mimeType: "image/png", data: "aGVsbG8=" }]),
      assistant([{ type: "toolCall", id: "aborted", name: "read", arguments: {} }], { stopReason: "aborted" }),
      assistant([{ type: "thinking", thinking: "other model", thinkingSignature: "invalid-for-this-model" }], { model: "other-model", stopReason: "stop" }),
      assistant([{ type: "toolCall", id: "orphan", name: "read", arguments: {} }]),
      { role: "user", content: [{ type: "text", text: "" }, { type: "text", text: "continue 😀\ud800" }], timestamp: 4 },
      { role: "system", content: "Keep later /tmp/pi/context too", sections: { rules: "project instructions" },
        toolsRemoved: [tools[3]], toolsAdded: [{ ...tools[1], name: "shepherd_late" }], timestamp: 5 },
    );
    const { wire } = await parity(api.streamSimple, { context, responseName: "mcp__pi__shepherd_late",
      requestModel: { ...model, compat: { supportsMidConvoSystemMessages: true, supportsMidConvoToolChanges: true } } });
    assert.ok(wire.body.tools.some(t => t.name === "mcp__pi__shepherd_late"));
    assert.ok(!wire.body.tools.some(t => t.name === "mcp__pi__skill"));
    assert.ok(JSON.stringify(wire.body.messages).includes("No result provided"));
  });

  test(`${name}: model parameters, cache modes, thinking budgets and custom header semantics equal upstream`, async () => {
    for (const cacheRetention of ["none", "short", "long"]) {
      for (const variant of [
        { maxTokens: 4096, reasoning: "high", thinkingBudgets: { high: 2048 }, requestModel: { ...model, id: "claude-sonnet-4-5" } },
        { maxTokens: 1024, reasoning: "high", requestModel: { ...model, id: "claude-opus-4-1" } },
        { maxTokens: 8192, reasoning: "max", requestModel: { ...model, thinkingLevelMap: { max: "xhigh" }, compat: { forceAdaptiveThinking: true } } },
        { maxTokens: 3000, reasoning: "low", requestModel: { ...model, compat: { forceAdaptiveThinking: false } } },
      ]) {
        await parity(api.streamSimple, { ...variant, cacheRetention, temperature: 0.7, toolChoice: { type: "tool", name: "read" },
          headers: { "X-Api-Key": "must-not-leak", AUTHORIZATION: "must-not-leak", "X-Custom": "preserved" } });
      }
    }
    await parity(api.stream, { context: transcript(""), env: { PI_CACHE_RETENTION: "long" } });
    await parity(api.stream, { context: transcript(instructions), maxTokens: 1, reasoning: "high" });
    await parity(api.stream, { context: transcript("custom"), stopReason: "refusal" });
    let response;
    await parity(api.stream, { onResponse(info) { response = info; throw Error("best effort"); } });
    assert.equal(response.status, 200);
    assert.equal(response.headers["x-fixture"], "yes");
  });

  test(`${name}: exact upstream custom tool mapping, including sanitization collisions, is not a hybrid`, async () => {
    for (const [toolName, wireName, decoded] of [
      ["shepherd_parent_message", "mcp__pi__shepherd_parent_message", "shepherd_parent_message"],
      ["mcp__web__search", "mcp__pi__mcp__web__search", "mcp__web__search"],
      ["skill", "mcp__pi__skill", "skill"],
      ["custom.tool", "mcp__pi__custom_tool", "custom.tool"],
    ]) {
      const context = transcript();
      context.messages[0].toolsAdded = [{ ...tools[1], name: toolName }];
      const { result } = await parity(api.streamSimple, { context, responseName: wireName });
      assert.equal(result.content[2].name, decoded);
    }
    const context = transcript();
    context.messages[0].toolsAdded = ["custom.tool", "custom_tool", "x".repeat(150)].map(name => ({ ...tools[1], name }));
    await parity(api.streamSimple, { context, responseName: "mcp__pi__custom_tool" });
  });

  test(`${name}: API-key auth, prompt, tools, model parameters and cache behavior remain native Pi`, async () => {
    for (const method of ["stream", "streamSimple"]) {
      const options = { key: "sk-ant-api-offline-fixture", maxTokens: 4096, temperature: 0.3 };
      const actual = await request(api[method], options);
      const expected = await request(native[method], options);
      assert.deepEqual(actual.wire, expected.wire, "API-key wire must equal pristine pinned Pi");
      assert.deepEqual(stableResult(actual.result), stableResult(expected.result));
      const { wire: { headers, body } } = actual;
      assert.equal(headers.authorization, undefined);
      assert.equal(headers["x-api-key"], "sk-ant-api-offline-fixture");
      assert.notEqual(headers["x-app"], "cli");
      assert.doesNotMatch(headers["user-agent"], /claude-cli/);
      assert.doesNotMatch(headers["anthropic-beta"] ?? "", /oauth|claude-code/);
      assert.deepEqual(body.system, [{ type: "text", text: prompt, cache_control: { type: "ephemeral" } }]);
      assert.deepEqual(body.tools.map(t => t.name), tools.map(t => t.name));
      assert.equal(body.max_tokens, 4096);
      assert.equal(body.temperature, 0.3);
    }
  });
}

for (const entrypoint of ["dist/cli.js", "dist/bundle/cli.js"]) {
  for (const disabled of [false, true]) {
    test(`${entrypoint}: Opus 5.5 selected ${disabled ? "built-in tool with extensions disabled" : "custom tool"} executes and returns OAuth history`, async t => {
      const customName = "shepherd_parent_message";
      const wireName = disabled ? "Read" : `mcp__pi__${customName}`;
      let fixturePath;
      let originalInstructions;
      await withPi(t, { entrypoint, args: [disabled ? "-ne" : "-ns", "-np", "--model", `anthropic/${model.id}`],
        files: () => ({ "extensions/oauth-tool.ts": `export default pi => pi.registerTool({
          name: "${customName}", label: "fixture parent", description: "Offline Shepherd custom tool",
          parameters: { type: "object", properties: {} },
          async execute() { return { content: [{ type: "text", text: "CUSTOM_OAUTH_EXECUTED" }], details: {} }; }
        });` }),
        project(dir, work) {
          fixturePath = path.join(work, "fixture.txt");
          fs.writeFileSync(fixturePath, "BUILTIN_OAUTH_EXECUTED");
          originalInstructions = path.join(work, "AGENTS.md");
          fs.writeFileSync(originalInstructions, instructions);
          const file = path.join(dir, "home/models.json");
          const models = JSON.parse(fs.readFileSync(file));
          models.providers.anthropic = { baseUrl: models.providers.fixture.baseUrl, models: [{ ...model, baseUrl: models.providers.fixture.baseUrl }] };
          fs.writeFileSync(file, JSON.stringify(models));
          fs.writeFileSync(path.join(dir, "home/auth.json"), JSON.stringify({ anthropic: {
            type: "oauth", access: oauth, refresh: "offline-refresh-fixture", expires: Date.now() + 3600000,
          } }));
        },
        onRequest({ index }) {
          return index === 0 ? { tool: { name: wireName, arguments: disabled ? { path: fixturePath } : {} } } : {};
        },
      }, async pi => {
        const userPrompt = `${instructions}\n\nUse the selected fixture tool once`;
        const turn = await pi.prompt(userPrompt);
        assert.equal(turn.reply.success, true);
        assert.equal(turn.requests.length, 2, JSON.stringify(turn.events));
        const execution = pi.toolEvents(turn.events).find(e => e.type === "tool_execution_end");
        assert.equal(execution.toolName, disabled ? "read" : customName);
        assert.equal(execution.isError, false);
        const history = pi.provider.requests[1].body.messages.flatMap(m => Array.isArray(m.content) ? m.content : []);
        const call = history.find(b => b.type === "tool_use");
        assert.equal(call.name, wireName);
        const result = history.find(b => b.type === "tool_result");
        assert.equal(result.tool_use_id, call.id);
        assert.ok(JSON.stringify(result).includes(disabled ? "BUILTIN_OAUTH_EXECUTED" : "CUSTOM_OAUTH_EXECUTED"));
        for (const wire of pi.provider.requests) assertOAuth(wire);
        assert.equal(fs.readFileSync(originalInstructions, "utf8"), instructions);
        const session = (await pi.request({ type: "get_state" })).data.sessionFile;
        const entries = fs.readFileSync(session, "utf8").trim().split("\n").map(line => JSON.parse(line));
        const saved = entries.find(entry => entry.message?.role === "user").message;
        const savedText = typeof saved.content === "string" ? saved.content : saved.content.filter(b => b.type === "text").map(b => b.text).join("\n");
        assert.equal(savedText, userPrompt, "persisted user instructions must not be rewritten");
        assert.equal(fs.existsSync(path.join(pi.dir, ".Claude Code")), false, "no upstream home symlink");
      });
    });
  }
}

for (const [name, relative] of [
  ["modular", "node_modules/@earendil-works/pi-ai/dist/auth/oauth/anthropic.js"],
  ["bundle", "dist/bundle/chunks/anthropic.js"],
]) {
  test(`${name}: login adapter preserves upstream OAuth scopes, PKCE, callback/state validation and credentials`, async () => {
    const { anthropicOAuth } = await load(relative);
    const originalCreateServer = http.createServer;
    const originalFetch = globalThis.fetch;
    const originalNow = Date.now;
    let announced;
    let exchange;
    // Exercise the complete upstream login without binding its fixed callback
    // port, opening a browser, reading credentials or calling a real endpoint.
    try {
      http.createServer = () => {
        const server = new EventEmitter();
        server.listen = (_port, _host, ready) => { server.listening = true; ready(); };
        server.closeAllConnections = () => {};
        server.close = () => { server.listening = false; };
        return server;
      };
      syncBuiltinESMExports();
      Date.now = () => 1000000;
      globalThis.fetch = async (url, init) => {
        exchange = { url, headers: init.headers, body: JSON.parse(init.body) };
        return Response.json({ access_token: "offline-access", refresh_token: "offline-refresh", expires_in: 3600 });
      };
      let badState = false;
      const input = () => {
        const auth = new URL(announced.url);
        return Promise.resolve(`${auth.searchParams.get("redirect_uri")}?code=offline-code&state=${badState ? "wrong-state" : auth.searchParams.get("state")}`);
      };
      const interaction = { notify(info) { announced = info; }, prompt: input };
      const upstream = await oracleAuth.loginAnthropic({ onAuth: interaction.notify, onPrompt: input, onManualCodeInput: input });
      const upstreamAuth = new URL(announced.url);
      const upstreamWire = structuredClone(exchange);
      assert.deepEqual(await anthropicOAuth.login(interaction), { type: "oauth", ...upstream });
      const auth = new URL(announced.url);
      assert.equal(exchange.body.state, auth.searchParams.get("state"));
      assert.equal(createHash("sha256").update(exchange.body.code_verifier).digest("base64url"), auth.searchParams.get("code_challenge"));
      for (const value of [exchange, upstreamWire]) {
        delete value.body.state;
        delete value.body.code_verifier;
      }
      for (const value of [auth, upstreamAuth]) {
        value.searchParams.delete("state");
        value.searchParams.delete("code_challenge");
      }
      assert.deepEqual(exchange, upstreamWire);
      assert.equal(auth.href, upstreamAuth.href);
      badState = true;
      exchange = undefined;
      await assert.rejects(anthropicOAuth.login(interaction), /OAuth state mismatch/);
      assert.equal(exchange, undefined, "invalid state must fail before token exchange");
    } finally {
      http.createServer = originalCreateServer;
      syncBuiltinESMExports();
      globalThis.fetch = originalFetch;
      Date.now = originalNow;
    }
  });

  test(`${name}: auth adapter uses upstream refresh semantics and retains refresh token if omitted`, async () => {
    const { anthropicOAuth } = await load(relative);
    const originalFetch = globalThis.fetch;
    const originalNow = Date.now;
    let captured;
    try {
      Date.now = () => 1000000;
      globalThis.fetch = async (url, init) => {
        captured = { url, headers: init.headers, body: JSON.parse(init.body) };
        return Response.json({ access_token: "offline-new-access", expires_in: 3600 });
      };
      const credentials = { type: "oauth", refresh: "offline-refresh", access: oauth, expires: 2000000 };
      const expected = await oracleAuth.refreshAnthropicToken(credentials);
      const expectedWire = captured;
      assert.deepEqual(await anthropicOAuth.refresh(credentials), { type: "oauth", ...expected });
      assert.deepEqual(captured, expectedWire);
      assert.equal(expected.refresh, credentials.refresh);
      assert.deepEqual(await anthropicOAuth.toAuth(credentials), { apiKey: oauth });
    } finally { globalThis.fetch = originalFetch; Date.now = originalNow; }
  });
}
