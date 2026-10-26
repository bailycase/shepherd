// Real modular and bundled RPC CLIs; private HOME, loopback provider, no credentials.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { withPi, until } from "./fixtures/pi-rpc-harness.mjs";

for (const entrypoint of ["dist/cli.js", "dist/bundle/cli.js"]) for (const extensions of [false, true]) {
  const options = { entrypoint, args: ["-ne", "-ns", "-np", "-nc", "--no-themes", ...(extensions ? ["-e", "./guideline.ts"] : [])],
    settings: { retry: { enabled: true, baseDelayMs: 1 }, compaction: { enabled: false } },
    project: (_dir, work) => {
      if (extensions) fs.writeFileSync(path.join(work, "guideline.ts"), `export default pi => {
        pi.on("before_agent_start", event => { event.systemPromptOptions.promptGuidelines.push("FAKE unchanged CLI guideline"); });
        pi.on("message_end", ({message}) => {
          if (message.role === "assistant" && ["stop", "length"].includes(message.stopReason) && !message.content.some(p => p.type === "text" ? p.text.trim() : p.type !== "thinking"))
            return {message: {...message, stopReason: "error", errorMessage: "The provider returned no answer or tool call. Retry to continue the interrupted turn."}};
        });
      };`);
    } };
  const name = `${entrypoint}, extensions=${extensions}`;
  test(`${name}: empty then success uses one existing retry and one user entry`, { timeout: 60000 }, async t => {
    await withPi(t, { ...options, onRequest: ({ index }) => index === 0 ? { outputText: "" } : {} }, async pi => {
      const turn = await pi.prompt("original request");
      assert.equal(turn.requests.length, 2);
      assert.equal(turn.events.filter(e => e.type === "auto_retry_start").length, 1);
      assert(turn.events.some(e => e.type === "agent_end" && e.willRetry));
      assert.equal(turn.events.findLast(e => e.type === "auto_retry_end").success, true);
      const entries = (await pi.request({ type: "get_entries" })).data.entries;
      assert.equal(entries.filter(e => e.message?.role === "user").length, 1);
      assert.equal(entries.filter(e => e.message?.stopReason === "error").length, 1);
      if (extensions) assert(turn.requests.every(r => r.system.includes("FAKE unchanged CLI guideline")));
    });
  });
  test(`${name}: permanent empty stops at default three retries`, { timeout: 60000 }, async t => {
    await withPi(t, { ...options, onRequest: () => ({ outputText: "" }) }, async pi => {
      const turn = await pi.prompt("original request");
      assert.equal(turn.requests.length, 4);
      assert.deepEqual(turn.events.filter(e => e.type === "auto_retry_start").map(e => e.attempt), [1, 2, 3]);
      assert.equal(turn.events.findLast(e => e.type === "auto_retry_end").success, false);
      assert((await pi.request({ type: "get_state" })).data.checkpointRecovery.checkpoint);
    });
  });
  test(`${name}: Stop during backoff cancels continuation`, { timeout: 60000 }, async t => {
    await withPi(t, { ...options, settings: { ...options.settings, retry: { enabled: true, baseDelayMs: 60000 } }, onRequest: () => ({ outputText: "" }) }, async pi => {
      const run = pi.prompt("original request");
      await until("retry backoff", () => pi.events.some(e => e.type === "auto_retry_start"));
      assert.equal((await pi.request({ type: "abort" })).success, true);
      await run;
      assert.equal(pi.provider.requests.length, 1);
      assert.equal(pi.events.findLast(e => e.type === "auto_retry_end").success, false);
    });
  });
  for (const [status, text] of [[401, "authentication failed"], [403, "insufficient_quota"]]) test(`${name}: ${status} ${text} stays terminal`, { timeout: 60000 }, async t => {
    await withPi(t, { ...options, onRequest: () => ({ status, text }) }, async pi => {
      await pi.prompt("original request");
      assert.equal(pi.provider.requests.length, 1);
      assert.equal(pi.events.filter(e => e.type === "auto_retry_start").length, 0);
    });
  });
  test(`${name}: completed tool is not redelivered after empty completion`, { timeout: 60000 }, async t => {
    await withPi(t, { ...options, onRequest: ({ index }) => index === 0 ? { tool: { name: "write", arguments: { path: "completed.txt", content: "done" } } }
      : index === 1 ? { outputText: "" } : {} }, async pi => {
      await pi.prompt("original request");
      assert.equal(pi.provider.requests.length, 3);
      assert.equal(pi.events.filter(e => e.type === "tool_execution_start").length, 1);
      assert.equal(fs.readFileSync(path.join(pi.work, "completed.txt"), "utf8"), "done");
      assert(JSON.stringify(pi.provider.requests[2].body).includes("completed.txt"));
      const entries = (await pi.request({ type: "get_entries" })).data.entries;
      assert.equal(entries.filter(e => e.message?.role === "user").length, 1);
    });
  });
}
