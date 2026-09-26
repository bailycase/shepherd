// Shepherd's root instructions reach pi's system prompt where Settings ▸ Instructions says they
// do, rendered by pi's own prompt builder; suggest_instruction drafts a line over a stand-in
// Shepherd socket. No model provider, only temporary files.
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
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const require = createRequire(path.join(pkg, "package.json"));
const { createJiti } = require("jiti");
const jiti = createJiti(import.meta.url, { alias: {
  "@earendil-works/pi-coding-agent": path.join(pkg, "dist/index.js"),
  typebox: path.join(pkg, "node_modules/typebox/build/index.mjs"),
} });
const { default: install } = await jiti.import(path.join(root, "Extensions/shepherd-instructions.ts"));
const { buildSystemPrompt, normalizeBuildSystemPromptOptions } = await import(path.join(pkg, "dist/core/system-prompt.js"));

/** A pi stand-in that records handlers, and the environment one agent launch sets. */
function launch(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-instructions-"));
  const instructions = path.join(dir, "instructions");
  const agentDir = path.join(dir, "pi");
  fs.mkdirSync(instructions);
  fs.mkdirSync(agentDir);
  for (const [name, text] of Object.entries(files)) fs.writeFileSync(path.join(instructions, name), text);
  const saved = { dir: process.env.SHEPHERD_INSTRUCTIONS_DIR, agent: process.env.PI_CODING_AGENT_DIR };
  process.env.SHEPHERD_INSTRUCTIONS_DIR = instructions;
  process.env.PI_CODING_AGENT_DIR = agentDir;
  const handlers = {};
  install({ on: (name, handler) => { (handlers[name] ??= []).push(handler); } });
  const emit = (name, event) => { for (const handler of handlers[name] ?? []) handler(event); };
  return {
    instructions, agentDir, handlers,
    start: () => emit("session_start", { type: "session_start", reason: "startup" }),
    /** One run's prompt options, as pi hands a fresh copy to every run's handlers. */
    run: (options) => {
      const current = normalizeBuildSystemPromptOptions(options);
      emit("before_agent_start", { type: "before_agent_start", prompt: "hi", systemPromptOptions: current });
      return current;
    },
    restore: () => {
      for (const [key, value] of [["SHEPHERD_INSTRUCTIONS_DIR", saved.dir], ["PI_CODING_AGENT_DIR", saved.agent]]) {
        if (value === undefined) delete process.env[key]; else process.env[key] = value;
      }
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
}

test("without SHEPHERD_INSTRUCTIONS_DIR the extension registers nothing", () => {
  const saved = process.env.SHEPHERD_INSTRUCTIONS_DIR;
  delete process.env.SHEPHERD_INSTRUCTIONS_DIR;
  const handlers = [];
  install({ on: (name) => handlers.push(name) });
  if (saved !== undefined) process.env.SHEPHERD_INSTRUCTIONS_DIR = saved;
  assert.deepEqual(handlers, []);
});

test("AGENTS.md sits after pi's root file and before the repo's; APPEND_SYSTEM.md follows pi's own", () => {
  const agent = launch({ "AGENTS.md": "- Prefer small commits.\n", "APPEND_SYSTEM.md": "Never force-push.\n" });
  try {
    agent.start();
    const options = agent.run({
      cwd: "/work/repo",
      contextFiles: [
        { path: path.join(agent.agentDir, "AGENTS.md"), content: "pi root rules" },
        { path: "/work/AGENTS.md", content: "parent folder rules" },
        { path: "/work/repo/AGENTS.md", content: "repo rules" },
      ],
      appendSystemPrompt: "pi's own addendum",
    });
    assert.deepEqual(options.contextFiles.map((file) => file.path), [
      path.join(agent.agentDir, "AGENTS.md"),
      path.join(agent.instructions, "AGENTS.md"),
      "/work/AGENTS.md",
      "/work/repo/AGENTS.md",
    ]);
    assert.equal(options.appendSystemPrompt, "pi's own addendum\n\nNever force-push.");
    const prompt = buildSystemPrompt(options);
    const order = ["pi root rules", "- Prefer small commits.", "parent folder rules", "repo rules"].map((text) => prompt.indexOf(text));
    assert.ok(order.every((at) => at >= 0), "every file is in the prompt");
    assert.deepEqual([...order].sort((a, b) => a - b), order, "in pi's reading order");
    assert.ok(prompt.includes("Never force-push."));
  } finally {
    agent.restore();
  }
});

test("without pi's own root file, Shepherd's comes first", () => {
  const agent = launch({ "AGENTS.md": "shepherd rules" });
  try {
    agent.start();
    const options = agent.run({ cwd: "/work/repo", contextFiles: [{ path: "/work/repo/AGENTS.md", content: "repo rules" }] });
    assert.deepEqual(options.contextFiles.map((file) => file.content), ["shepherd rules", "repo rules"]);
    assert.equal(options.appendSystemPrompt, "", "no APPEND_SYSTEM.md adds nothing");
  } finally {
    agent.restore();
  }
});

test("a running session keeps the version it started with, and every run gets it once", () => {
  const agent = launch({ "AGENTS.md": "first version", "APPEND_SYSTEM.md": "first rule" });
  try {
    agent.start();
    fs.writeFileSync(path.join(agent.instructions, "AGENTS.md"), "second version");
    fs.writeFileSync(path.join(agent.instructions, "APPEND_SYSTEM.md"), "second rule");
    for (let run = 0; run < 2; run++) {
      const options = agent.run({ cwd: "/work", contextFiles: [] });
      assert.deepEqual(options.contextFiles.map((file) => file.content), ["first version"]);
      assert.equal(options.appendSystemPrompt, "first rule");
    }
    agent.start();
    const next = agent.run({ cwd: "/work", contextFiles: [] });
    assert.deepEqual(next.contextFiles.map((file) => file.content), ["second version"]);
    assert.equal(next.appendSystemPrompt, "second rule");
  } finally {
    agent.restore();
  }
});

test("empty or missing files add nothing", () => {
  const agent = launch({ "AGENTS.md": "  \n\n" });
  try {
    agent.start();
    const options = agent.run({ cwd: "/work", contextFiles: [], appendSystemPrompt: "pi's own addendum" });
    assert.deepEqual(options.contextFiles, []);
    assert.equal(options.appendSystemPrompt, "pi's own addendum");
  } finally {
    agent.restore();
  }
});

/**
 * Runs `body` with Settings ▸ Experiments ▸ Suggested instructions on for `files`, against a
 * stand-in Shepherd socket that answers each request with `answer(frame)`.
 */
async function withSuggestions(files, answer, body) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sh-suggest-"));
  const socketPath = path.join(dir, "s");
  const frames = [];
  const server = net.createServer((socket) => {
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      buffer += chunk;
      const index = buffer.indexOf("\n");
      if (index < 0) return;
      const frame = JSON.parse(buffer.slice(0, index));
      frames.push(frame);
      socket.write(JSON.stringify(answer(frame)) + "\n");
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  const keys = ["SHEPHERD_SUGGEST_FILES", "SHEPHERD_AGENT_ID", "SHEPHERD_SOCKET"];
  const saved = keys.map((key) => process.env[key]);
  for (const [key, value] of [["SHEPHERD_SUGGEST_FILES", files], ["SHEPHERD_AGENT_ID", "a1"], ["SHEPHERD_SOCKET", socketPath]]) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
  const tools = new Map();
  try {
    install({ on: () => {}, registerTool: (tool) => tools.set(tool.name, tool) });
    await body(tools, frames);
  } finally {
    keys.forEach((key, index) => {
      if (saved[index] === undefined) delete process.env[key]; else process.env[key] = saved[index];
    });
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

const suggestion = (outcome) => (frame) => ({ type: "suggestion", id: frame.id, outcome });

test("suggest_instruction is offered only while the experiment is on for this agent", async () => {
  await withSuggestions(undefined, suggestion("waiting"), async (tools) => assert.equal(tools.size, 0));
  await withSuggestions("", suggestion("waiting"), async (tools) => assert.equal(tools.size, 0));
  await withSuggestions("AGENTS.md", suggestion("waiting"), async (tools) => {
    const tool = tools.get("suggest_instruction");
    assert.ok(tool, "the tool is registered");
    assert.deepEqual(Object.keys(tool.parameters.properties).sort(), ["line", "reason"], "one file needs no choice");
  });
  await withSuggestions("AGENTS.md,APPEND_SYSTEM.md,notes.md", suggestion("waiting"), async (tools) => {
    assert.deepEqual(Object.keys(tools.get("suggest_instruction").parameters.properties).sort(), ["file", "line", "reason"]);
  });
});

test("a suggestion goes to Shepherd, and the reply says what became of it", async () => {
  const outcomes = ["waiting", "alreadyWaiting", "dismissed", "inFile"];
  let next = 0;
  await withSuggestions("AGENTS.md,APPEND_SYSTEM.md", (frame) => suggestion(outcomes[next++])(frame), async (tools, frames) => {
    const tool = tools.get("suggest_instruction");
    const texts = [];
    for (const params of [
      { line: "- Ask for join keys first.", reason: "Two services re-ran." },
      { line: "- Ask for join keys first.", reason: "Again.", file: "APPEND_SYSTEM.md" },
      { line: "- Retry flaky tests.", reason: "It passed on retry.", file: "notes.md" },
      { line: "- Prefer the standard library.", reason: "A dependency broke." },
    ]) {
      const result = await tool.execute("call", params);
      texts.push(result.content[0].text);
    }
    assert.deepEqual(texts, [
      "Suggested for AGENTS.md. The user decides whether to add it; nothing is written until they do.",
      "That line is already waiting for the user.",
      "The user dismissed that line before, so it is not suggested again.",
      "AGENTS.md already has that line.",
    ]);
    assert.deepEqual(frames[0], {
      type: "suggestInstruction", agentID: "a1", line: "- Ask for join keys first.", reason: "Two services re-ran.",
      file: "AGENTS.md", id: 1,
    });
    // A file it may suggest for is kept; anything else falls back to the first.
    assert.deepEqual(frames.map((frame) => frame.file), ["AGENTS.md", "APPEND_SYSTEM.md", "AGENTS.md", "AGENTS.md"]);
  });
});

test("a refusal fails the tool call with Shepherd's reason", async () => {
  const refuse = (frame) => ({ type: "error", id: frame.id, code: "invalid", message: "Suggest one line at a time." });
  await withSuggestions("AGENTS.md", refuse, async (tools) => {
    await assert.rejects(tools.get("suggest_instruction").execute("call", { line: "- a\n- b", reason: "" }),
                         /Suggest one line at a time\. \(invalid\)/);
  });
});
