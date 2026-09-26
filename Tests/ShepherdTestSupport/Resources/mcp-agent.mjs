#!/usr/bin/env node
// One agent's MCP extension without pi, for the app's end-to-end tests (MCPAgentHarness): loads
// the extension at argv[2] with pi's tool and event API stood in, starts a session in argv[3],
// runs the tool calls on stdin's first line, prints one JSON line with the results, and shuts the
// session down when stdin closes. The extension itself talks to the real Shepherd socket its
// environment names. Run with node's type stripping; pi-ai's StringEnum and typebox's Type are
// stubbed beside the extension, since the tests never read the schemas they build.
import * as fs from "node:fs";
import * as path from "node:path";
import * as readline from "node:readline";
import { pathToFileURL } from "node:url";

const extensionFile = process.argv[2];
const cwd = process.argv[3] ?? process.cwd();

function stub(name, source) {
  const dir = path.join(path.dirname(extensionFile), "node_modules", name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "package.json"), JSON.stringify({ name, type: "module", main: "index.js" }));
  fs.writeFileSync(path.join(dir, "index.js"), source);
}
stub("@earendil-works/pi-ai", 'export const StringEnum = (values, options = {}) => ({ type: "string", enum: values, ...options });\n');
stub("typebox", [
  "export const Type = {",
  '  Object: (properties, options = {}) => ({ type: "object", properties, ...options }),',
  "  Optional: (schema) => schema,",
  '  String: (options = {}) => ({ type: "string", ...options }),',
  '  Record: (_key, _value, options = {}) => ({ type: "object", ...options }),',
  "  Unknown: () => ({}),",
  "};",
  "",
].join("\n"));

const { default: install } = await import(pathToFileURL(extensionFile).href);

const handlers = {};
const tools = new Map();
let active = new Set();
install({
  on: (name, handler) => { (handlers[name] ??= []).push(handler); },
  registerTool: (tool) => {
    if (!tools.has(tool.name)) active.add(tool.name);
    tools.set(tool.name, tool);
  },
  getAllTools: () => [...tools.values()].map((tool) => ({
    name: tool.name, description: tool.description, parameters: tool.parameters, sourceInfo: { path: extensionFile },
  })),
  getActiveTools: () => [...active],
  setActiveTools: (names) => { active = new Set(names); },
});

async function emit(name, event, ctx) {
  for (const handler of handlers[name] ?? []) await handler({ type: name, ...event }, ctx);
}

function textOf(result) {
  return (result?.content ?? []).filter((item) => item.type === "text").map((item) => item.text).join("\n");
}

await emit("session_start", { reason: "startup" }, { cwd });
const lines = readline.createInterface({ input: process.stdin })[Symbol.asyncIterator]();
const first = await lines.next();
const results = [];
for (const step of first.done ? [] : JSON.parse(first.value)) {
  const tool = tools.get(step.tool);
  if (!tool) {
    results.push({ ok: false, error: `no tool named ${step.tool}` });
    continue;
  }
  try {
    const result = await tool.execute(`call-${results.length}`, step.params ?? {}, undefined, undefined, { cwd });
    results.push({ ok: true, text: textOf(result) });
  } catch (error) {
    results.push({ ok: false, error: String(error?.message ?? error) });
  }
}
process.stdout.write(JSON.stringify({ tools: [...active].sort(), results }) + "\n");
while (!(await lines.next()).done) {}
await emit("session_shutdown", { reason: "quit" }, { cwd });
process.exit(0);
