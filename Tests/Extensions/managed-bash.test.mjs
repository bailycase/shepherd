import assert from "node:assert/strict";
import { test } from "node:test";
import { setImmediate } from "node:timers/promises";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, symlink, unlink, rmdir } from "node:fs/promises";
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

// The host's sweep of an escaped job is asked for only when a call is aborted or times out, and only
// for that call's own scope. A normal return never asks, and neither does a host without a thread marker.
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

test("an aborted or timed-out call asks for a sweep of its own scope only", async () => {
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
      assert.equal(scopes.length, 2);
      assert.ok(scopes.every((scope) => uuid.test(scope)));
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
