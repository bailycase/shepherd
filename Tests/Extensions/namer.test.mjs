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
const { default: install, promptLabel, distinguish } = await jiti.import(path.join(root, "Extensions/shepherd-namer.ts"));
const turn = () => new Promise((resolve) => setImmediate(resolve));
// The sibling lookup is a socket round trip before the model call.
const calledFor = (completions) => async (n) => { while (completions.length < n) await new Promise((resolve) => setTimeout(resolve, 5)); };

test("only the current session's detached naming result is reported, including switches back and shutdown", { timeout: 5000 }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-namer-"));
  const socketPath = path.join(dir, "s"), frames = [], sockets = [];
  let received;
  const server = net.createServer((s) => {
    sockets.push(s);
    let buffer = "";
    s.setEncoding("utf8");
    s.on("data", (chunk) => {
      buffer += chunk;
      // The namer asks for the other threads' names before naming; answer like Shepherd does.
      if (buffer.includes('"listAgents"')) {
        const { id } = JSON.parse(buffer.trim());
        buffer = "";
        s.end(JSON.stringify({ type: "agents", id, agents: [
          { id: "fixture", name: "Own provisional name", status: "working", cwd: "/", isSelf: true },
          { id: "other", name: "Fix cart total calculation", status: "done", cwd: "/", isSelf: false },
        ] }) + "\n");
      }
    });
    s.on("end", () => {
      for (const line of buffer.trim().split("\n").filter(Boolean)) frames.push(JSON.parse(line));
      if (buffer.trim()) received?.();
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  const env = { SHEPHERD_AGENT_ID: "fixture", SHEPHERD_SOCKET: socketPath, SHEPHERD_NEEDS_NAME: "1" };
  const saved = Object.fromEntries(Object.keys(env).map((k) => [k, process.env[k]]));
  const handlers = new Map(), completions = [], contexts = [];
  Object.assign(process.env, env);
  try { install({ on: (event, handler) => handlers.set(event, handler) }); }
  finally { for (const [k, v] of Object.entries(saved)) v === undefined ? delete process.env[k] : process.env[k] = v; }
  const model = { provider: "fixture", id: "fixture" };
  const ctx = (id, text = `Reply ${id}`) => ({ model, sessionManager: { getSessionId: () => id, getSessionName: () => undefined,
    getEntries: () => [{ type: "message", message: { role: "user", content: `Task ${id}` } },
      { type: "message", message: { role: "assistant", content: [{ type: "text", text }] } }] },
    modelRegistry: { getAvailable: () => [model], find: () => undefined, hasConfiguredAuth: () => true,
      complete: (_m, context) => { contexts.push(context.messages[0].content[0].text); return new Promise((resolve) => completions.push(resolve)); } } });
  const called = calledFor(completions);
  const finish = (index, title) => completions[index]({ content: [{ type: "toolCall", name: "propose_title", arguments: { title } }] });
  const waitFrames = async (n) => { while (frames.length < n) await new Promise((resolve) => { received = resolve; }); };
  try {
    handlers.get("session_start")({ reason: "startup" }, ctx("a"));
    handlers.get("before_agent_start")({ prompt: "Task a" }, ctx("a"));
    // Naming waits for the first run to settle, then reads the agent's reply too.
    assert.equal(completions.length, 0);
    handlers.get("agent_settled")({ aborted: false }, ctx("a", "Fixed the sidebar badge"));
    handlers.get("before_agent_start")({ prompt: "Second" }, ctx("a"));
    handlers.get("agent_settled")({ aborted: false }, ctx("a", "Again"));
    await called(1);
    assert.match(contexts[0], /Task a[\s\S]*Fixed the sidebar badge/);
    // Other threads' names go along so the title doesn't repeat one; its own row is left out.
    assert.match(contexts[0], /<titles>\nFix cart total calculation\n<\/titles>/);
    assert.doesNotMatch(contexts[0], /Own provisional name/);
    handlers.get("session_start")({ reason: "resume" }, ctx("b"));
    await called(2);
    assert.equal(completions.length, 2);
    assert.match(contexts[1], /Task b[\s\S]*Reply b/);
    finish(0, "Stale A"); await turn();
    finish(1, "Current B");
    await waitFrames(1);
    assert.deepEqual(frames, [{ type: "setAgentName", agentID: "fixture", name: "Current B", sessionID: "b" }]);
    handlers.get("session_start")({ reason: "resume" }, ctx("c"));
    handlers.get("session_start")({ reason: "resume" }, ctx("b"));
    handlers.get("session_start")({ reason: "resume" }, ctx("c"));
    await called(3);
    finish(2, "Earlier C generation"); await turn();
    handlers.get("session_info_changed")({ name: "Named C" }, ctx("c"));
    await waitFrames(2);
    assert.deepEqual(frames.at(-1), { type: "setAgentName", agentID: "fixture", name: "Named C", sessionID: "c" });
    assert.equal(frames.length, 2);
    handlers.get("session_start")({ reason: "resume" }, ctx("d"));
    await called(4);
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

test("the text generation model env names the candidate; the retired namer name does not", { timeout: 5000 }, async () => {
  const keys = ["SHEPHERD_AGENT_ID", "SHEPHERD_SOCKET", "SHEPHERD_TEXT_GENERATION_MODELS", "SHEPHERD_NAMER_MODELS"];
  const saved = Object.fromEntries(keys.map((k) => [k, process.env[k]]));
  // A socket path nothing listens on: the sibling lookup and the report both fail quietly.
  const dead = path.join(os.tmpdir(), `sh-namer-dead-${process.pid}`);
  const used = [];
  const titleWith = async (env) => {
    for (const k of keys) delete process.env[k];
    Object.assign(process.env, { SHEPHERD_AGENT_ID: "fixture", SHEPHERD_SOCKET: dead }, env);
    const handlers = new Map();
    install({ on: (event, handler) => handlers.set(event, handler) });
    const own = { provider: "own", id: "big" };
    const ctx = { model: own, sessionManager: { getSessionId: () => "s", getSessionName: () => undefined,
        getEntries: () => [{ type: "message", message: { role: "user", content: "Task" } }] },
      modelRegistry: { getAvailable: () => [own], find: (provider, id) => ({ provider, id }), hasConfiguredAuth: () => true,
        complete: async (model) => { used.push(`${model.provider}/${model.id}`); return { content: [{ type: "toolCall", name: "propose_title", arguments: { title: "Fix thing" } }] }; } } };
    const before = used.length;
    handlers.get("session_start")({ reason: "resume" }, ctx);
    while (used.length === before) await new Promise((resolve) => setTimeout(resolve, 5));
    handlers.get("session_shutdown")();
  };
  try {
    await titleWith({ SHEPHERD_TEXT_GENERATION_MODELS: "cheap/mini" });
    // The old setting's env name is retired with it: the cheapest-first defaults apply instead.
    await titleWith({ SHEPHERD_NAMER_MODELS: "cheap/mini" });
    assert.deepEqual(used, ["cheap/mini", "anthropic/claude-haiku-4-5"]);
  } finally {
    for (const [k, v] of Object.entries(saved)) v === undefined ? delete process.env[k] : process.env[k] = v;
  }
});

// The real namer behind a scratch socket that lists no siblings and records the names it is sent.
// `complete` stands in for the model. `run` plays one pi run: agent_end for the attempt, then
// agent_settled, which pi emits only once no retry or continuation is left.
async function namerFixture(complete) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-namer-"));
  const socketPath = path.join(dir, "s"), frames = [], sockets = [];
  const server = net.createServer((s) => {
    sockets.push(s);
    let buffer = "";
    s.setEncoding("utf8");
    s.on("data", (chunk) => {
      buffer += chunk;
      if (buffer.includes('"listAgents"')) {
        const { id } = JSON.parse(buffer.trim());
        buffer = "";
        s.end(JSON.stringify({ type: "agents", id, agents: [] }) + "\n");
      }
    });
    s.on("end", () => { for (const line of buffer.trim().split("\n").filter(Boolean)) frames.push(JSON.parse(line)); });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  const env = { SHEPHERD_AGENT_ID: "fixture", SHEPHERD_SOCKET: socketPath, SHEPHERD_NEEDS_NAME: "1" };
  const saved = Object.fromEntries(Object.keys(env).map((k) => [k, process.env[k]]));
  const handlers = new Map(), calls = [];
  Object.assign(process.env, env);
  try { install({ on: (event, handler) => handlers.set(event, handler) }); }
  finally { for (const [k, v] of Object.entries(saved)) v === undefined ? delete process.env[k] : process.env[k] = v; }
  const model = { provider: "fixture", id: "fixture" };
  let sessionID = "a", entries = [];
  const ctx = { model, sessionManager: { getSessionId: () => sessionID, getSessionName: () => undefined, getEntries: () => entries },
    modelRegistry: { getAvailable: () => [model], find: () => undefined, hasConfiguredAuth: () => true,
      complete: (_m, context) => { calls.push(context.messages[0].content[0].text); return complete(calls.length - 1); } } };
  const poll = async (done, what) => {
    const deadline = Date.now() + 2000;
    while (!done()) {
      if (Date.now() > deadline) throw Error(`${what}; ${calls.length} model calls, ${frames.length} names`);
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
  };
  handlers.get("session_start")({ reason: "startup" }, ctx);
  const text = (t) => ({ role: "assistant", content: [{ type: "text", text: t }], stopReason: "stop" });
  return {
    calls, frames, text,
    failed: { role: "assistant", content: [], stopReason: "error", errorMessage: "503 model overloaded" },
    run(prompt, assistant) {
      handlers.get("before_agent_start")({ prompt }, ctx);
      const messages = [{ role: "user", content: prompt }, assistant];
      entries.push(...messages.map((message) => ({ type: "message", message })));
      handlers.get("agent_end")?.({ messages }, ctx);
      handlers.get("agent_settled")?.({ aborted: false }, ctx);
    },
    called: (n) => poll(() => calls.length >= n, `waiting for model call ${n}`),
    named: (n) => poll(() => frames.length >= n, `waiting for name ${n}`),
    // A /resume lookup follows any earlier one through the same socket, so once its model call
    // is made, whatever an earlier run was going to start has started. Ends the session's naming.
    async fence() {
      sessionID = "fence";
      entries = [{ type: "message", message: { role: "user", content: "Task fence" } }];
      handlers.get("session_start")({ reason: "resume" }, ctx);
      await poll(() => calls.some((c) => c.includes("Task fence")), "waiting for the fence's model call");
    },
    async close() {
      handlers.get("session_shutdown")?.();
      for (const s of sockets) s.destroy();
      await new Promise((resolve) => server.close(resolve));
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
}
const proposes = (title) => ({ content: [{ type: "toolCall", name: "propose_title", arguments: { title } }] });

test("a run that failed does not name the thread, and the next run that settles does", { timeout: 5000 }, async () => {
  const f = await namerFixture(() => Promise.resolve(proposes("Fix sidebar badge")));
  try {
    f.run("Fix the badge", f.failed);
    f.run("Try again", f.text("Fixed the sidebar badge"));
    await f.named(1);
    // One call, on the opening prompt and the reply that worked: none for the failed run.
    assert.equal(f.calls.length, 1);
    assert.match(f.calls[0], /Fix the badge[\s\S]*Fixed the sidebar badge/);
    assert.deepEqual(f.frames, [{ type: "setAgentName", agentID: "fixture", name: "Fix sidebar badge", sessionID: "a" }]);
    // Named once: a later run asks for nothing (the fence is the only other call).
    f.run("More", f.text("Done"));
    await f.fence();
    assert.equal(f.calls.length, 2);
  } finally { await f.close(); }
});

test("a naming call that fails is tried again after the next run that settles, three times in all", { timeout: 5000 }, async () => {
  const f = await namerFixture(() => Promise.reject(new Error("503 model overloaded")));
  try {
    for (const n of [1, 2, 3]) {
      f.run("Fix the badge", f.text("Fixed the sidebar badge"));
      await f.called(n);
      await turn(); // the failure settles the call before the next run
    }
    f.run("Fix the badge", f.text("Fixed the sidebar badge"));
    await f.fence();
    // Three tries on the same opening prompt, then nothing; the fence is the fourth call.
    assert.equal(f.calls.length, 4);
    for (const call of f.calls.slice(0, 3)) assert.match(call, /Fix the badge[\s\S]*Fixed the sidebar badge/);
    assert.deepEqual(f.frames, []);
  } finally { await f.close(); }
});

test("a run that settles while a naming call is in flight starts no second call", { timeout: 5000 }, async () => {
  const gates = [];
  const f = await namerFixture(() => new Promise((resolve) => gates.push(resolve)));
  try {
    f.run("Fix the badge", f.text("Fixed the sidebar badge"));
    await f.called(1);
    f.run("More", f.text("Done"));
    await f.fence();
    assert.equal(f.calls.length, 2, "the first call and the fence, no second naming call");
  } finally {
    for (const gate of gates) gate(proposes("Late title"));
    await f.close();
  }
});

test("a title that opens like a sibling's leads with the developer's own label", () => {
  assert.equal(promptLabel("Scale test 4: list the files here and write a haiku about four"), "Scale test 4");
  assert.equal(promptLabel("PR-123 - fix the flaky retry"), "PR-123");
  assert.equal(promptLabel("“Checkout v2”: start the migration"), "Checkout v2");
  assert.equal(promptLabel("Note: the cart total is wrong on checkout"), undefined, "a plain word before a colon is no label");
  assert.equal(promptLabel("fix this"), undefined);
  const siblings = ["List files and celebrate eight", "List files and haiku five"];
  assert.equal(distinguish("List files and haiku four", "Scale test 4: list files, haiku about four", siblings), "Scale test 4: List files and haiku four");
  assert.equal(distinguish("List files and haiku four", "list files, haiku about four", siblings), "List files and haiku four", "no label, no change");
  assert.equal(distinguish("Fix checkout totals", "Scale test 4: fix totals", siblings), "Fix checkout totals", "a distinct stem needs no label");
  assert.equal(distinguish("Scale test 4 haiku", "Scale test 4: haiku", ["Scale test 4 haiku"]), "Scale test 4 haiku", "a label already in the title is not repeated");
  const long = distinguish("List files and write a very long haiku about the number four", "Scale test 4: go", siblings);
  assert(long.startsWith("Scale test 4: List files") && long.length <= 60);
});
