// The extension suite must give the same result in any agent thread: every test file starts from hermetic-env.mjs.
import "./hermetic-env.mjs";
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const dir = path.dirname(fileURLToPath(import.meta.url));

test("hermetic-env drops the surrounding thread's PI_ and SHEPHERD_ variables and keeps PI_PACKAGE_DIR", () => {
  const out = execFileSync(process.execPath, ["--input-type=module", "-e",
    `await import(${JSON.stringify(path.join(dir, "hermetic-env.mjs"))}); console.log(JSON.stringify(Object.keys(process.env).filter((k) => /^(PI|SHEPHERD)_/.test(k))))`],
  { env: { PATH: process.env.PATH, PI_PACKAGE_DIR: "/pkg", PI_MODEL: "m", SHEPHERD_EXT_VISION: "/v", SHEPHERD_CLI_SOCKET: "/s" }, encoding: "utf8" });
  assert.deepEqual(JSON.parse(out), ["PI_PACKAGE_DIR"]);
});

test("every extension test file imports hermetic-env before anything else", () => {
  for (const file of fs.readdirSync(dir).filter((name) => name.endsWith(".test.mjs"))) {
    const first = fs.readFileSync(path.join(dir, file), "utf8").split("\n").find((line) => line.startsWith("import "));
    assert.equal(first, 'import "./hermetic-env.mjs";', `${file} must start with import "./hermetic-env.mjs"`);
  }
});
