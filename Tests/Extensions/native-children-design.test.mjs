// A design agent's helpers use its design tools through it, with real processes: a real parent pi loads the design
// extension and the children extension against a stand-in Shepherd socket, and starts real helper pis whose
// (fake-provider) model calls design_read and board_edit. The helpers have none of the parent's identity; every
// design request Shepherd sees comes from the parent's own connection. No model call is made.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";
import { spawn } from "node:child_process";
import { children, childrenSource, harness, pkg, providerServer, root, scratchHome, sleep, tempDir, until, withEnv } from "./fixtures/children-harness.mjs";
process.env.SHEPHERD_MISSIONS = "1"; // These tests cover mission records and the mission parameters, which are off unless this is set (docs/native-subagents.md › Missions).

const designSource = path.join(root, "Extensions/shepherd-design.ts");
const BOARD = "<!doctype html>\n<x-dc>Pay now</x-dc>\n";
const PROFILE = `---
name: design-editor
description: edits design boards
model: fixture/helper
tools: [read, bash, design_read, board_edit, design_check]
---
Edit the boards you are given, and nothing else.
`;

/** A stand-in Shepherd: answers the design extension's frames, holds a board_edit whose find is HOLD. */
async function shepherd(dir) {
  const socketPath = path.join(dir, "s");
  const frames = [], sockets = [], held = [];
  // What a read answers never moves, so parallel helpers read the same thing whichever edits landed first.
  const revision = 4;
  let edits = 0;
  const server = net.createServer((socket) => {
    const connection = sockets.push(socket);
    const lines = children.jsonLines((frame) => {
      frames.push({ ...frame, connection });
      const reply = (body) => socket.write(JSON.stringify({ id: frame.id, ...body }) + "\n");
      if (frame.type === "designRead" && !frame.path) {
        reply({ type: "design", snapshot: { designID: "d1", revision, index: { v: 3, title: "Checkout", boards: {}, order: [] }, boards: {} } });
      } else if (frame.type === "designRead") {
        reply({ type: "designBoard", board: { path: frame.path, source: BOARD, sha256: "aa", revision } });
      } else if (frame.type === "designEditBoard") {
        if (frame.edits.some((edit) => edit.find === "HOLD")) { held.push({ frame, reply }); return; }
        edits += 1;
        reply({ type: "designEdited", result: { revision: revision + edits, changed: true, created: false, warnings: [], boardCount: 3 }, replaced: frame.edits.map(() => 1) });
      }
    }, () => socket.destroy());
    socket.on("data", lines);
    socket.on("error", () => {});
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  return { socketPath, frames, sockets, held,
    close: async () => { for (const socket of sockets) socket.destroy(); await new Promise((resolve) => server.close(resolve)); } };
}

/** The scripted models. A parent runs one scenario per user message; a helper one per task. */
function script(dir) {
  const stage = (messages) => {
    const at = messages.map((m) => m.role).lastIndexOf("user");
    const after = messages.slice(at + 1);
    const text = typeof messages[at]?.content === "string" ? messages[at].content : (messages[at]?.content ?? []).map((p) => p.text ?? "").join("");
    return { text, steps: after.filter((m) => m.role === "assistant" && m.tool_calls).map((m) => m.tool_calls.map((c) => c.function.name)),
      results: after.filter((m) => m.role === "tool").map((m) => m.content) };
  };
  return ({ body }) => {
    const { text, steps, results } = stage(body.messages);
    const toolNames = (body.tools ?? []).map((tool) => tool.function.name);
    if (!toolNames.includes("shepherd_parent_message")) {
      // The parent.
      const start = (task, extra = {}) => ({ name: "shepherd_child_start", args: { agent: "design-editor", task, mission: false, ...extra } });
      if (text === "ROUND") {
        if (steps.length === 0) return { toolCalls: [start("HELPER_A board A.dc.html"), start("HELPER_B board B.dc.html"), { name: "shepherd_child_start", args: { role: "scout", model: "fixture/helper", task: "SCOUT look around", mission: false } }] };
        return { text: "round delegated" };
      }
      // The scenarios below start a helper whose design call Shepherd holds, then act on it a prompt at a time, so
      // the test (not a timer) says when the helper's call is in flight.
      const held = /native-[0-9a-f-]{36}/.exec(JSON.stringify(body.messages))?.[0];
      // These scenarios explicitly fetch the result; a failure must not start a competing parent turn.
      if (text === "HOLD") return steps.length === 0 ? { toolCalls: [start("HOLD board C.dc.html", { delivery: "report" })] } : { text: "started" };
      if (text === "RESULT") return steps.length === 0 ? { toolCalls: [{ name: "shepherd_child_result", args: { id: held } }] } : { text: "read" };
      if (text === "CANCEL") {
        if (steps.length === 0) return { toolCalls: [{ name: "shepherd_child_cancel", args: { id: held } }] };
        return steps.length === 1 ? { toolCalls: [{ name: "shepherd_child_result", args: { id: held } }] } : { text: "cancelled" };
      }
      if (text === "FINISHED") {
        return steps.length === 0 ? { toolCalls: [{ name: "shepherd_child_result", args: { id: held } }] } : { text: "finished" };
      }
      return { text: "nothing to do" };
    }
    // A helper.
    if (text.startsWith("SCOUT")) return { text: "scouted" };
    const marker = text.split(" ")[0], board = text.split(" ").at(-1);
    if (steps.length === 0) {
      return { toolCalls: [{ name: "design_read", args: { path: board } },
        { name: "bash", args: { command: `env | grep '^SHEPHERD_' | sort > '${dir}/env-${marker}.txt'` } }] };
    }
    if (steps.length === 1) {
      return { toolCalls: [{ name: "board_edit", args: { path: board, edits: [{ find: marker === "HOLD" ? "HOLD" : "Pay now", replace: `Buy ${marker}` }] } }] };
    }
    if (steps.length === 2 && marker === "HELPER_A") return { toolCalls: [{ name: "comment_reply", args: { id: "c1", text: "Done" } }] };
    return { text: `edited ${marker}` };
  };
}

/** A real parent pi in RPC mode, driven by prompts; `design` decides whether it is a design agent. */
function startParent({ dir, home, socketPath, design }) {
  const events = [];
  const env = { ...process.env, HOME: dir, PI_CODING_AGENT_DIR: home, PI_OFFLINE: "1", SHEPHERD_AGENT_ID: "designer-1", SHEPHERD_SOCKET: socketPath,
    SHEPHERD_NATIVE_CHILDREN: "1", SHEPHERD_EXT_CHILDREN: childrenSource };
  delete env.SHEPHERD_CHILD; delete env.SHEPHERD_DESIGN_ID; delete env.SHEPHERD_CLIPROXYAPI_CONFIG;
  if (design) env.SHEPHERD_DESIGN_ID = "d1";
  const extensions = design ? ["-e", designSource, "-e", childrenSource] : ["-e", childrenSource];
  const proc = spawn(process.execPath, [path.join(pkg, "dist/bundle/cli.js"), "--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates",
    "--no-themes", "--no-approve", ...extensions, "--session", path.join(dir, "parent.jsonl"), "--model", "fixture/parent"],
    { cwd: dir, env, stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  proc.stdout.on("data", children.jsonLines((event) => events.push(event), () => {}));
  proc.stderr.on("data", (chunk) => { stderr += chunk; });
  proc.stdin.on("error", () => {});
  let sequence = 0;
  const settled = () => events.filter((event) => event.type === "agent_settled").length;
  return {
    proc, events, stderr: () => stderr,
    async prompt(message) {
      const before = settled(), id = `p-${++sequence}`;
      proc.stdin.write(JSON.stringify({ id, type: "prompt", message }) + "\n");
      await until(() => events.some((event) => event.id === id && event.type === "response"), 30000);
      const response = events.find((event) => event.id === id && event.type === "response");
      assert(response.success, `prompt refused: ${response.error ?? "unknown error"}; ${stderr}`);
      await until(() => settled() > before, 90000);
    },
    async round() {
      const childDir = path.join(dir, "children");
      const before = new Set(fs.existsSync(childDir) ? fs.readdirSync(childDir) : []);
      await this.prompt("ROUND");
      let runs;
      await until(() => {
        runs = fs.readdirSync(childDir).filter((name) => name.startsWith("native-") && !before.has(name))
          .map((name) => JSON.parse(fs.readFileSync(path.join(childDir, name, "status.json"), "utf8")));
        return runs.length === 3 && runs.every((run) => run.state === "complete");
      }, 60000);
      return runs;
    },
    stop: async () => { proc.stdin.end(); await new Promise((resolve) => { proc.once("close", resolve); setTimeout(() => { proc.kill("SIGKILL"); }, 5000).unref(); }); },
  };
}

const toolMessages = (requests, model) => requests.filter((request) => request.body.model === model)
  .flatMap((request) => request.body.messages.filter((message) => message.role === "tool").map((message) => message.content));

test("a design agent's helpers read and edit its boards through it, with no identity of their own", { timeout: 240000 }, async () => {
  const dir = tempDir("design-helpers");
  const provider = providerServer(script(dir));
  const port = await provider.listen();
  const host = await shepherd(dir);
  const home = scratchHome(dir, { port, models: ["parent", "helper"] });
  fs.mkdirSync(path.join(home, "agents"));
  fs.writeFileSync(path.join(home, "agents", "design-editor.md"), PROFILE);
  const parent = startParent({ dir, home, socketPath: host.socketPath, design: true });
  try {
    const completed = await parent.round();
    await until(() => completed.every((run) => provider.requests.some((request) => request.body.model === "parent"
      && JSON.stringify(request.body.messages).includes(`Child ${run.id}`))));
    assert(provider.requests.filter((request) => request.body.model === "parent")
      .every((request) => !request.body.tools.some((tool) => tool.function.name === "shepherd_child_wait")));

    // The parent's own facts read came first, on the connection the parent's design extension opened.
    const own = host.frames.find((frame) => frame.type === "designRead" && !frame.path);
    assert(own, "the parent's own design extension asked for the design");
    const design = host.frames.filter((frame) => ["designRead", "designEditBoard"].includes(frame.type) && frame !== own);
    assert.deepEqual(design.filter((frame) => frame.type === "designRead").map((frame) => frame.path).sort(), ["A.dc.html", "B.dc.html"], "each helper read its board");
    const edits = design.filter((frame) => frame.type === "designEditBoard");
    assert.deepEqual(edits.map((frame) => frame.path).sort(), ["A.dc.html", "B.dc.html"], "and edited it: parallel writes to different boards");
    assert.deepEqual(edits.map((frame) => frame.edits[0].replace).sort(), ["Buy HELPER_A", "Buy HELPER_B"]);
    for (const frame of host.frames.filter((frame) => ["designRead", "designEditBoard"].includes(frame.type))) {
      assert.equal(frame.agentID, "designer-1", "every request is the parent's agent");
      assert.equal(frame.designID, "d1");
      assert.equal(frame.connection, own.connection, "on the connection the parent's pi opened, never one of a helper's");
    }
    assert.equal(host.frames.filter((frame) => frame.type === "designCommentReply").length, 0, "a tool that isn't relayed reached no one");

    // What the helpers were given: the profile's design tools only, and no more.
    const helperRequests = provider.requests.filter((request) => request.body.model === "helper");
    const toolsOf = (marker) => helperRequests.find((request) => JSON.stringify(request.body.messages).includes(marker))
      .body.tools.map((tool) => tool.function.name).sort();
    const editorTools = toolsOf("HELPER_A");
    assert.deepEqual(editorTools, ["bash", "board_edit", "design_check", "design_read", "read", "shepherd_parent_message"]);
    assert(!editorTools.some((name) => ["board_write", "canvas_update", "comment_reply", "system_write", "markup_propose"].includes(name)), "nothing the profile didn't list");
    // (The bundled scout's tools, narrowed to what this parent has active: read.)
    assert.deepEqual(toolsOf("SCOUT"), ["read", "shepherd_parent_message"], "a helper whose profile lists no design tool has none");
    // The helper's model was told the tool isn't there when it asked for one it doesn't have.
    assert(toolMessages(provider.requests, "helper").some((content) => /comment_reply/.test(content) && /not found|unknown|not available/i.test(content)), "comment_reply failed inside the helper");
    // Its results reached it: design_read's board and board_edit's line.
    const seen = toolMessages(provider.requests, "helper").join("\n");
    assert.match(seen, /A\.dc\.html at revision 4 .*Pay now/s);
    assert.match(seen, /Edited A\.dc\.html · 1 edit \(matches replaced: 1\) · revision \d+/);

    // Cut off from the host: the only SHEPHERD_* a helper has are the bridge's own.
    for (const marker of ["HELPER_A", "HELPER_B"]) {
      const names = fs.readFileSync(path.join(dir, `env-${marker}.txt`), "utf8").trim().split("\n").map((line) => line.split("=")[0]).sort();
      assert.deepEqual(names, ["SHEPHERD_CHILD", "SHEPHERD_CHILD_RELAY", "SHEPHERD_CHILD_TOOLS"], `${marker}: no agent id, socket, design or extension path`);
    }
    // The helpers settle and report back without the parent issuing a blocking tool.
    assert.deepEqual(completed.map((run) => run.state), ["complete", "complete", "complete"]);
  } finally {
    await parent.stop();
    await host.close();
    await provider.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
  assert.doesNotMatch(parent.stderr(), /Error|TypeError/, parent.stderr());
});

test("stopping a helper cancels the design call it has in flight, and the parent carries on", { timeout: 240000 }, async () => {
  const dir = tempDir("design-hold");
  const provider = providerServer(script(dir));
  const port = await provider.listen();
  const host = await shepherd(dir);
  const home = scratchHome(dir, { port, models: ["parent", "helper"] });
  fs.mkdirSync(path.join(home, "agents"));
  fs.writeFileSync(path.join(home, "agents", "design-editor.md"), PROFILE);
  const parent = startParent({ dir, home, socketPath: host.socketPath, design: true });
  try {
    await parent.prompt("HOLD");
    await until(() => host.held.length === 1);
    assert.equal(host.held[0].frame.path, "C.dc.html", "Shepherd was asked to edit C, and never answered");
    assert.equal(host.held[0].frame.agentID, "designer-1");
    await parent.prompt("RESULT");
    await parent.prompt("CANCEL");
    const results = toolMessages(provider.requests, "parent").map((content) => { try { return JSON.parse(content); } catch { return undefined; } }).filter(Boolean);
    const summaries = results.filter((result) => result.task === "HOLD board C.dc.html");
    const live = summaries.filter((result) => result.state === "running").at(-1);
    assert.equal(live?.relaying, 1, "while it waited, the parent held the helper's design call");
    const stopped = summaries.find((result) => result.state === "stopped");
    assert(stopped, `the helper was stopped: ${JSON.stringify(summaries)}`);
    assert.equal(stopped.relaying, undefined, "and the call went with it");
    // Shepherd's reply, too late, changes nothing and breaks nothing: the parent serves a new round.
    host.held[0].reply({ type: "designEdited", result: { revision: 99, changed: true, created: false, warnings: [], boardCount: 3 }, replaced: [1] });
    await sleep(100);
    await parent.round();
    assert.equal(host.frames.filter((frame) => frame.type === "designEditBoard" && frame.path !== "C.dc.html").length, 2);
  } finally {
    await parent.stop();
    await host.close();
    await provider.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("a helper killed outright takes the design call it had in flight with it", { timeout: 240000 }, async () => {
  const dir = tempDir("design-kill");
  const provider = providerServer(script(dir));
  const port = await provider.listen();
  const host = await shepherd(dir);
  const home = scratchHome(dir, { port, models: ["parent", "helper"] });
  fs.mkdirSync(path.join(home, "agents"));
  fs.writeFileSync(path.join(home, "agents", "design-editor.md"), PROFILE);
  const parent = startParent({ dir, home, socketPath: host.socketPath, design: true });
  try {
    await parent.prompt("HOLD");
    await until(() => host.held.length === 1);
    // SIGKILL leaves the helper no chance to say it cancelled: only the parent noticing it is gone drops the call.
    const [run] = fs.readdirSync(path.join(dir, "children")).filter((name) => name.startsWith("native-"));
    const { pid } = JSON.parse(fs.readFileSync(path.join(dir, "children", run, "writer", "owner.json"), "utf8"));
    process.kill(pid, "SIGKILL");
    await until(() => JSON.parse(fs.readFileSync(path.join(dir, "children", run, "status.json"), "utf8")).state === "failed");
    await parent.prompt("FINISHED");
    const checked = toolMessages(provider.requests, "parent").map((content) => { try { return JSON.parse(content); } catch { return undefined; } })
      .filter((result) => result?.task === "HOLD board C.dc.html").at(-1);
    assert.equal(checked.state, "failed", JSON.stringify(checked));
    assert.equal(checked.relaying, undefined, "no call of a dead helper is left in flight");
  } finally {
    await parent.stop();
    await host.close();
    await provider.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("a parent that draws no design refuses a profile's design tools before anything starts", { timeout: 120000 }, async () => {
  const dir = tempDir("design-none");
  const home = scratchHome(dir);
  fs.mkdirSync(path.join(home, "agents"));
  fs.writeFileSync(path.join(home, "agents", "design-editor.md"), PROFILE);
  await withEnv({ HOME: dir, PI_CODING_AGENT_DIR: home, PI_OFFLINE: "1", SHEPHERD_NATIVE_CHILDREN: "1", SHEPHERD_AGENT_ID: "plain", SHEPHERD_SOCKET: path.join(dir, "s"),
    SHEPHERD_EXT_CHILDREN: childrenSource, SHEPHERD_DESIGN_ID: undefined, SHEPHERD_CLIPROXYAPI_CONFIG: undefined }, async () => {
    const h = await harness(dir, { models: [{ provider: "fixture", id: "fixture" }, { provider: "fixture", id: "helper" }], extra: { activeTools: ["design_read", "board_edit", "design_check"] } });
    try {
      await assert.rejects(h.call("start", { agent: "design-editor", task: "x", mission: false }),
        /design_read, board_edit, design_check: design tools are relayed only to the helpers of a design agent, and this session draws no design\. Drop them/);
      assert.deepEqual(await h.call("result", {}), [], "no helper was made");
    } finally { await h.shutdown(); }
  });
  fs.rmSync(dir, { recursive: true, force: true });
});
