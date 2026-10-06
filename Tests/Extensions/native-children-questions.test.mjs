// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/native-children-questions.test.mjs
// A child never reaches the user: its question goes to its parent, which answers it or asks the user and passes the
// answer down. Real Pi children against a local fake provider, in a temporary directory; no model request leaves the machine.
import test, { before, after } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as http from "node:http";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
process.env.SHEPHERD_MISSIONS = "1"; // These tests cover mission records and the mission parameters, which are off unless this is set (docs/native-subagents.md › Missions).
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to pi's package");
const require = createRequire(path.join(pkg, "package.json"));
const { createJiti } = require("jiti");
const jiti = createJiti(import.meta.url, { alias: {
  "@earendil-works/pi-coding-agent": path.join(pkg, "dist/index.js"),
  "@earendil-works/pi-tui": path.join(pkg, "node_modules/@earendil-works/pi-tui/dist/index.js"),
  "@earendil-works/pi-ai": path.join(pkg, "node_modules/@earendil-works/pi-ai/dist/index.js"),
  typebox: path.join(pkg, "node_modules/typebox/build/index.mjs"),
} });
const source = path.join(root, "Extensions/shepherd-children.ts");
const mod = await jiti.import(source);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, timeout = 20000) { const end = Date.now() + timeout; while (!await fn()) { if (Date.now() > end) throw Error("Timed out waiting for condition"); await sleep(25); } }

const requests = [];
function fixtureServer() {
  return http.createServer(async (req, res) => {
    let raw = ""; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw); requests.push(body);
    const last = body.messages.at(-1);
    const text = typeof last.content === "string" ? last.content : (last.content ?? []).map((p) => p.text ?? "").join("\n");
    const say = (delta, finish = "stop") => {
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta, finish_reason: null }] })}\n\n`);
      res.end(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: finish }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } })}\n\ndata: [DONE]\n\n`);
    };
    const call = (id, name, args) => say({ tool_calls: [{ index: 0, id, type: "function", function: { name, arguments: JSON.stringify(args) } }] }, "tool_calls");
    if (last.role === "user" && text.includes("ASK_PARENT")) {
      const topic = text.match(/ASK_PARENT:(\w+)/)?.[1] ?? "topic";
      call(`ask-${topic}`, "shepherd_parent_message", { message: `Which ${topic} should I use?`, needsReply: true, options: ["Replace everywhere", "Rename new ones"], short: `${topic}?` });
    } else if (last.role === "user" && text.includes("ASK_UI")) {
      call("ask-ui", "ask_user", { question: "Which retention?" });
    } else if (last.role === "tool" && JSON.stringify(body.messages).includes("ASK_SLOW")) {
      await sleep(1200); say({ content: "I asked my parent." });
    } else if (last.role === "user" && text.includes("SLOWER")) {
      await sleep(6000); say({ content: `reply:${text}` });
    } else {
      say({ content: last.role === "tool" ? "tool finished" : `reply:${text}` });
    }
  });
}

// The parent's runtime as the extension sees it: its tools, hooks and what it sends the parent model.
async function harness(dir) {
  const tools = new Map(), commands = new Map(), events = new Map(), messages = [], projections = [], entries = [];
  const bus = new Map();
  const activeTools = ["read", "grep", "find", "ls", "bash", "edit", "write", "ask_user"];
  const pi = { registerCommand(name, command) { commands.set(name, command); }, registerEntryRenderer() {},
    getCommands: () => [...commands.keys()].map((name) => ({ name })), getAllTools: () => [...tools.values()],
    registerTool(tool) { tools.set(tool.name, tool); }, on(name, handler) {
      events.set(name, name === "agent_start" ? (...args) => { events.get("before_agent_start")?.(); return handler(...args); } : handler);
    },
    events: { on(name, fn) { bus.set(name, fn); return () => bus.delete(name); }, emit(name, data) { projections.push(data); bus.get(name)?.(data); } },
    getActiveTools: () => activeTools, appendEntry: (customType, data) => entries.push({ type: "custom", customType, data }),
    sendMessage: (message, options) => messages.push({ message, options }) };
  const ctx = { cwd: dir, thinkingLevel: "off", model: { provider: "fixture", id: "fixture" },
    modelRegistry: { getAll: () => [{ provider: "fixture", id: "fixture" }] },
    sessionManager: { getSessionId: () => "parent-fixture", getEntries: () => entries, getBranch: () => [], getSessionFile: () => undefined } };
  ctx.isProjectTrusted = () => true;
  mod.default(pi, { setInterval, clearInterval }, { SHEPHERD_AGENT_ID: "" });
  await events.get("session_start")({}, ctx);
  const card = (id) => projections.at(-1).children.find((c) => c.runID === id);
  return { tools, events, messages, projections, entries, ctx, card,
    call: async (name, p) => (await tools.get(`shepherd_child_${name}`).execute("call", p, undefined, undefined, ctx)).details,
    tool: async (name, p) => (await tools.get(name).execute("call", p, undefined, undefined, ctx)).details,
    shutdown: () => events.get("session_shutdown")() };
}

let dir, server, saved, h;
before(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-questions-"));
  server = fixtureServer();
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  saved = { ...process.env };
  process.env.HOME = dir; delete process.env.SHEPHERD_CLIPROXYAPI_CONFIG;
  process.env.PI_CODING_AGENT_DIR = path.join(dir, "config"); process.env.PI_OFFLINE = "1";
  process.env.SHEPHERD_NATIVE_CHILDREN = "1"; process.env.SHEPHERD_AGENT_ID = "fixture";
  process.env.SHEPHERD_SOCKET = path.join(dir, "absent.sock"); process.env.SHEPHERD_EXT_CHILDREN = source;
  fs.mkdirSync(process.env.PI_CODING_AGENT_DIR);
  fs.writeFileSync(path.join(process.env.PI_CODING_AGENT_DIR, "models.json"), JSON.stringify({ providers: { fixture: {
    baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "local-fixture-not-secret",
    models: [{ id: "fixture", name: "fixture", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
  } } }));
  // A profile whose tool asks the human through pi's dialog, as an ask-style extension tool does.
  const asker = path.join(dir, "ask-user.ts");
  fs.writeFileSync(asker, `export default function(pi) {
    pi.registerTool({ name: "ask_user", label: "ask", description: "Ask the user a question.",
      parameters: { type: "object", properties: { question: { type: "string" } }, required: ["question"] },
      async execute(_id, params, _signal, _update, ctx) { const answer = await ctx.ui.select(params.question, ["30 days", "13 months"]); return { content: [{ type: "text", text: String(answer) }] }; } });
  }`);
  fs.mkdirSync(path.join(process.env.PI_CODING_AGENT_DIR, "agents"), { recursive: true });
  fs.writeFileSync(path.join(process.env.PI_CODING_AGENT_DIR, "agents", "asker.md"), `---\nname: asker\ndescription: asks the human\ntools: read, ask_user\nextensions: ${asker}\n---\nAsk the human.\n`);
  h = await harness(dir);
});
after(async () => {
  await h?.shutdown();
  await new Promise((r) => server.close(r));
  for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key];
  Object.assign(process.env, saved);
  fs.rmSync(dir, { recursive: true, force: true });
});

const noticesAbout = (id) => h.messages.filter((m) => m.message.content.includes(id));
const askingState = async (id) => (await h.call("wait", { ids: [id], timeoutSeconds: 30 }))[0];
const countOf = (text, needle) => text.split(needle).length - 1;

test("a child is told to ask its parent and never the user, in its prompt and in its tool", async () => {
  assert.match(mod.CHILD_ASK_RULE, /never the user/);
  assert.match(mod.CHILD_ASK_RULE, /shepherd_parent_message with needsReply: true/);
  assert.match(mod.CHILD_ASK_RULE, /finish your turn/);
  const child = await h.call("start", { task: "ASK_PARENT:alias", role: "scout", mission: false });
  const prompt = fs.readFileSync(path.join(path.dirname(child.sessionFile), "prompt.md"), "utf8");
  assert(prompt.includes(mod.CHILD_ASK_RULE), "the injected prompt carries the rule");
  await askingState(child.id);
  const request = requests.find((r) => JSON.stringify(r.messages).includes("ASK_PARENT:alias"));
  const system = JSON.stringify(request.messages);
  assert(system.includes("You never talk to the user"), "the child's system prompt says so");
  assert(system.includes("Never ask the user anything"), "and so does its tool's guideline");
  const tool = request.tools.find((t) => t.function.name === "shepherd_parent_message");
  assert.match(tool.function.description, /You never reach the user/);
  assert.match(tool.function.description, /ask your parent, never the user/);
  assert(request.tools.every((t) => ["read", "grep", "find", "ls", "shepherd_parent_message"].includes(t.function.name)), "no other way to ask");
});

test("a child's question reaches its parent as a hidden notice that says what to do, and wakes an idle parent", async () => {
  h.messages.length = 0;
  const child = await h.call("start", { task: "ASK_PARENT:alias", role: "scout", mission: false });
  await until(() => noticesAbout(child.id).length === 1);
  const [{ message, options }] = noticesAbout(child.id);
  assert.equal(message.display, false, "a coordination notice, not a chat message");
  assert.deepEqual(options, { triggerTurn: true, deliverAs: "followUp" });
  const asked = await askingState(child.id);
  assert.equal(asked.needsReply, true);
  const text = message.content;
  assert(text.includes("Needs reply: Which alias should I use?"));
  assert(text.includes("Options it offered: Replace everywhere | Rename new ones"));
  assert(text.includes(`questionID: ${asked.questionID}`));
  assert(text.includes(mod.PARENT_QUESTION_GUIDE), "the parent's instructions come with the question");
  assert.match(text, /Answer it yourself if you can/);
  assert.match(text, /ask the USER yourself, in your own reply/);
  assert.match(text, /pass the answer down the same way, with the same id and questionID/);
  assert.match(text, /do not ask the user what you can answer/);
  assert.equal(noticesAbout(child.id).length, 1, "a question notifies once, with no completion wake behind it");
  // The notice is the question's only record in the parent's context, so a restored parent still owes the answer.
  assert.equal(h.card(child.id).needsAttention, true);
  assert.equal(h.card(child.id).question.text, "Which alias should I use?");
});

test("wait and result hand the parent the question, its questionID and the call that answers it", async () => {
  const child = await h.call("start", { task: "ASK_PARENT:cache", role: "scout", mission: false });
  const asked = await askingState(child.id);
  assert.equal(asked.needsReply, true);
  assert.match(asked.parentAction, /asked its parent \(you\) a question and waits on you; it never reaches the user/);
  assert(asked.parentAction.includes(`shepherd_child_resume {id: "${child.id}", message: <your answer>, questionID: "${asked.questionID}"}`));
  assert.match(asked.parentAction, /ask the USER yourself in your reply, end your turn, and pass their answer down/);
  const read = await h.call("result", { id: child.id });
  assert.equal(read.questionID, asked.questionID);
  assert(read.parentAction.includes(asked.questionID));
  const list = await h.call("result", {});
  const row = list.find((r) => r.id === child.id);
  assert.deepEqual([row.needsReply, row.questionID, row.question], [true, asked.questionID, "Which cache should I use?"],
    "the list names who still waits, so a question outlives its notice");
  // A child that did not ask has nothing to answer.
  const quiet = await h.call("start", { task: "just work", role: "scout", mission: false });
  const done = await askingState(quiet.id);
  assert.equal(done.parentAction, undefined); assert.equal(done.needsReply, false);
});

test("the parent answers with the questionID and the child continues; an obsolete question is refused", async () => {
  const child = await h.call("start", { task: "ASK_PARENT:index", role: "scout", mission: false });
  const asked = await askingState(child.id);
  await assert.rejects(h.call("resume", { id: child.id, message: "wrong", questionID: "old-attempt/question" }), /Child question changed/);
  await assert.rejects(h.call("message", { id: child.id, message: "wrong", questionID: "old-attempt/question" }), /Child question changed/);
  const answer = "Replace everywhere. The alias is internal.";
  await h.call("resume", { id: child.id, message: answer, questionID: asked.questionID });
  const done = await askingState(child.id);
  assert.equal(done.state, "complete");
  assert.equal(done.needsReply, false, "answering closes the question");
  assert.equal(done.questionID, undefined);
  assert.match(done.output, /reply:Replace everywhere/);
  assert(fs.readFileSync(asked.sessionFile, "utf8").includes(answer), "the child's transcript holds the parent's answer");
  assert.equal(h.card(child.id).needsAttention, false);
  assert.equal(h.card(child.id).question, undefined);
  // The same questionID answers nothing twice.
  await assert.rejects(h.call("resume", { id: child.id, message: "again", questionID: asked.questionID }), /Child question changed/);
  // shepherd_child_message takes the answer as well: it resumes a child that finished its turn to wait for it.
  const second = await h.call("start", { task: "ASK_PARENT:index2", role: "scout", mission: false });
  const secondAsked = await askingState(second.id);
  const receipt = await h.call("message", { id: second.id, message: "Rename new ones", questionID: secondAsked.questionID });
  assert.equal(receipt.id, second.id);
  const secondDone = await askingState(second.id);
  assert.match(secondDone.output, /reply:Rename new ones/);
  assert.equal(secondDone.needsReply, false);
});

test("an answer that comes while the child is still finishing the turn it asked in waits for it, and is not lost with it", async () => {
  const child = await h.call("start", { task: "ASK_PARENT:race ASK_SLOW", role: "scout", mission: false });
  const dir = path.dirname(child.sessionFile), status = () => JSON.parse(fs.readFileSync(path.join(dir, "status.json")));
  await until(() => status().needsReply === true);
  assert.equal(status().state, "running", "the child asked and is still writing its last words");
  const answer = "Replace everywhere, quickly.";
  // The parent, woken by the question, answers at once: a message into that turn would end with the turn's process.
  await h.call("message", { id: child.id, message: answer, questionID: status().questionID });
  const done = await askingState(child.id);
  assert.equal(done.state, "complete");
  assert.equal(done.needsReply, false);
  assert.match(done.output, /reply:Replace everywhere, quickly\./, "the child answered from its parent's words, not from its first turn");
  assert(fs.readFileSync(child.sessionFile, "utf8").includes(answer));
});

test("a user's own steer closes the question, and the parent's later answer to it is refused as obsolete", async () => {
  const child = await h.call("start", { task: "ASK_PARENT:steer", role: "scout", mission: false });
  const asked = await askingState(child.id);
  const dir = path.dirname(asked.sessionFile), status = () => JSON.parse(fs.readFileSync(path.join(dir, "status.json")));
  // The inspector's Steer (and an older client's Answer) is a message to the child, still accepted.
  fs.writeFileSync(path.join(dir, "control", "steer-requests", "steer.json"), JSON.stringify({ message: "Use the old one" }));
  await until(() => status().controlRequestID === "steer" && status().controlNotice === "reply accepted or queued");
  const done = await askingState(child.id);
  assert.match(done.output, /reply:Use the old one/);
  assert.equal(done.needsReply, false);
  await assert.rejects(h.call("resume", { id: child.id, message: "late", questionID: asked.questionID }), /Child question changed/);
});

test("Stop on a child waiting for its parent closes the question instead of leaving it to wait", async () => {
  const child = await h.call("start", { task: "ASK_PARENT:stop", role: "scout", mission: false });
  const asked = await askingState(child.id);
  assert.equal(asked.needsReply, true);
  const stopped = await h.call("cancel", { id: child.id });
  assert.equal(stopped.state, "stopped");
  assert.equal(stopped.needsReply, false);
  assert.equal(h.card(child.id).needsAttention, false);
  await assert.rejects(h.call("resume", { id: child.id, message: "late", questionID: asked.questionID }), /Child question changed/);
});

test("a question wakes the parent in report delivery too, while a report completion does not", async () => {
  h.messages.length = 0;
  const report = await h.call("start", { task: "ASK_PARENT:report", role: "scout", mission: false, delivery: "report" });
  await until(() => noticesAbout(report.id).length === 1);
  assert.equal(noticesAbout(report.id)[0].options.triggerTurn, true, "a blocking question notifies in either mode");
  assert(noticesAbout(report.id)[0].message.content.includes(mod.PARENT_QUESTION_GUIDE));
  const quiet = await h.call("start", { task: "just report", role: "scout", mission: false, delivery: "report" });
  await until(() => noticesAbout(quiet.id).length === 1);
  assert.equal(noticesAbout(quiet.id)[0].options.triggerTurn, false, "a report completion only adds context");
  assert(!noticesAbout(quiet.id)[0].message.content.includes(mod.PARENT_QUESTION_GUIDE));
});

test("a working parent gets the question at its settlement boundary, several children in one delivery with the instructions once", async () => {
  h.messages.length = 0;
  h.events.get("agent_start")();
  const ids = [], files = {}, questionIDs = {};
  for (const topic of ["port", "name", "scope"]) {
    const child = await h.call("start", { task: `ASK_PARENT:${topic}`, role: "scout", mission: false });
    ids.push(child.id); files[child.id] = path.join(path.dirname(child.sessionFile), "status.json");
  }
  await until(() => ids.every((id) => h.card(id)?.needsAttention === true && h.card(id).state === "complete"));
  // Not read through result or wait, which would consume the notices this test is about.
  for (const id of ids) questionIDs[id] = JSON.parse(fs.readFileSync(files[id], "utf8")).questionID;
  assert.equal(h.messages.length, 0, "a working parent is not interrupted by a question");
  const boundary = h.events.get("agent_before_settle")({ entries: [], outcome: "completed" });
  assert.equal(boundary.continue, true, "the question gets the parent one more turn");
  assert.equal(boundary.entries.length, 1, "one continuation for all three");
  const text = boundary.entries[0].content;
  assert.equal(boundary.entries[0].display, false);
  for (const id of ids) {
    assert(text.includes(`Child ${id} (scout): Needs reply:`));
    assert(text.includes(`questionID: ${questionIDs[id]}`));
  }
  assert.equal(countOf(text, mod.PARENT_QUESTION_GUIDE), 1, "the instructions are said once for all of them");
  assert.match(text, /With several questions, answer what you can and put the rest in one message to the user, naming each child/);
  assert.equal(h.events.get("agent_before_settle")({ entries: [], outcome: "completed" }), undefined, "and it notifies once");
  h.events.get("agent_settled")();
  // Whatever the parent could not answer survives the turn it asked the user in: the children still wait, with their ids.
  const owed = (await h.call("result", {})).filter((r) => r.needsReply).map((r) => r.id);
  for (const id of ids) assert(owed.includes(id));
  // The user's reply arrives in a later turn; the parent passes it down and the children go on.
  for (const id of ids) {
    const { questionID } = await h.call("result", { id });
    await h.call("resume", { id, message: "Use the default.", questionID });
  }
  for (const id of ids) assert.match((await askingState(id)).output, /reply:Use the default\./);
});

test("a wait for all hands the parent a child that asked without holding it for the others", async () => {
  const slow = await h.call("start", { task: "SLOWER work", role: "scout", mission: false });
  const asking = await h.call("start", { task: "ASK_PARENT:wait", role: "scout", mission: false });
  const started = Date.now();
  const results = await h.call("wait", { ids: [slow.id, asking.id], all: true, timeoutSeconds: 30 });
  const byID = Object.fromEntries(results.map((r) => [r.id, r]));
  assert.equal(byID[asking.id].needsReply, true);
  assert(byID[asking.id].parentAction.includes(byID[asking.id].questionID));
  assert.equal(byID[slow.id].state, "running", `the slow child is still running (${Date.now() - started} ms)`);
  await h.call("cancel", { id: slow.id });
  await h.call("cancel", { id: asking.id });
});

test("a workflow's child that asks reaches the parent with its questionID, once the workflow ends", async () => {
  h.messages.length = 0;
  const script = 'const [a, b] = await runs.all([{ key: "asks", agent: "scout", task: "ASK_PARENT:flow" }, { key: "works", agent: "scout", task: "just work" }]); return { asked: a.needsReply === true, question: a.question, other: b.ok };';
  const sync = await h.tool("shepherd_workflow", { async: false, mission: false, workflowScript: script });
  assert.equal(sync.state, "complete", sync.error);
  assert.deepEqual([sync.output.asked, sync.output.question, sync.output.other], [true, "Which flow should I use?", true],
    "runs.all marks the child that asked, so a script never takes its question for a result");
  const asking = sync.children.find((c) => c.key === "asks");
  assert.equal(asking.needsReply, true);
  assert.equal(typeof asking.questionID, "string");
  assert.equal(sync.children.find((c) => c.key === "works").needsReply, undefined);
  assert.match(sync.parentAction, /asked you a question and wait on you, never on the user/);
  assert.match(sync.parentAction, /shepherd_child_resume \{id, message, questionID\}/);
  // The workflow is over, so the parent answers it like any child.
  await h.call("resume", { id: asking.id, message: "Use the shared flow.", questionID: asking.questionID });
  assert.match((await askingState(asking.id)).output, /reply:Use the shared flow\./);

  // Asynchronously the question rides the workflow's completion notice, and wakes the parent even in report delivery.
  h.messages.length = 0;
  const started = await h.tool("shepherd_workflow", { mission: false, delivery: "report",
    workflowScript: 'return await runs.run("asks", { agent: "scout", task: "ASK_PARENT:async" });' });
  await until(() => noticesAbout(started.id).length === 1);
  const [{ message, options }] = noticesAbout(started.id);
  assert.equal(options.triggerTurn, true, "a question wakes the parent although the workflow reports quietly");
  const child = (await h.tool("shepherd_workflow", { action: "status", id: started.id })).children[0];
  assert(message.content.includes(`Child ${child.id} (scout): Needs reply: Which async should I use?`));
  assert(message.content.includes(`questionID: ${child.questionID}`));
  assert(message.content.includes(mod.PARENT_QUESTION_GUIDE));
  await h.call("cancel", { id: child.id });
});

test("a child that tries to open a human dialog is stopped and told to ask its parent", async () => {
  const child = await h.call("start", { task: "ASK_UI", agent: "asker", mission: false });
  const failed = await askingState(child.id);
  assert(["failed", "stopped"].includes(failed.state), failed.state);
  assert.match(failed.error, /unsupported human interaction \(select\): Which retention\?/);
  assert.match(failed.error, /ask your parent with shepherd_parent_message \(needsReply: true\)/);
  assert.equal(failed.needsReply, false, "a refused dialog is not a question to the parent either");
});
