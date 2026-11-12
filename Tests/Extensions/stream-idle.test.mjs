// A model request that stops producing content ends the turn with pi's ordinary "timed out" error (and its
// automatic retry) instead of leaving the thread working. The fake provider keeps the response open with Anthropic
// `ping` events, which an HTTP idle timeout does not see because it counts bytes.
// PI_PACKAGE_DIR=<patched pinned package> node --test Tests/Extensions/stream-idle.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { withPi, until } from "./fixtures/pi-rpc-harness.mjs";

const model = { id: "claude-opus-5-5", name: "fixture", api: "anthropic-messages", provider: "anthropic",
  reasoning: true, input: ["text"], contextWindow: 1000000, maxTokens: 64000, cost: { input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25 } };
const idle = 1500;

// `oauth` signs the fixture in the way a Claude subscription does, which takes Shepherd's own Anthropic stream.
const piOptions = (entrypoint, oauth, settings) => ({
  entrypoint, api: "anthropic-messages", settings: { httpIdleTimeoutMs: idle, retry: { enabled: false }, ...settings },
  args: ["-ne", "-ns", "-np", "--model", oauth ? `anthropic/${model.id}` : "fixture/fixture"],
  project(dir) {
    if (!oauth) return;
    const file = path.join(dir, "home/models.json");
    const models = JSON.parse(fs.readFileSync(file));
    models.providers.anthropic = { baseUrl: models.providers.fixture.baseUrl, models: [{ ...model, baseUrl: models.providers.fixture.baseUrl }] };
    fs.writeFileSync(file, JSON.stringify(models));
    fs.writeFileSync(path.join(dir, "home/auth.json"), JSON.stringify({ anthropic: { type: "oauth", access: "sk-ant-oat-offline-fixture", refresh: "offline-refresh-fixture", expires: Date.now() + 3600000 } }));
  },
});

for (const entrypoint of ["dist/cli.js", "dist/bundle/cli.js"]) {
  for (const oauth of [false, true]) {
    const name = `${entrypoint}, ${oauth ? "subscription" : "API key"}`;

    test(`${name}: a stream that only pings fails the turn with a timeout`, { timeout: 60000 }, async t => {
      await withPi(t, { ...piOptions(entrypoint, oauth), onRequest: () => ({ stall: true }) }, async pi => {
        const turn = await pi.prompt("hello", 20000);
        const error = turn.events.findLast(e => e.type === "message_end" && e.message.role === "assistant");
        assert.equal(error.message.stopReason, "error");
        assert.match(error.message.errorMessage, /timed out/);
        assert.equal(pi.provider.requests.length, 1);
        assert.equal((await pi.request({ type: "get_state" })).data.isStreaming, false);
      });
    });

    test(`${name}: pi's automatic retry asks again after the timeout`, { timeout: 60000 }, async t => {
      await withPi(t, { ...piOptions(entrypoint, oauth, { retry: { enabled: true, maxRetries: 1, baseDelayMs: 1 } }),
        onRequest: ({ index }) => (index === 0 ? { stall: true } : {}) }, async pi => {
        const turn = await pi.prompt("hello", 20000);
        assert.equal(turn.events.filter(e => e.type === "auto_retry_start").length, 1);
        assert.equal(turn.events.findLast(e => e.type === "auto_retry_end").success, true);
        assert.equal(pi.provider.requests.length, 2);
        const answer = turn.events.findLast(e => e.type === "message_end" && e.message.role === "assistant");
        assert.equal(answer.message.stopReason, "stop");
      });
    });
  }
}

test("a stream that keeps producing content is never timed out", { timeout: 60000 }, async t => {
  await withPi(t, { ...piOptions("dist/cli.js", false, { httpIdleTimeoutMs: 500 }), onRequest: () => ({}) }, async pi => {
    const turn = await pi.prompt("hello", 20000);
    assert.equal(turn.events.findLast(e => e.type === "message_end" && e.message.role === "assistant").message.stopReason, "stop");
  });
});

test("Stop still ends a stalled request as aborted, not as a timeout", { timeout: 60000 }, async t => {
  await withPi(t, { ...piOptions("dist/cli.js", false, { httpIdleTimeoutMs: 30000 }), onRequest: () => ({ stall: true }) }, async pi => {
    const mark = pi.events.length;
    await pi.request({ type: "prompt", message: "hello" });
    await until("the request", () => pi.provider.requests.length === 1);
    await pi.request({ type: "abort" });
    await until("the turn to settle", () => pi.events.slice(mark).some(e => e.type === "agent_settled"), 20000);
    const last = pi.events.slice(mark).findLast(e => e.type === "message_end" && e.message.role === "assistant");
    assert.equal(last.message.stopReason, "aborted");
  });
});
