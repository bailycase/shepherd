// Shepherd's Retry: the status extension's `/shepherd-retry <ms>` against pi's real runtime.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/retry.test.mjs
// Everything runs in a temporary HOME against a local fake provider.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as http from "node:http";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const statusSource = path.join(root, "Extensions/shepherd-status.ts");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, fn, timeout = 30000) {
  const end = Date.now() + timeout;
  while (!fn()) { if (Date.now() > end) throw Error(`Timed out waiting for ${what}`); await sleep(20); }
}
// A 1×1 PNG.
const PIXEL = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

// pi in RPC mode with the status extension, a provider that fails its first request and answers
// the rest, and a session file in `dir`.
async function startPi(dir) {
  const requests = [];
  const server = http.createServer(async (req, res) => {
    let raw = ""; for await (const chunk of req) raw += chunk;
    requests.push(JSON.parse(raw));
    if (requests.length === 1) {
      res.writeHead(400, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { message: "Bad request from the fixture", type: "invalid_request_error" } }));
      return;
    }
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write(`data: ${JSON.stringify({ id: "f", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta: { content: "Recovered." }, finish_reason: null }] })}\n\n`);
    res.end(`data: ${JSON.stringify({ id: "f", object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } })}\n\ndata: [DONE]\n\n`);
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const config = path.join(dir, "config");
  fs.mkdirSync(config);
  fs.writeFileSync(path.join(config, "settings.json"), JSON.stringify({ retry: { enabled: false } }));
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: [{ id: "fixture", name: "fixture", reasoning: false, input: ["text", "image"], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  const sessions = path.join(dir, "sessions");
  const env = { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1",
    SHEPHERD_AGENT_ID: "fixture", SHEPHERD_SOCKET: path.join(dir, "absent.sock") };
  const child = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--session-dir", sessions,
    "-ne", "-ns", "-np", "--model", "fixture/fixture", "-e", statusSource], { cwd: dir, env, stdio: ["pipe", "pipe", "pipe"] });
  const events = [];
  let out = "", err = "", next = 0;
  child.stdout.on("data", (chunk) => {
    out += chunk;
    for (let nl; (nl = out.indexOf("\n")) >= 0; out = out.slice(nl + 1)) {
      try { events.push(JSON.parse(out.slice(0, nl))); } catch {}
    }
  });
  child.stderr.on("data", (chunk) => { err += chunk; });
  const pi = {
    events, requests, sessions,
    get stderr() { return err; },
    send(command) { const id = `r${++next}`; child.stdin.write(JSON.stringify({ id, ...command }) + "\n"); return id; },
    async request(command) {
      const id = pi.send(command);
      await until(`the answer to ${command.type}`, () => events.some((e) => e.type === "response" && e.id === id));
      return events.find((e) => e.type === "response" && e.id === id);
    },
    settled: () => events.filter((e) => e.type === "agent_settled").length,
    async stop() {
      child.kill();
      await new Promise((r) => child.once("exit", r));
      server.close();
    },
  };
  return pi;
}

function userMessages(messages) { return messages.filter((m) => m.role === "user"); }

test("real Pi RPC: Retry navigates back and resends, leaving one copy with its images", { timeout: 120000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-retry-"));
  const pi = await startPi(dir);
  try {
    const image = { type: "image", data: PIXEL, mimeType: "image/png" };
    assert.equal((await pi.request({ type: "prompt", message: "Describe this", images: [image] })).success, true);
    await until("the failed turn to settle", () => pi.settled() === 1);
    let messages = (await pi.request({ type: "get_messages" })).data.messages;
    const failed = messages.at(-1);
    assert.equal(failed.role, "assistant");
    assert.equal(failed.stopReason, "error", "the first request fails");
    const [prompt] = userMessages(messages);

    const retry = await pi.request({ type: "prompt", message: `/shepherd-retry ${Math.trunc(prompt.timestamp)}` });
    assert.equal(retry.success, true);
    await until("the retried turn to settle", () => pi.settled() === 2);

    messages = (await pi.request({ type: "get_messages" })).data.messages;
    const users = userMessages(messages);
    assert.equal(users.length, 1, "the active branch holds the prompt once");
    assert.deepEqual(users[0].content.filter((p) => p.type === "text").map((p) => p.text), ["Describe this"]);
    assert.deepEqual(users[0].content.filter((p) => p.type === "image").map((p) => [p.mimeType, p.data]), [["image/png", PIXEL]]);
    assert(users[0].timestamp > prompt.timestamp, "a new message, not the old one");
    assert(!messages.some((m) => m.role === "assistant" && m.stopReason === "error"), "the failed reply left the branch");
    assert.deepEqual(messages.at(-1).content, [{ type: "text", text: "Recovered." }]);

    // The model saw the prompt once, with its image.
    const sent = pi.requests[1].messages.filter((m) => m.role === "user");
    assert.equal(sent.length, 1);
    assert(JSON.stringify(sent[0].content).includes(PIXEL), "the image went again");
    assert(!pi.requests[1].messages.some((m) => m.role === "assistant"), "nothing of the failed turn went");

    // The failed turn stays in the session file, off the active branch.
    const [file] = fs.readdirSync(pi.sessions, { recursive: true }).filter((f) => String(f).endsWith(".jsonl"));
    const entries = fs.readFileSync(path.join(pi.sessions, String(file)), "utf8").trim().split("\n").map((l) => JSON.parse(l));
    const stored = entries.filter((e) => e.type === "message" && e.message.role === "user");
    assert.equal(stored.length, 2, "both copies are in the file");
    assert.equal(stored[1].parentId, stored[0].parentId, "the retry is a sibling of the failed prompt");
    assert(entries.some((e) => e.type === "message" && e.message.stopReason === "error"));
    assert(!pi.events.some((e) => e.type === "extension_error"), "the command never throws into pi");
  } catch (error) {
    error.message += `\npi stderr:\n${pi.stderr}`;
    throw error;
  } finally {
    await pi.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("real Pi RPC: Retry of a message that isn't on the branch changes nothing and says so", { timeout: 120000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-retry-miss-"));
  const pi = await startPi(dir);
  try {
    await pi.request({ type: "prompt", message: "First" });
    await until("the turn to settle", () => pi.settled() === 1);
    const before = (await pi.request({ type: "get_messages" })).data.messages;
    assert.equal((await pi.request({ type: "prompt", message: "/shepherd-retry 12345" })).success, true);
    await until("the notice", () => pi.events.some((e) => e.type === "extension_ui_request" && e.method === "notify"));
    const notice = pi.events.find((e) => e.type === "extension_ui_request" && e.method === "notify");
    assert.match(notice.message, /no longer in this conversation/);
    assert.deepEqual((await pi.request({ type: "get_messages" })).data.messages, before);
    assert.equal(pi.requests.length, 1, "nothing went to the model");
    assert.equal(pi.settled(), 1);
  } catch (error) {
    error.message += `\npi stderr:\n${pi.stderr}`;
    throw error;
  } finally {
    await pi.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
