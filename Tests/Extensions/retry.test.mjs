// The retired extension command must refuse visibly. Recovery lives in the guarded engine API,
// not in a command that rewinds or manufactures a user message.
import test from "node:test";
import assert from "node:assert/strict";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { withPi, until } from "./fixtures/pi-rpc-harness.mjs";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

test("legacy /shepherd-retry never rewinds, resends or adds user input", { timeout: 60000 }, async t => {
  await withPi(t, {
    args: ["-ne", "-ns", "-np", "-nc", "--no-themes", "-e", path.join(root, "Extensions/shepherd-status.ts")],
    settings: { retry: { enabled: false }, compaction: { enabled: false } },
    env: dir => ({ SHEPHERD_AGENT_ID: "fixture-ordinary-thread", SHEPHERD_SOCKET: path.join(dir, "unused.sock") }),
    onRequest: () => ({ status: 400, text: "fixture provider failure" }),
  }, async pi => {
    await pi.prompt("original request");
    const before = (await pi.request({ type: "get_entries" })).data.entries;
    const original = before.find(e => e.message?.role === "user");
    const mark = pi.events.length;
    const response = await pi.request({ type: "prompt", message: `/shepherd-retry ${original.message.timestamp}` });
    assert.equal(response.success, true);
    await until("legacy capability refusal", () => pi.events.slice(mark).some(e => e.type === "extension_ui_request" && /message-free checkpoint recovery/.test(e.message ?? "")));
    assert.deepEqual((await pi.request({ type: "get_entries" })).data.entries, before);
    assert.equal(pi.provider.requests.length, 1);
  });
});
