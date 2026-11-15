// A thread never runs out of room for helpers: at the retention limit the oldest finished helper that the parent
// has taken is dropped from the list (and from what restores), and only a thread whose helpers are all live refuses.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { projectConfigHost } from "./fixtures/project-config-host.mjs";
import { childrenSource, harness, providerServer, scratchHome, tempDir, until, withEnv } from "./fixtures/children-harness.mjs";

const OWNER = "parent-fixture";
const PARENT = (dir, home) => ({
  HOME: dir, PI_CODING_AGENT_DIR: home, PI_OFFLINE: "1", SHEPHERD_CLIPROXYAPI_CONFIG: undefined,
  SHEPHERD_NATIVE_CHILDREN: "1", SHEPHERD_AGENT_ID: "fixture", SHEPHERD_SOCKET: path.join(dir, "shepherd.sock"), SHEPHERD_EXT_CHILDREN: childrenSource,
});
// `respond` answers the helpers' model calls; a promise that never settles keeps a helper running.
async function withParent(label, respond, fn) {
  const dir = tempDir(label), fixture = providerServer(respond);
  const port = await fixture.listen();
  const host = await projectConfigHost(path.join(dir, "shepherd.sock"));
  try {
    const home = scratchHome(dir, { port });
    return await withEnv(PARENT(dir, home), async () => {
      return await fn(dir, []);
    });
  } finally { await host.close(); await fixture.close(); fs.rmSync(dir, { recursive: true, force: true }); }
}
// A helper a previous parent session left behind: its persisted descriptor and its status.json.
function seed(dir, entries, index, status) {
  const id = `native-seed-${String(index).padStart(3, "0")}`, childDir = path.join(dir, "children", id);
  fs.mkdirSync(childDir, { recursive: true });
  fs.writeFileSync(path.join(childDir, "session.jsonl"), "{}\n");
  fs.writeFileSync(path.join(childDir, "status.json"), JSON.stringify({ state: "complete", startedAt: 1000 + index, endedAt: 2000 + index, output: `result ${index}`, ...status }));
  entries.push({ type: "custom", customType: "shepherd-child", data: { owner: OWNER, id, role: "worker", name: `acme-web-${index}`, model: "fixture/fixture", cwd: dir,
    task: `task ${index}`, tools: ["read"], startedAt: 1000 + index, delivery: "continue" } });
  return id;
}
const list = (h) => h.call("result", {});
const ids = async (h) => (await list(h)).map((r) => r.id);
const settled = (h, id) => until(async () => ["complete", "failed", "stopped"].includes((await h.call("result", { id })).state));
const asking = { needsReply: true, questionID: "q/1", questionText: "Which database?" };

test("at 64 finished helpers a new one starts and the oldest finished one is dropped", { timeout: 120000 }, async () => {
  await withParent("room", () => ({ text: "done" }), async (dir, entries) => {
    const seededIds = Array.from({ length: 64 }, (_, i) => seed(dir, entries, i, {}));
    const h = await harness(dir, { entries });
    try {
      assert.equal((await list(h)).length, 64);
      const receipt = await h.call("start", { task: "one more", name: "acme-web-new" });
      const after = await ids(h);
      assert.equal(after.length, 64);
      assert.ok(after.includes(receipt.id));
      assert.ok(!after.includes(seededIds[0]), "the oldest finished helper is gone from the list");
      assert.ok(after.includes(seededIds[1]));
      // The tray's list loses it too, and its session file stays on disk.
      assert.ok(!h.projections.at(-1).children.some((c) => c.runID === seededIds[0]));
      assert.ok(fs.existsSync(path.join(dir, "children", seededIds[0], "session.jsonl")));
      // The id still answers, with where the conversation is; other calls on it say the same.
      const note = await h.call("result", { id: seededIds[0] });
      assert.equal(note.dropped, true);
      assert.equal(note.sessionFile, path.join(dir, "children", seededIds[0], "session.jsonl"));
      assert.match(note.note, /dropped from this thread to make room.*session\.jsonl/);
      await assert.rejects(h.call("message", { id: seededIds[0], message: "hi" }), /dropped from this thread to make room/);
      await settled(h, receipt.id);
      // A relaunch restores the 64 that were kept, never the dropped one, and still has room.
      await h.shutdown();
      const again = await harness(dir, { entries });
      try {
        const restored = await ids(again);
        assert.equal(restored.length, 64);
        assert.ok(!restored.includes(seededIds[0]));
        assert.ok(restored.includes(receipt.id));
        assert.equal((await again.call("result", { id: seededIds[0] })).dropped, true);
        const second = await again.call("start", { task: "and another" });
        assert.ok(!(await ids(again)).includes(seededIds[1]));
        assert.ok((await ids(again)).includes(second.id));
        await settled(again, second.id);
      } finally { await again.shutdown(); }
    } finally { await h.shutdown(); }
  });
});

test("a thread whose helpers are all live or waiting refuses, and names the fix", { timeout: 120000 }, async () => {
  await withParent("full", () => new Promise(() => {}), async (dir, entries) => {
    for (let i = 0; i < 63; i++) seed(dir, entries, i, asking);
    const h = await harness(dir, { entries });
    try {
      const running = await h.call("start", { task: "long job" });
      assert.equal((await list(h)).length, 64);
      await assert.rejects(h.call("start", { task: "no room" }), /Cancel a running helper \(shepherd_child_cancel\) or wait for one to finish/);
      assert.equal((await list(h)).length, 64);
      assert.equal((await h.call("result", { id: running.id })).state, "running");
      // Cancelling frees a slot: the cancelled helper is the only finished one.
      await h.call("cancel", { id: running.id });
      const next = await h.call("start", { task: "now there is room" });
      const after = await ids(h);
      assert.ok(!after.includes(running.id) && after.includes(next.id));
      assert.equal(after.length, 64);
    } finally { await h.shutdown(); }
  });
});

test("a finished helper whose result the parent has not read is never dropped", { timeout: 120000 }, async () => {
  await withParent("unread", () => ({ text: "done" }), async (dir, entries) => {
    for (let i = 0; i < 63; i++) seed(dir, entries, i, asking);
    const h = await harness(dir, { entries });
    try {
      h.events.get("agent_start")(); // the parent is mid-turn, so the finished helper's notice stays pending
      const quick = await h.call("start", { task: "quick job" });
      // The list shows states without reading any result.
      await until(async () => (await list(h)).find((r) => r.id === quick.id)?.state === "complete");
      await assert.rejects(h.call("start", { task: "no room" }), /Cancel a running helper \(shepherd_child_cancel\) or wait for one to finish/);
      assert.ok((await ids(h)).includes(quick.id));
      // Reading it makes it droppable.
      assert.equal((await h.call("result", { id: quick.id })).state, "complete");
      const next = await h.call("start", { task: "now there is room" });
      const after = await ids(h);
      assert.ok(!after.includes(quick.id) && after.includes(next.id));
      assert.equal(after.length, 64);
    } finally { await h.shutdown(); }
  });
});

test("a workflow past 32 retained drops the oldest finished one, never an unread or running one", { timeout: 120000 }, async () => {
  await withParent("workflows", () => ({ text: "done" }), async (dir) => {
    const h = await harness(dir);
    try {
      const flow = (params) => h.tools.get("shepherd_workflow").execute("call", { workflowScript: "return 1", ...params }, undefined, undefined, h.ctx).then((r) => r.details);
      // /workflows lists the retained workflows without reading any of them.
      const retained = async () => {
        h.messages.length = 0;
        await h.commands.get("workflows").handler("", h.ctx);
        return h.messages.at(-1).message.content.split("\n").filter((line) => line.startsWith("workflow-")).map((line) => line.split(" · "));
      };
      h.events.get("agent_start")(); // mid-turn: an async workflow's result notice stays pending until read
      const started = [];
      for (let i = 0; i < 32; i++) {
        started.push((await flow({ async: true })).id); // four may run at once
        await until(async () => (await retained()).every(([, state]) => state !== "running"));
      }
      assert.equal((await retained()).length, 32);
      // Every one is finished and unread: nothing may be dropped.
      await assert.rejects(flow({ async: false }), /32 retained per parent and every one is still running or unread/);
      assert.equal((await retained()).length, 32);
      // Reading the oldest makes it the one that gives way.
      assert.equal((await flow({ action: "status", id: started[0] })).state, "complete");
      const next = await flow({ async: false });
      assert.equal(next.state, "complete");
      const after = (await retained()).map(([id]) => id);
      assert.equal(after.length, 32);
      assert.ok(!after.includes(started[0]) && after.includes(next.id) && after.includes(started[1]));
      await assert.rejects(flow({ action: "status", id: started[0] }), /Unknown workflow/);
    } finally { await h.shutdown(); }
  });
});
