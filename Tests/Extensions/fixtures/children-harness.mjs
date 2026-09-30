// Shared by the native-children tests that start real helper pis against a local fake provider:
// the children extension under a stand-in pi API (so the test reads every tool call and event), a
// scratch pi home, and an OpenAI-compatible server that answers from a function. No model call is made.
import * as fs from "node:fs";
import * as http from "node:http";
import * as os from "node:os";
import * as path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
// pi's package, named: never a `pi` looked up on PATH.
export const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to pi's package");
const require = createRequire(path.join(pkg, "package.json"));
const { createJiti } = require("jiti");
export const jiti = createJiti(import.meta.url, { alias: {
  "@earendil-works/pi-coding-agent": path.join(pkg, "dist/index.js"),
  "@earendil-works/pi-tui": path.join(pkg, "node_modules/@earendil-works/pi-tui/dist/index.js"),
  "@earendil-works/pi-ai": path.join(pkg, "node_modules/@earendil-works/pi-ai/dist/index.js"),
  typebox: path.join(pkg, "node_modules/typebox/build/index.mjs"),
} });
export const childrenSource = path.join(root, "Extensions/shepherd-children.ts");
export const children = await jiti.import(childrenSource);
export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
export async function until(fn, timeout = 20000) {
  const end = Date.now() + timeout;
  while (!await fn()) { if (Date.now() > end) throw Error("Timed out waiting for condition"); await sleep(25); }
}

/** Runs `body` with these environment variables set (undefined removes one), then puts every key back. */
export async function withEnv(values, body) {
  const saved = Object.fromEntries(Object.keys(values).map((key) => [key, process.env[key]]));
  for (const [key, value] of Object.entries(values)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
  try { return await body(); }
  finally { for (const [key, value] of Object.entries(saved)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; } }
}

export const modelEntry = (id) => ({ id, name: id, reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } });

/**
 * An OpenAI-compatible chat server. `respond({ body, text, last, request })` answers each request with
 * `{ text }` or `{ toolCalls: [{ name, args }] }` (or a promise of one). Every request is recorded.
 */
export function providerServer(respond) {
  const requests = [];
  const server = http.createServer(async (request, response) => {
    let raw = "";
    for await (const chunk of request) raw += chunk;
    let body = {};
    try { body = JSON.parse(raw); } catch { /* recorded as empty */ }
    requests.push({ url: request.url, headers: request.headers, body });
    const last = body.messages?.at(-1) ?? {};
    const text = typeof last.content === "string" ? last.content : (last.content ?? []).map((part) => part.text ?? "").join("\n");
    const answer = await respond({ body, text, last, request });
    const say = (delta, finish) => {
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.write(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 1, model: body.model, choices: [{ index: 0, delta, finish_reason: null }] })}\n\n`);
      response.end(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: finish }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } })}\n\ndata: [DONE]\n\n`);
    };
    if (answer.toolCalls) {
      say({ tool_calls: answer.toolCalls.map((call, index) => ({ index, id: call.id ?? `call-${requests.length}-${index}`, type: "function",
        function: { name: call.name, arguments: JSON.stringify(call.args ?? {}) } })) }, "tool_calls");
    } else {
      say({ content: answer.text ?? "ok" }, "stop");
    }
  });
  return {
    server, requests,
    listen: () => new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port))),
    close: () => new Promise((resolve) => { server.closeAllConnections?.(); server.close(resolve); }),
  };
}

/** A scratch pi home with a models.json naming one OpenAI-compatible provider. */
export function scratchHome(dir, { provider = "fixture", port, models = ["fixture"] } = {}) {
  const home = path.join(dir, "config");
  fs.mkdirSync(home, { recursive: true });
  if (port) {
    fs.writeFileSync(path.join(home, "models.json"), JSON.stringify({ providers: { [provider]: {
      baseUrl: `http://127.0.0.1:${port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret", models: models.map(modelEntry),
    } } }));
  }
  return home;
}

/** What Shepherd's pi home holds for the managed CLIProxyAPI provider: the extension, and its connection file. */
export function installManagedProvider(home, { baseURL, models, apiKey = "fixture-key", enabled = true } = {}) {
  fs.copyFileSync(path.join(root, "Extensions/shepherd-cliproxyapi.ts"), path.join(home, "shepherd-cliproxyapi.ts"));
  if (baseURL) fs.writeFileSync(path.join(home, "shepherd-cliproxyapi.json"), JSON.stringify({ enabled, baseURL, apiKey, updatedAt: 1, models: models.map((id) => ({ id })) }));
}

/**
 * The children extension loaded into a stand-in pi, as a parent would. The caller has set the parent's
 * environment (SHEPHERD_NATIVE_CHILDREN, SHEPHERD_AGENT_ID, SHEPHERD_SOCKET, SHEPHERD_EXT_CHILDREN,
 * PI_CODING_AGENT_DIR, HOME). `models` is the parent's model registry.
 */
export async function harness(dir, { models = [{ provider: "fixture", id: "fixture" }], entries = [], extra } = {}) {
  const tools = new Map(), commands = new Map(), events = new Map(), messages = [], projections = [];
  const bus = new Map();
  const activeTools = ["read", "grep", "find", "ls", "bash", "edit", "write"];
  const pi = {
    registerCommand(name, command) { commands.set(name, command); }, registerEntryRenderer() {},
    getCommands: () => [...commands.keys()].map((name) => ({ name })), getAllTools: () => [...tools.values()],
    registerTool(tool) { tools.set(tool.name, tool); },
    on(name, handler) { events.set(name, handler); },
    events: { on(name, fn) { bus.set(name, fn); return () => bus.delete(name); }, emit(name, data) { projections.push(data); bus.get(name)?.(data); } },
    getActiveTools: () => [...activeTools, ...(extra?.activeTools ?? [])], appendEntry: (customType, data) => entries.push({ type: "custom", customType, data }),
    sendMessage: (message, options) => messages.push({ message, options }),
  };
  const ctx = { cwd: dir, thinkingLevel: "off", model: models[0], modelRegistry: { getAll: () => models },
    sessionManager: { getSessionId: () => "parent-fixture", getEntries: () => entries, getBranch: () => [], getSessionFile: () => undefined },
    isProjectTrusted: () => true };
  extra?.install?.(pi);
  children.default(pi);
  await events.get("session_start")({}, ctx);
  return { tools, commands, events, messages, projections, entries, ctx, pi,
    call: async (name, params, signal) => (await tools.get(`shepherd_child_${name}`).execute("call", params, signal, undefined, ctx)).details,
    shutdown: () => events.get("session_shutdown")() };
}

export const tempDir = (label) => fs.mkdtempSync(path.join(os.tmpdir(), `sh-${label}-`));
