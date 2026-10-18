// Owned scratch servers only: MCP close must finish wrappers even when their leader exits first.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { pathToFileURL } from "node:url";
import { spawn } from "node:child_process";
import { until } from "./fixtures/pi-rpc-harness.mjs";

const pkg = process.env.PI_PACKAGE_DIR;
const { StdioTransport } = await import(pathToFileURL(path.join(pkg, "node_modules/@earendil-works/pi-mcp/dist/transports/stdio.js")));
const fixture = path.resolve("Tests/Extensions/fixtures/fake-mcp-stdio.mjs");
// Linux can retain an orphan's zombie until its reaper runs; kill(pid, 0) still succeeds.
// comm is parenthesized and can itself contain spaces or ')', so use its final delimiter.
const exitedLinuxState = (stat) => {
  const end = stat.lastIndexOf(")");
  return end >= 0 && ["Z", "X"].includes(stat.slice(end + 1).trimStart().split(/\s/, 1)[0]);
};
const alive = (pid) => {
  try { process.kill(pid, 0); } catch (error) { return error.code !== "ESRCH"; }
  if (process.platform === "linux") {
    try { return !exitedLinuxState(fs.readFileSync(`/proc/${pid}/stat`, "utf8")); }
    catch (error) { return error.code !== "ENOENT"; } // Gone during the read; other errors stay conservative.
  }
  return true;
};

test("process liveness distinguishes Linux zombies from live and unreadable states", () => {
  for (const state of ["R", "S", "D", "T", "t", "I"]) {
    assert.equal(exitedLinuxState(`123 (worker ) name with spaces) ${state} 1 2 3`), false);
  }
  for (const state of ["Z", "X"]) {
    assert.equal(exitedLinuxState(`123 (worker ) name with spaces) ${state} 1 2 3`), true);
  }
  assert.equal(exitedLinuxState(""), false);
  assert.equal(exitedLinuxState("unreadable"), false);
  assert.equal(exitedLinuxState("Z"), false);
  assert.equal(alive(process.pid), true, "a live process must never pass the cleanup check");
});
const pidAt = (file) => { try { const pid = Number(fs.readFileSync(file, "utf8")); return pid > 0 ? pid : undefined; } catch {} };

for (const entry of ["dist/cli.js", "dist/bundle/cli.js"]) for (const initializing of [false, true]) {
  test(`${entry} closes detached MCP descendants on normal shutdown (initializing: ${initializing})`, { timeout: 20000 }, async (t) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-mcp-close-"));
    const leaderFile = path.join(dir, "leader.pid"), descendantFile = path.join(dir, "descendant.pid");
    const logFile = path.join(dir, "mcp.log");
    fs.writeFileSync(path.join(dir, "settings.json"), JSON.stringify({ extensions: ["-builtin:mcp", "-builtin:codemode", "-builtin:tool-search"] }));
    fs.writeFileSync(path.join(dir, "mcp.json"), JSON.stringify({ mcpServers: { fixture: {
      command: process.execPath, args: [fixture], exposure: "deferred",
      env: { FAKE_MCP_PIDFILE: leaderFile, FAKE_MCP_DESCENDANT: descendantFile,
        ...(initializing ? { FAKE_MCP_HOLD_INITIALIZE: "1", FAKE_MCP_LOG: logFile } : {}) },
    } } }));
    const pi = spawn(process.execPath, [path.join(pkg, entry), "--mode", "rpc", "--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates", "-e", "builtin:mcp"], {
      cwd: dir, detached: true, stdio: ["pipe", "pipe", "pipe"],
      env: { HOME: dir, PATH: process.env.PATH, PI_CODING_AGENT_DIR: dir, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" },
    });
    let leader, output = "", errors = "";
    pi.stdout.on("data", (data) => { output += data; });
    pi.stderr.on("data", (data) => { errors += data; });
    t.after(() => {
      for (const pid of [leader ?? pidAt(leaderFile), pi.pid]) if (pid) { try { process.kill(-pid, "SIGKILL"); } catch {} }
      fs.rmSync(dir, { recursive: true, force: true });
    });
    pi.stdin.write(JSON.stringify({ type: "get_state", id: "ready" }) + "\n");
    await until("Pi and its owned MCP descendants ready", () => output.includes('"id":"ready"') && pidAt(leaderFile) && pidAt(descendantFile), 10000);
    if (initializing) {
      await until("MCP initialize received but deliberately unanswered", () => fs.existsSync(logFile) && fs.readFileSync(logFile, "utf8").includes('"method":"initialize"'));
      assert.ok(!fs.readFileSync(logFile, "utf8").includes('"method":"notifications/initialized"'));
    }
    leader = Number(fs.readFileSync(leaderFile, "utf8"));
    const descendant = Number(fs.readFileSync(descendantFile, "utf8"));
    assert.ok(alive(leader) && alive(descendant), "MCP leader and descendant must be live before shutdown");
    pi.stdin.end();
    await until("Pi and MCP tree gone", () => pi.exitCode !== null && !alive(leader) && !alive(descendant), 5000);
    assert.equal(pi.exitCode, 0, errors);
  });
}

for (const resistantLeader of [false, true]) {
  test(`MCP close cleans a TERM-resistant descendant (leader resistant: ${resistantLeader})`, { timeout: 15000 }, async (t) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mcp-close-"));
    const descendantFile = path.join(dir, "descendant.pid");
    const leaderFile = path.join(dir, "leader.pid");
    let leader, descendant;
    t.after(() => {
      // Exact scratch-owned group, never a process-name match or a real server.
      if (leader) { try { process.kill(-leader, "SIGKILL"); } catch {} }
      fs.rmSync(dir, { recursive: true, force: true });
    });
    const transport = new StdioTransport({ command: process.execPath, args: [fixture], inheritEnv: false,
      env: { HOME: dir, PATH: process.env.PATH, FAKE_MCP_PIDFILE: leaderFile, FAKE_MCP_DESCENDANT: descendantFile,
        ...(resistantLeader ? { FAKE_MCP_IGNORE_TERM: "1", FAKE_MCP_LINGER: "1" } : {}) },
    });
    await transport.start();
    leader = transport.pid;
    await until("the owned server and descendant to start", () => pidAt(leaderFile) && pidAt(descendantFile));
    descendant = Number(fs.readFileSync(descendantFile, "utf8"));
    assert.ok(descendant > 0);
    assert.ok(alive(leader) && alive(descendant), "MCP leader and descendant must be live before close");
    await transport.close();
    await until("the entire MCP process group to exit", () => !alive(leader) && !alive(descendant), 5000);
    assert.equal(alive(descendant), false);
  });
}
