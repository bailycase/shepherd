// The terminal tools an agent drives its own workspace with (Extensions/shepherd-panes.ts),
// against a local Shepherd socket. A terminal is a tab under the thread: there are no panes and
// no splits, the tools are named terminal_*, and the agent's own thread is never a terminal.
import assert from "node:assert/strict";
import { test } from "node:test";
import * as net from "node:net";
import * as path from "node:path";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const require = createRequire(path.join(pkg, "package.json"));
const { createJiti } = require("jiti");
const jiti = createJiti(import.meta.url, { alias: {
  "@earendil-works/pi-coding-agent": path.join(pkg, "dist/index.js"),
  typebox: path.join(pkg, "node_modules/typebox/build/index.mjs"),
} });
const { default: install } = await jiti.import(path.join(root, "Extensions/shepherd-panes.ts"));

const TERMINAL_TOOLS = ["terminal_list", "terminal_open", "terminal_run", "terminal_read", "terminal_focus", "terminal_close"];
const OLD_TOOLS = ["pane_list", "pane_open", "pane_run", "pane_read", "pane_focus", "pane_close"];

/// Every string an agent is shown about a tool: its name, label, description, prompt lines and
/// the names and descriptions of its parameters.
function shownText(tool) {
  const parameters = Object.entries(tool.parameters?.properties ?? {})
    .flatMap(([name, schema]) => [name, schema.description ?? ""]);
  return [tool.name, tool.label, tool.description, tool.promptSnippet, ...(tool.promptGuidelines ?? []), ...parameters]
    .filter((line) => typeof line === "string");
}

async function harness(replyTo) {
  const dir = await mkdtemp(`${tmpdir()}/sh-term-`);
  process.env.SHEPHERD_SOCKET = `${dir}/s`;
  process.env.SHEPHERD_AGENT_ID = "agent-1";
  const frames = [];
  const sockets = new Set();
  const server = net.createServer((socket) => {
    sockets.add(socket);
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const frame = JSON.parse(buffer.slice(0, newline));
        buffer = buffer.slice(newline + 1);
        frames.push(frame);
        const reply = replyTo(frame);
        if (reply) socket.write(JSON.stringify({ id: frame.id, ...reply }) + "\n");
      }
    });
  });
  await new Promise((resolve) => server.listen(process.env.SHEPHERD_SOCKET, resolve));
  const tools = new Map();
  const events = new Map();
  install({ registerTool: (tool) => tools.set(tool.name, tool), on: (event, cb) => events.set(event, cb),
    sendUserMessage() {}, sendMessage() {} });
  return {
    tools,
    frames,
    close: () => {
      events.get("session_shutdown")?.();
      for (const socket of sockets) socket.destroy();
      server.close();
    },
  };
}

const output = (result) => result.content.map((block) => block.text).join("\n");

test("the tools are the terminal_* set and the old pane_* names are gone", async () => {
  const h = await harness(() => null);
  try {
    for (const name of TERMINAL_TOOLS) assert.ok(h.tools.has(name), `${name} is registered`);
    for (const name of OLD_TOOLS) assert.ok(!h.tools.has(name), `${name} is not registered`);
  } finally { h.close(); }
});

test("nothing an agent is shown about any tool says pane or split", async () => {
  const h = await harness(() => null);
  try {
    for (const tool of h.tools.values()) {
      for (const line of shownText(tool)) {
        assert.ok(!/\bpanes?\b|split/i.test(line), `${tool.name} shows ${JSON.stringify(line)}`);
      }
    }
  } finally { h.close(); }
});

test("terminal_open takes a command and a folder, and never says where to split", async () => {
  const h = await harness((frame) => frame.type === "openPane"
    ? { type: "paneOpened", pane: { id: "t1", cwd: "/work", isAgentPane: false, isFocused: false, isAlive: true } }
    : null);
  try {
    const open = h.tools.get("terminal_open");
    assert.deepEqual(Object.keys(open.parameters.properties).sort(), ["command", "cwd"]);
    const result = await open.execute("call", { command: "make dev", cwd: "/work" });
    assert.equal(output(result), "opened terminal t1 in /work\nrunning: make dev");
    const frame = h.frames.find((f) => f.type === "openPane");
    assert.equal(frame.command, "make dev");
    assert.equal(frame.cwd, "/work");
    assert.ok(!("axis" in frame) && !("relativeTo" in frame), "the request names no split");
  } finally { h.close(); }
});

test("terminal_list shows the terminals and never the agent's own thread", async () => {
  const h = await harness((frame) => frame.type === "listPanes"
    ? { type: "panes", panes: [
        { id: "thread", cwd: "/work", isAgentPane: true, isFocused: true, isAlive: true },
        { id: "t1", cwd: "/work", isAgentPane: false, isFocused: false, isAlive: true },
        { id: "t2", cwd: "/work/api", isAgentPane: false, isFocused: true, isAlive: false },
      ] }
    : null);
  try {
    const listed = output(await h.tools.get("terminal_list").execute("call", {}));
    assert.equal(listed, "t1  /work\nt2  /work/api  [focused, no process]");
    assert.ok(!listed.includes("thread"));
  } finally { h.close(); }
});

test("terminal_list says so when there are none", async () => {
  const h = await harness((frame) => frame.type === "listPanes"
    ? { type: "panes", panes: [{ id: "thread", cwd: "/work", isAgentPane: true, isFocused: true, isAlive: true }] }
    : null);
  try {
    assert.equal(output(await h.tools.get("terminal_list").execute("call", {})), "no terminals");
  } finally { h.close(); }
});

test("run, read, focus and close name the terminal by its id", async () => {
  const h = await harness((frame) => {
    if (frame.type === "readPane") return { type: "paneContent", paneID: frame.paneID, lines: ["$ make", "ok"] };
    return { type: "ok" };
  });
  try {
    for (const name of ["terminal_run", "terminal_read", "terminal_focus", "terminal_close"]) {
      const schema = h.tools.get(name).parameters;
      assert.ok("terminalID" in schema.properties, `${name} takes a terminalID`);
      assert.ok(schema.required.includes("terminalID"));
    }
    assert.equal(output(await h.tools.get("terminal_run").execute("call", { terminalID: "t1", text: "ls" })), "sent to terminal t1");
    await h.tools.get("terminal_run").execute("call", { terminalID: "t1", text: "y", submit: false });
    assert.equal(output(await h.tools.get("terminal_read").execute("call", { terminalID: "t1" })), "$ make\nok");
    assert.equal(output(await h.tools.get("terminal_focus").execute("call", { terminalID: "t1" })), "focused terminal t1");
    assert.equal(output(await h.tools.get("terminal_close").execute("call", { terminalID: "t1" })), "closed terminal t1");

    const sends = h.frames.filter((f) => f.type === "sendPaneInput");
    assert.deepEqual(sends.map((f) => [f.paneID, f.text, f.submit]), [["t1", "ls", true], ["t1", "y", false]]);
    assert.deepEqual(h.frames.filter((f) => ["readPane", "focusPane", "closePane"].includes(f.type)).map((f) => [f.type, f.paneID]),
      [["readPane", "t1"], ["focusPane", "t1"], ["closePane", "t1"]]);
  } finally { h.close(); }
});

test("a refusal from Shepherd reaches the agent as an error", async () => {
  const h = await harness(() => ({ type: "error", code: "no_such_terminal", message: "terminal t9 is not in this agent's layout" }));
  try {
    await assert.rejects(() => h.tools.get("terminal_close").execute("call", { terminalID: "t9" }),
      /terminal t9 is not in this agent's layout \(no_such_terminal\)/);
  } finally { h.close(); }
});
