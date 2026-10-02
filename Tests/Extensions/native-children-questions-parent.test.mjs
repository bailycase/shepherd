// A subagent asks its parent, and the parent answers it or asks the user, with a REAL parent pi (`pi --mode rpc`)
// that loads the children extension and a real child pi, both on one scripted local provider.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/native-children-questions-parent.test.mjs
// Everything runs in a temporary HOME; no model request leaves the machine. The scripted parent only reads what a
// real model would: its context. So a question that survives the parent's turn is proved by the next turn finding it.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as http from "node:http";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const extension = path.join(root, "Extensions/shepherd-children.ts");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to pi's package");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, fn, timeout = 30000) {
  const end = Date.now() + timeout;
  while (!fn()) { if (Date.now() > end) throw Error(`Timed out waiting for ${what}`); await sleep(20); }
}

const textOf = (message) => typeof message?.content === "string" ? message.content : (message?.content ?? []).map((part) => part.text ?? "").join("\n");

// The scripted models. A child is told so by its system prompt; the parent is everything else.
function scripted(body) {
  const messages = body.messages ?? [];
  const system = messages.filter((m) => m.role === "system" || m.role === "developer").map(textOf).join("\n");
  const last = messages.at(-1) ?? {};
  const lastText = textOf(last);
  const call = (name, args) => ({ tool: name, args });
  if (system.includes("You are a Shepherd child")) {
    const user = messages.filter((m) => m.role === "user").map(textOf);
    const task = user[0] ?? "";
    if (user.length > 1) return { text: `Used: ${user.at(-1)}` };
    if (last.role === "tool") return { text: "I asked my parent." };
    const question = task.includes("db") ? "Which database should the migration target?" : "Which customer is this for?";
    return call("shepherd_parent_message", { message: question, needsReply: true, options: task.includes("db") ? ["Postgres", "SQLite"] : undefined });
  }
  const notice = [...messages].reverse().find((m) => m.role === "user" && /Needs reply:/.test(textOf(m)));
  const owed = notice && { id: textOf(notice).match(/Child (native-[\w-]+)/)?.[1], questionID: textOf(notice).match(/questionID: (\S+)/)?.[1] };
  if (last.role === "tool") return { text: "Done." };
  if (lastText.startsWith("START")) {
    return call("shepherd_child_start", { role: "scout", task: lastText.includes("db") ? "ASK_PARENT db" : "ASK_PARENT customer" });
  }
  if (lastText.startsWith("The user says:")) {
    // The notice is still in this turn's context, though the turn that read it ended to ask the user.
    return call("shepherd_child_resume", { id: owed.id, message: lastText.slice("The user says:".length).trim(), questionID: owed.questionID });
  }
  if (/Needs reply:/.test(lastText)) {
    const id = lastText.match(/Child (native-[\w-]+)/)[1], questionID = lastText.match(/questionID: (\S+)/)[1];
    if (lastText.includes("database")) return call("shepherd_child_resume", { id, message: "Postgres. It is what the rest of the stack runs.", questionID });
    return { text: "I can't tell which customer this is for. Which customer should it be?" };
  }
  return { text: "Noted." };
}

async function startProvider() {
  const requests = [];
  const server = http.createServer(async (req, res) => {
    let raw = ""; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw);
    requests.push(body);
    const step = scripted(body);
    const chunk = (delta, finish) => `data: ${JSON.stringify({ id: "p", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta, finish_reason: finish ?? null }],
      ...(finish ? { usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } } : {}) })}\n\n`;
    res.writeHead(200, { "content-type": "text/event-stream" });
    if (step.tool) {
      res.write(chunk({ tool_calls: [{ index: 0, id: `call_${requests.length}`, type: "function", function: { name: step.tool, arguments: JSON.stringify(step.args) } }] }));
      res.end(chunk({}, "tool_calls") + "data: [DONE]\n\n");
    } else {
      res.write(chunk({ content: step.text }));
      res.end(chunk({}, "stop") + "data: [DONE]\n\n");
    }
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { requests, server };
}

async function startParent(dir, provider) {
  const config = path.join(dir, "config");
  fs.mkdirSync(config);
  fs.writeFileSync(path.join(config, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }));
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${provider.server.address().port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: [{ id: "fixture", name: "fixture", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  const env = { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0",
    SHEPHERD_NATIVE_CHILDREN: "1", SHEPHERD_AGENT_ID: "parent", SHEPHERD_SOCKET: path.join(dir, "absent.sock"), SHEPHERD_EXT_CHILDREN: extension };
  const pi = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--session-dir", path.join(dir, "sessions"),
    "-ne", "-ns", "-np", "-e", extension, "--model", "fixture/fixture"], { cwd: dir, env, stdio: ["pipe", "pipe", "pipe"] });
  const events = [];
  let out = "", err = "";
  pi.stdout.on("data", (chunk) => {
    out += chunk;
    for (let nl; (nl = out.indexOf("\n")) >= 0; out = out.slice(nl + 1)) { try { events.push(JSON.parse(out.slice(0, nl))); } catch { /* not an event */ } }
  });
  pi.stderr.on("data", (chunk) => { err += chunk; });
  pi.stdin.on("error", () => {});
  return {
    events, get stderr() { return err; },
    prompt(message) { pi.stdin.write(JSON.stringify({ type: "prompt", message }) + "\n"); },
    // Every turn that started has settled. How turns divide depends on timing (a question that lands while the parent
    // still works is a continuation of its turn), so the tests wait on what was said, never on a count of turns.
    idle: () => events.some((e) => e.type === "agent_start") && events.filter((e) => e.type === "agent_start").length === events.filter((e) => e.type === "agent_settled").length,
    stop() { pi.stdin.end(); pi.kill("SIGTERM"); },
  };
}

// Every parent request that carried the question's notice, and the tool calls the parent made.
const parentRequests = (provider) => provider.requests.filter((r) => !JSON.stringify(r.messages).includes("You are a Shepherd child"));
const resumeCalls = (provider) => {
  const calls = new Map();
  for (const request of parentRequests(provider)) for (const message of request.messages) for (const c of message.tool_calls ?? []) {
    if (c.function.name === "shepherd_child_resume") calls.set(c.id, JSON.parse(c.function.arguments));
  }
  return [...calls.values()];
};

test("a real parent answers a child's question itself, from the notice, with the questionID, and the child goes on", { timeout: 120000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-qparent-"));
  const provider = await startProvider();
  const parent = await startParent(dir, provider);
  try {
    parent.prompt("START db");
    // The child asks; the notice reaches the parent (waking it, or at the end of the turn it is in); the parent answers;
    // the child finishes and its completion reaches the parent.
    await until("the parent to have answered the child", () => resumeCalls(provider).length === 1);
    const [answer] = resumeCalls(provider);
    assert.match(answer.id, /^native-/);
    assert.match(answer.questionID, /^[\w-]+\/\w+$/, "the questionID the notice named, attempt and call");
    assert.equal(answer.message, "Postgres. It is what the rest of the stack runs.");
    // What the parent read: the question, its options, the instructions (once), and no word that the user was asked.
    const woken = parentRequests(provider).find((r) => /Needs reply:/.test(textOf(r.messages.at(-1))));
    const notice = textOf(woken.messages.at(-1));
    assert(notice.includes("Which database should the migration target?"));
    assert(notice.includes("Options it offered: Postgres | SQLite"));
    assert(notice.includes(`questionID: ${answer.questionID}`));
    assert.equal(notice.split("Answer it yourself if you can").length - 1, 1, "the instructions come once");
    // The child went on from its parent's answer, as its own next turn, and its result came back.
    await until("the child to receive the parent's answer as its next message", () => provider.requests.some((r) => JSON.stringify(r.messages).includes("You are a Shepherd child")
      && textOf(r.messages.at(-1)).startsWith("Postgres.")));
    await until("the child's result to reach the parent", () => parentRequests(provider).some((r) => textOf(r.messages.at(-1)).includes("Used: Postgres.")));
  } finally { parent.stop(); provider.server.closeAllConnections(); provider.server.close(); fs.rmSync(dir, { recursive: true, force: true }); }
});

test("a real parent that cannot answer asks the user in its own reply, and passes the user's answer down in a later turn", { timeout: 120000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-qparent-"));
  const provider = await startProvider();
  const parent = await startParent(dir, provider);
  try {
    parent.prompt("START customer");
    await until("the parent to have asked the user", () => parent.events.some((e) => e.type === "message_end" && e.message?.role === "assistant"
      && textOf(e.message).includes("Which customer should it be?")));
    await until("the parent to be idle", () => parent.idle());
    await sleep(300);
    assert.equal(resumeCalls(provider).length, 0, "it did not guess an answer for the user");
    const asked = parent.events.filter((e) => e.type === "message_end" && e.message?.role === "assistant").map((e) => textOf(e.message));
    assert(asked.some((text) => text.includes("Which customer should it be?")), "the question to the user is the parent's own reply");
    // The user answers in a later turn. The parent still owes the child: the notice is in its context, and it passes the answer down.
    parent.prompt("The user says: Acme Corp");
    await until("the answer to be passed down", () => resumeCalls(provider).length === 1);
    const [answer] = resumeCalls(provider);
    assert.equal(answer.message, "Acme Corp");
    assert.match(answer.questionID, /^[\w-]+\/\w+$/);
    await until("the child to continue with the user's answer", () => parentRequests(provider).some((r) => textOf(r.messages.at(-1)).includes("Used: Acme Corp")));
  } finally { parent.stop(); provider.server.closeAllConnections(); provider.server.close(); fs.rmSync(dir, { recursive: true, force: true }); }
});
