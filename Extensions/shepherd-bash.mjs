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
  const pendingSweeps = new Set();
  const stop = (group) => group.stdin.destroy(); // EOF is an owned handle, not a reusable PID.
  return {
    stopAll() {
      for (const group of groups) stop(group);
      // Request sweeps now: closing stdin can settle these calls before pi's abort arrives.
      for (const requestSweep of pendingSweeps) requestSweep();
    },
    async exec(command, cwd, { onData, signal, timeout, env }) {
      signal?.throwIfAborted();
      if (timeout !== undefined && (!Number.isFinite(timeout) || timeout <= 0 || timeout > 2147483.647)) throw new Error("Invalid bash timeout");
      const thread = process.env.SHEPHERD_OWNED_THREAD;
      const scope = sweep && thread ? randomUUID() : undefined;
      // Child Bash calls share the attempt's scope, including when Pi supplies a custom env.
      const ownership = scope ?? (process.env.SHEPHERD_CHILD === "1" ? process.env.SHEPHERD_OWNED_BASH : undefined);
      const group = spawn(process.execPath, [executable, "--supervise", command], {
        cwd, env: thread && ownership ? { ...(env ?? process.env), SHEPHERD_OWNED_THREAD: thread, SHEPHERD_OWNED_BASH: ownership } : env,
        detached: true, stdio: ["pipe", "ignore", "ignore", "pipe", "pipe", "pipe"],
      });
      const [, , , stdout, stderr, status] = group.stdio;
      groups.add(group);
      group.once("exit", () => groups.delete(group));
      group.on("error", () => groups.delete(group));
      group.stdin.on("error", () => {});
      stdout.on("data", onData); stderr.on("data", onData);
      let timedOut = false, sweepRequested = false;
      const requestSweep = () => {
        if (!scope || sweepRequested) return;
        sweepRequested = true;
        sweep(scope);
      };
      if (scope) pendingSweeps.add(requestSweep);
      const abort = () => { stop(group); requestSweep(); };
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
        pendingSweeps.delete(requestSweep);
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
    reapWhenEmpty(100);
  }
  // Probe at once, then back off while a background job keeps the group alive. Any probe
  // failure retries: only a clean listing of our own pid may end the supervisor.
  function reapWhenEmpty(delay) {
    let retried = false;
    const retry = () => {
      if (retried) return;
      retried = true;
      setTimeout(reapWhenEmpty, delay, Math.min(delay * 2, 30_000));
    };
    try {
      // macOS pgrep leaves out itself and its ancestors unless given -a, and the probe is our
      // child, so without it we would never see our own pid. On Linux (procps) -a prints the
      // full command line and pgrep never lists itself, so -g alone is right. Either way the
      // first field of each line is the pid. The live supervisor pins the group during the check.
      const flags = process.platform === "darwin" ? ["-a", "-g"] : ["-g"];
      const probe = spawn("/usr/bin/pgrep", [...flags, ownGroup], { stdio: ["ignore", "pipe", "ignore"] });
      // Listen first: a resource error (EMFILE) can return a child without stdout, then emit error.
      probe.on("error", retry);
      if (!probe.stdout) return retry();
      let listing = "";
      probe.stdout.on("data", (chunk) => { listing += chunk; }).on("error", retry);
      probe.on("close", (code) => {
        const pids = listing.split("\n").filter((line) => line.trim()).map((line) => line.trim().split(/\s+/)[0]);
        if (!retried && code === 0 && pids.length > 0 && pids.every((pid) => pid === ownGroup)) process.exit(0);
        retry();
      });
    } catch { retry(); }
  }
}
