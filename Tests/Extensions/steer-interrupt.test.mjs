// "Steer now" against pi's real runtime: what steer, clear_queue, abort and a following prompt do in
// `pi --mode rpc`, which is the recipe Shepherd's host relies on to interrupt an agent.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/steer-interrupt.test.mjs
// Everything runs in a temporary HOME against a local fake OpenAI-completions provider; no extensions load.
// Set STEER_INTERRUPT_TRACE=1 to print each test's event order.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as http from "node:http";
import { spawn, execFileSync } from "node:child_process";

const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(what, fn, timeout = 20000) {
  const end = Date.now() + timeout;
  while (!fn()) { if (Date.now() > end) throw Error(`Timed out waiting for ${what}`); await sleep(10); }
}

// A fake OpenAI chat-completions endpoint. `script(body, index)` returns the steps for request `index`:
//   { text }                        one content chunk
//   { slow, times, every }          `slow` as a content chunk `times` times, `every` ms apart
//   { wait }                        pause `wait` ms
//   { gate }                        hold until release(gate) (or the client disconnects)
//   { tool, command, id }           a complete tool call
//   { partialTool, args, id }       a tool call whose arguments stop short (no finish)
// Unless a step holds forever, the reply then finishes ("tool_calls" after any tool call, else "stop").
async function startFake(script) {
  const requests = [], disconnected = [], gates = new Map();
  const gate = (name) => {
    if (!gates.has(name)) { let open; const promise = new Promise((r) => { open = r; }); gates.set(name, { promise, open }); }
    return gates.get(name);
  };
  const server = http.createServer(async (req, res) => {
    let raw = ""; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw);
    const index = requests.push(body) - 1;
    let closed = false, finished = false, wake;
    const gone = new Promise((r) => { wake = r; });
    res.on("close", () => { if (!finished) { closed = true; disconnected[index] = true; wake(); } });
    const pause = (ms) => Promise.race([sleep(ms), gone]);
    const chunk = (delta, finish, usage) => `data: ${JSON.stringify({ id: "f", object: "chat.completion.chunk", created: 1, model: "fixture",
      choices: [{ index: 0, delta, finish_reason: finish ?? null }], ...(usage ? { usage } : {}) })}\n\n`;
    const send = (delta) => { if (!closed) res.write(chunk(delta)); };
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.flushHeaders();
    let tools = 0;
    try {
      for (const step of script(body, index)) {
        if (closed) return;
        if (step.text !== undefined) send({ content: step.text });
        if (step.slow !== undefined) for (let i = 0; i < step.times && !closed; i++) { send({ content: step.slow }); await pause(step.every ?? 50); }
        if (step.wait) await pause(step.wait);
        if (step.gate) await Promise.race([gate(step.gate).promise, gone]);
        if (step.tool) {
          const i = tools++, id = step.id ?? `call_${index}_${i}`;
          send({ tool_calls: [{ index: i, id, type: "function", function: { name: step.tool, arguments: "" } }] });
          send({ tool_calls: [{ index: i, function: { arguments: JSON.stringify({ command: step.command }) } }] });
        }
        if (step.partialTool) {
          const i = tools++;
          send({ tool_calls: [{ index: i, id: step.id, type: "function", function: { name: step.partialTool, arguments: step.args } }] });
        }
      }
      if (closed) return;
      res.write(chunk({}, tools > 0 ? "tool_calls" : "stop", { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }));
      finished = true;
      res.end("data: [DONE]\n\n");
    } catch { finished = true; }
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return {
    requests, server,
    disconnected: (index) => disconnected[index] === true,
    release: (name) => gate(name).open(),
    async stop() {
      for (const g of gates.values()) g.open();
      server.closeAllConnections();
      server.close();
    },
  };
}

// pi in RPC mode with no extensions, skills or templates, on a fake provider driven by `script`.
async function startPi(dir, script, settings = {}) {
  const fake = await startFake(script);
  const config = path.join(dir, "config");
  fs.mkdirSync(config);
  fs.writeFileSync(path.join(config, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false }, ...settings }));
  fs.writeFileSync(path.join(config, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${fake.server.address().port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: [{ id: "fixture", name: "fixture", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  const env = { PATH: process.env.PATH, HOME: dir, PI_CODING_AGENT_DIR: config, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" };
  const child = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--session-dir", path.join(dir, "sessions"),
    "-ne", "-ns", "-np", "--model", "fixture/fixture"], { cwd: dir, env, stdio: ["pipe", "pipe", "pipe"] });
  const events = [];
  let out = "", err = "", next = 0;
  child.stdout.on("data", (chunk) => {
    out += chunk;
    for (let nl; (nl = out.indexOf("\n")) >= 0; out = out.slice(nl + 1)) {
      try { events.push(JSON.parse(out.slice(0, nl))); } catch {}
    }
  });
  child.stderr.on("data", (chunk) => { err += chunk; });
  child.stdin.on("error", () => {});
  const pi = {
    events, fake, requests: fake.requests,
    get stderr() { return err; },
    send(command) { const id = `r${++next}`; child.stdin.write(JSON.stringify({ id, ...command }) + "\n"); return id; },
    // Both commands reach pi in one read of its stdin, so it handles them back to back.
    sendTogether(...commands) {
      const ids = commands.map((command) => ({ id: `r${++next}`, ...command }));
      child.stdin.write(ids.map((c) => JSON.stringify(c) + "\n").join(""));
      return ids.map((c) => c.id);
    },
    answered: (id) => events.some((e) => e.type === "response" && e.id === id),
    async response(id, what) {
      await until(`the answer to ${what}`, () => pi.answered(id));
      return events.find((e) => e.type === "response" && e.id === id);
    },
    async request(command) { return pi.response(pi.send(command), command.type); },
    indexOf: (predicate) => events.findIndex(predicate),
    ofType: (type) => events.filter((e) => e.type === type),
    settled: () => events.filter((e) => e.type === "agent_settled").length,
    // The session's messages without the leading tool-loadout system message.
    async messages() { return (await pi.request({ type: "get_messages" })).data.messages.filter((m) => m.role !== "system"); },
    // The events in arrival order, one short label each.
    trace() {
      return events.flatMap((e) => {
        switch (e.type) {
          case "message_update": return [];
          case "response": return [`response:${e.command}${e.success ? "" : "(error)"}`];
          case "message_start": case "message_end":
            return [`${e.type}:${e.message.role}${e.message.role === "assistant" ? `(${e.message.stopReason ?? "-"})` : ""}`];
          case "tool_execution_start": case "tool_execution_end": return [`${e.type}:${e.toolCallId}`];
          case "queue_update": return [`queue_update:steering=${JSON.stringify(e.steering)},followUp=${JSON.stringify(e.followUp)}`];
          default: return [e.type];
        }
      });
    },
    async stop() {
      if (child.exitCode === null && child.signalCode === null) {
        const exited = new Promise((r) => child.once("exit", r));
        child.kill();
        const timer = setTimeout(() => child.kill("SIGKILL"), 5000);
        await exited;
        clearTimeout(timer);
      }
      await fake.stop();
    },
  };
  return pi;
}

// Runs `body(pi)` against a fresh pi in its own temporary HOME, then cleans up.
async function withPi(script, body, settings) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-steer-"));
  const pi = await startPi(dir, script, settings);
  try {
    await body(pi);
    if (process.env.STEER_INTERRUPT_TRACE) console.log(pi.trace().join("\n"));
  } catch (error) {
    console.error(`events:\n${pi.trace().join("\n")}\npi stderr:\n${pi.stderr}`);
    throw error;
  } finally {
    await pi.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

const flat = (content) => typeof content === "string" ? content
  : (content ?? []).filter((part) => part.type === "text").map((part) => part.text).join("");
// A session message as "role:text".
const line = (m) => `${m.role}:${flat(m.content)}`;
const users = (events) => events.filter((e) => e.type === "message_start" && e.message.role === "user").map((e) => flat(e.message.content));
// A provider request's conversation, without the system prompt: user text, assistant text and tool call ids, tool result ids.
function shape(body) {
  return body.messages.filter((m) => m.role !== "system" && m.role !== "developer").map((m) => {
    if (m.role === "user") return `user:${flat(m.content)}`;
    if (m.role === "tool") return `tool:${m.tool_call_id}`;
    const calls = (m.tool_calls ?? []).map((c) => c.id);
    return `assistant:${flat(m.content)}${calls.length ? `[${calls}]` : ""}`;
  });
}
const count = (haystack, needle) => haystack.split(needle).length - 1;
const twoCalls = [{ tool: "bash", command: "sleep 1.5; echo first", id: "call_a" }, { tool: "bash", command: "echo second", id: "call_b" }];

test("real Pi RPC: a steer sent during a tool batch lands after the batch and before the next model call", { timeout: 60000 }, async () => {
  await withPi((body, i) => i === 0 ? twoCalls : [{ text: "All done." }], async (pi) => {
    assert.equal((await pi.request({ type: "prompt", message: "work" })).success, true);
    await until("the batch to start", () => pi.events.some((e) => e.type === "tool_execution_start" && e.toolCallId === "call_a"));
    const steer = pi.send({ type: "prompt", message: "change course", streamingBehavior: "steer" });
    assert.equal((await pi.response(steer, "the steer")).success, true, "a prompt during a run with streamingBehavior steer is accepted");
    const answered = pi.indexOf((e) => e.id === steer);
    assert(!pi.events.slice(0, answered).some((e) => e.type === "tool_execution_end" && e.toolCallId === "call_a"), "the first tool was still running");
    await until("the run to settle", () => pi.settled() === 1);

    // queue_update fires when the steer is queued (before the response), and again, empty, as it lands.
    const queued = pi.ofType("queue_update");
    assert.deepEqual(queued.map((e) => [e.steering, e.followUp]), [[["change course"], []], [[], []]]);
    assert(pi.indexOf((e) => e.type === "queue_update" && e.steering.length === 1) < answered);
    const landed = pi.indexOf((e) => e.type === "message_start" && e.message.role === "user" && flat(e.message.content) === "change course");
    assert(pi.indexOf((e) => e.type === "queue_update" && e.steering.length === 0) < landed, "the queue empties just before the message starts");

    // Both tool calls ran to completion; nothing was skipped.
    const ends = pi.ofType("tool_execution_end");
    assert.deepEqual(ends.map((e) => [e.toolCallId, e.isError]).sort(), [["call_a", false], ["call_b", false]]);
    assert.match(flat(ends.find((e) => e.toolCallId === "call_a").result.content), /first/);
    assert.match(flat(ends.find((e) => e.toolCallId === "call_b").result.content), /second/);
    const lastEnd = Math.max(...ends.map((e) => pi.events.indexOf(e)));
    assert(landed > lastEnd, "the steer starts after the whole batch");
    const secondReply = pi.events.findIndex((e, i) => e.type === "message_start" && e.message.role === "assistant" && i > lastEnd);
    assert(landed < secondReply, "and before the next model reply");

    assert.equal(pi.requests.length, 2);
    assert.deepEqual(shape(pi.requests[1]), ["user:work", "assistant:[call_a,call_b]", "tool:call_a", "tool:call_b", "user:change course"]);
    assert.equal(pi.ofType("agent_start").length, 1);
    assert.equal(pi.settled(), 1, "one run, one agent_settled");
  });
});

test("real Pi RPC: several steers land one at a time, each at its own step boundary", { timeout: 60000 }, async () => {
  await withPi((body, i) => i === 0 ? twoCalls : [{ text: `Reply ${i}.` }], async (pi) => {
    await pi.request({ type: "prompt", message: "work" });
    await until("the batch to start", () => pi.events.some((e) => e.type === "tool_execution_start" && e.toolCallId === "call_a"));
    for (const message of ["s1", "s2"]) {
      assert.equal((await pi.request({ type: "prompt", message, streamingBehavior: "steer" })).success, true);
    }
    assert(!pi.events.some((e) => e.type === "tool_execution_end" && e.toolCallId === "call_a"), "both steers were queued while the first tool ran");
    assert.equal((await pi.request({ type: "get_state" })).data.steeringMode, "one-at-a-time");
    await until("the run to settle", () => pi.settled() === 1);

    assert.deepEqual(pi.ofType("queue_update").map((e) => e.steering), [["s1"], ["s1", "s2"], ["s2"], []]);
    assert.deepEqual(users(pi.events), ["work", "s1", "s2"], "in order, once each");
    assert.equal(pi.requests.length, 3, "one model call per steer boundary");
    assert.deepEqual(shape(pi.requests[1]), ["user:work", "assistant:[call_a,call_b]", "tool:call_a", "tool:call_b", "user:s1"]);
    assert.deepEqual(shape(pi.requests[2]), [...shape(pi.requests[1]), "assistant:Reply 1.", "user:s2"]);
    assert.equal(pi.ofType("agent_start").length, 1, "all inside one run");
    assert.equal(pi.settled(), 1);
  });
});

test("real Pi RPC: clear_queue, abort, then a plain prompt interrupts a streaming reply", { timeout: 60000 }, async () => {
  const script = (body, i) => i === 0 ? [{ text: "Partial reply so far. " }, { slow: "more ", times: 400, every: 50 }] : [{ text: "Fresh answer." }];
  await withPi(script, async (pi) => {
    assert.equal((await pi.request({ type: "prompt", message: "first question" })).success, true);
    await until("the reply to stream", () => pi.events.some((e) => e.type === "message_update" && e.assistantMessageEvent.type === "text_delta"));

    assert.equal((await pi.request({ type: "prompt", message: "held", streamingBehavior: "steer" })).success, true);
    const cleared = await pi.request({ type: "clear_queue" });
    assert.equal(cleared.success, true);
    assert.deepEqual(cleared.data, { steering: ["held"], followUp: [] });

    const abortId = pi.send({ type: "abort" });
    assert.equal((await pi.response(abortId, "abort")).success, true);
    // The abort response is the last word: the run has ended and settled by the time it arrives.
    const abortAt = pi.indexOf((e) => e.id === abortId);
    const endAt = pi.indexOf((e) => e.type === "agent_end");
    const settledAt = pi.indexOf((e) => e.type === "agent_settled");
    assert(endAt >= 0 && endAt < settledAt && settledAt < abortAt, `agent_end, then agent_settled, then the abort response (${endAt}, ${settledAt}, ${abortAt})`);
    assert.equal(pi.settled(), 1);
    assert.equal(pi.fake.disconnected(0), true, "the provider request was cut");
    assert(!users(pi.events).includes("held"), "the cleared steer never started");
    assert.equal(pi.ofType("agent_start").length, 1);

    let messages = await pi.messages();
    const aborted = messages.at(-1);
    assert.equal(aborted.role, "assistant");
    assert.equal(aborted.stopReason, "aborted");
    assert(flat(aborted.content).startsWith("Partial reply so far. "), "the partial text is kept");
    assert.deepEqual(messages.map(line).filter((l) => l.startsWith("user")), ["user:first question"]);

    // The new message goes straight after the abort response, with no streamingBehavior.
    assert.equal((await pi.request({ type: "prompt", message: "new message" })).success, true);
    await until("the new run to settle", () => pi.settled() === 2);
    assert.equal(pi.ofType("agent_start").length, 2, "exactly one new run");
    assert.equal(pi.requests.length, 2);
    const sent = JSON.stringify(pi.requests[1].messages);
    assert.equal(count(sent, "new message"), 1, "the model sees the new message once");
    assert(!shape(pi.requests[1]).some((l) => l.includes("held")), "the cleared steer never reaches the model");
    // FINDING: the aborted partial reply stays in the session but pi leaves it out of what the model is sent
    // (transformMessages skips assistant messages that stopped as "aborted" or "error").
    assert(!sent.includes("Partial reply so far"), "the aborted reply is not replayed");
    assert.deepEqual(shape(pi.requests[1]), ["user:first question", "user:new message"], "two user messages in a row");

    messages = await pi.messages();
    assert.deepEqual(messages.map((m) => `${m.role}${m.stopReason ? `(${m.stopReason})` : ""}`),
      ["user", "assistant(aborted)", "user", "assistant(stop)"]);
    assert.equal(line(messages[2]), "user:new message");
    assert.equal(line(messages[3]), "assistant:Fresh answer.");
    assert(flat(messages[1].content).startsWith("Partial reply so far. "));
  });
});

test("real Pi RPC: abort kills a running bash", { timeout: 60000 }, async () => {
  const marker = `sleep 29.${Math.floor(1000 + Math.random() * 9000)}`;
  const running = () => execFileSync("ps", ["-axo", "command"], { encoding: "utf8" }).split("\n").filter((l) => l.includes(marker));
  await withPi((body, i) => i === 0 ? [{ tool: "bash", command: `${marker}; echo unreachable`, id: "call_long" }] : [{ text: "Fine." }], async (pi) => {
    await pi.request({ type: "prompt", message: "run it" });
    await until("the command to run", () => running().length > 0);
    assert(pi.events.some((e) => e.type === "tool_execution_start" && e.toolCallId === "call_long"));

    const started = Date.now();
    assert.equal((await pi.request({ type: "abort" })).success, true);
    assert(Date.now() - started < 10000, "the abort does not wait for the command");
    const end = pi.events.find((e) => e.type === "tool_execution_end" && e.toolCallId === "call_long");
    assert.equal(end.isError, true);
    assert.match(flat(end.result.content), /aborted/i);
    await until("the command to be gone", () => running().length === 0, 5000);
    assert.equal(pi.settled(), 1);

    // FINDING: the aborted batch still leads to one more model step. It sends no request and ends as an empty
    // assistant message with stopReason "error" (not "aborted") and errorMessage "This operation was aborted".
    assert.equal(pi.requests.length, 1, "no second model call after the abort");
    const messages = await pi.messages();
    assert.deepEqual(messages.map((m) => `${m.role}${m.stopReason ? `(${m.stopReason})` : ""}`), ["user", "assistant(toolUse)", "toolResult", "assistant(error)"]);
    assert.equal(messages[2].isError, true);
    assert.deepEqual(messages[3].content, []);
    assert.match(messages[3].errorMessage, /aborted/i);

    // The next prompt sees the tool call with its error result, and none of the aborted step.
    assert.equal((await pi.request({ type: "prompt", message: "next" })).success, true);
    await until("the next run to settle", () => pi.settled() === 2);
    assert.deepEqual(shape(pi.requests[1]), ["user:run it", "assistant:[call_long]", "tool:call_long", "user:next"]);
  });
});

test("real Pi RPC: abort drops a tool call that was still streaming in", { timeout: 60000 }, async () => {
  const script = (body, i) => i === 0
    ? [{ text: "Let me run that. " }, { partialTool: "bash", id: "call_half", args: '{"command": "echo hal' }, { gate: "never" }]
    : [{ text: "Recovered." }];
  await withPi(script, async (pi) => {
    await pi.request({ type: "prompt", message: "do it" });
    await until("the tool call to stream", () => pi.events.some((e) => e.type === "message_update" && e.assistantMessageEvent.type === "toolcall_delta"));
    assert.equal((await pi.request({ type: "abort" })).success, true);
    assert.equal(pi.settled(), 1);
    assert(!pi.events.some((e) => e.type === "tool_execution_start"), "the half-sent call never ran");

    const messages = await pi.messages();
    assert.deepEqual(messages.map((m) => `${m.role}${m.stopReason ? `(${m.stopReason})` : ""}`), ["user", "assistant(aborted)"]);
    // FINDING: the aborted message keeps the tool call as it stood, arguments cut short and nothing to answer it.
    const call = messages[1].content.find((part) => part.type === "toolCall");
    assert.equal(call?.id, "call_half");
    assert.equal(call.arguments.command, "echo hal");
    assert(!("partialArgs" in call), "the streaming scratch buffer is not kept");

    assert.equal((await pi.request({ type: "prompt", message: "again" })).success, true);
    await until("the next run to settle", () => pi.settled() === 2);
    assert(!JSON.stringify(pi.requests[1].messages).includes("call_half"), "the half-sent call is not replayed");
    assert(!pi.requests[1].messages.some((m) => m.tool_calls || m.role === "tool"), "no tool call or tool result goes to the model");
    assert.deepEqual(shape(pi.requests[1]), ["user:do it", "user:again"]);
  });
});

test("real Pi RPC: abort while idle changes nothing", { timeout: 60000 }, async () => {
  await withPi(() => [{ text: "Hello." }], async (pi) => {
    assert.equal((await pi.request({ type: "abort" })).success, true);
    assert.equal((await pi.request({ type: "get_state" })).data.isStreaming, false);
    assert(!pi.events.some((e) => ["agent_start", "agent_end", "agent_settled", "turn_start"].includes(e.type)), "no run events");
    assert.equal((await pi.request({ type: "prompt", message: "hi" })).success, true);
    await until("the run to settle", () => pi.settled() === 1);
    assert.equal(pi.ofType("agent_start").length, 1);
    assert.deepEqual((await pi.messages()).map(line), ["user:hi", "assistant:Hello."]);
  });
});

test("real Pi RPC: a followUp prompt sent right behind an abort is queued, not run, until a later run", { timeout: 60000 }, async () => {
  const script = (body, i) => i === 0 ? [{ text: "Working on it. " }, { gate: "hold" }] : [{ text: `Reply ${i}.` }];
  await withPi(script, async (pi) => {
    await pi.request({ type: "prompt", message: "long task" });
    await until("the reply to stream", () => pi.events.some((e) => e.type === "message_update" && e.assistantMessageEvent.type === "text_delta"));

    // FINDING: this is a race. Sent as two separate writes, pi mostly (29 of 30 runs here) read the prompt after the
    // abort had fully settled, so it started a fresh run and ignored streamingBehavior; otherwise both lines came in one
    // read, and the prompt was handled while the run was still winding down (below). One write pins the second case.
    const [abortId, earlyId] = pi.sendTogether({ type: "abort" }, { type: "prompt", message: "early", streamingBehavior: "followUp" });
    const early = await pi.response(earlyId, "the early prompt");
    const abort = await pi.response(abortId, "abort");
    assert.equal(abort.success, true);
    assert.equal(early.success, true, "pi accepts it: the run has not ended yet, so it is queued");
    assert(pi.indexOf((e) => e.id === earlyId) < pi.indexOf((e) => e.type === "agent_settled"), "it was accepted before the run settled");
    assert.equal(pi.settled(), 1);

    // FINDING: the abort ends the run without draining the follow-up queue, so "early" never runs by itself.
    // It stays queued, and shows up as pending, in an idle pi.
    const state = (await pi.request({ type: "get_state" })).data;
    assert.equal(state.isStreaming, false);
    assert.equal(state.pendingMessageCount, 1);
    assert.deepEqual(pi.ofType("queue_update").at(-1).followUp, ["early"]);
    await sleep(300); // a short wait to prove a negative; the happy path does not depend on it
    assert.equal(pi.ofType("agent_start").length, 1, "nothing ran it");
    assert.equal(pi.requests.length, 1);
    assert(!users(pi.events).includes("early"));

    // FINDING: the stale follow-up is delivered at the end of the NEXT run, after that run's own reply.
    assert.equal((await pi.request({ type: "prompt", message: "after" })).success, true);
    await until("the next run to settle", () => pi.settled() === 2);
    assert.equal(pi.ofType("agent_start").length, 2, "one run");
    assert.deepEqual(users(pi.events), ["long task", "after", "early"]);
    assert.deepEqual(shape(pi.requests[1]), ["user:long task", "user:after"]);
    assert.deepEqual(shape(pi.requests[2]), ["user:long task", "user:after", "assistant:Reply 1.", "user:early"]);
    assert.equal((await pi.request({ type: "get_state" })).data.pendingMessageCount, 0);
  });
});

test("real Pi RPC: clear_queue after an abort drops a follow-up that raced it", { timeout: 60000 }, async () => {
  const script = (body, i) => i === 0 ? [{ text: "Working on it. " }, { gate: "hold" }] : [{ text: `Reply ${i}.` }];
  await withPi(script, async (pi) => {
    await pi.request({ type: "prompt", message: "long task" });
    await until("the reply to stream", () => pi.events.some((e) => e.type === "message_update" && e.assistantMessageEvent.type === "text_delta"));
    const [abortId, earlyId] = pi.sendTogether({ type: "abort" }, { type: "prompt", message: "early", streamingBehavior: "followUp" });
    await pi.response(earlyId, "the early prompt");
    await pi.response(abortId, "abort");
    const cleared = await pi.request({ type: "clear_queue" });
    assert.deepEqual(cleared.data, { steering: [], followUp: ["early"] });

    assert.equal((await pi.request({ type: "prompt", message: "after" })).success, true);
    await until("the next run to settle", () => pi.settled() === 2);
    assert.equal(pi.requests.length, 2);
    assert.deepEqual(shape(pi.requests[1]), ["user:long task", "user:after"]);
    assert.deepEqual(users(pi.events), ["long task", "after"]);
  });
});

for (const streamingBehavior of ["steer", "followUp"]) {
  test(`real Pi RPC: a ${streamingBehavior} prompt sent after the abort response just starts a new run`, { timeout: 60000 }, async () => {
    const script = (body, i) => i === 0 ? [{ text: "Working on it. " }, { gate: "hold" }] : [{ text: `Reply ${i}.` }];
    await withPi(script, async (pi) => {
      await pi.request({ type: "prompt", message: "long task" });
      await until("the reply to stream", () => pi.events.some((e) => e.type === "message_update" && e.assistantMessageEvent.type === "text_delta"));
      assert.equal((await pi.request({ type: "abort" })).success, true);

      // An idle pi ignores streamingBehavior: nothing is queued, the prompt is an ordinary one.
      assert.equal((await pi.request({ type: "prompt", message: "next", streamingBehavior })).success, true);
      await until("the new run to settle", () => pi.settled() === 2);
      assert.equal(pi.ofType("agent_start").length, 2);
      assert.equal(pi.ofType("queue_update").length, 0, "the message was never queued");
      assert.deepEqual(users(pi.events), ["long task", "next"]);
      assert.deepEqual(shape(pi.requests[1]), ["user:long task", "user:next"]);
      assert.equal((await pi.request({ type: "get_state" })).data.pendingMessageCount, 0);
    });
  });
}

test("real Pi RPC: a prompt during a manual compaction is refused", { timeout: 60000 }, async () => {
  // A summary request carries no tools; the agent's own requests do. Pi may split the summary in two requests.
  const script = (body, i) => body.tools ? [{ text: `Reply ${i}.` }] : [{ gate: "summary" }, { text: "The summary." }];
  await withPi(script, async (pi) => {
    for (const [n, message] of ["one", "two"].entries()) {
      assert.equal((await pi.request({ type: "prompt", message })).success, true);
      await until("the turn to settle", () => pi.settled() === n + 1);
    }
    const compactId = pi.send({ type: "compact" });
    await until("the summary request", () => pi.requests.some((r) => !r.tools));
    assert.equal((await pi.request({ type: "get_state" })).data.isCompacting, true);

    for (const streamingBehavior of ["steer", "followUp", undefined]) {
      const refused = await pi.request({ type: "prompt", message: "too soon", streamingBehavior });
      assert.equal(refused.success, false);
      assert.match(refused.error, /^Cannot submit a prompt while compaction is in progress/);
    }
    assert(!pi.answered(compactId), "the compaction is still running");
    assert.equal(pi.requests.filter((r) => r.tools).length, 2, "nothing else reached the model");
    assert.equal(pi.ofType("agent_start").length, 2, "and no run started");

    pi.fake.release("summary");
    const compacted = await pi.response(compactId, "compact");
    assert.equal(compacted.success, true);
    assert.match(compacted.data.summary, /The summary\./);
    assert.equal((await pi.request({ type: "prompt", message: "three" })).success, true);
    await until("the next run to settle", () => pi.settled() === 3);
    assert(!JSON.stringify(pi.requests.at(-1)).includes("too soon"));
  }, { compaction: { enabled: false, keepRecentTokens: 1 } });
});
