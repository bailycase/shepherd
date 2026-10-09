import assert from "node:assert/strict";
import { test } from "node:test";
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
