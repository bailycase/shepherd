// Offline wire checks for Shepherd's engine-level OAuth compatibility, not an opt-in extension.
// PI_PACKAGE_DIR=<patched pinned package> node --test Tests/Extensions/anthropic-oauth.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { pathToFileURL } from "node:url";
import { withPi, pkg } from "./fixtures/pi-rpc-harness.mjs";

const load = (relative) => import(pathToFileURL(path.join(pkg, relative)).href);
const { buildSystemPrompt } = await load("dist/core/system-prompt.js");
const patch = JSON.parse(fs.readFileSync(new URL("../../scripts/pi-engine-patches/skills.json", import.meta.url)));
const providers = [
  ["modular", "node_modules/@earendil-works/pi-ai/dist/api/anthropic-messages.js"],
  ["bundle", patch.files.find((f) => f.path.startsWith("dist/bundle/chunks/anthropic-messages-")).path],
];
const model = { id: "claude-sonnet-4-6", name: "fixture", api: "anthropic-messages", provider: "anthropic",
  baseUrl: "https://offline.invalid", reasoning: true, input: ["text", "image"], contextWindow: 200000, maxTokens: 8192,
  cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 } };
const oauth = "sk-ant-oat-offline-fixture";
const instructions = 'Keep /tmp/pi/project/.pi/AGENTS.md and C:\\pi\\file intact. You are pi in this example.\n\nRead @earendil-works/pi-coding-agent and badlogic/pi-mono. 😀';
const tools = [{ name: "read", description: instructions, parameters: { type: "object", properties: { path: { type: "string" } }, required: ["path"] } },
  { name: "shepherd_parent_message", description: "Ask the parent", parameters: { type: "object", properties: {} } }];
const prompt = buildSystemPrompt({ cwd: "/tmp/pi/project", contextFiles: [{ path: "/tmp/pi/AGENTS.md", content: instructions }],
  appendSystemPrompt: instructions, selectedTools: ["read"], toolSnippets: { read: "Read files" } });
const transcript = (text = prompt) => ({ messages: [
  { role: "system", content: text, toolsAdded: tools, timestamp: 0 },
  { role: "user", content: instructions, timestamp: 1 },
] });

// A fetch stand-in records the SDK's real serialized request and returns an Anthropic tool stream.
// No account, auth storage, external network, or provider billing is involved.
async function request(api, { key = oauth, context = transcript(), method = "streamSimple", cacheRetention = "short", ...options } = {}) {
  let captured;
  const fetch = async (url, init) => {
    captured = { url: String(url), headers: new Headers(init.headers), body: JSON.parse(init.body) };
    const events = [
      { type: "message_start", message: { id: "fixture", model: model.id, usage: { input_tokens: 5, output_tokens: 1 } } },
      { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "call_fixture", name: key === oauth ? "Read" : "read", input: {} } },
      { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: JSON.stringify({ path: "/tmp/pi/project/.pi/AGENTS.md" }) } },
      { type: "content_block_stop", index: 0 },
      { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { output_tokens: 3 } },
      { type: "message_stop" },
    ];
    return new Response(events.map((e) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join(""), { headers: { "content-type": "text/event-stream" } });
  };
  const before = JSON.stringify(context);
  const result = await api[method](model, context, { apiKey: key, fetch, maxRetries: 0, cacheRetention, ...options }).result();
  assert.equal(result.stopReason, "toolUse", result.errorMessage);
  assert.equal(JSON.stringify(context), before, "request shaping must not mutate session history");
  assert.equal(result.content[0].name, "read", "canonical OAuth names must map back to the real tool");
  assert.deepEqual(result.content[0].arguments, { path: "/tmp/pi/project/.pi/AGENTS.md" });
  return captured;
}

function assertOAuth({ headers, body }) {
  assert.equal(headers.get("authorization"), `Bearer ${oauth}`);
  assert.equal(headers.get("x-api-key"), null);
  assert.equal(headers.get("user-agent"), "claude-cli/2.1.280 (external, cli)");
  assert.equal(headers.get("x-app"), "cli");
  assert.ok(headers.get("anthropic-beta").includes("oauth-2025-04-20"));
  assert.ok(headers.get("anthropic-beta").includes("claude-code-20250219"));
  assert.match(body.system[0].text, /^x-anthropic-billing-header: cc_version=2\.1\.280; cc_entrypoint=cli; cch=00000; cc_prompt_id=[0-9a-f-]{36}$/);
  assert.equal(body.system[1].text, "You are a Claude agent, built on Anthropic's Claude Agent SDK.");
  assert.equal(body.system[0].cache_control, undefined);
  assert.equal(body.system[1].cache_control, undefined);
}

for (const [name, relative] of providers) {
  const api = await load(relative);
  test(`${name}: OAuth headers, billing order, path-safe shaping, tools and reasoning use the existing provider`, async () => {
    const wire = await request(api, { reasoning: "high" });
    assertOAuth(wire);
    const text = wire.body.system[2].text;
    assert.ok(text.startsWith("You are an expert coding assistant. You help users"));
    assert.ok(text.includes("Agent harness documentation"));
    assert.ok(text.includes(instructions), "real instructions and package references must survive");
    assert.ok(text.includes(`/tmp/pi/AGENTS.md`));
    // Every absolute documentation path remains byte-for-byte usable.
    for (const line of prompt.split("\n").filter((line) => /^- (Main documentation|Additional docs|Examples):/.test(line))) assert.ok(text.includes(line));
    assert.deepEqual(wire.body.system[2].cache_control, { type: "ephemeral" });
    assert.deepEqual(wire.body.tools.map((t) => t.name), ["Read", "shepherd_parent_message"]);
    assert.equal(wire.body.tools[0].description, instructions);
    assert.equal(wire.body.messages[0].content[0].text, instructions);
    assert.equal(wire.body.thinking.type, "enabled");
    assert.ok(wire.body.thinking.budget_tokens >= 1024);
    assert.equal(wire.body.model, model.id);
    const again = await request(api);
    assert.notEqual(wire.body.system[0].text, again.body.system[0].text, "fresh prompt ID for each model call");
    const trickyPath = "/tmp/pi packages (docs/packages.md)/- When reading pi docs or examples,/README.md";
    const withPath = prompt.replace(/- Main documentation: [^\n]+/, `- Main documentation: ${trickyPath}`);
    const tricky = await request(api, { context: transcript(withPath) });
    assert.ok(tricky.body.system[2].text.includes(trickyPath), "documentation prose rewrites must never rewrite a path");
  });

  test(`${name}: custom/empty prompts, system updates and all cache policies survive OAuth`, async () => {
    for (const cacheRetention of ["none", "short", "long"]) {
      const custom = await request(api, { context: transcript(instructions), method: "stream", cacheRetention });
      assertOAuth(custom);
      assert.equal(custom.body.system[2].text, instructions);
      assert.deepEqual(custom.body.system[2].cache_control, cacheRetention === "none" ? undefined : { type: "ephemeral", ...(cacheRetention === "long" ? { ttl: "1h" } : {}) });
    }
    const empty = await request(api, { context: transcript("") });
    assertOAuth(empty);
    assert.equal(empty.body.system.length, 2);
    const context = transcript(instructions);
    context.messages.push({ role: "system", content: "Keep later /tmp/pi/context too", timestamp: 2 });
    const updated = await request(api, { context });
    assert.ok(updated.body.system[2].text.includes("Keep later /tmp/pi/context too"));
  });

  test(`${name}: API-key requests keep upstream auth, prompts, tool names and caching`, async () => {
    for (const method of ["stream", "streamSimple"]) {
      const { headers, body } = await request(api, { key: "sk-ant-api-offline-fixture", method });
      assert.equal(headers.get("authorization"), null);
      assert.equal(headers.get("x-api-key"), "sk-ant-api-offline-fixture");
      assert.notEqual(headers.get("x-app"), "cli");
      assert.doesNotMatch(headers.get("user-agent"), /claude-cli/);
      assert.doesNotMatch(headers.get("anthropic-beta") ?? "", /oauth|claude-code/);
      assert.deepEqual(body.system, [{ type: "text", text: prompt, cache_control: { type: "ephemeral" } }]);
      assert.deepEqual(body.tools.map((t) => t.name), ["read", "shepherd_parent_message"]);
    }
  });
}

for (const entrypoint of ["dist/cli.js", "dist/bundle/cli.js"]) {
  test(`${entrypoint}: real RPC launches get compatibility automatically with extensions disabled`, async (t) => {
    await withPi(t, { entrypoint, args: ["-ne", "-ns", "-np", "--model", `anthropic/${model.id}`], project(dir) {
      const file = path.join(dir, "home/models.json");
      const models = JSON.parse(fs.readFileSync(file));
      models.providers.anthropic = { baseUrl: models.providers.fixture.baseUrl, models: [{ ...model, baseUrl: models.providers.fixture.baseUrl }] };
      fs.writeFileSync(file, JSON.stringify(models));
      fs.writeFileSync(path.join(dir, "home/auth.json"), JSON.stringify({ anthropic: {
        type: "oauth", access: oauth, refresh: "offline-refresh-fixture", expires: Date.now() + 3600000,
      } }));
    } }, async (pi) => {
      const turn = await pi.prompt(instructions);
      assert.equal(turn.reply.success, true);
      assert.equal(turn.requests.length, 1);
      const wire = pi.provider.requests[0];
      assertOAuth({ headers: new Headers(wire.headers), body: wire.body });
      assert.ok(wire.body.system[2].text.startsWith("You are an expert coding assistant. You help users"));
      assert.ok(wire.body.messages[0].content[0].text.includes(instructions));
    });
  });
}
