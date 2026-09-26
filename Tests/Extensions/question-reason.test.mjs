// The status extension's short reason for an asking tool ("retention?"), which Shepherd's
// sidebar shows beside a thread waiting on you.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/question-reason.test.mjs
// Everything runs in a temporary HOME against a local fake provider.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as http from "node:http";
import * as net from "node:net";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const require = createRequire(path.join(pkg, "package.json"));
const { createJiti } = require("jiti");
const jiti = createJiti(import.meta.url, { alias: {
  "@earendil-works/pi-coding-agent": path.join(pkg, "dist/index.js"),
  typebox: path.join(pkg, "node_modules/typebox/build/index.mjs"),
} });
const { Type } = await jiti.import("typebox");
const statusSource = path.join(root, "Extensions/shepherd-status.ts");
const { default: install } = await jiti.import(statusSource);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, fn, timeout = 30000) {
  const end = Date.now() + timeout;
  while (!fn()) { if (Date.now() > end) throw Error(`Timed out waiting for ${what}`); await sleep(20); }
}

// A stand-in for pi's extension API: the handlers the extension registers and the tools it sees.
function fakePi(tools) {
  const handlers = new Map();
  return {
    handlers,
    on(event, handler) { handlers.set(event, [...(handlers.get(event) ?? []), handler]); return () => {}; },
    getAllTools: () => tools.map(({ name, parameters }) => ({ name, parameters })),
    async fire(event, payload = {}) {
      for (const handler of handlers.get(event) ?? []) await handler(payload, { sessionManager: { getSessionId: () => "s" } });
    },
  };
}

async function withEnvironment(env, body) {
  const saved = { ...process.env };
  Object.assign(process.env, env);
  try { return await body(); } finally {
    for (const key of Object.keys(env)) delete process.env[key];
    Object.assign(process.env, saved);
  }
}

test("asking tools get an optional short reason; others and tools with their own keep theirs", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-reason-"));
  const ask = { name: "ask_user", parameters: Type.Object({ question: Type.String() }) };
  const strict = { name: "question", parameters: Type.Object({ question: Type.String() }, { additionalProperties: false }) };
  const own = { name: "human.ask", parameters: Type.Object({ question: Type.String(), short: Type.Boolean() }) };
  const read = { name: "read", parameters: Type.Object({ path: Type.String() }) };
  const late = { name: "late_question", parameters: Type.Object({ question: Type.String() }) };
  const tools = [ask, strict, own, read];
  const pi = fakePi(tools);
  await withEnvironment({ SHEPHERD_AGENT_ID: "a", SHEPHERD_SOCKET: path.join(dir, "absent.sock") }, async () => {
    install(pi);
    await pi.fire("session_start");
    try {
      for (const tool of [ask, strict]) {
        assert.equal(tool.parameters.properties.short.type, "string");
        assert.match(tool.parameters.properties.short.description, /1-3 words/);
        assert(!(tool.parameters.required ?? []).includes("short"), "optional");
      }
      assert.equal(own.parameters.properties.short.type, "boolean", "a tool's own short stays its own");
      assert.equal(read.parameters.properties.short, undefined, "only asking tools are offered one");

      // The asking tool never receives the short Shepherd added; one with its own keeps it.
      const input = { question: "Retention?", short: "retention?" };
      await pi.fire("tool_call", { toolName: "ask_user", toolCallId: "1", input });
      assert.deepEqual(input, { question: "Retention?" });
      const ownInput = { question: "Retention?", short: true };
      await pi.fire("tool_call", { toolName: "human.ask", toolCallId: "2", input: ownInput });
      assert.deepEqual(ownInput, { question: "Retention?", short: true });

      // A tool registered later is covered before the next prompt, and offering twice adds nothing.
      tools.push(late);
      await pi.fire("before_agent_start");
      await pi.fire("before_agent_start");
      assert.equal(late.parameters.properties.short.type, "string");
      assert.deepEqual(Object.keys(ask.parameters.properties), ["question", "short"]);
    } finally {
      await pi.fire("session_shutdown");
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});

test("outside Shepherd the extension is inert and touches no tool", async () => {
  const ask = { name: "ask_user", parameters: Type.Object({ question: Type.String() }) };
  const pi = fakePi([ask]);
  await withEnvironment({ SHEPHERD_AGENT_ID: "", SHEPHERD_SOCKET: "" }, () => install(pi));
  assert.equal(pi.handlers.size, 0);
  assert.equal(ask.parameters.properties.short, undefined);
});

// Real pi in RPC mode: the model sees `short` on a strict asking tool, pi accepts the call, the
// call's arguments on the wire carry it (Shepherd reads them there), and the tool never gets it.
test("real Pi RPC: a strict asking tool's call carries short to the host and not to the tool", { timeout: 120000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-reason-pi-"));
  const requests = [];
  const server = http.createServer(async (req, res) => {
    let raw = ""; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw); requests.push(body);
    const last = body.messages.at(-1);
    const delta = last.role === "tool" ? { content: "Noted." } : { tool_calls: [{ index: 0, id: "ask-call", type: "function", function: {
      name: "ask_user", arguments: JSON.stringify({ question: "Retention: 30 days or 13 months?", short: "retention?" }) } }] };
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(`data: ${JSON.stringify({ id: "f", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta, finish_reason: null }] })}\n\n`);
    res.end(`data: ${JSON.stringify({ id: "f", object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: delta.tool_calls ? "tool_calls" : "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } })}\n\ndata: [DONE]\n\n`);
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const socketPath = path.join(dir, "s.sock");
  const frames = [];
  const shepherd = net.createServer((socket) => {
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      for (let nl; (nl = buffer.indexOf("\n")) >= 0; buffer = buffer.slice(nl + 1)) frames.push(JSON.parse(buffer.slice(0, nl)));
    });
    socket.on("error", () => {});
  });
  await new Promise((r) => shepherd.listen(socketPath, r));
  const config = path.join(dir, "config");
  fs.mkdirSync(config);
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: [{ id: "fixture", name: "fixture", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  const received = path.join(dir, "received.json");
  const asker = path.join(dir, "asker.ts");
  fs.writeFileSync(asker, `import * as fs from "node:fs";
    export default function (pi) {
      pi.registerTool({ name: "ask_user", label: "ask", description: "Ask the user a question.",
        parameters: { type: "object", properties: { question: { type: "string" } }, required: ["question"], additionalProperties: false },
        async execute(_id, params, _signal, _update, ctx) {
          fs.writeFileSync(${JSON.stringify(received)}, JSON.stringify(params));
          const answer = await ctx.ui.select(params.question, ["30 days", "13 months"]);
          return { content: [{ type: "text", text: "User chose " + answer }], details: undefined };
        } });
    }`);
  const env = { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1", SHEPHERD_AGENT_ID: "fixture", SHEPHERD_SOCKET: socketPath };
  const pi = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--no-session", "-ne", "-ns", "-np",
    "--model", "fixture/fixture", "-e", statusSource, "-e", asker], { cwd: dir, env, stdio: ["pipe", "pipe", "pipe"] });
  const events = [];
  let out = "", err = "";
  pi.stdout.on("data", (chunk) => {
    out += chunk;
    for (let nl; (nl = out.indexOf("\n")) >= 0; out = out.slice(nl + 1)) {
      try { events.push(JSON.parse(out.slice(0, nl))); } catch {}
    }
  });
  pi.stderr.on("data", (chunk) => { err += chunk; });
  try {
    pi.stdin.write(JSON.stringify({ type: "prompt", message: "go" }) + "\n");
    await until("the question", () => events.some((e) => e.type === "extension_ui_request" && e.method === "select"));
    const dialog = events.find((e) => e.type === "extension_ui_request" && e.method === "select");
    assert.equal(dialog.title, "Retention: 30 days or 13 months?");
    const start = events.find((e) => e.type === "tool_execution_start" && e.toolName === "ask_user");
    assert.equal(start?.args?.short, "retention?", "the host reads the reason from the call's arguments");
    assert.deepEqual(JSON.parse(fs.readFileSync(received, "utf8")), { question: "Retention: 30 days or 13 months?" }, "the tool never sees it");
    const offered = requests[0].tools.find((t) => t.function.name === "ask_user").function.parameters;
    assert.equal(offered.properties.short.type, "string");
    assert.deepEqual(offered.required, ["question"]);
    assert(requests[0].tools.filter((t) => t.function.name !== "ask_user").every((t) => !t.function.parameters?.properties?.short));
    assert(frames.some((f) => f.type === "setAgentStatus" && f.status === "blocked"));
    pi.stdin.write(JSON.stringify({ type: "extension_ui_response", id: dialog.id, value: "30 days" }) + "\n");
    await until("the turn to settle", () => events.some((e) => e.type === "agent_settled"));
    const end = events.find((e) => e.type === "tool_execution_end" && e.toolName === "ask_user");
    assert.equal(end.isError, false, `pi accepted the call: ${JSON.stringify(end.result)}`);
  } catch (error) {
    error.message += `\npi stderr:\n${err}`;
    throw error;
  } finally {
    pi.kill();
    await new Promise((r) => pi.once("exit", r));
    server.close(); shepherd.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
