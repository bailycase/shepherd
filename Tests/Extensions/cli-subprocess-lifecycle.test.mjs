import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import net from "node:net";
import { execFileSync } from "node:child_process";
import { withPi, until } from "./fixtures/pi-rpc-harness.mjs";
import { root, installTestCliLauncher } from "./fixtures/children-harness.mjs";

for (const scenario of ["untrusted", "missing", "timeout", "blocked", "child-blocked", "ordinary", "nested"]) test(`Spec Kit stops safely on ${scenario}`, { timeout: 20000 }, async t => {
  const dir = fs.mkdtempSync("/tmp/sk-life-");
  const socket = path.join(dir, "s"), connections = new Set();
  const server = net.createServer(c => {
    connections.add(c); c.on("error", () => {});
    c.on("data", chunk => {
      for (const line of String(chunk).trim().split("\n")) {
        const frame = JSON.parse(line);
        if (frame.type === "prepareProjectConfiguration") c.write(JSON.stringify({ type: "ok", id: frame.id }) + "\n");
      }
    });
  });
  await new Promise(resolve => server.listen(socket, resolve));
  t.after(async () => { for (const c of connections) c.destroy(); await new Promise(resolve => server.close(resolve)); fs.rmSync(dir, { recursive: true, force: true }); });
  const bridge = path.join(root, "Extensions/shepherd-children.ts");
  let childPID;
  await withPi(t, {
    launcher: process.env.SHEPHERD_TEST_PI_LAUNCHER, agentDir: process.env.SHEPHERD_TEST_PI_HOME,
    args: ["-e", bridge], usage: () => ({ input: 1, output: 1 }),
    files: (_dir, work) => ({ "trust.json": { [work]: !["untrusted", "ordinary"].includes(scenario) } }),
    env: { SHEPHERD_NATIVE_CHILDREN: "0", SHEPHERD_AGENT_ID: "parent", SHEPHERD_SOCKET: socket, SHEPHERD_EXT_CHILDREN: bridge },
    project(_dir, work) {
      installTestCliLauncher(process.env.SHEPHERD_TEST_PI_HOME ?? path.join(_dir, "home"));
      childPID = path.join(work, "pid");
      fs.mkdirSync(path.join(work, ".pi/prompts"), { recursive: true });
      fs.writeFileSync(path.join(work, ".pi/prompts/speckit.fixture.md"), "Run the fixture");
      if (scenario.includes("blocked")) {
        const extensions = path.join(process.env.SHEPHERD_TEST_PI_HOME ?? path.join(_dir, "home"), "extensions");
        fs.mkdirSync(extensions, { recursive: true });
        fs.writeFileSync(path.join(extensions, "permissions.ts"), `export default pi => pi.on("tool_call", event => {
          if (event.toolName === "bash" && ${scenario === "blocked" ? "true" : 'event.input.command.includes("BASHPID")'}) return { block: true, reason: "Fixture permission denied" };
        });`);
      }
    },
    onRequest({ body }) {
      const child = body.tools?.some(tool => tool.function.name === "shepherd_parent_message");
      if (child && scenario === "child-blocked" && body.messages.some(m => m.role === "tool")) return { outputText: "Child shell denied" };
      if (child && scenario === "nested") return body.messages.some(m => m.role === "tool") ? { outputText: "Nested dispatch denied" } : { call: "pi -p 'nested prompt'" };
      if (child) return { call: `echo $BASHPID > ${JSON.stringify(childPID)}; sleep 60` };
      if (!body.messages.some(m => m.role === "tool")) return { tool: { name: "bash", arguments: { command: scenario === "ordinary" ? "printf ordinary-ok" : `pi -p '/speckit.${scenario === "missing" ? "missing" : "fixture"}'`, timeout: 1 } } };
      return { outputText: "stopped" };
    },
  }, async pi => {
    await pi.request({ type: "prompt", message: "Run fixture" });
    await until("runner stopped", () => pi.events.some(e => e.type === "agent_settled"), 10000);
    const result = pi.events.find(e => e.type === "tool_execution_end" && e.toolName === "bash" && e.toolCallId === "call_1");
    assert.equal(result?.isError, !["child-blocked", "ordinary", "nested"].includes(scenario), JSON.stringify(result));
    if (scenario === "ordinary") {
      assert.match(JSON.stringify(result), /ordinary-ok/);
      assert.equal(result.result.details?.cliUsage, undefined);
      return;
    }
    if (scenario === "nested") {
      assert.match(JSON.stringify(result), /Nested dispatch denied/);
      assert.equal(pi.provider.requests.filter(r => r.body.tools?.some(tool => tool.function.name === "shepherd_parent_message")).length, 2);
      return;
    }
    assert.match(JSON.stringify(result), scenario === "untrusted" ? /Approve this project/ : scenario === "missing" ? /not enabled/ : scenario === "blocked" ? /Fixture permission denied/ : scenario === "child-blocked" ? /Child shell denied/ : /timed out|time limit|abort|cancel/i);
    if (scenario === "timeout") {
      assert.ok(fs.existsSync(childPID), "the child started its Bash command before cancellation");
      const pid = Number(fs.readFileSync(childPID, "utf8"));
      await until("child Bash stopped", () => {
        try { return /^Z/.test(execFileSync("/bin/ps", ["-p", String(pid), "-o", "stat="], { encoding: "utf8" }).trim()); }
        catch { return true; }
      }, 5000);
    } else assert.equal(fs.existsSync(childPID), false);
  });
});
