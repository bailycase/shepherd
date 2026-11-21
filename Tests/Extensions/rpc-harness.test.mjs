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

test("a setup that throws after the provider started leaves no provider and no directory behind", { timeout: 30000 }, async (t) => {
  let port, dir;
  await t.test("the failing setup", async (inner) => {
    await assert.rejects(withPi(inner, { files: (d) => {
      dir = d;
      port = Number(new URL(JSON.parse(fs.readFileSync(path.join(d, "home/models.json"), "utf8")).providers.fixture.baseUrl).port);
      assert.equal(port > 0, true);
      throw Error("setup failed");
    } }, async () => assert.fail("body must not run")), /setup failed/);
  });
  assert.equal(await portOpen(port), false, "the fake provider is still listening");
  assert.equal(fs.existsSync(dir), false, "the fixture directory was not removed");
});

test("a pi that ignores SIGTERM is killed at teardown instead of hanging it", { timeout: 30000 }, async (t) => {
  const bin = fs.mkdtempSync(path.join(os.tmpdir(), "pi-stubborn-"));
  t.after(() => fs.rmSync(bin, { recursive: true, force: true }));
  const launcher = path.join(bin, "stubborn");
  // A shell shebang, because process.execPath may contain spaces; exec makes the node process the one spawned.
  fs.writeFileSync(launcher, `#!/bin/sh\nexec "${process.execPath}" -e 'process.on("SIGTERM", () => {}); require("fs").writeFileSync("ready", ""); setInterval(() => {}, 1000)'\n`, { mode: 0o755 });
  let pid;
  await t.test("the stubborn pi", async (inner) => {
    await withPi(inner, { launcher }, async (pi) => { pid = pi.child.pid; await until("the stub to ignore SIGTERM", () => fs.existsSync(path.join(pi.work, "ready"))); });
  });
  assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
});
