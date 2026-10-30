// The ask-the-user extension against a stand-in for pi's extension API: inert without its
// variable, one tool, a question that goes through pi's native dialog in the shape Shepherd's
// question dock reads, and a cancel that is never an answer.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/ask.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import * as path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");
const { createJiti } = createRequire(path.join(pkg, "package.json"))("jiti");
const jiti = createJiti(import.meta.url, { alias: { typebox: path.join(pkg, "node_modules/typebox/build/index.mjs") } });
const { default: install } = await jiti.import(path.join(root, "Extensions/shepherd-ask.ts"));

function load(env) {
  const saved = process.env.SHEPHERD_EXT_ASK;
  if (env === undefined) delete process.env.SHEPHERD_EXT_ASK; else process.env.SHEPHERD_EXT_ASK = env;
  const tools = new Map();
  try { install({ registerTool: (tool) => tools.set(tool.name, tool), on() {} }); }
  finally { if (saved === undefined) delete process.env.SHEPHERD_EXT_ASK; else process.env.SHEPHERD_EXT_ASK = saved; }
  return tools;
}

test("inert without SHEPHERD_EXT_ASK=1", () => {
  assert.equal(load(undefined).size, 0);
  assert.equal(load("0").size, 0);
  assert.deepEqual([...load("1").keys()], ["ask_user"]);
});

test("a question with options is one native input Shepherd turns into buttons and a field; the answer comes back", async () => {
  const tool = load("1").get("ask_user");
  const dialogs = [];
  const ctx = { hasUI: true, ui: { input: async (title, placeholder) => { dialogs.push({ title, placeholder }); return "30 days"; } } };
  const result = await tool.execute("call-1", { question: "How long should we keep logs?", options: ["7 days", "30 days", "Say anything"], short: "retention?" }, undefined, undefined, ctx);
  assert.deepEqual(dialogs, [{ title: 'How long should we keep logs?\n\nOptions:\n["7 days","30 days"]', placeholder: "Say anything" }]);
  assert.equal(result.isError, undefined);
  assert.deepEqual(result.details, { answer: "30 days" });
  assert.match(result.content[0].text, /answered: 30 days/);
  // Free text: the plain question, no placeholder.
  await tool.execute("call-2", { question: "Which branch?" }, undefined, undefined, ctx);
  assert.deepEqual(dialogs.at(-1), { title: "Which branch?", placeholder: undefined });
  // Details follow the one-line question after a blank line, ahead of the options.
  await tool.execute("call-3", { question: "Keep\nlogs?", details: "They cost disk.\n\nOld ones are rarely read.", options: ["Yes", "No"] }, undefined, undefined, ctx);
  assert.deepEqual(dialogs.at(-1), { title: 'Keep logs?\n\nThey cost disk.\n\nOld ones are rarely read.\n\nOptions:\n["Yes","No"]', placeholder: "Say anything" });
});

test("a dismissed question is reported, never answered, and bad input or no UI is an error", async () => {
  const tool = load("1").get("ask_user");
  const dismissed = await tool.execute("c", { question: "Continue?" }, undefined, undefined, { hasUI: true, ui: { input: async () => undefined } });
  assert.deepEqual(dismissed.details, { cancelled: true });
  assert.match(dismissed.content[0].text, /did not answer/);
  const silent = await tool.execute("c", { question: "Continue?" }, undefined, undefined, { hasUI: false, ui: { input: async () => { throw Error("never"); } } });
  assert.equal(silent.isError, true);
  const asked = [];
  const ctx = { hasUI: true, ui: { input: async () => { asked.push(1); return "x"; } } };
  assert.equal((await tool.execute("c", { question: "   " }, undefined, undefined, ctx)).isError, true);
  assert.equal((await tool.execute("c", { question: "q", options: ["a", "b", "c", "d", "e", "f", "g"] }, undefined, undefined, ctx)).isError, true);
  // A question past one short sentence is refused so the background goes in details.
  assert.equal((await tool.execute("c", { question: "x".repeat(301) }, undefined, undefined, ctx)).isError, true);
  assert.equal((await tool.execute("c", { question: "q", details: "x".repeat(1601) }, undefined, undefined, ctx)).isError, true);
  assert.equal(asked.length, 0, "no dialog opens for a refused call");
});
