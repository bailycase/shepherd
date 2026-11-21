import assert from "node:assert/strict";
import { test } from "node:test";
import { setImmediate, setTimeout as sleep } from "node:timers/promises";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, symlink, unlink, rmdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { managedBash } from "../../Extensions/shepherd-bash.mjs";

const alive = (pid) => {
  try { process.kill(pid, 0); return true; }
  catch (error) { if (error.code === "ESRCH") return false; throw error; }
};
async function eventually(check) {
  const deadline = Date.now() + 5000;
  while (!check()) {
    assert.ok(Date.now() < deadline, "background process did not stop");
    await setImmediate();
  }
}

// Inner Bash exits, so its child no longer belongs to it by PPID. The child's stdout/stderr
// are redirected just like a dev server; finishing the tool must not close the server itself.
const background = `/bin/bash -c '/usr/bin/nohup /bin/sleep 60 </dev/null >/dev/null 2>&1 & echo $!'`;

test("completed Bash leaves an orphan running; thread Stop still owns its group", async () => {
  const bash = managedBash();
  let output = "";
  try {
    const reply = await bash.exec(`${background}; exit 7`, process.cwd(), { onData: (chunk) => { output += chunk; }, timeout: 5 });
    assert.equal(reply.exitCode, 7);
    const pid = Number(output.trim());
    assert.ok(Number.isSafeInteger(pid) && pid > 0);
    assert.ok(alive(pid), "normal return keeps background work alive");
    bash.stopAll();
    await eventually(() => !alive(pid));
    const next = await bash.exec("exit 0", process.cwd(), { onData: () => {} });
    assert.equal(next.exitCode, 0, "ordinary Stop keeps the caller usable");
  } finally { bash.stopAll(); }
});

test("ending the engine closes its retained groups even without running JS shutdown", { timeout: 7000 }, async () => {
  const module = new URL("../../Extensions/shepherd-bash.mjs", import.meta.url).href;
  const script = `import { managedBash } from ${JSON.stringify(module)};
    await managedBash().exec(${JSON.stringify(background)}, process.cwd(), { onData: (d) => process.stdout.write(d) });`;
  const engine = spawn(process.execPath, ["--input-type=module", "--eval", script], { stdio: ["ignore", "pipe", "inherit"] });
  const exit = once(engine, "exit");
  try {
    const [output] = await once(engine.stdout, "data");
    const pid = Number(String(output).trim());
    assert.ok(Number.isSafeInteger(pid) && pid > 0);
    assert.deepEqual(await exit, [0, null]);
    await eventually(() => !alive(pid));
  } finally { engine.kill("SIGKILL"); }
});

test("a supervisor that stops without a status does not report success", async () => {
  const bash = managedBash();
  try {
    await assert.rejects(bash.exec("echo ready; exec /bin/sleep 30", process.cwd(), {
      onData: () => bash.stopAll(), timeout: 5,
    }), /supervisor.*without.*status/i);
  } finally { bash.stopAll(); }
});

const supervisorPath = fileURLToPath(new URL("../../Extensions/shepherd-bash.mjs", import.meta.url));
async function supervise(path, signal, args = []) {
  const child = spawn(process.execPath, [...args, path, "--supervise", "exit 7"], {
    detached: true, signal, stdio: ["pipe", "ignore", "ignore", "pipe", "pipe", "pipe"],
  });
  const exit = once(child, "exit");
  child.stdio[3].resume(); child.stdio[4].resume();
  let status = "";
  child.stdio[5].on("data", (chunk) => { status += chunk; });
  try {
    await once(child.stdio[5], "end");
    // The supervisor may retain its group after reporting status. Release it as pi would.
    child.stdin.destroy();
    const [code, signal] = await exit;
    assert.ok(code === 0 || signal === "SIGKILL", `supervisor crashed: ${code ?? signal}`);
    return status;
  } finally { child.stdin.destroy(); }
}

test("the supervisor runs when invoked through a symlink", { timeout: 7000 }, async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "shepherd-bash-"));
  const link = join(dir, "bash.mjs");
  await symlink(supervisorPath, link);
  try {
    assert.equal(await supervise(link, t.signal), "7\n");
  } finally {
    await unlink(link);
    await rmdir(dir);
  }
});

test("the supervisor publishes one status if the Bash child emits error then exit", { timeout: 7000 }, async (t) => {
  const preload = `import cp from 'node:child_process';
    import { EventEmitter } from 'node:events';
    import { syncBuiltinESMExports } from 'node:module';
    const spawn = cp.spawn;
    cp.spawn = (file, ...args) => {
      if (file !== '/bin/bash') return spawn(file, ...args);
      const child = new EventEmitter();
      queueMicrotask(() => {
        child.emit('error', new Error('child failed'));
        child.emit('exit', 1, null);
      });
      return child;
    };
    syncBuiltinESMExports();`;
  assert.equal(await supervise(supervisorPath, t.signal, ["--import", `data:text/javascript,${encodeURIComponent(preload)}`]), "127\n");
});

test("a managed Bash timeout kills orphaned descendants", async () => {
  const bash = managedBash();
  let output = "";
  try {
    await assert.rejects(bash.exec(`${background}; /bin/sleep 30`, process.cwd(), { onData: (chunk) => { output += chunk; }, timeout: 1 }), /timeout:1/);
    const pid = Number(output.trim());
    assert.ok(Number.isSafeInteger(pid) && pid > 0);
    await eventually(() => !alive(pid));
  } finally { bash.stopAll(); }
});

// Starts a supervisor and keeps its stdin open, as pi does, so only its own reaping can end it.
// Exit is observed through a listener registered at spawn, so nothing here ever signals a pid
// that might have been recycled.
async function startSupervisor(command) {
  const child = spawn(process.execPath, [supervisorPath, "--supervise", command], {
    detached: true, stdio: ["pipe", "ignore", "ignore", "pipe", "pipe", "pipe"],
  });
  const exit = once(child, "exit");
  child.stdio[3].resume(); child.stdio[4].resume(); child.stdio[5].resume();
  child.stdin.on("error", () => {});
  await once(child.stdio[5], "end");
  return { child, exit };
}
// Resolves with [code, signal], or fails if the supervisor is still running after ms.
async function exitsWithin(exit, ms) {
  const timer = new AbortController();
  const result = await Promise.race([exit, sleep(ms, "timeout", { signal: timer.signal })]);
  timer.abort();
  assert.notEqual(result, "timeout", `supervisor still alive after ${ms} ms`);
  return result;
}

test("the supervisor exits by itself once its command is done and nothing else is in the group", { timeout: 40000 }, async () => {
  const { child, exit } = await startSupervisor("exit 0");
  try { assert.deepEqual(await exitsWithin(exit, 30000), [0, null]); }
  finally { child.stdin.destroy(); }
});

test("the supervisor outlives a background job until the test releases it, then exits", { timeout: 70000 }, async () => {
  const dir = await mkdtemp(join(tmpdir(), "shepherd-bash-"));
  const hold = join(dir, "hold");
  await writeFile(hold, "");
  // The job runs until the test deletes the file, so it cannot finish before the check below.
  const { child, exit } = await startSupervisor(`(while [ -e '${hold}' ]; do /bin/sleep 0.1; done) </dev/null >/dev/null 2>&1 &`);
  let exited = false;
  exit.then(() => { exited = true; });
  try {
    await sleep(1500); // several probes at the 100 ms backoff start; a late wakeup cannot weaken the check
    assert.ok(!exited, "supervisor must stay while the job is in its group");
    await unlink(hold);
    assert.deepEqual(await exitsWithin(exit, 30000), [0, null]);
  } finally {
    child.stdin.destroy();
    await rm(dir, { recursive: true, force: true });
  }
});
