// The service tier extension (the composer's Speed control) against pi's real runtime: the body pi
// sends for each API Shepherd can use, with the tier on Fast and on Standard, and what pi's
// `before_provider_request` hook does (order, replacement, a handler that throws).
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/service-tier.test.mjs
// Everything runs in a temporary HOME against a local fake provider (fake-provider.mjs).
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { startProvider } from "./fake-provider.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const tierSource = path.join(root, "Extensions/shepherd-service-tier.ts");
const proxySource = path.join(root, "Extensions/shepherd-cliproxyapi.ts");
const { createJiti } = createRequire(path.join(pkg, "package.json"))("jiti");
const { ruleFor, tiersFor, wireValue } = await createJiti(import.meta.url).import(tierSource);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, fn, timeout = 30000) {
  const end = Date.now() + timeout;
  while (!fn()) { if (Date.now() > end) throw Error(`Timed out waiting for ${what}`); await sleep(20); }
}
const b64 = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
// What pi reads the ChatGPT account from: a token whose payload carries the claim.
const codexToken = `${b64({ alg: "none" })}.${b64({ "https://api.openai.com/auth": { chatgpt_account_id: "acct_fixture" } })}.sig`;
const COST = { input: 0.2, output: 0.75, cacheRead: 0, cacheWrite: 0 };

// MARK: the table

const table = JSON.parse(fs.readFileSync(path.join(here, "service-tier-support.json"), "utf8")).rows;

test("the extension's support table is the one Swift's ServiceTierSupport is tested against", () => {
  assert.ok(table.length >= 40);
  for (const row of table) {
    const model = { provider: row.provider, api: row.api, id: row.id, ownedBy: row.ownedBy };
    const label = `${row.provider} ${row.api} ${row.id} owner ${row.ownedBy}`;
    assert.deepEqual(tiersFor(model), row.tiers, label);
    assert.equal(wireValue("fast", model), row.fast ?? undefined, label);
    assert.equal(wireValue("standard", model), undefined, `${label}: Standard sends nothing`);
  }
  assert.equal(ruleFor({ provider: "anthropic", api: "anthropic-messages", id: "claude-opus-5" }), undefined);
});

// MARK: pi, for real

// pi in RPC mode with the tier extension on a fake provider. `models` is models.json's providers; `model` is what
// --model takes; `tier` is what the agent's tier file holds (null: no file).
async function startPi(t, { providers, model, tier = "fast", extensions = [], tierFirst = false, proxy, env = {}, settings = {}, inert = false }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-tier-"));
  const config = path.join(dir, "config");
  fs.mkdirSync(config);
  fs.writeFileSync(path.join(config, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false }, transport: "sse", ...settings }));
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers }));
  const tierFile = path.join(dir, "tier.json");
  const setTier = (value) => fs.writeFileSync(tierFile, typeof value === "string" && value.startsWith("{") ? value : JSON.stringify({ tier: value }));
  if (tier !== null) setTier(tier);
  const args = [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--session-dir", path.join(dir, "sessions"), "-ne", "-ns", "-np", "--model", model];
  const extra = {};
  if (proxy) {
    const file = path.join(dir, "proxy.json");
    fs.writeFileSync(file, JSON.stringify({ enabled: true, apiKey: "fixture-key", updatedAt: 1, ...proxy }));
    extra.SHEPHERD_CLIPROXYAPI_CONFIG = file;
    args.push("-e", proxySource);
  }
  if (tierFirst) args.push("-e", tierSource);
  for (const source of extensions) args.push("-e", source);
  if (!tierFirst) args.push("-e", tierSource);
  const child = spawn(process.execPath, args, { cwd: dir, stdio: ["pipe", "pipe", "pipe"],
    env: { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0",
      ...(inert ? {} : { SHEPHERD_EXT_SERVICE_TIER: tierFile }), ...extra, ...env } });
  const events = [];
  let out = "", err = "", next = 0;
  child.stdout.on("data", (chunk) => {
    out += chunk;
    for (let nl; (nl = out.indexOf("\n")) >= 0; out = out.slice(nl + 1)) { try { events.push(JSON.parse(out.slice(0, nl))); } catch {} }
  });
  child.stderr.on("data", (chunk) => { err += chunk; });
  child.stdin.on("error", () => {});
  const exited = new Promise((resolve) => child.once("exit", resolve));
  const pi = {
    dir, events, setTier, tierFile,
    get stderr() { return err; },
    settled: () => events.filter((e) => e.type === "agent_settled").length,
    async request(command) {
      const id = `r${++next}`;
      child.stdin.write(JSON.stringify({ id, ...command }) + "\n");
      await until(`the answer to ${command.type}`, () => events.some((e) => e.type === "response" && e.id === id));
      return events.find((e) => e.type === "response" && e.id === id);
    },
    // Sends a prompt and waits for the turn to settle.
    async turn(message = "hi") {
      const before = pi.settled();
      assert.equal((await pi.request({ type: "prompt", message })).success, true);
      await until("the turn to settle", () => pi.settled() === before + 1);
    },
    async lastCost() {
      const messages = (await pi.request({ type: "get_messages" })).data.messages;
      return messages.filter((m) => m.role === "assistant").at(-1)?.usage?.cost?.total;
    },
    async stop() {
      child.kill();
      await exited;
    },
  };
  t.after(async () => { await pi.stop(); fs.rmSync(dir, { recursive: true, force: true }); });
  return pi;
}

async function provider(t, options) {
  const fake = await startProvider(options);
  t.after(() => fake.stop());
  return fake;
}

const tierOf = (request) => request.body?.service_tier;
const hasTier = (request) => request.body && "service_tier" in request.body;

// A fixture model on a built-in provider's own name, so the table's provider check sees what a signed-in user would.
const gpt = { id: "gpt-6-luna", name: "gpt-6-luna", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024, cost: COST };

test("OpenAI Responses: Fast puts service_tier priority in the body pi sends, Standard leaves it out", { timeout: 120000 }, async (t) => {
  const fake = await provider(t);
  const pi = await startPi(t, { providers: { openai: { baseUrl: `http://127.0.0.1:${fake.port}/v1`, apiKey: "fixture-not-secret", api: "openai-responses", models: [gpt] } },
    model: "openai/gpt-6-luna", tier: "standard" });
  await pi.turn();
  await pi.turn();
  assert.equal(fake.requests.length, 2);
  assert.equal(fake.requests[0].path, "/v1/responses");
  assert.ok(Array.isArray(fake.requests[0].body.input), "a Responses body");
  assert.ok(!hasTier(fake.requests[0]), "Standard: the field is absent, not null");
  pi.setTier("fast");
  await pi.turn();
  assert.equal(tierOf(fake.requests[2]), "priority");
  assert.ok(!pi.events.some((e) => e.type === "extension_error"), JSON.stringify(pi.events.filter((e) => e.type === "extension_error")));
});

test("OpenAI Chat Completions: the same field in the same place", { timeout: 120000 }, async (t) => {
  const fake = await provider(t);
  const pi = await startPi(t, { providers: { openai: { baseUrl: `http://127.0.0.1:${fake.port}/v1`, apiKey: "fixture-not-secret", api: "openai-completions", models: [{ ...gpt, id: "gpt-4o", name: "gpt-4o" }] } },
    model: "openai/gpt-4o", tier: "fast" });
  await pi.turn();
  assert.equal(fake.requests[0].path, "/v1/chat/completions");
  assert.ok(Array.isArray(fake.requests[0].body.messages), "a Chat Completions body");
  assert.equal(tierOf(fake.requests[0]), "priority");
  pi.setTier("standard");
  await pi.turn();
  assert.ok(!hasTier(fake.requests[1]));
});

test("the Codex backend's API: the body reaches /codex/responses with service_tier priority, and Standard without it", { timeout: 120000 }, async (t) => {
  const fake = await provider(t);
  const pi = await startPi(t, { providers: { "openai-codex": { baseUrl: `http://127.0.0.1:${fake.port}/backend-api`, apiKey: codexToken } },
    model: "openai-codex/gpt-6-luna", tier: "fast" });
  await pi.turn();
  const [request] = fake.requests;
  assert.equal(request.path, "/backend-api/codex/responses");
  assert.equal(request.headers["chatgpt-account-id"], "acct_fixture", "pi's own Codex request, through its own provider");
  assert.equal(request.body.model, "gpt-6-luna");
  assert.equal(request.body.stream, true);
  assert.equal(tierOf(request), "priority");
  pi.setTier("standard");
  await pi.turn();
  assert.ok(!hasTier(fake.requests[1]));
});

test("a Fast turn is priced at pi's priority rate because the provider reports the tier it used", { timeout: 120000 }, async (t) => {
  const fake = await provider(t);
  const pi = await startPi(t, { providers: { openai: { baseUrl: `http://127.0.0.1:${fake.port}/v1`, apiKey: "fixture-not-secret", api: "openai-responses", models: [gpt] } },
    model: "openai/gpt-6-luna", tier: "standard" });
  await pi.turn();
  const standard = await pi.lastCost();
  pi.setTier("fast");
  await pi.turn();
  const fast = await pi.lastCost();
  assert.ok(standard > 0);
  assert.ok(Math.abs(fast / standard - 2) < 1e-9, `priority costs twice Standard in pi (${standard} -> ${fast})`);
});

test("Anthropic, other providers and models the table leaves out are never touched, whatever the file says", { timeout: 180000 }, async (t) => {
  const cases = [
    { name: "anthropic", path: "/v1/messages", providers: (port) => ({ anthropic: { baseUrl: `http://127.0.0.1:${port}`, apiKey: "fixture-not-secret", api: "anthropic-messages",
        models: [{ id: "claude-opus-5", name: "claude-opus-5", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024, cost: COST }] } }), model: "anthropic/claude-opus-5" },
    { name: "a provider the table does not list", path: "/v1/chat/completions", providers: (port) => ({ fixture: { baseUrl: `http://127.0.0.1:${port}/v1`, apiKey: "fixture-not-secret", api: "openai-completions",
        models: [{ ...gpt, id: "gpt-6-luna" }] } }), model: "fixture/gpt-6-luna" },
    { name: "an OpenAI model that is not a chat model", path: "/v1/responses", providers: (port) => ({ openai: { baseUrl: `http://127.0.0.1:${port}/v1`, apiKey: "fixture-not-secret", api: "openai-responses",
        models: [{ ...gpt, id: "gpt-realtime-2.1" }] } }), model: "openai/gpt-realtime-2.1" },
    { name: "OpenAI's API named for another provider", path: "/v1/responses", providers: (port) => ({ xai: { baseUrl: `http://127.0.0.1:${port}/v1`, apiKey: "fixture-not-secret", api: "openai-responses",
        models: [{ ...gpt, id: "gpt-6-luna" }] } }), model: "xai/gpt-6-luna" },
  ];
  for (const item of cases) {
    const fake = await startProvider();
    const pi = await startPi(t, { providers: item.providers(fake.port), model: item.model, tier: "fast" });
    try {
      await pi.turn();
      assert.equal(fake.requests.length, 1, item.name);
      assert.equal(fake.requests[0].path.split("?")[0], item.path, item.name);
      assert.ok(!hasTier(fake.requests[0]), `${item.name}: ${JSON.stringify(fake.requests[0].body)}`);
    } finally {
      await pi.stop();
      await fake.stop();
    }
  }
});

test("without its variable the extension does nothing, and a missing, broken or unknown tier file is Standard", { timeout: 180000 }, async (t) => {
  const setups = [
    { name: "no variable", options: { inert: true, tier: "fast" } },
    { name: "no file", options: { tier: null } },
    { name: "a file that isn't JSON", options: { tier: "fast but not JSON" } },
    { name: "a tier from a newer Shepherd", options: { tier: "ultrafast" } },
    { name: "a file of the wrong shape", options: { tier: "[1,2]" } },
  ];
  for (const { name, options } of setups) {
    const fake = await startProvider();
    const pi = await startPi(t, { providers: { openai: { baseUrl: `http://127.0.0.1:${fake.port}/v1`, apiKey: "fixture-not-secret", api: "openai-responses", models: [gpt] } },
      model: "openai/gpt-6-luna", ...options });
    try {
      await pi.turn();
      assert.ok(!hasTier(fake.requests[0]), name);
      assert.ok(!pi.events.some((e) => e.type === "extension_error"), name);
    } finally {
      await pi.stop();
      await fake.stop();
    }
  }
});

test("a change applies to the next model call, even inside a turn, and never to the request in flight", { timeout: 180000 }, async (t) => {
  // Chat Completions, so the turn is a tool call and then the answer: two requests for one prompt.
  const tierFileOf = {};
  const fake = await provider(t, {
    onRequest: (request) => {
      // The first request of each turn runs a command; the file changes while it is in flight.
      if (request.index === 0) { tierFileOf.pi.setTier("fast"); return { call: "echo hi" }; }
      if (request.index === 2) { tierFileOf.pi.setTier("standard"); return { call: "echo hi" }; }
      return {};
    },
  });
  const pi = await startPi(t, { providers: { openai: { baseUrl: `http://127.0.0.1:${fake.port}/v1`, apiKey: "fixture-not-secret", api: "openai-completions",
    models: [{ ...gpt, id: "gpt-4o" }] } }, model: "openai/gpt-4o", tier: "standard" });
  tierFileOf.pi = pi;
  await pi.turn("run it");
  assert.equal(fake.requests.length, 2, "a tool call and its answer");
  assert.ok(!hasTier(fake.requests[0]), "the request already in flight when the file changed is unchanged");
  assert.equal(tierOf(fake.requests[1]), "priority", "the next call of the same turn carries it");
  await pi.turn("again");
  assert.equal(fake.requests.length, 4);
  assert.equal(tierOf(fake.requests[2]), "priority", "a new turn starts on the tier the file holds");
  assert.ok(!hasTier(fake.requests[3]), "and Standard again takes it back off");
});

test("a pi started later reads the file at once: nothing to hand over, and a change needs no reconnect", { timeout: 120000 }, async (t) => {
  const fake = await provider(t);
  const providers = { openai: { baseUrl: `http://127.0.0.1:${fake.port}/v1`, apiKey: "fixture-not-secret", api: "openai-responses", models: [gpt] } };
  const first = await startPi(t, { providers, model: "openai/gpt-6-luna", tier: "fast" });
  await first.turn();
  await first.stop();
  assert.equal(tierOf(fake.requests[0]), "priority");
  // A relaunch, or Retry's new pi, is another process reading the same file.
  const second = await startPi(t, { providers, model: "openai/gpt-6-luna", tier: "fast" });
  await second.turn();
  assert.equal(tierOf(fake.requests[1]), "priority");
});

// MARK: CLIProxyAPI, the managed provider

const proxy = (port, models) => ({ baseURL: `http://127.0.0.1:${port}/v1`, models });

test("the managed CLIProxyAPI provider: Fast reaches an OpenAI model's body and its own payload rewriting still runs", { timeout: 120000 }, async (t) => {
  const fake = await provider(t);
  const pi = await startPi(t, { providers: {}, model: "cliproxyapi/gpt-6-sol", tier: "fast",
    proxy: proxy(fake.port, [{ id: "gpt-6-sol", owned_by: "openai" }, { id: "claude-opus-5", owned_by: "anthropic" }]) });
  await pi.turn();
  const [request] = fake.requests;
  assert.equal(request.path, "/v1/responses", "the proxy's Responses route");
  assert.equal(tierOf(request), "priority");
  assert.equal(request.headers.authorization, "Bearer fixture-key", "the provider's own auth is untouched");
  const functions = request.body.tools.filter((tool) => tool.type === "function");
  assert.ok(functions.length > 0);
  assert.ok(functions.every((tool) => tool.strict === null), "the provider's strict:null rewrite ran after the tier was added");
  pi.setTier("standard");
  await pi.turn();
  assert.ok(!hasTier(fake.requests[1]));
  assert.ok(fake.requests[1].body.tools.filter((tool) => tool.type === "function").every((tool) => tool.strict === null), "and still runs without it");
});

test("CLIProxyAPI models the table leaves out get nothing: another owner, and a chat-completions route", { timeout: 180000 }, async (t) => {
  const models = [{ id: "gpt-6-sol", owned_by: "openai" }, { id: "claude-opus-5", owned_by: "anthropic" },
    { id: "gpt-oss-120b-medium", owned_by: "antigravity" }, { id: "gpt-not-in-pis-catalog-9", owned_by: "openai" }];
  for (const [id, path] of [["claude-opus-5", "/v1/chat/completions"], ["gpt-oss-120b-medium", "/v1/chat/completions"], ["gpt-not-in-pis-catalog-9", "/v1/chat/completions"]]) {
    const fake = await startProvider();
    const pi = await startPi(t, { providers: {}, model: `cliproxyapi/${id}`, tier: "fast", proxy: proxy(fake.port, models) });
    try {
      await pi.turn();
      assert.equal(fake.requests[0].path, path, id);
      assert.ok(!hasTier(fake.requests[0]), `${id}: ${JSON.stringify(Object.keys(fake.requests[0].body))}`);
    } finally {
      await pi.stop();
      await fake.stop();
    }
  }
});

// MARK: pi's hook

// A test extension recording what each handler saw and returning what `mode` says.
function recorder(dir, name, body) {
  const file = path.join(dir, `${name}.ts`);
  fs.writeFileSync(file, `import * as fs from "node:fs";
export default function (pi: any) {
  pi.on("before_provider_request", (event: any, ctx: any) => {
    fs.appendFileSync(${JSON.stringify(path.join(dir, "hook.log"))}, JSON.stringify({ name: ${JSON.stringify(name)}, keys: Object.keys(event.payload ?? {}), type: event.type, model: ctx.model?.id, api: ctx.model?.api, provider: ctx.model?.provider, tier: event.payload?.service_tier, marks: event.payload?.marks }) + "\\n");
${body}
  });
}
`);
  return file;
}

test("pi's before_provider_request: handlers run in load order on each other's result, what the last returns is the body on the wire, and a handler that throws changes nothing", { timeout: 120000 }, async (t) => {
  const fake = await provider(t);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-tier-hooks-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const first = recorder(dir, "first", `    return { ...event.payload, marks: ["first"] };`);
  const throwing = recorder(dir, "throwing", `    throw new Error("a handler that fails");`);
  const nothing = recorder(dir, "nothing", `    return undefined;`);
  const last = recorder(dir, "last", `    return { ...event.payload, marks: [...(event.payload.marks ?? []), "last"] };`);
  const pi = await startPi(t, { providers: { openai: { baseUrl: `http://127.0.0.1:${fake.port}/v1`, apiKey: "fixture-not-secret", api: "openai-responses", models: [gpt] } },
    model: "openai/gpt-6-luna", tier: "fast", extensions: [first, throwing, nothing, last] });
  await pi.turn();
  const log = fs.readFileSync(path.join(dir, "hook.log"), "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(log.map((entry) => entry.name), ["first", "throwing", "nothing", "last"], "extensions run in the order they load");
  assert.ok(log.every((entry) => entry.type === "before_provider_request" && entry.provider === "openai" && entry.api === "openai-responses" && entry.model === "gpt-6-luna"),
    "each handler is told the current model through its context, and the event carries only the payload");
  assert.equal(log[0].marks, undefined);
  assert.deepEqual(log[2].marks, ["first"], "a thrown error and an undefined result leave the last good payload");
  assert.deepEqual(log[3].marks, ["first"]);
  assert.ok(log[0].keys.includes("input") && log[0].keys.includes("model") && log[0].keys.includes("stream"), "the payload is the request body before it is sent");
  assert.deepEqual(fake.requests[0].body.marks, ["first", "last"], "the last result is the body on the wire");
  assert.equal(tierOf(fake.requests[0]), "priority", "the tier extension loaded after them all, and saw and kept their result");
  const errors = pi.events.filter((e) => e.type === "extension_error");
  assert.equal(errors.length, 1, "pi reports the failure and goes on");
  assert.equal(errors[0].event, "before_provider_request");
  assert.match(errors[0].error, /a handler that fails/);
});

test("the tier extension adds its field whichever side of another request handler it loads", { timeout: 120000 }, async (t) => {
  const providers = (port) => ({ openai: { baseUrl: `http://127.0.0.1:${port}/v1`, apiKey: "fixture-not-secret", api: "openai-responses", models: [gpt] } });
  for (const tierFirst of [true, false]) {
    const fake = await startProvider();
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-tier-order-"));
    const other = recorder(dir, "other", `    return { ...event.payload, marks: ["other"] };`);
    const pi = await startPi(t, { providers: providers(fake.port), model: "openai/gpt-6-luna", tier: "fast", extensions: [other], tierFirst });
    try {
      await pi.turn();
      const [seen] = fs.readFileSync(path.join(dir, "hook.log"), "utf8").trim().split("\n").map((line) => JSON.parse(line));
      assert.equal(seen.tier, tierFirst ? "priority" : undefined, tierFirst ? "a handler loaded after it sees the field" : "a handler loaded before it sees no field yet");
      assert.equal(tierOf(fake.requests[0]), "priority", `tier extension first: ${tierFirst}`);
      assert.deepEqual(fake.requests[0].body.marks, ["other"], "and the other handler's change is on the wire too");
    } finally {
      await pi.stop();
      await fake.stop();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }
});
