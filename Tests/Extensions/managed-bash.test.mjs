import assert from "node:assert/strict";
import { test } from "node:test";
import { setImmediate } from "node:timers/promises";
import { spawn } from "node:child_process";
import { once } from "node:events";
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
