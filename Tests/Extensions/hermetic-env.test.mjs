// The extension suite must give the same result in any agent thread: every test file starts from hermetic-env.mjs.
import "./hermetic-env.mjs";
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { runnerControls } from "./hermetic-env.mjs";

const dir = path.dirname(fileURLToPath(import.meta.url));

// What survives hermetic-env.mjs when the process starts with `env`.
const surviving = (env) => JSON.parse(execFileSync(process.execPath, ["--input-type=module", "-e",
  `await import(${JSON.stringify(path.join(dir, "hermetic-env.mjs"))}); console.log(JSON.stringify(Object.fromEntries(Object.entries(process.env).filter(([k]) => /^(PI|SHEPHERD)_/.test(k)))))`],
{ env: { PATH: process.env.PATH, ...env }, encoding: "utf8" }));

test("hermetic-env drops the surrounding thread's PI_ and SHEPHERD_ variables", () => {
  const thread = { PI_MODEL: "m", PI_CODING_AGENT_DIR: "/home", SHEPHERD_EXT_VISION: "/v", SHEPHERD_CLI_SOCKET: "/s", SHEPHERD_SOCKET: "/s", SHEPHERD_AGENT_ID: "a",
    SHEPHERD_TEST_UNLISTED: "1", PI_TEST_UNLISTED: "1" };
  assert.deepEqual(surviving(thread), {});
});

test("hermetic-env keeps every runner control and nothing else", () => {
  assert.ok(runnerControls.length > 0);
  const controls = Object.fromEntries(runnerControls.map((key) => [key, `value of ${key}`]));
  assert.deepEqual(surviving({ ...controls, SHEPHERD_EXT_VISION: "/v", PI_MODEL: "m" }), controls);
});

test("every extension test file imports hermetic-env before anything else", () => {
  const files = fs.readdirSync(dir).filter((name) => name.endsWith(".test.mjs"));
  assert.ok(files.length > 0, "found no test files to check");
  for (const file of files) {
    const first = fs.readFileSync(path.join(dir, file), "utf8").split("\n").find((line) => line.startsWith("import "));
    assert.equal(first, 'import "./hermetic-env.mjs";', `${file} must start with import "./hermetic-env.mjs"`);
  }
});
