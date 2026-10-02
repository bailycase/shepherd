// The context budget (docs/context-budget.md): what an agent's context carries before the user has said
// anything, measured on a real pi, and which tools register where.
// Run: PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/context-budget.test.mjs
// Every launch runs in a temporary HOME against a local fake provider (context-harness.mjs).
import test from "node:test";
import assert from "node:assert/strict";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { root } from "./context-harness.mjs";

const pkg = process.env.PI_PACKAGE_DIR;
if (!pkg) throw Error("Set PI_PACKAGE_DIR to the installed Pi package");

test("the prompt an agent starts with stays within the committed ceilings (scripts/context-budget.json)", { timeout: 240000 }, () => {
  const run = spawnSync("python3", [path.join(root, "scripts", "context_budget.py"), "--check", "--pi", pkg], { encoding: "utf8", timeout: 220000 });
  assert.equal(run.status, 0, `${run.stdout}${run.stderr}`);
  assert.match(run.stdout, /context budget ok/);
});
