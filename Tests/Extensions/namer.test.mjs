// The actual namer with gated in-memory model completions and a scratch socket. No provider calls.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR");
const { createJiti } = createRequire(path.join(pkg, "package.json"))("jiti");
const jiti = createJiti(import.meta.url, { alias: { typebox: path.join(pkg, "node_modules/typebox/build/index.mjs") } });
const { default: install } = await jiti.import(path.join(root, "Extensions/shepherd-namer.ts"));
const turn = () => new Promise((resolve) => setImmediate(resolve));

test("only the current session's detached naming result is reported, including switches back and shutdown", { timeout: 5000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-namer-"));
  const socketPath = path.join(dir, "s"), frames = [], sockets = [];
  let received;
  const server = net.createServer((s) => {
    sockets.push(s);
    let buffer = "";
    s.setEncoding("utf8");
    s.on("data", (chunk) => { buffer += chunk; });
    s.on("end", () => {
      for (const line of buffer.trim().split("\n").filter(Boolean)) frames.push(JSON.parse(line));
      received?.();
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  const env = { SHEPHERD_AGENT_ID: "fixture", SHEPHERD_SOCKET: socketPath, SHEPHERD_NEEDS_NAME: "1" };
  const saved = Object.fromEntries(Object.keys(env).map((k) => [k, process.env[k]]));
  const handlers = new Map(), completions = [];
  Object.assign(process.env, env);
  try { install({ on: (event, handler) => handlers.set(event, handler) }); }
  finally { for (const [k, v] of Object.entries(saved)) v === undefined ? delete process.env[k] : process.env[k] = v; }
  const model = { provider: "fixture", id: "fixture" };
  const ctx = (id) => ({ model, sessionManager: { getSessionId: () => id, getSessionName: () => undefined,
    getEntries: () => [{ type: "message", message: { role: "user", content: `Task ${id}` } }] },
    modelRegistry: { getAvailable: () => [model], find: () => undefined, hasConfiguredAuth: () => true,
      complete: () => new Promise((resolve) => completions.push(resolve)) } });
  const finish = (index, title) => completions[index]({ content: [{ type: "toolCall", name: "propose_title", arguments: { title } }] });
  const waitFrames = async (n) => { while (frames.length < n) await new Promise((resolve) => { received = resolve; }); };
  try {
    handlers.get("session_start")({ reason: "startup" }, ctx("a"));
    handlers.get("before_agent_start")({ prompt: "Task a" }, ctx("a"));
    handlers.get("session_start")({ reason: "resume" }, ctx("b"));
    assert.equal(completions.length, 2);
    finish(0, "Stale A"); await turn();
    finish(1, "Current B");
    await waitFrames(1);
    assert.deepEqual(frames, [{ type: "setAgentName", agentID: "fixture", name: "Current B", sessionID: "b" }]);
    handlers.get("session_start")({ reason: "resume" }, ctx("c"));
    handlers.get("session_start")({ reason: "resume" }, ctx("b"));
    handlers.get("session_start")({ reason: "resume" }, ctx("c"));
    finish(2, "Earlier C generation"); await turn();
    handlers.get("session_info_changed")({ name: "Named C" }, ctx("c"));
    await waitFrames(2);
    assert.deepEqual(frames.at(-1), { type: "setAgentName", agentID: "fixture", name: "Named C", sessionID: "c" });
    assert.equal(frames.length, 2);
    handlers.get("session_start")({ reason: "resume" }, ctx("d"));
    handlers.get("session_shutdown")();
    finish(3, "After shutdown"); await turn(); await turn();
    assert.equal(frames.length, 2);
  } finally {
    handlers.get("session_shutdown")?.();
    for (const s of sockets) s.destroy();
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
