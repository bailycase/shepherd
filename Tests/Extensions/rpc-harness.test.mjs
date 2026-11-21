import "./hermetic-env.mjs";
import assert from "node:assert/strict";
import { test } from "node:test";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { withPi, until } from "./fixtures/pi-rpc-harness.mjs";

test("RPC and diagnostic text preserve Unicode split across pipe chunks", { timeout: 30000 }, async (t) => {
  await withPi(t, {}, async (pi) => {
    await pi.request({ type: "get_state" });
    for (const split of [1, 2, 3]) {
      const event = { type: "fixture_unicode", split, output: "left🐑right" };
      const record = Buffer.from(JSON.stringify(event) + "\n");
      const cut = record.indexOf(Buffer.from("🐑")) + split;
      // push supplies separate byte chunks to the real reader without relying on OS pipe timing.
      pi.child.stdout.push(record.subarray(0, cut));
      pi.child.stdout.push(record.subarray(cut));
      await until("the split Unicode record", () => pi.events.some((e) => e.type === event.type && e.split === split));
      assert.deepEqual(pi.events.find((e) => e.type === event.type && e.split === split), event);
      const diagnostic = Buffer.from(`diagnostic-${split}🐑\n`);
      const diagnosticCut = diagnostic.indexOf(Buffer.from("🐑")) + split;
      pi.child.stderr.push(diagnostic.subarray(0, diagnosticCut));
      pi.child.stderr.push(diagnostic.subarray(diagnosticCut));
      await until("the split Unicode diagnostic", () => pi.stderr.includes(`diagnostic-${split}`));
      assert.ok(pi.stderr.includes(diagnostic.toString("utf8")), pi.stderr);
    }
  });
});

const portOpen = (port) => new Promise((resolve) => {
  const socket = net.connect(port, "127.0.0.1");
  socket.on("connect", () => { socket.destroy(); resolve(true); });
  socket.on("error", () => resolve(false));
});

// Records every server that starts listening while `t` runs, and closes all of them when `t` ends, so a probe that
// finds a leaked listener (or a close that never completes) cannot leave it behind. Independent of the harness cleanup
// under test. With `hangClose`, server.close() never calls back.
function ownServers(t, { hangClose = false } = {}) {
  const servers = [];
  const { listen, close } = net.Server.prototype;
  net.Server.prototype.listen = function (...args) { servers.push(this); return listen.apply(this, args); };
  if (hangClose) net.Server.prototype.close = function () { return this; };
  t.after(async () => {
    net.Server.prototype.listen = listen;
    net.Server.prototype.close = close;
    for (const server of servers) {
      server.closeAllConnections?.();
      if (server.listening) await new Promise((resolve) => close.call(server, resolve));
    }
  });
}

// A stand-in for the `t` withPi registers its cleanup on, so a cleanup that fails can be asserted instead of failing the test.
const fakeTest = () => { const hooks = []; return { after: (fn) => hooks.push(fn), cleanup: async () => { for (const hook of hooks) await hook(); } }; };

test("a setup that throws after the provider started leaves no provider and no directory behind", { timeout: 30000 }, async (t) => {
  ownServers(t);
  let port, dir;
  // The directory assertion needs the removal to run, so PI_TEST_KEEP_FIXTURES is unset for the harness call only.
  const keep = process.env.PI_TEST_KEEP_FIXTURES;
  delete process.env.PI_TEST_KEEP_FIXTURES;
  try {
    await t.test("the failing setup", async (inner) => {
      await assert.rejects(withPi(inner, { files: (d) => {
        dir = d;
        port = Number(new URL(JSON.parse(fs.readFileSync(path.join(d, "home/models.json"), "utf8")).providers.fixture.baseUrl).port);
        assert.equal(port > 0, true);
        throw Error("setup failed");
      } }, async () => assert.fail("body must not run")), /setup failed/);
    });
  } finally {
    if (keep === undefined) delete process.env.PI_TEST_KEEP_FIXTURES; else process.env.PI_TEST_KEEP_FIXTURES = keep;
  }
  assert.equal(await portOpen(port), false, "the fake provider is still listening");
  assert.equal(fs.existsSync(dir), false, "the fixture directory was not removed");
});

test("a fake provider whose server never closes fails teardown by name within the deadline and the directory is still removed", { timeout: 30000 }, async (t) => {
  ownServers(t, { hangClose: true });
  const harness = fakeTest();
  const keep = process.env.PI_TEST_KEEP_FIXTURES;
  delete process.env.PI_TEST_KEEP_FIXTURES;
  t.after(() => { if (keep !== undefined) process.env.PI_TEST_KEEP_FIXTURES = keep; });
  let dir, child;
  t.after(() => child?.kill("SIGKILL")); // pi is stopped by the cleanup under test; this is only for when that regresses
  await withPi(harness, {}, async (pi) => { dir = pi.dir; child = pi.child; await pi.request({ type: "get_state" }); });
  const started = Date.now();
  await assert.rejects(harness.cleanup(), /stopping the fake provider: .*did not close within 5000 ms/);
  assert.ok(Date.now() - started < 15000, "teardown was not bounded");
  assert.equal(fs.existsSync(dir), false, "the fixture directory was not removed");
});

test("a pi that ignores SIGTERM is sent SIGTERM first and killed after the deadline instead of hanging teardown", { timeout: 30000 }, async (t) => {
  const bin = fs.mkdtempSync(path.join(os.tmpdir(), "pi-stubborn-"));
  const ready = path.join(bin, "ready"), sigterm = path.join(bin, "sigterm");
  let child;
  ownServers(t); // withPi starts a provider even with a custom launcher
  // The test owns the stub: it is killed here whatever the harness did, so a regression cannot leave it running.
  t.after(() => { child?.kill("SIGKILL"); fs.rmSync(bin, { recursive: true, force: true }); });
  fs.writeFileSync(path.join(bin, "stub.js"), `const fs = require("fs");
process.on("SIGTERM", () => fs.writeFileSync(${JSON.stringify(sigterm)}, ""));
fs.writeFileSync(${JSON.stringify(ready)}, "");
setInterval(() => {}, 1000);
`);
  const launcher = path.join(bin, "stubborn");
  // A shell shebang, because process.execPath may contain spaces; exec makes the node process the one spawned.
  fs.writeFileSync(launcher, `#!/bin/sh\nexec "${process.execPath}" "${path.join(bin, "stub.js")}"\n`, { mode: 0o755 });
  await t.test("the stubborn pi", async (inner) => {
    await withPi(inner, { launcher }, async (pi) => { child = pi.child; await until("the stub to be ready", () => fs.existsSync(ready), 10000); });
  });
  assert.ok(fs.existsSync(sigterm), "the stub never received SIGTERM");
  await until("the stub to exit", () => child.exitCode !== null || child.signalCode !== null, 5000);
  assert.equal(child.signalCode, "SIGKILL");
});
