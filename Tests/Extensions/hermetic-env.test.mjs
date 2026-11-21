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

// Pinned here on purpose: the implementation's own list must not be the oracle for what survives.
const expectedControls = ["PI_PACKAGE_DIR", "PI_FAKE_BUNDLED_CLI", "PI_TEST_KEEP_FIXTURES", "SHEPHERD_TEST_PI_LAUNCHER", "SHEPHERD_TEST_PI_HOME", "SHEPHERD_TEST_SPECKIT_PYTHON"];

test("hermetic-env keeps every runner control and nothing else", () => {
  assert.deepEqual([...runnerControls].sort(), [...expectedControls].sort());
  const controls = Object.fromEntries(expectedControls.map((key) => [key, `value of ${key}`]));
  assert.deepEqual(surviving({ ...controls, SHEPHERD_EXT_VISION: "/v", PI_MODEL: "m" }), controls);
});

// The scrub import must be the first statement: only blank lines and comments may precede it.
const scrubFirst = (source) => /^(?:\s|\/\/[^\n]*(?:\n|$)|\/\*[\s\S]*?\*\/)*import\s*"\.\/hermetic-env\.mjs"\s*;/.test(source);

test("the scrub-first check accepts only the scrub as the first statement", () => {
  const scrub = 'import "./hermetic-env.mjs";\n';
  assert.ok(scrubFirst(scrub + 'import test from "node:test";\n'));
  assert.ok(scrubFirst('// note\n/* block\n import x from "y"; */\n\n  ' + scrub));
  assert.ok(!scrubFirst('import{test} from "node:test";\n' + scrub));
  assert.ok(!scrubFirst('  import test from "node:test";\n' + scrub));
  assert.ok(!scrubFirst('import test from "node:test";\n' + scrub));
  assert.ok(!scrubFirst('const x = 1;\n' + scrub));
});

test("every extension test file imports hermetic-env before anything else", () => {
  const files = fs.readdirSync(dir).filter((name) => name.endsWith(".test.mjs"));
  assert.ok(files.length > 0, "found no test files to check");
  for (const file of files) {
    assert.ok(scrubFirst(fs.readFileSync(path.join(dir, file), "utf8")), `${file} must start with import "./hermetic-env.mjs"`);
  }
});
