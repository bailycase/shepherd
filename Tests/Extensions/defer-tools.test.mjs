// Deferred tools (docs/context-budget.md › Deferred tools): Shepherd's rarely used tools (the browser's, the ones that reach other
// threads, the automation tools and review_diff) are registered `deferred` while SHEPHERD_DEFER_TOOLS=1, so pi sends none of them until
// the model loads them with tool_search. The status extension keeps tool_search reachable, says in one rule line that they exist, and
// loads a whole family when the best match of a search is one of its tools. Real pi in RPC mode on a fake provider that records every
// request, with a stand-in for the app's extension socket that answers the tools, and unit checks of the status extension.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/defer-tools.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import * as path from "node:path";
import * as fs from "node:fs";
import * as os from "node:os";
import { createRequire } from "node:module";
import { root, capture, scriptedBashCalls, startThread } from "./context-harness.mjs";

const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");

const BROWSER = ["browser_open", "browser_read", "browser_click", "browser_type", "browser_press", "browser_scroll", "browser_wait",
  "browser_screenshot", "browser_console", "browser_eval", "browser_back", "browser_forward", "browser_reload"];
const PEERS = ["agent_list", "agent_send", "agent_read", "agent_steer", "agent_interrupt", "agent_wait", "agent_delete", "agent_spawn"];
const AUTOMATIONS = ["automation_create", "automation_list", "automation_update", "automation_delete", "automation_start", "automation_stop"];
const DEFERRED = [...BROWSER, ...PEERS, ...AUTOMATIONS, "review_diff"];
const DIRECT = ["read", "bash", "edit", "write", "terminal_list", "terminal_open", "terminal_run", "terminal_read", "terminal_focus", "terminal_close", "notify",
  "shepherd_child_agents", "shepherd_child_start", "shepherd_child_message", "shepherd_child_result", "shepherd_child_wait", "shepherd_child_cancel",
  "shepherd_child_resume", "shepherd_workflow"];

const names = (request) => request.body.tools.map((tool) => tool.name);
const outputs = (request) => request.body.input.filter((item) => item.type === "function_call_output").map((item) => String(item.output));
const systemText = (request) => request.body.input.filter((item) => item.role === "system" || item.role === "developer")
  .map((item) => typeof item.content === "string" ? item.content : JSON.stringify(item.content)).join("\n");
const script = (steps) => { let i = 0; return () => steps[i++] ?? {}; };
const search = (query) => ({ tool: { name: "tool_search", arguments: { query } } });
const call = (name, args = {}) => ({ tool: { name, arguments: args } });

/** The app's side of the socket, for the four families: what each tool asks for, and a short answer. */
function app(frame, reply) {
  switch (frame.type) {
    case "browser": return reply({ type: "browserResult", id: frame.id, text: `Page: ${frame.request?.url ?? frame.request?.action}` });
    case "listAgents": return reply({ type: "agents", id: frame.id, agents: [{ id: "a-1", name: "api", status: "idle", cwd: "/work/api", isSelf: false }] });
    case "listAutomations": return reply({ type: "automations", id: frame.id, automations: [] });
    case "requestReview": return reply({ type: "review", id: frame.id, text: "Review ready in the Changes tab" });
    default: return undefined;
  }
}

async function run(options, steps, message = "do it") {
  const thread = await startThread({ needsName: false, onFrame: app, onRequest: script(steps), ...options });
  try {
    await thread.turn(message, 120000);
    return { thread, requests: thread.mainRequests(), events: thread.events };
  } catch (error) {
    await thread.stop();
    throw error;
  }
}

// MARK: what a thread starts with

test("a thread's first request carries none of the deferred tools or their lines, and one rule line says they exist", { timeout: 120000 }, async () => {
  const first = await capture("thread", { pkg });
  const sent = first.body.tools.map((tool) => tool.name);
  for (const name of DEFERRED) assert.ok(!sent.includes(name), `${name} is not sent before a search`);
  for (const name of [...DIRECT, "tool_search"]) assert.ok(sent.includes(name), `${name} is sent`);
  const system = JSON.stringify(first.body.input) + String(first.body.instructions ?? "");
  for (const name of DEFERRED) assert.ok(!system.includes(`- ${name}:`), `${name} has no line in the tool list`);
  assert.equal(first.activeTools.includes("browser_open"), false);
  assert.ok(first.toolSources.browser_open.endsWith("shepherd-browser.ts"), "the tool is registered, only not declared");
  // One line, naming each family, and the rule about what arrives, written once.
  const lines = system.split("\\n- ").filter((line) => line.startsWith("Shepherd tools you load with tool_search"));
  assert.equal(lines.length, 1, "one line");
  assert.match(lines[0], /agent_\* \(other agent threads, only when the user explicitly asks you to\); automation_\* \(Shepherd automations, the saved watch tasks\); review_diff \(.*\); browser_\* \(this thread's Browser page/);
  assert.equal(system.split("A message that begins with [from: <name>]").length, 2);
  assert.ok(!system.includes("Use agent_send, agent_steer"), "the rule about using the tools joins when they load");
  assert.ok(!system.includes("browser_* tools drive"), "and the browser's own rules too");
});

test("a thread with every tool direct is what it was: the switch off sends all of them, and no line", { timeout: 120000 }, async () => {
  const off = await capture("thread-defer-off", { pkg });
  const sent = off.body.tools.map((tool) => tool.name);
  for (const name of [...DEFERRED, ...DIRECT]) assert.ok(sent.includes(name), `${name} is sent`);
  assert.ok(!JSON.stringify(off.body.input).includes("Shepherd tools you load with tool_search"));
  assert.ok(JSON.stringify(off.body.input).includes("- browser_open: Open a URL in the thread's Browser page"), "with its line in the tool list");
});

test("without tool_search in the launch the deferred tools are declared like any other rather than left unreachable", { timeout: 120000 }, async () => {
  const { thread, requests } = await run({ mcp: false, toolSearch: false }, []);
  try {
    const sent = names(requests[0]);
    for (const name of [...DEFERRED, ...DIRECT]) assert.ok(sent.includes(name), `${name} is sent`);
    assert.ok(!sent.includes("tool_search"));
    assert.ok(!systemText(requests[0]).includes("Shepherd tools you load with tool_search"), "and no line says to search for them");
  } finally { await thread.stop(); }
});

test("with MCP off the launch still starts pi's tool_search by name, over the home's switch that turns it off, and it loads a family", { timeout: 120000 }, async () => {
  // PiHome.install writes these three to the home's settings.json: an explicit `-e builtin:tool-search` is what wins over them.
  const OFF = ["-builtin:mcp", "-builtin:codemode", "-builtin:tool-search"];
  const { thread, requests } = await run({ mcp: false, settings: { extensions: OFF } }, [search("open a web page"), call("browser_open", { url: "https://example.com/" })]);
  try {
    assert.ok(names(requests[0]).includes("tool_search") && !names(requests[0]).includes("mcp__docs__echo"), "tool_search without any MCP");
    for (const name of BROWSER) assert.ok(names(requests[1]).includes(name), name);
    assert.equal(outputs(requests[2]).at(-1), "Page: https://example.com/");
    assert.ok(!(await thread.request({ type: "get_commands" })).data.commands.some((command) => command.name === "mcp"), "and no /mcp: only the search was switched on");
  } finally { await thread.stop(); }
});

// MARK: finding a tool, loading it, calling it

const FAMILIES = [
  ["the browser", "open a web page", BROWSER, call("browser_open", { url: "https://example.com/" }), /^Page: https:\/\/example\.com\/$/],
  ["other threads", "message another agent", PEERS, call("agent_list"), /^a-1  api  \[idle\]  \/work\/api/],
  ["automations", "create an automation", AUTOMATIONS, call("automation_list"), /^no automations$/],
  ["the diff review", "show me the diff", ["review_diff"], call("review_diff"), /^Review ready in the Changes tab$/],
];

for (const [label, query, family, use, answer] of FAMILIES) {
  test(`${label}: a search for "${query}" loads the family, the next request declares it, and a call to it answers`, { timeout: 120000 }, async () => {
    const { thread, requests, events } = await run({}, [search(query), use]);
    try {
      assert.equal(requests.length, 3, "the search, the call, the answer");
      for (const name of family) assert.ok(!names(requests[0]).includes(name), `${name} is not in the first request`);
      for (const name of family) assert.ok(names(requests[1]).includes(name), `${name} is declared after the search`);
      const found = outputs(requests[1])[0];
      const loaded = names(requests[1]).filter((name) => !names(requests[0]).includes(name));
      assert.match(found, new RegExp(`^Loaded ${loaded.length} tools?\\.`), "the count it says is the count that loaded: " + found.slice(0, 120));
      assert.ok(found.includes(`- ${family[0]}:`) || family.length === 1 || /Loaded with them, from the same set/.test(found), "and the result names what loaded");
      assert.match(outputs(requests[2]).at(-1), answer, "the call answered");
      // No other family came whole: a weak match by a word they share (browser_wait for "show") is the most that can.
      for (const other of [BROWSER, PEERS, AUTOMATIONS].filter((other) => other !== family)) {
        assert.ok(other.some((name) => !names(requests[2]).includes(name)), `${other[0]}'s family is still deferred`);
      }
      assert.ok(!events.some((event) => event.type === "extension_error"), JSON.stringify(events.filter((event) => event.type === "extension_error")));
    } finally { await thread.stop(); }
  });
}

test("a search for something an MCP server offers loads the weaker matches it always did, but not their families", { timeout: 120000 }, async () => {
  const { thread, requests } = await run({ env: { FAKE_MCP_TOOLS: "20" } }, [search("create an issue")]);
  try {
    const loaded = names(requests[1]).filter((name) => !names(requests[0]).includes(name));
    assert.ok(loaded.some((name) => /^mcp__\w+__create_issue$/.test(name)), `the servers' tools load: ${loaded}`);
    // Whatever else the search loads by a word they share (pi loads every match up to its limit), a family never comes with it.
    assert.ok(AUTOMATIONS.filter((name) => loaded.includes(name)).length <= 1, `no automation family: ${loaded}`);
    assert.ok(!BROWSER.some((name) => loaded.includes(name)) && !PEERS.some((name) => loaded.includes(name)), `no other family: ${loaded}`);
  } finally { await thread.stop(); }
});

// MARK: clearing, and the cache

test("clearing the search result out of the request does not unload the tools, and a call to one after it answers", { timeout: 240000 }, async () => {
  const LINE = "lorem ipsum dolor sit amet consectetur adipiscing elit";
  const bulk = (tag) => `awk 'BEGIN{for(i=1;i<=200;i++) printf "%d ${LINE} ${tag}%d\\n", i, i}'`;
  const BULK = 24;
  const steps = [search("open a web page"), call("browser_open", { url: "https://example.com/before" }),
    ...Array.from({ length: BULK }, (_, i) => ({ call: bulk(i) })), call("browser_open", { url: "https://example.com/after" })];
  const { thread, requests } = await run({ contextWindow: 60_000, usage: (entry) => ({ input: Math.ceil(JSON.stringify(entry.body).length / 4), output: 40 }) }, steps, "search the tools, use one, then read a lot");
  try {
    const last = requests.at(-1);
    const [searchOutput] = outputs(last);
    assert.match(searchOutput, /^\[tool_search .*output removed from context: about /, "the batch cleared the search result");
    for (const request of requests.slice(1)) for (const name of BROWSER) assert.ok(names(request).includes(name), `${name} is declared in request ${request.index}`);
    assert.equal(outputs(last).at(-1), "Page: https://example.com/after", "and the call after the clearing answered");
  } finally { await thread.stop(); }
});

test("loading changes the request from its head on a model that cannot take a tool in place, and appends it on one that can, until something is cleared", { timeout: 240000 }, async () => {
  const anchored = { supportsAdditionalTools: true, supportsMidConvoSystemMessages: true };
  const tail = (request) => request.body.input.map((item) => item.type ?? item.role);
  const plain = await run({ trim: false }, [search("open a web page"), call("browser_open", { url: "https://example.com/" })]);
  const placed = await run({ trim: false, compat: anchored }, [search("open a web page"), call("browser_open", { url: "https://example.com/" })]);
  try {
    // Plain: the tool list sent is longer, so a cached prefix of the request ends at the first difference, in the tools.
    assert.equal(names(plain.requests[0]).length + BROWSER.length, names(plain.requests[1]).length);
    assert.ok(!tail(plain.requests[1]).includes("additional_tools"));
    // Anchored: the same tools at the top, the new ones where they were loaded, and everything before them as it was.
    assert.deepEqual(names(placed.requests[1]), names(placed.requests[0]));
    assert.ok(tail(placed.requests[1]).includes("additional_tools"));
    const before = JSON.stringify(placed.requests[0].body.input), after = JSON.stringify(placed.requests[1].body.input);
    assert.ok(after.startsWith(before.slice(0, -1)), "the earlier request is a prefix of the later one");
  } finally { await plain.thread.stop(); await placed.thread.stop(); }
});

test("a compaction keeps what a search loaded declared", { timeout: 240000 }, async () => {
  // pi compacts when the window fills, which is what this change is for: a thread that opened the browser must not lose it then.
  const row = (turn, call) => `awk 'BEGIN{for(i=1;i<=${call === 1 ? 800 : 220};i++) printf "%d.${call}.%d ${"x".repeat(call === 1 ? 50 : 45)} %d\\n", ${turn}, i, i}'`;
  const plan = (turn) => turn === 0 ? [search("open a web page"), call("browser_open", { url: "https://example.com/" })] : [row(turn, 1), row(turn, 2)];
  const thread = await startThread({ needsName: false, onFrame: app, onRequest: scriptedBashCalls(plan), usage: (entry) => ({ input: Math.ceil(JSON.stringify(entry.body).length / 4), output: 40 }) });
  try {
    for (let turn = 0; turn < 5; turn++) await thread.turn(`turn ${turn}`, 120000);
    const compacted = await thread.request({ type: "compact" });
    assert.ok(compacted.success, JSON.stringify(compacted));
    const before = thread.mainRequests().length;
    await thread.turn("after the compaction", 120000);
    const after = thread.mainRequests().slice(before);
    assert.ok(after.length > 0);
    for (const request of after) for (const name of BROWSER) assert.ok(names(request).includes(name), `${name} is declared after the compaction`);
    assert.ok(JSON.stringify(after[0].body.input).includes("The conversation history before this point was compacted into the following summary"), "the compaction really replaced the early conversation");
  } finally { await thread.stop(); }
});

// MARK: a restart

test("a restart keeps what a search loaded, and a thread from before deferral resumes deferred", { timeout: 240000 }, async () => {
  // Shepherd resumes an agent's session in a new pi (`--session-id`), where pi 1.0 does not bring back what tool_search loaded
  // (checked on an MCP tool too): the status extension reads it off the transcript.
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "defer-resume-"));
  try {
    const first = await startThread({ dir: folder, keepDir: true, needsName: false, onFrame: app, onRequest: script([search("open a web page")]) });
    await first.turn("open a page");
    const before = first.mainRequests();
    assert.ok(!names(before[0]).includes("browser_open") && names(before[1]).includes("browser_open"));
    await first.stop();
    const resumed = await startThread({ dir: folder, keepDir: true, needsName: false, onFrame: app });
    await resumed.turn("and now?");
    const [request] = resumed.mainRequests();
    assert.ok(request.body.input.some((item) => item.type === "function_call"), "the session was resumed, not started over");
    for (const name of BROWSER) assert.ok(names(request).includes(name), `${name} is still loaded`);
    for (const name of [...PEERS, ...AUTOMATIONS, "review_diff"]) assert.ok(!names(request).includes(name), `${name} was never loaded`);
    await resumed.stop();

    // A session that began with every tool direct has nothing a search loaded: it resumes with the deferral on.
    fs.rmSync(folder, { recursive: true, force: true });
    fs.mkdirSync(folder);
    const old = await startThread({ dir: folder, keepDir: true, needsName: false, defer: false });
    await old.turn("hello");
    assert.ok(names(old.mainRequests()[0]).includes("browser_open"));
    await old.stop();
    const next = await startThread({ dir: folder, keepDir: true, needsName: false });
    await next.turn("hello again");
    assert.ok(next.mainRequests()[0].body.input.length > 2, "the session was resumed, not started over");
    assert.ok(!names(next.mainRequests()[0]).includes("browser_open"), "the first set is the launch's own, not a load");
    await next.stop();
  } finally {
    fs.rmSync(folder, { recursive: true, force: true });
  }
});

// MARK: the other kinds of agent

test("a watch agent keeps agent_send, terminals and notify direct and defers the browser and the review", { timeout: 120000 }, async () => {
  const run1 = await capture("automation", { pkg });
  const sent = run1.body.tools.map((tool) => tool.name);
  for (const name of ["agent_send", "notify", "terminal_open", "shepherd_child_start", "tool_search"]) assert.ok(sent.includes(name), name);
  for (const name of [...BROWSER, "review_diff"]) assert.ok(!sent.includes(name), `${name} is deferred`);
  for (const name of [...PEERS.filter((name) => name !== "agent_send"), ...AUTOMATIONS]) assert.ok(!run1.toolSources[name], `${name} is not registered for a watch agent`);
  const system = JSON.stringify(run1.body.input);
  const line = /Shepherd tools you load with tool_search when you need them: ([^"\\]*)/.exec(system)[1];
  assert.match(line, /^review_diff \(.*\); browser_\* \(/, line);
  assert.ok(!/agent_\*|automation_\*/.test(line), "the line names only what it can load");
  assert.ok(system.includes("Use agent_send, agent_steer"), "agent_send carries the rules it always did");
});

test("a design's agent gets exactly its own tools, none deferred and no line about any", { timeout: 120000 }, async () => {
  const design = await capture("design", { pkg });
  const sent = design.body.tools.map((tool) => tool.name);
  for (const name of ["design_read", "board_write", "board_edit", "canvas_update", "design_check", "comment_list", "comment_reply", "system_read", "system_write"]) assert.ok(sent.includes(name), name);
  for (const name of [...BROWSER, ...PEERS, ...AUTOMATIONS, "review_diff"]) assert.ok(!design.toolSources[name], `${name} is not registered for a design's agent`);
  assert.ok(sent.includes("shepherd_child_start"), "the helpers it relays through stay");
  assert.ok(!JSON.stringify(design.body.input).includes("Shepherd tools you load with tool_search"));
});

test("a thread that holds a design reference keeps design_get and design_note direct next to the deferred tools", { timeout: 120000 }, async () => {
  const held = await capture("thread-with-design-reference", { pkg });
  const sent = held.body.tools.map((tool) => tool.name);
  assert.ok(sent.includes("design_get") && sent.includes("design_note"));
  for (const name of DEFERRED) assert.ok(!sent.includes(name), `${name} is deferred`);
});

test("a native helper's pi is sent pi's four tools and the way to ask its parent, with no search and no line about deferred tools", { timeout: 120000 }, async () => {
  const helper = await capture("subagent", { pkg });
  assert.deepEqual(helper.body.tools.map((tool) => tool.name), ["read", "bash", "edit", "write", "shepherd_parent_message"]);
  for (const name of DEFERRED) assert.ok(!helper.toolSources[name], `${name} is not registered for a helper`);
  assert.ok(!JSON.stringify(helper.body.input).includes("tool_search"), "it has no tool search to name");
});

test("a native subagent and a design's agent never register the browser, with deferral on or off", async () => {
  const require = createRequire(path.join(pkg, "package.json"));
  const { createJiti } = require("jiti");
  const jiti = createJiti(import.meta.url, { alias: { "@earendil-works/pi-coding-agent": path.join(pkg, "dist/index.js"), typebox: path.join(pkg, "node_modules/typebox/build/index.mjs") } });
  const { default: browser } = await jiti.import(path.join(root, "Extensions/shepherd-browser.ts"));
  const base = { SHEPHERD_EXT_BROWSER: "1", SHEPHERD_AGENT_ID: "a", SHEPHERD_SOCKET: "/tmp/none.sock" };
  for (const extra of [{ SHEPHERD_CHILD: "1" }, { SHEPHERD_DESIGN_ID: "d" }]) {
    for (const defer of [undefined, "1"]) {
      const saved = Object.fromEntries(Object.keys({ ...base, ...extra, SHEPHERD_DEFER_TOOLS: 1 }).map((key) => [key, process.env[key]]));
      Object.assign(process.env, base, extra);
      if (defer) process.env.SHEPHERD_DEFER_TOOLS = defer; else delete process.env.SHEPHERD_DEFER_TOOLS;
      try {
        const registered = [];
        browser({ registerTool: (tool) => registered.push(tool.name), on() {} });
        assert.deepEqual(registered, [], JSON.stringify({ ...extra, defer }));
      } finally {
        for (const [key, value] of Object.entries(saved)) if (value === undefined) delete process.env[key]; else process.env[key] = value;
      }
    }
  }
});

// MARK: the status extension on its own

const status = await createRequire(path.join(pkg, "package.json"))("jiti").createJiti(import.meta.url, { alias: {
  "@earendil-works/pi-coding-agent": path.join(pkg, "dist/index.js"),
} }).import(path.join(root, "Extensions/shepherd-status.ts"));

/** A pi with a registry of tools: `getAllTools`, the active set and the handlers the extension registers. */
function fakePi(registered, { active = [] } = {}) {
  const handlers = {};
  const state = { active: [...active], sets: 0 };
  const pi = {
    getSettings: () => ({}),
    on: (event, handler) => { (handlers[event] ??= []).push(handler); },
    registerCommand() {},
    getAllTools: () => registered,
    getActiveTools: () => [...state.active],
    setActiveTools: (list) => { state.active = [...list]; state.sets++; },
    sendUserMessage() {},
  };
  return { pi, handlers, state };
}

const tool = (name, exposure, namespace) => ({ name, exposure, ...(namespace ? { namespace } : {}), description: name, parameters: {} });
const BROWSER_NS = { name: "shepherd_browser", description: "this thread's Browser page: open, read" };
const PEER_NS = { name: "shepherd_agents", description: "other agent threads, only when the user explicitly asks you to" };
const REGISTRY = [
  tool("read", undefined), tool("tool_search", "model-only"),
  tool("agent_list", "deferred", PEER_NS), tool("agent_send", "deferred", PEER_NS),
  tool("review_diff", "deferred", { name: "shepherd_review", description: "a diff review" }),
  tool("browser_open", "deferred", BROWSER_NS), tool("browser_read", "deferred", BROWSER_NS), tool("browser_click", "deferred", BROWSER_NS),
  tool("mcp__docs__echo", "deferred", { name: "mcp__docs", description: "docs" }),
];

/** A branch as pi records it: a first system message with the launch's tools, user turns, and later system messages that changed the set. */
const system = (added, removed = []) => ({ type: "message", message: { role: "system", content: "", toolsAdded: added.map((name) => ({ name })), toolsRemoved: removed.map((name) => ({ name })) } });
const user = { type: "message", message: { role: "user", content: "hi" } };

async function statusWith(env, registry, options) {
  const saved = {};
  const values = { SHEPHERD_AGENT_ID: "a1", SHEPHERD_SOCKET: "/tmp/defer-none.sock", ...env };
  for (const key of ["SHEPHERD_AGENT_ID", "SHEPHERD_SOCKET", "SHEPHERD_DEFER_TOOLS"]) { saved[key] = process.env[key]; delete process.env[key]; }
  Object.assign(process.env, values);
  const fake = fakePi(registry, options);
  try { status.default(fake.pi); } finally {
    for (const [key, value] of Object.entries(saved)) if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
  const fire = async (event, payload = {}, branch = []) => { let result; for (const handler of fake.handlers[event] ?? []) result = (await handler(payload, { sessionManager: { getSessionId: () => "s", getBranch: () => branch }, ui: { notify() {} } })) ?? result; return result; };
  return { ...fake, fire, close: () => fire("session_shutdown") };
}

test("without SHEPHERD_DEFER_TOOLS the status extension does nothing about tools", async () => {
  const s = await statusWith({}, REGISTRY, { active: ["read"] });
  await s.fire("session_start");
  assert.deepEqual(s.state.active, ["read"], "tool_search is not activated");
  assert.equal(s.handlers.tool_result, undefined, "and it listens for no tool result");
  const options = { promptGuidelines: [] };
  await s.fire("before_agent_start", { systemPromptOptions: options });
  assert.deepEqual(options.promptGuidelines, []);
  await s.close();
});

test("with deferral on it activates tool_search once, which pi's MCP does only for a server on Search", async () => {
  const s = await statusWith({ SHEPHERD_DEFER_TOOLS: "1" }, REGISTRY, { active: ["read"] });
  await s.fire("session_start");
  assert.deepEqual(s.state.active, ["read", "tool_search"]);
  await s.fire("session_start");
  assert.equal(s.state.sets, 1, "a resumed or reloaded session finds it active and leaves it");
  await s.close();
});

test("a restart brings back the Shepherd tools a search loaded, as the transcript's later system messages say, and nothing else", async () => {
  const s = await statusWith({ SHEPHERD_DEFER_TOOLS: "1" }, REGISTRY, { active: ["read"] });
  const branch = [system(["read", "tool_search"]), user, system(["browser_open", "browser_read", "browser_click", "mcp__docs__echo"]), user, system([], ["browser_click"])];
  await s.fire("session_start", {}, branch);
  assert.deepEqual(s.state.active, ["read", "tool_search", "browser_open", "browser_read"], "loaded, not removed since, and only Shepherd's deferred tools");
  await s.close();
  // The first message is the launch's own set: a thread that began with every tool direct resumes deferred.
  const old = await statusWith({ SHEPHERD_DEFER_TOOLS: "1" }, REGISTRY, { active: ["read"] });
  await old.fire("session_start", {}, [system(["read", "agent_list", "browser_open", "browser_read"]), user, user]);
  assert.deepEqual(old.state.active, ["read", "tool_search"]);
  // A session with no branch, or one that cannot be read, starts clean.
  const fresh = await statusWith({ SHEPHERD_DEFER_TOOLS: "1" }, REGISTRY, { active: ["read"] });
  await fresh.fire("session_start", {}, undefined);
  assert.deepEqual(fresh.state.active, ["read", "tool_search"]);
  await old.close(); await fresh.close();
});

test("with deferral on and no tool_search, it declares the deferred Shepherd tools and leaves MCP's alone", async () => {
  const s = await statusWith({ SHEPHERD_DEFER_TOOLS: "1" }, REGISTRY.filter((t) => t.name !== "tool_search"), { active: ["read"] });
  await s.fire("session_start");
  assert.deepEqual(s.state.active, ["read", "agent_list", "agent_send", "review_diff", "browser_open", "browser_read", "browser_click"]);
  await s.close();
});

test("the rule line names each family by its prefix, with the namespace's words, in registration order, and only once per prompt", async () => {
  const s = await statusWith({ SHEPHERD_DEFER_TOOLS: "1" }, REGISTRY, { active: ["read", "tool_search"] });
  const options = { promptGuidelines: ["Be kind"] };
  await s.fire("before_agent_start", { systemPromptOptions: options });
  await s.fire("before_agent_start", { systemPromptOptions: options });
  assert.deepEqual(options.promptGuidelines, ["Be kind",
    "Shepherd tools you load with tool_search when you need them: agent_* (other agent threads, only when the user explicitly asks you to); " +
    "review_diff (a diff review); browser_* (this thread's Browser page: open, read)."]);
  const none = { promptGuidelines: [] };
  const bare = await statusWith({ SHEPHERD_DEFER_TOOLS: "1" }, REGISTRY.filter((t) => !t.namespace || t.name.startsWith("mcp__")), { active: ["read"] });
  await bare.fire("before_agent_start", { systemPromptOptions: none });
  assert.deepEqual(none.promptGuidelines, [], "no Shepherd tool deferred, no line");
  await assert.doesNotReject(s.fire("before_agent_start", {}), "an event without options is not a failure");
  await s.close(); await bare.close();
});

test("a search whose best match is a Shepherd tool loads its family and says so in the answer, and no other does", async () => {
  const result = (loaded) => ({ toolName: "tool_search", details: { loaded }, content: [{ type: "text", text: `Loaded ${loaded.length} tools. They are available from your next call:\n${loaded.map((name) => `- ${name}: ${name}`).join("\n")}` }] });
  const s = await statusWith({ SHEPHERD_DEFER_TOOLS: "1" }, REGISTRY, { active: ["read", "tool_search", "browser_open", "browser_read"] });
  // The best match is a browser tool, with one more of its own: the other browser tool comes, and the count stays true.
  const changed = await s.fire("tool_result", result(["browser_open", "browser_read"]));
  assert.deepEqual(s.state.active, ["read", "tool_search", "browser_open", "browser_read", "browser_click"]);
  assert.match(changed.content[0].text, /^Loaded 3 tools\. They are available from your next call:\n- browser_open: browser_open\n- browser_read: browser_read\nLoaded with them, from the same set: browser_click\.$/);
  assert.deepEqual(changed.details.loaded, ["browser_open", "browser_read", "browser_click"]);
  // The best match is an MCP tool: a weaker Shepherd match does not bring its family.
  const fresh = await statusWith({ SHEPHERD_DEFER_TOOLS: "1" }, REGISTRY, { active: ["read", "tool_search"] });
  assert.equal(await fresh.fire("tool_result", result(["mcp__docs__echo", "agent_list"])), undefined);
  assert.deepEqual(fresh.state.active, ["read", "tool_search"], "nothing was added");
  // Nothing to add, another tool's result, and malformed events are all left alone.
  assert.equal(await s.fire("tool_result", result(["browser_open"])), undefined, "its family is loaded already");
  assert.equal(await s.fire("tool_result", { toolName: "bash", details: {}, content: [] }), undefined);
  assert.equal(await s.fire("tool_result", { toolName: "tool_search" }), undefined);
  assert.equal(await s.fire("tool_result", { toolName: "tool_search", details: { loaded: ["agent_list"] }, content: [{ type: "image" }] }), undefined);
  await s.close(); await fresh.close();
});
