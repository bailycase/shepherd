// Opt-in compatibility check against an isolated upstream specify-cli installation.
// Real Shepherd launcher and Pi, with all model requests handled by a loopback fake provider.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { withPi, requestSummary } from "./fixtures/pi-rpc-harness.mjs";

const launcher = process.env.SHEPHERD_TEST_PI_LAUNCHER;
const agentDir = process.env.SHEPHERD_TEST_PI_HOME;
const python = process.env.SHEPHERD_TEST_SPECKIT_PYTHON;
const fixture = fileURLToPath(new URL("./fixtures/speckit-contract.py", import.meta.url));
const q = value => "'" + value.replaceAll("'", "'\"'\"'") + "'";

test("upstream Spec Kit installs extensions, evaluates hooks and dispatches Pi workflow steps through Shepherd", { skip: !launcher || !python, timeout: 60000 }, async t => {
  await withPi(t, {
    launcher, agentDir,
    settings: { ...JSON.parse(fs.readFileSync(path.join(agentDir, "settings.json"))), defaultProvider: "fixture", defaultModel: "fixture" },
    files: (_dir, work) => ({ "trust.json": { [work]: true } }),
    project: (dir, work) => {
      const setup = spawnSync(python, [fixture, "setup", work], { env: { PATH: "/usr/bin:/bin", HOME: dir }, encoding: "utf8", timeout: 30000 });
      assert.equal(setup.status, 0, setup.stdout + setup.stderr);
    },
    onRequest: entry => {
      const messages = requestSummary(entry).messages;
      if (!JSON.stringify(messages).includes("SPECKIT_REGISTERED_HOOK")) {
        assert.ok(JSON.stringify(messages).includes("hooks.before_tasks"));
        assert.ok(JSON.stringify(messages).includes("hooks.after_tasks"));
        return { outputText: "EXECUTE_COMMAND: speckit.fixture.record" };
      }
      if (messages.some(m => m.role === "tool")) return { outputText: "Hook finished" };
      const mode = JSON.stringify(messages).includes("raw-json") ? "raw-json" : "workflow";
      return { call: `printf '${mode}\\n' >> upstream-hooks.txt` };
    },
  }, async pi => {
    assert.ok((await pi.commands()).some(c => c.name === "speckit.fixture.record"));
    await pi.prompt("/speckit.tasks");
    // Model prose is data: a printed EXECUTE_COMMAND marker must not itself dispatch anything.
    assert.equal(fs.existsSync(path.join(pi.work, "upstream-hooks.txt")), false);
    const result = await pi.request({ type: "bash", command: `${q(python)} ${q(fixture)} verify ${q(pi.work)}`, timeout: 45 });
    assert.equal(result.success, true, JSON.stringify(result));
    assert.equal(result.data.exitCode, 0, result.data.output);
    assert.ok(result.data.output.includes('"workflow": "completed"'), result.data.output);
    assert.equal(fs.readFileSync(path.join(pi.work, "upstream-hooks.txt"), "utf8"), "raw-json\nworkflow\n");
    assert.equal(pi.provider.requests.length, 5);
  });
});
