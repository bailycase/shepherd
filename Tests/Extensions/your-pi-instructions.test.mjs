// The user's own pi's global instructions reach an agent's system prompt, read live before each
// run, through the status extension (Settings ▸ Pi ▸ From your pi), and sit before Shepherd's own
// root instructions. Rendered by pi's own prompt builder; no model provider, only temporary files.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
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
const { default: status } = await jiti.import(path.join(root, "Extensions/shepherd-status.ts"));
const { default: instructions } = await jiti.import(path.join(root, "Extensions/shepherd-instructions.ts"));
const { buildSystemPrompt, normalizeBuildSystemPromptOptions } = await import(path.join(pkg, "dist/core/system-prompt.js"));

const KEYS = ["SHEPHERD_YOUR_PI_INSTRUCTIONS", "SHEPHERD_INSTRUCTIONS_DIR", "PI_CODING_AGENT_DIR", "SHEPHERD_AGENT_ID", "SHEPHERD_SOCKET"];

/** One agent's launch: "your pi" holding `files`, and the status extension (and, with `shepherd`, Shepherd's own instructions) loaded. */
function launch(files, { yourPi = true, shepherd } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-your-pi-"));
  const yours = path.join(dir, "your-pi");
  const home = path.join(dir, "shepherd-pi");
  const own = path.join(dir, "instructions");
  for (const folder of [yours, home, own]) fs.mkdirSync(folder);
  for (const [name, text] of Object.entries(files)) fs.writeFileSync(path.join(yours, name), text);
  const saved = Object.fromEntries(KEYS.map((key) => [key, process.env[key]]));
  for (const key of KEYS) delete process.env[key];
  if (yourPi) process.env.SHEPHERD_YOUR_PI_INSTRUCTIONS = yours;
  process.env.PI_CODING_AGENT_DIR = home;
  if (shepherd) {
    fs.writeFileSync(path.join(own, "AGENTS.md"), shepherd);
    process.env.SHEPHERD_INSTRUCTIONS_DIR = own;
  }
  const handlers = {};
  const pi = { on: (name, handler) => { (handlers[name] ??= []).push(handler); } };
  status(pi);
  if (shepherd) instructions(pi);
  const emit = (name, event) => { for (const handler of handlers[name] ?? []) handler(event); };
  return {
    yours, home, own, handlers,
    run: (options) => {
      emit("session_start", { type: "session_start", reason: "startup" });
      const current = normalizeBuildSystemPromptOptions(options);
      emit("before_agent_start", { type: "before_agent_start", prompt: "hi", systemPromptOptions: current });
      return current;
    },
    restore: () => {
      for (const [key, value] of Object.entries(saved)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
}

test("without SHEPHERD_YOUR_PI_INSTRUCTIONS the status extension adds nothing to the context", () => {
  const agent = launch({ "AGENTS.md": "your rules" }, { yourPi: false });
  try {
    assert.equal(agent.handlers.before_agent_start, undefined);
  } finally {
    agent.restore();
  }
});

test("your global instructions join the context with their real path, before the project's", () => {
  const agent = launch({ "AGENTS.md": "- Say FIXTURE-GLOBAL-INSTRUCTIONS.\n" });
  try {
    const options = agent.run({ cwd: "/work/repo", contextFiles: [{ path: "/work/repo/AGENTS.md", content: "repo rules" }] });
    assert.deepEqual(options.contextFiles.map((file) => file.path), [path.join(agent.yours, "AGENTS.md"), "/work/repo/AGENTS.md"]);
    const prompt = buildSystemPrompt(options);
    assert.ok(prompt.includes("FIXTURE-GLOBAL-INSTRUCTIONS"));
    assert.ok(prompt.includes(path.join(agent.yours, "AGENTS.md")), "the model sees where the file really is");
    assert.ok(prompt.indexOf("FIXTURE-GLOBAL-INSTRUCTIONS") < prompt.indexOf("repo rules"));
  } finally {
    agent.restore();
  }
});

test("pi's pick among your files wins, and each run reads it afresh", () => {
  const agent = launch({ "CLAUDE.md": "claude rules" });
  try {
    assert.deepEqual(agent.run({ cwd: "/w", contextFiles: [] }).contextFiles.map((file) => file.content), ["claude rules"]);
    fs.writeFileSync(path.join(agent.yours, "AGENTS.md"), "agents rules");
    assert.deepEqual(agent.run({ cwd: "/w", contextFiles: [] }).contextFiles.map((file) => file.content), ["agents rules"]);
    fs.writeFileSync(path.join(agent.yours, "AGENTS.override.md"), "override rules");
    assert.deepEqual(agent.run({ cwd: "/w", contextFiles: [] }).contextFiles.map((file) => file.content), ["override rules"]);
    for (const name of ["AGENTS.override.md", "AGENTS.md", "CLAUDE.md"]) fs.rmSync(path.join(agent.yours, name));
    assert.deepEqual(agent.run({ cwd: "/w", contextFiles: [] }).contextFiles, [], "no file adds nothing");
  } finally {
    agent.restore();
  }
});

test("your instructions follow pi's own root file, and Shepherd's own follow yours", () => {
  const agent = launch({ "AGENTS.md": "your rules" }, { shepherd: "shepherd rules" });
  try {
    const options = agent.run({ cwd: "/work/repo", contextFiles: [
      { path: path.join(agent.home, "AGENTS.md"), content: "pi root rules" },
      { path: "/work/repo/AGENTS.md", content: "repo rules" },
    ] });
    assert.deepEqual(options.contextFiles.map((file) => file.content), ["pi root rules", "your rules", "shepherd rules", "repo rules"]);
  } finally {
    agent.restore();
  }
});

test("a file too large, or not a file, is left out and never fails the run", () => {
  const agent = launch({ "CLAUDE.md": "claude rules" });
  try {
    fs.mkdirSync(path.join(agent.yours, "AGENTS.override.md"));
    assert.deepEqual(agent.run({ cwd: "/w", contextFiles: [] }).contextFiles.map((file) => file.content), ["claude rules"]);
    fs.writeFileSync(path.join(agent.yours, "AGENTS.md"), "x".repeat(300 * 1024));
    assert.deepEqual(agent.run({ cwd: "/w", contextFiles: [] }).contextFiles, []);
    assert.doesNotThrow(() => agent.run({ cwd: "/w" }));
  } finally {
    agent.restore();
  }
});
