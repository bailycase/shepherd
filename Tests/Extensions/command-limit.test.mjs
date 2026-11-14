// A bash call with no timeout gets Shepherd's default command limit (20 minutes), so a watcher, a dev server or a
// deadlocked test cannot hold a tool call open for hours. Real pi, a fake provider, a tiny limit through
// SHEPHERD_COMMAND_LIMIT_SECONDS. Run: PI_PACKAGE_DIR=/path/to/pi/package node --test Tests/Extensions/command-limit.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { withPi, script, until } from "./fixtures/pi-rpc-harness.mjs";
import { root, startThread, scriptedBashCalls } from "./context-harness.mjs";

const status = path.join(root, "Extensions/shepherd-status.ts");
const hosted = (limit) => ({
  args: ["-e", status],
  env: { SHEPHERD_AGENT_ID: "limit-test", SHEPHERD_SOCKET: "/tmp/shepherd-limit-test-missing.sock", SHEPHERD_COMMAND_LIMIT_SECONDS: limit },
});
const live = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
const toolText = (end) => JSON.stringify(end?.result?.content);
const bashEnd = (events, name = "bash") => events.find((e) => e.type === "tool_execution_end" && e.toolName === name);

// A folder for the pid files, and the command that starts a descendant, records its pid and waits: pi must kill the group.
function pids(t) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "limit-")));
  const file = path.join(dir, "pid");
  // A failing run must not leave its sleep behind.
  t.after(() => { try { process.kill(Number(fs.readFileSync(file, "utf8"))); } catch {} fs.rmSync(dir, { recursive: true, force: true }); });
  return { hang: `sleep 9999 & echo $! > '${file}'; wait`, pid: () => Number(fs.readFileSync(file, "utf8")), file };
}

test("an agent's bash call with no timeout stops at the limit and leaves no process behind", { timeout: 120000 }, async (t) => {
  const p = pids(t);
  await withPi(t, { ...hosted("1"), onRequest: script([{ call: p.hang }]) }, async (pi) => {
    const turn = await pi.prompt();
    const end = bashEnd(turn.events);
    assert.equal(end?.isError, true, toolText(end));
    assert.match(toolText(end), /timed out after 1 seconds/);
    await until("the descendant to be gone", () => !live(p.pid()));
  });
});

test("a timeout the model passes is kept", { timeout: 120000 }, async (t) => {
  await withPi(t, { ...hosted("1"), onRequest: script([{ tool: { name: "bash", arguments: { command: "sleep 2; echo finished", timeout: 30 } } }]) }, async (pi) => {
    const end = bashEnd((await pi.prompt()).events);
    assert.equal(end?.isError, false, toolText(end));
    assert.match(toolText(end), /finished/);
  });
  const p = pids(t);
  await withPi(t, { ...hosted("30"), onRequest: script([{ tool: { name: "bash", arguments: { command: p.hang, timeout: 1 } } }]) }, async (pi) => {
    const end = bashEnd((await pi.prompt()).events);
    assert.match(toolText(end), /timed out after 1 seconds/, "the model's shorter timeout wins over the limit");
    await until("the descendant to be gone", () => !live(p.pid()));
  });
});

test("a codemode script's inner bash call gets the limit", { timeout: 120000 }, async (t) => {
  const p = pids(t);
  const code = `return await tools.bash({command: ${JSON.stringify(p.hang)}});`;
  await withPi(t, { ...hosted("1"), settings: { extensions: ["-builtin:mcp", "-builtin:tool-search", "-builtin:codemode"], codemode: { enabled: true } },
    onRequest: script([{ tool: { name: "codemode", arguments: { code } } }]) }, async (pi) => {
    const turn = await pi.prompt();
    const inner = turn.events.find((e) => e.type === "tool_execution_end" && e.toolName === "bash" && e.parentToolCallId);
    assert.match(toolText(inner), /timed out after 1 seconds/, toolText(bashEnd(turn.events, "codemode")));
    await until("the descendant to be gone", () => !live(p.pid()));
  });
});

test("a subagent's bash call gets the limit, and keeps a timeout it passes", { timeout: 120000 }, async (t) => {
  const p = pids(t);
  const thread = await startThread({ helper: true, instructions: false, skills: false, mcp: false, env: { SHEPHERD_COMMAND_LIMIT_SECONDS: "1" },
    onRequest: scriptedBashCalls([[p.hang, { tool: { name: "bash", arguments: { command: "sleep 2; echo finished", timeout: 30 } } }]]) });
  t.after(() => thread.stop());
  await thread.turn("go");
  const ends = thread.events.filter((e) => e.type === "tool_execution_end" && e.toolName === "bash");
  assert.equal(ends.length, 2);
  assert.match(toolText(ends[0]), /timed out after 1 seconds/);
  assert.equal(ends[1].isError, false, toolText(ends[1]));
  assert.match(toolText(ends[1]), /finished/);
  await until("the descendant to be gone", () => !live(p.pid()));
});
