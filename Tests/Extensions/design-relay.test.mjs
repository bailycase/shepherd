// The design tools a design agent's helpers use through their parent: the registry the design extension
// publishes, and the parent's side of a relayed call (allowlist, sizes, cancellation, errors), against a
// stand-in Shepherd socket. The helpers themselves, real pi processes, are in native-children-design.test.mjs.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";
import { children, jiti, root, sleep, tempDir, until, withEnv } from "./fixtures/children-harness.mjs";

const design = await jiti.import(path.join(root, "Extensions/shepherd-design.ts"));
const KEY = Symbol.for("shepherd.design.relay.v1");
const TITLE = "shepherd-relay:v1:";
const RELAYED = [
  "board_edit", "board_extract", "board_render", "board_search", "board_write", "boards_edit", "canvas_update", "checkpoint_create",
  "checkpoint_list", "comment_list", "design_check", "design_read", "system_read", "system_write",
];

function fakePi() {
  const handlers = {}, tools = new Map();
  return { handlers, tools, api: { on: (name, handler) => { (handlers[name] ??= []).push(handler); }, registerTool: (tool) => tools.set(tool.name, tool) } };
}

/** A stand-in Shepherd socket that records each connection's frames and answers with `answer(frame)` (null: no answer). */
async function shepherd(answer) {
  const dir = tempDir("relay");
  const socketPath = path.join(dir, "s");
  const frames = [], sockets = [];
  const server = net.createServer((socket) => {
    const connection = sockets.push(socket);
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      buffer += chunk;
      for (let at = buffer.indexOf("\n"); at >= 0; at = buffer.indexOf("\n")) {
        const frame = JSON.parse(buffer.slice(0, at));
        buffer = buffer.slice(at + 1);
        frames.push({ ...frame, connection });
        const reply = answer(frame, socket);
        if (reply) socket.write(JSON.stringify({ id: frame.id, ...reply }) + "\n");
      }
    });
    socket.on("error", () => {});
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  return { frames, sockets, socketPath,
    close: async () => { for (const socket of sockets) socket.destroy(); await new Promise((resolve) => server.close(resolve)); fs.rmSync(dir, { recursive: true, force: true }); } };
}

const SOURCE = "<!doctype html>\n<x-dc>Pay now</x-dc>\n";
const answers = (frame) => {
  if (frame.type === "designRead" && frame.path === "A.dc.html") return { type: "designBoard", board: { path: "A.dc.html", source: SOURCE, sha256: "aa", revision: 4 } };
  if (frame.type === "designEditBoard") return { type: "designEdited", result: { revision: 5, changed: true, created: false, warnings: [], boardCount: 1 }, replaced: frame.edits.map(() => 1) };
  return { type: "error", code: "unexpected", message: frame.type };
};

/** The design extension installed as a design agent's pi would, then `body({ pi, host, relay })`. */
async function withRelay(answer, body) {
  const host = await shepherd(answer);
  const pi = fakePi();
  try {
    await withEnv({ SHEPHERD_AGENT_ID: "designer-1", SHEPHERD_SOCKET: host.socketPath, SHEPHERD_DESIGN_ID: "d1", SHEPHERD_DESIGN_SKILL_DIR: undefined }, async () => {
      design.default(pi.api);
      await body({ pi, host, relay: globalThis[KEY] });
    });
  } finally {
    for (const handler of pi.handlers.session_shutdown ?? []) handler({});
    await host.close();
  }
}

const newRun = (tools = ["design_read", "board_edit"]) => ({ id: "native-1", relayTools: tools, relays: new Map() });
const request = (tool, params, id = "abc") => ({ id: `req-${id}`, title: TITLE + id, placeholder: JSON.stringify({ tool, params }) });
async function serve(run, event, relay, ctx = { cwd: "/parent" }) {
  const answered = [];
  await children.serveRelay(run, event, { relay, ctx, answer: (value) => answered.push(JSON.parse(value)) });
  return answered;
}

test("only a design agent's pi publishes a relay, with exactly the tools a helper may use, and it goes with the session", async () => {
  await withEnv({ SHEPHERD_AGENT_ID: undefined, SHEPHERD_SOCKET: undefined, SHEPHERD_DESIGN_ID: undefined }, async () => {
    const plain = fakePi();
    design.default(plain.api);
    assert.equal(globalThis[KEY], undefined, "inert without the design's environment");
    assert.equal(children.designRelay(), undefined);
  });
  await withRelay(() => null, async ({ pi, relay }) => {
    assert.deepEqual([...relay.tools.keys()].sort(), RELAYED);
    assert.deepEqual([...design.RELAYED_TOOLS].sort(), RELAYED);
    assert(pi.tools.has("comment_reply") && pi.tools.has("markup_propose") && pi.tools.has("checkpoint_restore"), "the agent has them");
    assert(!relay.tools.has("comment_reply") && !relay.tools.has("markup_propose"), "a helper never does: they are the agent's voice toward the viewer");
    assert(!relay.tools.has("checkpoint_restore"), "nor a restore: it rewinds every board, a sibling's work included");
    assert.equal(relay.designID, "d1");
    assert.equal(children.designRelay(), relay);
    // The registry names one design; another agent's environment is not it.
    await withEnv({ SHEPHERD_DESIGN_ID: "d2" }, () => assert.equal(children.designRelay(), undefined));
    pi.handlers.session_shutdown[0]({});
    assert.equal(globalThis[KEY], undefined, "the session's end takes it away");
    assert.equal(children.designRelay(), undefined);
  });
});

test("a relayed call runs through the design extension's own tool, on the parent's connection and agent id", async () => {
  await withRelay(answers, async ({ host, relay }) => {
    const run = newRun(["design_read", "board_edit"]);
    const read = await serve(run, request("design_read", { path: "A.dc.html" }, "one"), relay);
    assert.equal(read.length, 1);
    assert.equal(read[0].ok, true);
    assert.match(read[0].content[0].text, /^A\.dc\.html at revision 4 \(\d+ bytes\)/);
    assert.match(read[0].content[0].text, /Pay now/);
    assert.deepEqual(read[0].details, { revision: 4, sha256: "aa" });

    const edit = await serve(run, request("board_edit", { path: "A.dc.html", edits: [{ find: "Pay now", replace: "Buy" }], baseRevision: 4 }, "two"), relay);
    assert.equal(edit[0].ok, true);
    assert.equal(edit[0].content[0].text, "Edited A.dc.html · 1 edit (matches replaced: 1) · revision 5");

    assert.deepEqual(host.frames.map((frame) => frame.type), ["designRead", "designEditBoard"]);
    assert(host.frames.every((frame) => frame.agentID === "designer-1" && frame.designID === "d1"), "the parent's identity, never the helper's");
    assert(host.frames.every((frame) => frame.connection === 1), "on the one connection the parent's pi opened");
    assert.deepEqual(host.frames[1].edits, [{ find: "Pay now", replace: "Buy" }]);
    assert.equal(run.relays.size, 0, "nothing is left in flight");
  });
});

test("a tool the helper's profile didn't list is refused by the parent and never reaches Shepherd", async () => {
  await withRelay(answers, async ({ host, relay }) => {
    const run = newRun(["design_read"]);
    for (const tool of ["board_edit", "system_write", "comment_reply", "markup_propose", "bash", "__proto__", "constructor", undefined, 7]) {
      const refused = await serve(run, request(tool, { path: "A.dc.html" }, `t${String(tool)}`), relay);
      assert.equal(refused.length, 1, String(tool));
      assert.equal(refused[0].ok, false, String(tool));
      assert.match(refused[0].error, /is not relayed to this helper \(its profile's design tools: design_read\)/, String(tool));
    }
    // Even a name the registry holds is refused when the profile's list (what the parent allowed at launch) lacks it,
    // and one the relay never carries is refused when the list is forged to include it.
    const forged = newRun(["comment_reply", "design_read"]);
    const forgedAnswer = await serve(forged, request("comment_reply", { id: "x", text: "Done" }, "forged"), relay);
    assert.equal(forgedAnswer[0].ok, false);
    assert.equal(host.frames.length, 0, "Shepherd saw none of it");
  });
});

test("a call that is malformed, invalid for its tool, repeated or too big is answered with why, and sends nothing", async () => {
  await withRelay(answers, async ({ host, relay }) => {
    const run = newRun(["board_edit", "design_read"]);
    const notJSON = await serve(run, { id: "r1", title: TITLE + "a", placeholder: "{not json" }, relay);
    assert.match(notJSON[0].error, /not JSON/);
    const badID = await serve(run, { id: "r2", title: TITLE + "../../x", placeholder: "{}" }, relay);
    assert.match(badID[0].error, /invalid or repeated relay call id/);
    const invalid = await serve(run, request("board_edit", { path: "A.dc.html", edits: "Pay now" }, "b"), relay);
    assert.equal(invalid[0].ok, false);
    assert.match(invalid[0].error, /edits/, "the schema's own complaint names the field");
    const missing = await serve(run, request("board_edit", { edits: [{ find: "a", replace: "b" }] }, "c"), relay);
    assert.match(missing[0].error, /path/);
    const huge = await serve(run, { id: "r3", title: TITLE + "d", placeholder: JSON.stringify({ tool: "board_edit", params: { path: "A.dc.html", edits: [{ find: "a", replace: "x".repeat(1024 * 1024) }] } }) }, relay);
    assert.match(huge[0].error, /larger than the 1048576 byte relay limit/);
    assert.equal(host.frames.length, 0);
    // A call id in flight can't be reused.
    run.relays.set("dup", new AbortController());
    assert.match((await serve(run, request("design_read", { path: "A.dc.html" }, "dup"), relay))[0].error, /repeated/);
    run.relays.clear();
  });
});

test("a helper gets the batch tools through its parent too, a rendered board's picture with them, and never a restore", async () => {
  const png = { data: "iVBORw0KGgo=", mimeType: "image/png" };
  const answer = (frame) => {
    if (frame.type === "designRender") return { type: "designRendered", text: "A.dc.html · 390×844", image: png };
    if (frame.type === "designSearch") return { type: "designSearchResult", result: { boards: [], totalMatches: 0, totalBoards: 0, searched: 2, omittedBoards: 0 } };
    if (frame.type === "designEditBoards") return { type: "designBatchEdited", result: { result: { revision: 6, changed: false }, boards: [], dryRun: true, atomic: false, blocked: false } };
    if (frame.type === "designCheckpoint") return { type: "designCheckpoints", result: { action: frame.request.action, checkpoints: [] } };
    return { type: "error", code: "unexpected", message: frame.type };
  };
  await withRelay(answer, async ({ host, relay }) => {
    const run = newRun(["board_render", "board_search", "boards_edit", "checkpoint_create", "checkpoint_list"]);
    const picture = await serve(run, request("board_render", { path: "A.dc.html" }, "r1"), relay);
    assert.equal(picture[0].ok, true);
    assert.deepEqual(picture[0].content, [{ type: "text", text: "A.dc.html · 390×844" }, { type: "image", ...png }], "the helper's model gets the picture");
    const found = await serve(run, request("board_search", { text: "Pay" }, "r2"), relay);
    assert.match(found[0].content[0].text, /^No matches in 2 boards\.$/);
    const edited = await serve(run, request("boards_edit", { paths: ["A.dc.html"], edits: [{ find: "a", replace: "b" }], dry_run: true }, "r3"), relay);
    assert.match(edited[0].content[0].text, /^Dry run: 0 of 0 boards would be edited/);
    const saved = await serve(run, request("checkpoint_list", {}, "r4"), relay);
    assert.equal(saved[0].content[0].text, "The design has no checkpoints.");
    assert(host.frames.every((frame) => frame.agentID === "designer-1" && frame.designID === "d1" && frame.connection === 1), "all on the parent's connection");

    // A restore rewinds every board, siblings' work included: a profile can't list it, and a forged list is refused.
    for (const list of [["checkpoint_restore"], ["checkpoint_create"]]) {
      const forged = newRun(list);
      const refused = await serve(forged, request("checkpoint_restore", { name: "x" }, `f-${list[0]}`), relay);
      assert.equal(refused[0].ok, false);
      assert.match(refused[0].error, /is not relayed to this helper|not relayed/);
    }
    assert.match(children.designToolsProblem(["checkpoint_restore"], relay), /^checkpoint_restore can't be relayed to a helper/);
    // Only a picture crosses besides text, and only a small PNG or JPEG one.
    const tool = relay.tools.get("board_render");
    const original = tool.execute;
    tool.execute = async () => ({ content: [{ type: "text", text: "x" }, { type: "image", data: "AAAA", mimeType: "image/svg+xml" }, { type: "resource", uri: "file:///etc/passwd" }] });
    try {
      const odd = await serve(newRun(["board_render"]), request("board_render", { path: "A.dc.html" }, "r5"), relay);
      assert.deepEqual(odd[0].content, [{ type: "text", text: "x" }]);
    } finally { tool.execute = original; }
  });
});

test("a result over the relay's limit is refused, and a failure of Shepherd's reaches the helper in Shepherd's words", async () => {
  const big = "x".repeat(1024 * 1024 + 10);
  const answer = (frame) => {
    if (frame.path === "Big.dc.html") return { type: "designBoard", board: { path: "Big.dc.html", source: big, sha256: "b", revision: 4 } };
    if (frame.type === "designEditBoard" && frame.baseRevision === 1) return { type: "error", code: "stale_revision", message: "the design changed since revision 1 (it is at 6); read it again and redo the change" };
    if (frame.type === "designEditBoard") return { type: "error", code: "edit_not_found", message: 'edit 1 of 1: find matched nothing: "zzz" (in A.dc.html; nothing was changed)' };
    return null;
  };
  await withRelay(answer, async ({ relay }) => {
    const run = newRun(["design_read", "board_edit"]);
    const tooBig = await serve(run, request("design_read", { path: "Big.dc.html" }, "big"), relay);
    assert.match(tooBig[0].error, /design_read's result is \d+ bytes; the relay carries at most 1048576/);
    const stale = await serve(run, request("board_edit", { path: "A.dc.html", edits: [{ find: "a", replace: "b" }], baseRevision: 1 }, "stale"), relay);
    assert.equal(stale[0].ok, false);
    assert.match(stale[0].error, /changed since revision 1 \(it is at 6\); read it again and redo the change \(stale_revision\)/);
    const missed = await serve(run, request("board_edit", { path: "A.dc.html", edits: [{ find: "zzz", replace: "b" }] }, "miss"), relay);
    assert.match(missed[0].error, /^edit 1 of 1: find matched nothing.*nothing was changed.*\(edit_not_found\)$/);
  });
});

test("at most eight design calls are in flight for one helper", async () => {
  const held = [];
  await withRelay((frame, socket) => { held.push({ frame, socket }); return null; }, async ({ relay }) => {
    const run = newRun(["design_read"]);
    const pending = [];
    for (let i = 0; i < 8; i++) {
      const answered = [];
      pending.push({ answered, done: children.serveRelay(run, request("design_read", { path: "A.dc.html" }, `p${i}`), { relay, ctx: {}, answer: (v) => answered.push(JSON.parse(v)) }) });
    }
    await until(() => held.length === 8);
    const ninth = await serve(run, request("design_read", { path: "A.dc.html" }, "p8"), relay);
    assert.match(ninth[0].error, /8 design calls are already in flight/);
    // Answering one frees a place.
    const first = held[0];
    first.socket.write(JSON.stringify({ id: first.frame.id, ...answers(first.frame) }) + "\n");
    await pending[0].done;
    assert.equal(pending[0].answered[0].ok, true);
    assert.equal(run.relays.size, 7);
    for (const call of run.relays.values()) call.abort();
    await Promise.all(pending.map((p) => p.done));
    assert.equal(run.relays.size, 0);
  });
});

test("cancelling a relayed call drops it at once: its signal aborts, the request is dropped, and a late reply is ignored", async () => {
  const held = [];
  await withRelay((frame, socket) => { held.push({ frame, socket }); return null; }, async ({ relay }) => {
    const run = newRun(["board_edit"]);
    const answered = [];
    const done = children.serveRelay(run, request("board_edit", { path: "A.dc.html", edits: [{ find: "HOLD", replace: "x" }] }, "slow"),
      { relay, ctx: {}, answer: (v) => answered.push(JSON.parse(v)) });
    await until(() => held.length === 1 && run.relays.size === 1);
    const started = Date.now();
    run.relays.get("slow").abort();
    await done;
    assert(Date.now() - started < 1000, "the call ended without waiting for Shepherd's reply or its 30 s timeout");
    assert.deepEqual(answered, [], "no one is left to answer");
    assert.equal(run.relays.size, 0);
    // Shepherd's reply comes late: the extension has dropped the request, so nothing fails or answers.
    held[0].socket.write(JSON.stringify({ id: held[0].frame.id, ...answers(held[0].frame) }) + "\n");
    await sleep(50);
    assert.deepEqual(answered, []);
  });
});

test("the design extension's tools honor the signal they are given", async () => {
  const held = [];
  await withRelay((frame, socket) => { held.push({ frame, socket }); return null; }, async ({ pi }) => {
    const controller = new AbortController();
    const call = pi.tools.get("board_write").execute("t1", { path: "A.dc.html", source: "<x-dc></x-dc>" }, controller.signal);
    await until(() => held.length === 1);
    controller.abort();
    await assert.rejects(call, /cancelled before Shepherd replied \(cancelled\)/);
    await assert.rejects(pi.tools.get("design_read").execute("t2", {}, controller.signal), /abort/i, "an aborted signal sends nothing");
    assert.equal(held.length, 1);
  });
});

test("without a live design agent a relayed call is refused, and the parent's problems with a profile's design tools are spelled out", async () => {
  const run = newRun(["design_read"]);
  assert.match((await serve(run, request("design_read", {}, "x"), undefined))[0].error, /no longer draws a design/);
  assert.match(children.designToolsProblem(["design_read"], undefined), /only to the helpers of a design agent/);
  await withRelay(() => null, async ({ relay }) => {
    assert.equal(children.designToolsProblem(["design_read", "board_edit", "system_write"], relay), undefined);
    assert.match(children.designToolsProblem(["design_read", "comment_reply", "markup_propose", "checkpoint_restore"], relay),
      /^comment_reply, markup_propose, checkpoint_restore can't be relayed to a helper: the design agent answers .* restores checkpoints itself.* Relayed: design_read, design_check, system_read, comment_list, board_write, board_edit, boards_edit, board_search, board_render, board_extract, checkpoint_create, checkpoint_list, canvas_update, system_write\.$/);
    const partial = { tools: new Map([["design_read", {}]]) };
    assert.match(children.designToolsProblem(["design_read", "board_edit"], partial), /^board_edit isn't available/);
  });
});

test("a helper is handed plain schemas: no function, no symbol, and what it is told about the relay", async () => {
  await withRelay(() => null, async ({ relay }) => {
    const specs = children.relaySpecs(["design_read", "board_edit"], relay);
    assert.deepEqual(specs.map((spec) => spec.name), ["design_read", "board_edit"]);
    assert.deepEqual(JSON.parse(JSON.stringify(specs)), specs, "survives an environment variable");
    const edit = specs[1];
    assert.match(edit.description, /find-and-replace/);
    assert.match(edit.description, /your parent draws this design and runs the call for you/);
    assert.deepEqual(edit.parameters.required.sort(), ["edits", "path"]);
    assert.equal(edit.parameters.properties.edits.maxItems, 64);
    assert(JSON.stringify(specs).length < 12_000, "small enough for an environment variable");
  });
});

// ---- the helper's side ----

/** A stand-in `ctx.ui` for a helper: `input` answers with `reply(title, placeholder, opts)`; notices are recorded. */
function helperContext(reply) {
  const inputs = [], notices = [];
  return { inputs, notices, ctx: { ui: {
    input: async (title, placeholder, opts) => { inputs.push({ title, placeholder, opts }); return reply(title, placeholder, opts); },
    notify: (message, type) => notices.push({ message, type }),
  } } };
}

test("a helper's proxy sends one request up its channel and returns the parent's result or error", async () => {
  const ok = helperContext(() => JSON.stringify({ ok: true, content: [{ type: "text", text: "Edited A.dc.html" }], details: { revision: 5 } }));
  const result = await children.relayedCall("board_edit", { path: "A.dc.html", edits: [{ find: "a", replace: "b" }] }, undefined, ok.ctx);
  assert.deepEqual(result, { content: [{ type: "text", text: "Edited A.dc.html" }], details: { revision: 5 } });
  assert.equal(ok.inputs.length, 1);
  assert.match(ok.inputs[0].title, /^shepherd-relay:v1:[0-9a-f-]{36}$/);
  assert.deepEqual(JSON.parse(ok.inputs[0].placeholder), { tool: "board_edit", params: { path: "A.dc.html", edits: [{ find: "a", replace: "b" }] } });
  assert.equal(ok.inputs[0].opts.timeout, 120_000, "it waits for the parent, but not for ever");

  const refused = helperContext(() => JSON.stringify({ ok: false, error: "the design changed since revision 1 (it is at 6) (stale_revision)" }));
  await assert.rejects(children.relayedCall("board_edit", {}, undefined, refused.ctx), /^Error: the design changed since revision 1 \(it is at 6\) \(stale_revision\)$/);
  await assert.rejects(children.relayedCall("board_edit", {}, undefined, helperContext(() => "not json").ctx), /answer was not understood/);
  await assert.rejects(children.relayedCall("board_edit", { source: "x".repeat(1024 * 1024) }, undefined, helperContext(() => "").ctx), /larger than the 1048576 byte relay limit/);
  await assert.rejects(children.relayedCall("board_edit", {}, undefined, { ui: {} }), /no channel to its parent/);
});

test("a helper that is aborted, or never answered, tells its parent which call to drop", async () => {
  // Aborted while the parent works: pi resolves the dialog empty, and the helper names the call it cancelled.
  const controller = new AbortController();
  const aborted = helperContext(() => new Promise((resolve) => controller.signal.addEventListener("abort", () => resolve(undefined))));
  const call = children.relayedCall("design_read", { path: "A.dc.html" }, controller.signal, aborted.ctx);
  await until(() => aborted.inputs.length === 1);
  controller.abort();
  await assert.rejects(call, /abort/i);
  assert.equal(aborted.notices.length, 1);
  const id = aborted.inputs[0].title.slice(TITLE.length);
  assert.deepEqual(JSON.parse(aborted.notices[0].message), { shepherdRelayCancel: id });
  // Already aborted: nothing is sent at all.
  const never = helperContext(() => assert.fail("sent"));
  await assert.rejects(children.relayedCall("design_read", {}, AbortSignal.abort(), never.ctx), /abort/i);
  assert.equal(never.inputs.length, 0);
  // No answer within its time: the same notice, and the reason.
  const silent = helperContext(() => undefined);
  await assert.rejects(children.relayedCall("design_read", {}, undefined, silent.ctx), /the parent did not answer within 120 seconds/);
  assert.equal(JSON.parse(silent.notices[0].message).shepherdRelayCancel, silent.inputs[0].title.slice(TITLE.length));
});

test("the parent drops the call a helper's notice names, and nothing else", () => {
  const first = new AbortController(), second = new AbortController();
  const run = { relays: new Map([["one", first], ["two", second]]) };
  assert.equal(children.relayCancel(run, JSON.stringify({ shepherdRelayCancel: "one" })), true);
  assert(first.signal.aborted && !second.signal.aborted);
  for (const other of [JSON.stringify({ shepherdChildTools: ["read"] }), "not json", JSON.stringify({ shepherdRelayCancel: 7 }), "null"]) {
    assert.equal(children.relayCancel(run, other), false, other);
  }
  assert.equal(children.relayCancel(run, JSON.stringify({ shepherdRelayCancel: "unknown" })), true, "a call that already finished is nothing to drop");
  assert(!second.signal.aborted);
  assert.equal(children.relayCancel({}, JSON.stringify({ shepherdRelayCancel: "one" })), true, "a run that never relayed");
});

test("a helper's bridge registers a proxy only for the names a parent may relay", async () => {
  const specs = [
    { name: "design_read", label: "Read Design", description: "read", parameters: { type: "object", properties: { path: { type: "string" } } } },
    { name: "board_edit", description: "edit", parameters: { type: "object", properties: {} } },
    { name: "comment_reply", description: "speaks for the agent", parameters: { type: "object", properties: {} } },
    { name: "bash", description: "a builtin", parameters: { type: "object", properties: {} } },
    { name: "system_read", description: "no schema" },
  ];
  async function bridge(relay) {
    const tools = new Map();
    await withEnv({ SHEPHERD_CHILD: "1", SHEPHERD_CHILD_RELAY: relay, SHEPHERD_CHILD_TOOLS: undefined, SHEPHERD_NATIVE_CHILDREN: undefined }, async () => {
      children.default({ registerTool: (tool) => tools.set(tool.name, tool), registerCommand() {}, on() {}, getActiveTools: () => [], setActiveTools() {} });
    });
    return [...tools.keys()].sort();
  }
  assert.deepEqual(await bridge(JSON.stringify(specs)), ["bash", "board_edit", "design_read", "shepherd_parent_message"],
    "bash is the helper's own bridge tool; comment_reply, the builtin-named one and the one without a schema are not proxied");
  assert.deepEqual(await bridge(undefined), ["bash", "shepherd_parent_message"], "no relay in the environment, no design tool");
  assert.deepEqual(await bridge("not json"), ["bash", "shepherd_parent_message"]);
});
