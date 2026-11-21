import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { closeSync, realpathSync, writeSync } from "node:fs";
import { constants } from "node:os";
import { fileURLToPath } from "node:url";

const executable = fileURLToPath(import.meta.url);

// One supervisor per Bash call. It leads the group until the jobs leave it, so neither an
// intermediary's exit nor a normal tool return loses ownership of a background process.
export function managedBash(sweep) {
  const groups = new Set();
  const stop = (group) => group.stdin.destroy(); // EOF is an owned handle, not a reusable PID.
  return {
    stopAll() { for (const group of groups) stop(group); },
    async exec(command, cwd, { onData, signal, timeout, env }) {
      signal?.throwIfAborted();
      if (timeout !== undefined && (!Number.isFinite(timeout) || timeout <= 0 || timeout > 2147483.647)) throw new Error("Invalid bash timeout");
      const scope = sweep && process.env.SHEPHERD_OWNED_THREAD ? randomUUID() : undefined;
      const group = spawn(process.execPath, [executable, "--supervise", command], {
        cwd, env: scope ? { ...(env ?? process.env), SHEPHERD_OWNED_THREAD: process.env.SHEPHERD_OWNED_THREAD, SHEPHERD_OWNED_BASH: scope } : env,
        detached: true, stdio: ["pipe", "ignore", "ignore", "pipe", "pipe", "pipe"],
      });
      const [, , , stdout, stderr, status] = group.stdio;
      groups.add(group);
      group.once("exit", () => groups.delete(group));
      group.on("error", () => groups.delete(group));
      group.stdin.on("error", () => {});
      stdout.on("data", onData); stderr.on("data", onData);
      let timedOut = false;
      const abort = () => {
        if (group.stdin.destroyed) return;
        stop(group);
        if (scope) sweep(scope);
      };
      const timer = timeout === undefined ? undefined : setTimeout(() => { timedOut = true; abort(); }, timeout * 1000);
      signal?.addEventListener("abort", abort, { once: true });
      // Supervisors that survive a successful call do not keep the engine alive. Its pipe closes
      // at engine exit, including when Fleet cancels or closes the entire thread.
      group.unref(); group.stdin.unref();
      let exitCode = null;
      try {
        await Promise.all([
          complete(group, stdout), complete(group, stderr),
          complete(group, status, (text) => { if (/^\d+\n$/.test(text)) exitCode = Number(text); }),
        ]);
        signal?.throwIfAborted();
        if (timedOut) throw new Error(`timeout:${timeout}`);
        if (exitCode === null) throw new Error("Bash supervisor exited without reporting a status");
        return { exitCode };
      } finally {
        clearTimeout(timer); signal?.removeEventListener("abort", abort);
        stdout.destroy(); stderr.destroy(); status.destroy();
      }
    },
  };
}

function complete(group, stream, read) {
  return new Promise((resolve, reject) => {
    let status = "";
    if (read) stream.on("data", (chunk) => { status += chunk; });
    group.once("error", reject);
    stream.once("error", reject);
    stream.once("end", () => { group.off("error", reject); read?.(status); resolve(); });
  });
}

function isSupervisor() {
  if (process.argv[2] !== "--supervise" || !process.argv[1]) return false;
  try { return realpathSync(process.argv[1]) === realpathSync(executable); }
  catch { return false; }
}

if (isSupervisor()) {
  const ownGroup = String(process.pid);
  const stop = () => process.kill(-process.pid, "SIGKILL");
  process.stdin.on("end", stop).on("error", stop).resume();
  process.on("SIGTERM", stop);
  const command = spawn("/bin/bash", ["-c", 'eval "$1"', "shepherd-bash", process.argv[3]], { stdio: ["ignore", 3, 4] });
  let finished = false;
  command.once("error", () => finish(127));
  command.once("exit", (code, signal) => finish(code ?? 128 + (constants.signals[signal] ?? 0)));
  function finish(code) {
    if (finished) return;
    finished = true;
    writeSync(5, `${code}\n`);
    // Keep stdio open. libuv uses those descriptors when it spawns the group probe.
    for (const fd of [3, 4, 5]) closeSync(fd);
    reapWhenEmpty();
  }
  function reapWhenEmpty() {
    // pgrep excludes itself. The live supervisor pins the group identity during every check.
    const probe = spawn("/usr/bin/pgrep", ["-g", ownGroup], { stdio: ["ignore", "pipe", "ignore"] });
    let count = "";
    probe.stdout.on("data", (chunk) => { count += chunk; });
    probe.on("error", () => {});
    probe.on("close", (code) => {
      if (code === 0 && count.trim() === ownGroup) process.exit(0);
      else setTimeout(reapWhenEmpty, 5_000);
    });
  }
}
