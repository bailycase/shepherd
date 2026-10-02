// The context budget (docs/context-budget.md): what an agent's context carries before the user has said
// anything, measured on a real pi, and which tools register where, each with a verdict.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/context-budget.test.mjs
// Every launch runs in a temporary HOME against a local fake provider (context-harness.mjs).
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { capture, root } from "./context-harness.mjs";

const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");

test("the prompt an agent starts with stays within the committed ceilings (scripts/context-budget.json)", { timeout: 240000 }, () => {
  const run = spawnSync("python3", [path.join(root, "scripts", "context_budget.py"), "--check", "--pi", pkg], { encoding: "utf8", timeout: 220000 });
  assert.equal(run.status, 0, `${run.stdout}${run.stderr}`);
  assert.match(run.stdout, /context budget ok/);
});

// MARK: which tools register where

const registry = JSON.parse(fs.readFileSync(path.join(root, "Tests/Extensions/context-tools.json"), "utf8"));
const rows = new Map();
for (const family of registry.families) for (const name of family.tools) rows.set(name, family);

// Tools that register only when something else is on: a design reference, the suggestions experiment.
const CONDITIONAL = new Set(["design_get", "design_note", "suggest_instruction"]);

// The tools a launch sends the model that Shepherd's extensions registered: not pi's other built-ins (inactive, never sent), and
// not an MCP server's direct tools, which are the user's (`mcp__<server>__<tool>`, pi's own MCP).
function sent(captured) {
  const body = captured.body;
  const names = (body.tools ?? []).map((tool) => tool.name ?? tool.function?.name);
  return names.filter((name) => !name.startsWith("mcp__"));
}

// Every tool an extension registered, sent or not: a deferred tool is registered and left out of the request until tool_search loads it.
function registered(captured) {
  return new Set(Object.keys(captured.toolSources).filter((name) => !name.startsWith("mcp__")));
}

const LAUNCHES = [
  ["thread", "thread", { designRefs: false }],
  ["automation", "automation", {}],
  ["design", "design", {}],
  ["thread-with-design-reference", "thread", { designRefs: true }],
];

for (const [scenario, context, { designRefs }] of LAUNCHES) {
  test(`${scenario}: every tool registered has a verdict, none that was dropped is back, every kept tool is sent and every deferred one is registered and not sent`, { timeout: 120000 }, async () => {
    const captured = await capture(scenario, { pkg });
    const tools = new Set(sent(captured));
    const all = registered(captured);
    for (const name of all) {
      const row = rows.get(name);
      if (!row) {
        // A tool of pi's that no launch activates (grep, find, ls) is not Shepherd's, and is in neither request nor registry.
        if (!tools.has(name) && !captured.toolSources[name]?.endsWith(".ts")) continue;
        assert.fail(`${name} is registered in ${scenario} (by ${captured.toolSources[name] || "pi"}) but has no row in Tests/Extensions/context-tools.json: give it a verdict, and say in docs/context-budget.md what it costs`);
      }
      const verdict = row.verdicts[context];
      assert.ok(verdict, `${name} is registered in ${scenario}, which the registry says it never is: ${JSON.stringify(row.verdicts)}`);
      assert.notEqual(verdict, "drop", `${name} was dropped for ${context} (${row.reason}) and is registered again`);
    }
    for (const name of tools) {
      const verdict = rows.get(name)?.verdicts[context];
      assert.notEqual(verdict, "defer", `${name} is deferred for ${context} (${rows.get(name)?.reason}) and is sent in every request`);
    }
    for (const [name, row] of rows) {
      const verdict = row.verdicts[context];
      if (verdict === "drop") assert.ok(!all.has(name), `${name} is dropped for ${context} and is registered`);
      if (verdict !== "keep" && verdict !== "defer") continue;
      if (CONDITIONAL.has(name) && !(designRefs && name.startsWith("design_"))) continue;
      if (context === "child" || (name === "shepherd_parent_message")) continue;
      assert.ok(all.has(name), `${name} should be registered in ${scenario} (${verdict}) and is not: renamed or removed? Update Tests/Extensions/context-tools.json and docs/context-budget.md`);
      if (verdict === "keep") assert.ok(tools.has(name), `${name} should be sent in ${scenario} (keep) and is not`);
      else assert.ok(!tools.has(name), `${name} is deferred in ${scenario} and is sent`);
    }
  });
}

test("missions are off: no mission tool and no mission parameter in a thread, and SHEPHERD_MISSIONS=1 brings both back", { timeout: 120000 }, async () => {
  const find = (captured, name) => captured.body.tools.find((tool) => (tool.name ?? tool.function?.name) === name);
  const off = await capture("thread", { pkg });
  assert.ok(!find(off, "shepherd_mission"), "no mission tool");
  for (const name of ["shepherd_child_start", "shepherd_workflow"]) {
    const properties = Object.keys((find(off, name).parameters ?? find(off, name).function?.parameters).properties);
    assert.ok(!properties.includes("mission") && !properties.includes("missionId"), `${name} offers no mission parameter: ${properties}`);
    assert.ok(!/mission/i.test(JSON.stringify(find(off, name))), `${name} says nothing of missions`);
  }
  const on = await capture("thread", { pkg, env: { SHEPHERD_MISSIONS: "1" } });
  assert.ok(find(on, "shepherd_mission"), "the tool is back");
  const properties = Object.keys((find(on, "shepherd_child_start").parameters).properties);
  assert.ok(properties.includes("mission") && properties.includes("missionId"));
});
