// Read-only installed pinned pi, scratch HOME, loopback provider; no external credentials or APIs.
import * as fs from "node:fs";
import * as path from "node:path";
import * as http from "node:http";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed pinned Pi package");
const source = path.join(root, "Extensions/shepherd-goal.ts");
export async function until(what, fn, timeout = 15000) {
  const end = Date.now() + timeout;
  while (!fn()) {
    if (Date.now() > end) throw Error(`Timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}
const flat = (content) => typeof content === "string" ? content : (content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("\n");
export const acceptance = "All 12 acceptance tests passed.";
export const verdictCall = (payload, verdict = "met", extra = {}) => ({ name: "goal_verdict", arguments: {
  verdict, reason: "Acceptance result observed", summary: "12 acceptance tests passed", blocker: "",
  evidence: payload?.transcript.filter((e) => e.role === "toolResult").slice(-1).map((e) => ({ requirementId: "r1", entryId: e.entryId, quote: acceptance })) ?? [], ...extra,
} });
const defaultScript = (_body, { evaluator, evaluationNumber, workerNumber, payload }) => evaluator
  ? { gate: evaluationNumber === 1 ? "evaluation" : undefined, call: verdictCall(payload, evaluationNumber < 3 ? "not_met" : "met") }
  : workerNumber % 2 === 1 ? { call: { name: "read", arguments: { path: "acceptance.txt" } } } : { text: "Worker finished its check." };

export async function realPi(dir, { script = defaultScript, settings = {}, env = {}, extensions = [], contextWindow = 64000 } = {}) {
  const requests = [], gates = new Map(), disconnected = new Set();
  let evaluationNumber = 0, workerNumber = 0;
  const gate = (name) => {
    if (!gates.has(name)) { let open; const promise = new Promise((r) => { open = r; }); gates.set(name, { promise, open }); }
    return gates.get(name);
  };
  const server = http.createServer(async (req, res) => {
    let raw = ""; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw); requests.push(body);
    const requestNumber = requests.length;
    const evaluator = body.tools?.some((t) => t.function?.name === "goal_verdict");
    const payload = evaluator ? JSON.parse(flat(body.messages.filter((m) => m.role === "user").at(-1).content)) : undefined;
    if (evaluator) evaluationNumber++; else if (body.tools) workerNumber++;
    const reply = await script(body, { evaluator, payload, evaluationNumber, workerNumber, requestNumber });
    if (reply.status) { res.writeHead(reply.status, { "content-type": "application/json" }); res.end(JSON.stringify({ error: { message: reply.error ?? "Overloaded 529", type: "overloaded_error" } })); return; }
    let gone;
    const closed = new Promise((r) => { gone = r; });
    res.on("close", () => { if (!res.writableEnded) { disconnected.add(requestNumber); gone(); } });
    if (reply.headersGate) { await Promise.race([gate(reply.headersGate).promise, closed]); if (res.destroyed) return; }
    res.writeHead(200, { "content-type": "text/event-stream" }); res.flushHeaders();
    if (reply.gate) { await Promise.race([gate(reply.gate).promise, closed]); if (res.destroyed) return; }
    const call = reply.call;
    const chunk = (delta, finish = null) => ({ id: "fixture", object: "chat.completion.chunk", created: 1, model: body.model,
      choices: [{ index: 0, delta, finish_reason: finish }] });
    res.write(`data: ${JSON.stringify(chunk(call ? { tool_calls: [{ index: 0, id: `call${requestNumber}`, type: "function", function: { name: call.name, arguments: JSON.stringify(call.arguments) } }] } : { content: reply.text ?? "Worker finished its check." }))}\n\n`);
    const n = reply.tokens ?? 5;
    res.end(`data: ${JSON.stringify({ ...chunk({}, call ? "tool_calls" : "stop"), usage: { prompt_tokens: 2, completion_tokens: n - 2, total_tokens: n } })}\n\ndata: [DONE]\n\n`);
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const config = path.join(dir, "config"), sessions = path.join(dir, "sessions"); fs.mkdirSync(config);
  fs.writeFileSync(path.join(dir, "acceptance.txt"), acceptance + "\n");
  fs.writeFileSync(path.join(config, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false }, ...settings }));
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: ["worker", "small"].map((id) => ({ id, name: id, reasoning: false, input: ["text"], contextWindow, maxTokens: 2048, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } })),
  } } }));
  const child = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--session-dir", sessions,
    "-ne", "-ns", "-np", "--model", "fixture/worker", ...[source, ...extensions].flatMap((p) => ["-e", p])], { cwd: dir, stdio: ["pipe", "pipe", "pipe"], env: {
      PATH: process.env.PATH, HOME: dir, TMPDIR: dir, PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", SHEPHERD_EXT_GOAL: "1", ...env,
    } });
  const events = []; let output = "", stderr = "", counter = 0;
  child.stdout.on("data", (chunk) => {
    output += chunk;
    for (let nl; (nl = output.indexOf("\n")) >= 0; output = output.slice(nl + 1)) { try { events.push(JSON.parse(output.slice(0, nl))); } catch { } }
  });
  child.stderr.on("data", (chunk) => { stderr += chunk; }); child.stdin.on("error", () => {});
  const pi = { events, requests, sessions, disconnected,
    get stderr() { return stderr; },
    goal: () => {
      const widget = events.filter((e) => e.type === "extension_ui_request" && e.method === "setWidget" && e.widgetKey === "shepherd.goal").at(-1);
      return widget ? JSON.parse(widget.widgetLines[0].slice("SHEPHERD_GOAL:".length)) : undefined;
    },
    send(command) { const id = `req${++counter}`; child.stdin.write(JSON.stringify({ id, ...command }) + "\n"); return id; },
    async response(id, what) {
      await until(`response to ${what}`, () => events.some((e) => e.type === "response" && e.id === id));
      return events.find((e) => e.type === "response" && e.id === id);
    },
    async request(command) { return pi.response(pi.send(command), command.type); },
    async action(value) { return pi.request({ type: "prompt", message: `/shepherd-goal ${JSON.stringify(value)}` }); },
    settled: () => events.filter((e) => e.type === "agent_settled").length,
    release: (name = "evaluation") => gate(name).open(),
    async stop() {
      for (const g of gates.values()) g.open();
      if (child.exitCode === null && child.signalCode === null) {
        const exited = new Promise((r) => child.once("exit", r)); child.kill();
        const timeout = setTimeout(() => child.kill("SIGKILL"), 5000); await exited; clearTimeout(timeout);
      }
      server.closeAllConnections(); await new Promise((r) => server.close(r));
    },
  };
  return pi;
}
