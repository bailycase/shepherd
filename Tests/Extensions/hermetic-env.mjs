// Imported first by every Tests/Extensions/*.test.mjs. The suite runs inside agent threads whose environment
// describes that thread (PI_MODEL, SHEPHERD_EXT_VISION, SHEPHERD_CLI_SOCKET, ...). Left in place, those change what the
// extensions do (a text-only model's thread sets SHEPHERD_EXT_VISION, which makes board_render attach a picture), so
// the result would depend on who ran it. Drop every PI_* and SHEPHERD_* variable except the runner controls below;
// a test that needs anything else sets it itself.
//
// Runner controls are inputs a person or a runner (EngineSmokeTests.swift, CI, a shell) passes to the suite on
// purpose. They are an exact list, not a prefix rule: a prefix such as SHEPHERD_TEST_* would also let through a
// variable a thread or a later change happens to name that way, and PI_FAKE_BUNDLED_CLI would not match it anyway.
// Adding a control means adding it here, with what it does and who sets it.
export const runnerControls = [
  "PI_PACKAGE_DIR",              // the installed pi package: fixtures/pi-rpc-harness.mjs needs it (CI, pi_engine.py stage)
  "PI_FAKE_BUNDLED_CLI",         // "1" runs the bundled dist/bundle/cli.js instead of dist/cli.js (fixtures/pi-rpc-harness.mjs)
  "PI_TEST_KEEP_FIXTURES",       // "1" keeps each withPi temp directory for inspection (fixtures/pi-rpc-harness.mjs)
  "SHEPHERD_TEST_PI_LAUNCHER",   // the real Shepherd launcher to run pi through (EngineSmokeTests; cli-subprocess*.test.mjs)
  "SHEPHERD_TEST_PI_HOME",       // the home that launcher installed (EngineSmokeTests; cli-subprocess*.test.mjs)
  "SHEPHERD_TEST_SPECKIT_PYTHON", // a Python with upstream specify-cli; unset skips the upstream case (cli-subprocess.test.mjs)
];
// (PI_SMOKE_MODEL and PI_SMOKE_SINGLE belong to native-children.smoke.mjs, which is not a test file and does not import this.)

for (const key of Object.keys(process.env)) if (/^(PI|SHEPHERD)_/.test(key) && !runnerControls.includes(key)) delete process.env[key];
