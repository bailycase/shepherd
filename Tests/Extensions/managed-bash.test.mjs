import "./hermetic-env.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import { setImmediate, setTimeout as sleep } from "node:timers/promises";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, readFile, symlink, unlink, rmdir, rm, writeFile } from "node:fs/promises";
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

test("thread Stop kills a returned Bash call's retained group without requesting a sweep", async () => {
  await withThreadMarker("thread-marker", async () => {
    const swept = [], bash = managedBash((scope) => swept.push(scope));
    let output = "";
    try {
      const reply = await bash.exec(`${background}; exit 7`, process.cwd(), { onData: (chunk) => { output += chunk; }, timeout: 5 });
      assert.equal(reply.exitCode, 7);
      const pid = Number(output.trim());
      assert.ok(Number.isSafeInteger(pid) && pid > 0);
      assert.ok(alive(pid), "normal return keeps background work alive");
      bash.stopAll();
      await eventually(() => !alive(pid));
      assert.deepEqual(swept, []);
      const next = await bash.exec("exit 0", process.cwd(), { onData: () => {} });
      assert.equal(next.exitCode, 0, "ordinary Stop keeps the caller usable");
    } finally { bash.stopAll(); }
  });
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

// Stop, abort and timeout can sweep a call's own scope while it is in flight.
// A normal return never asks, and neither does a host without a thread marker.
async function withThreadMarker(marker, body) {
  const saved = process.env.SHEPHERD_OWNED_THREAD;
  if (marker === undefined) delete process.env.SHEPHERD_OWNED_THREAD; else process.env.SHEPHERD_OWNED_THREAD = marker;
  try { await body(); }
  finally { if (saved === undefined) delete process.env.SHEPHERD_OWNED_THREAD; else process.env.SHEPHERD_OWNED_THREAD = saved; }
}
const markers = `printf '%s|%s' "$SHEPHERD_OWNED_THREAD" "$SHEPHERD_OWNED_BASH"`;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

test("each Bash call gets its own scope next to the thread marker, and a normal return never asks for a sweep", async () => {
  await withThreadMarker("thread-marker", async () => {
    const swept = [], bash = managedBash((scope) => swept.push(scope));
    const seen = [];
    try {
      for (const env of [undefined, { CALLER: "kept" }]) {
        let output = "";
        assert.equal((await bash.exec(markers, process.cwd(), { onData: (chunk) => { output += chunk; }, env })).exitCode, 0);
        const [thread, scope] = output.split("|");
        assert.equal(thread, "thread-marker");
        assert.match(scope, uuid);
        seen.push(scope);
      }
      assert.notEqual(seen[0], seen[1], "scopes are per call");
      assert.deepEqual(swept, []);
    } finally { bash.stopAll(); }
  });
});

test("a child's Bash keeps its real ownership when Pi supplies an env without markers or with forged ones", async () => {
  const saved = { child: process.env.SHEPHERD_CHILD, scope: process.env.SHEPHERD_OWNED_BASH };
  process.env.SHEPHERD_CHILD = "1"; process.env.SHEPHERD_OWNED_BASH = "attempt-1";
  const bash = managedBash();
  try {
    await withThreadMarker("thread-marker", async () => {
      for (const env of [{ PATH: process.env.PATH, CALLER: "kept" }, { PATH: process.env.PATH, SHEPHERD_OWNED_THREAD: "forged-thread", SHEPHERD_OWNED_BASH: "forged-scope" }]) {
        let output = "";
        assert.equal((await bash.exec(markers, process.cwd(), { onData: (chunk) => { output += chunk; }, env })).exitCode, 0);
        assert.equal(output, "thread-marker|attempt-1");
      }
    });
  } finally {
    bash.stopAll();
    for (const [key, value] of [["SHEPHERD_CHILD", saved.child], ["SHEPHERD_OWNED_BASH", saved.scope]]) if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
});

test("Stop then abort, abort alone, and timeout each sweep only their own in-flight call once", async () => {
  await withThreadMarker("thread-marker", async () => {
    const swept = [], bash = managedBash((scope) => swept.push(scope));
    const scopes = [];
    const run = async (options) => {
      let output = "";
      const done = bash.exec(`${markers}; /bin/sleep 30`, process.cwd(), { onData: (chunk) => { output += chunk; options.started?.(); }, ...options });
      await assert.rejects(done);
      scopes.push(output.split("|")[1]);
    };
    try {
      const controller = new AbortController();
      await run({ signal: controller.signal, started: () => controller.abort() });
      await run({ timeout: 1 });
      const stopped = new AbortController();
      let stoppedScopeBeforeAbort;
      await run({ signal: stopped.signal, started: () => {
        bash.stopAll();
        stoppedScopeBeforeAbort = swept[2];
        stopped.abort();
      } });
      assert.ok(scopes.every((scope) => uuid.test(scope)));
      assert.equal(stoppedScopeBeforeAbort, scopes[2], "Stop requests the sweep before abort arrives");
      assert.deepEqual(swept, scopes, "one request per call, each naming only that call's scope");
    } finally { bash.stopAll(); }
  });
});

test("without the thread marker the call carries no scope and never asks for a sweep", async () => {
  await withThreadMarker(undefined, async () => {
    const swept = [], bash = managedBash((scope) => swept.push(scope));
    let output = "";
    try {
      await assert.rejects(bash.exec(`printf '%s|%s' "\${SHEPHERD_OWNED_THREAD-unset}" "\${SHEPHERD_OWNED_BASH-unset}"; /bin/sleep 30`, process.cwd(), { onData: (chunk) => { output += chunk; }, timeout: 1 }), /timeout:1/);
      assert.equal(output, "unset|unset");
      assert.deepEqual(swept, []);
    } finally { bash.stopAll(); }
  });
});

// Starts a supervisor and keeps its stdin open, as pi does, so only its own reaping can end it.
// Exit is observed through a listener registered at spawn, so nothing here ever signals a pid
// that might have been recycled.
async function startSupervisor(command, args = []) {
  const child = spawn(process.execPath, [...args, supervisorPath, "--supervise", command], {
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

test("a probe that spawns without stdout, then errors, is retried once and the supervisor survives", { timeout: 40000 }, async () => {
  const dir = await mkdtemp(join(tmpdir(), "shepherd-bash-"));
  const calls = join(dir, "calls");
  // The first pgrep spawn fails as EMFILE does: a child with no stdout that emits error on the next tick.
  const preload = `import cp from 'node:child_process';
    import { appendFileSync } from 'node:fs';
    import { EventEmitter } from 'node:events';
    import { syncBuiltinESMExports } from 'node:module';
    const spawn = cp.spawn;
    let probes = 0;
    cp.spawn = (file, ...args) => {
      if (file !== '/usr/bin/pgrep') return spawn(file, ...args);
      appendFileSync(${JSON.stringify(calls)}, 'x');
      if (probes++ > 0) return spawn(file, ...args);
      const child = new EventEmitter();
      process.nextTick(() => child.emit('error', Object.assign(new Error('spawn pgrep EMFILE'), { code: 'EMFILE' })));
      return child;
    };
    syncBuiltinESMExports();`;
  const { child, exit } = await startSupervisor("exit 0", ["--import", `data:text/javascript,${encodeURIComponent(preload)}`]);
  try {
    assert.deepEqual(await exitsWithin(exit, 30000), [0, null], "an unhandled probe error would crash it");
    assert.equal((await readFile(calls, "utf8")).length, 2, "one failed probe schedules exactly one retry");
  } finally {
    child.stdin.destroy();
    await rm(dir, { recursive: true, force: true });
  }
});

test("the supervisor outlives a background job until the test releases it, then exits", { timeout: 100000 }, async () => {
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
    // The back-off caps at 30 s: allow a probe that just missed the release plus one more interval and margin.
    assert.deepEqual(await exitsWithin(exit, 75000), [0, null]);
  } finally {
    child.stdin.destroy();
    await rm(dir, { recursive: true, force: true });
  }
});
