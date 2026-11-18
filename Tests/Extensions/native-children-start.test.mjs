// A subagent starts on the first try: a label is not a profile, a near miss of a profile is refused, and every other
// refusal names the field to change.
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { projectConfigHost } from "./fixtures/project-config-host.mjs";
import { childrenSource, harness, providerServer, scratchHome, tempDir, withEnv } from "./fixtures/children-harness.mjs";

const PARENT = (dir, home) => ({
  HOME: dir, PI_CODING_AGENT_DIR: home, PI_OFFLINE: "1", SHEPHERD_CLIPROXYAPI_CONFIG: undefined,
  SHEPHERD_NATIVE_CHILDREN: "1", SHEPHERD_AGENT_ID: "fixture", SHEPHERD_SOCKET: path.join(dir, "shepherd.sock"), SHEPHERD_EXT_CHILDREN: childrenSource,
});
// A parent whose helpers can really start, against a local provider that answers "done".
async function withParent(label, fn, { models } = {}) {
  const dir = tempDir(label), fixture = providerServer(() => ({ text: "done" }));
  const port = await fixture.listen();
  const host = await projectConfigHost(path.join(dir, "shepherd.sock"));
  try {
    const home = scratchHome(dir, { port });
    return await withEnv(PARENT(dir, home), async () => {
      const h = await harness(dir, models ? { models } : {});
      try { return await fn(h, { dir, home }); } finally { await h.shutdown(); }
    });
  } finally { await host.close(); await fixture.close(); fs.rmSync(dir, { recursive: true, force: true }); }
}
const put = (file, text) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); };
const finished = (h, id) => h.tools.get("shepherd_child_result").execute("c", { id }, undefined, undefined, h.ctx).then(async (r) => r.details);
const settle = async (h, id) => { for (let i = 0; i < 400; i++) { const r = await finished(h, id); if (["complete", "failed", "stopped"].includes(r.state)) return r; await new Promise((x) => setTimeout(x, 25)); } throw Error("never settled"); };

test("a label is shown, persisted with the run and restored, and a run without one still decodes", { timeout: 120000 }, async () => {
  await withParent("label", async (h, { dir }) => {
    const receipt = await h.call("start", { task: "Check card network rules", agent: "scout", name: "card-network-rules" });
    assert.equal(receipt.name, "card-network-rules");
    assert.equal(receipt.role, "scout");
    assert.equal(receipt.note, undefined);
    const card = h.projections.at(-1).children.find((c) => c.runID === receipt.id);
    assert.equal(card.name, "card-network-rules");
    assert.equal(card.role, "scout");
    assert.match(card.label, /^card-network-rules: Check card network rules/);
    const done = await settle(h, receipt.id);
    assert.equal(done.state, "complete");
    assert.equal(done.name, "card-network-rules");
    assert.deepEqual((await h.call("result", {})).map((r) => [r.name, r.role]), [["card-network-rules", "scout"]]);
    // What a parent session persists is what restores it; an older descriptor has no name.
    const descriptor = h.entries.find((e) => e.customType === "shepherd-child").data;
    assert.equal(descriptor.name, "card-network-rules");
    const { name: _, ...older } = descriptor;
    for (const [entry, name] of [[descriptor, "card-network-rules"], [older, undefined]]) {
      const again = await harness(dir, { entries: [{ type: "custom", customType: "shepherd-child", data: entry }] });
      try {
        const [restored] = await again.call("result", {});
        assert.equal(restored.name, name);
        assert.equal(restored.role, "scout");
        assert.equal(again.projections.at(-1).children[0].name, name);
        assert.match(again.projections.at(-1).children[0].label, name ? /^card-network-rules: / : /^scout: /);
      } finally { await again.shutdown(); }
    }
  });
});

test("a role or agent that is no profile and no near miss starts a worker under that name, and says so", { timeout: 120000 }, async () => {
  await withParent("fallback", async (h) => {
    for (const field of ["role", "agent"]) {
      const receipt = await h.call("start", { task: `via ${field}`, [field]: "card-network-rules" });
      assert.equal(receipt.role, "worker");
      assert.equal(receipt.name, "card-network-rules");
      assert.equal(receipt.note, 'No agent profile "card-network-rules"; started a worker named card-network-rules. agent picks a profile (shepherd_child_agents lists them); name is the label.');
      assert.equal((await settle(h, receipt.id)).state, "complete");
    }
    // A label beside the profile it belongs to, whichever field each went in.
    const both = await h.call("start", { task: "both", agent: "scout", role: "provider-requirements" });
    assert.deepEqual([both.role, both.name, both.note], ["scout", "provider-requirements", undefined]);
    const swapped = await h.call("start", { task: "both", agent: "industry-practice", role: "reviewer" });
    assert.deepEqual([swapped.role, swapped.name], ["reviewer", "industry-practice"]);
    const same = await h.call("start", { task: "same", agent: "scout", role: "scout" });
    assert.deepEqual([same.role, same.name], ["scout", undefined]);
    const plain = await h.call("start", { task: "plain" });
    assert.deepEqual([plain.role, plain.name], ["worker", undefined]);
    for (const r of [both, swapped, same, plain]) await settle(h, r.id);
  });
});

test("a workflow lane takes a name, and a role that is no profile starts a worker with the note", { timeout: 120000 }, async () => {
  await withParent("lanes", async (h) => {
    const flow = (script) => h.tools.get("shepherd_workflow").execute("c", { workflowScript: script, async: false }, undefined, undefined, h.ctx).then((r) => r.details);
    const out = await flow(`const [a, b] = await runs.all([{ key: "a", task: "one", agent: "scout", name: "provider-requirements" }, { key: "b", task: "two", role: "industry-practice" }]); return { a, b };`);
    assert.equal(out.state, "complete", JSON.stringify(out));
    const { a, b } = JSON.parse(typeof out.output === "string" ? out.output : JSON.stringify(out.output));
    assert.deepEqual([a.agent, a.name, a.note], ["scout", "provider-requirements", undefined]);
    assert.deepEqual([b.agent, b.name], ["worker", "industry-practice"]);
    assert.match(b.note, /^No agent profile "industry-practice"; started a worker/);
    const cards = h.projections.at(-1).children;
    assert.deepEqual(cards.map((c) => c.name).sort(), ["industry-practice", "provider-requirements"]);
  });
});

test("a profile that might be a typo is refused, never run as a worker", { timeout: 120000 }, async () => {
  await withParent("typo", async (h) => {
    for (const [field, name, near] of [["role", "reviewr", "reviewer"], ["agent", "trust-scout", "scout"], ["role", "planer", "planner"], ["agent", "wroker", "worker"]]) {
      await assert.rejects(h.call("start", { task: "x", [field]: name }), (error) => {
        assert(error.message.includes(`Unknown agent "${name}". Did you mean ${near}`), error.message);
        assert(error.message.includes(`name: "${name}" if it is only a label`));
        return true;
      });
    }
    // A label beside a bad agent is refused too: the agent field is the mistake.
    await assert.rejects(h.call("start", { task: "x", agent: "card-network-rules", name: "lane" }), /Unknown agent "card-network-rules"\. agent picks a profile; a label goes in name\./);
    assert.deepEqual(await h.call("result", {}), [], "nothing started");
  });
});

test("every other refusal names the field and the fix", async () => {
  await withParent("refusals", async (h, { dir, home }) => {
    put(path.join(home, "agents", "broken.md"), "---\nname: broken\ndescription: d\nacceptanceRole: x\n---\nBody.\n");
    put(path.join(home, "agents", "off.md"), "---\nname: off\ndescription: d\ndisabled: true\ntools: [read]\n---\nBody.\n");
    put(path.join(home, "agents", "exotic.md"), "---\nname: exotic\ndescription: d\ntools: [read, contact_supervisor]\n---\nBody.\n");
    put(path.join(home, "agents", "nested.md"), "---\nname: nested\ndescription: d\ntools: [read, shepherd_child_start]\n---\nBody.\n");
    fs.writeFileSync(path.join(dir, "file.txt"), "x");
    const refused = async (params, ...expected) => assert.rejects(h.call("start", { task: "x", ...params }), (error) => {
      for (const text of expected) assert(text instanceof RegExp ? text.test(error.message) : error.message.includes(text), `${text} in: ${error.message}`);
      return true;
    });
    await refused({ cwd: "nowhere" }, `cwd ${path.join(dir, "nowhere")} doesn't exist. Pass cwd as an existing directory, or omit it`);
    await refused({ cwd: "file.txt" }, "is a file, not a directory. Pass its folder as cwd, or omit cwd.");
    await refused({ prompt: "x", label: "y" }, 'Unknown parameters "prompt", "label" for shepherd_child_start.', "name labels the helper and agent picks its profile");
    await refused({ agent: "broken" }, "Agent profile broken can't run. Its file is invalid: Unsupported agent fields: acceptanceRole.", "broken.md, or pass another agent.");
    await refused({ agent: "off" }, "Agent profile off is disabled. Remove disabled: true from", "off.md, or pass another agent.");
    await refused({ agent: "exotic" }, "Agent profile exotic lists tools no helper can load: contact_supervisor. Remove them from tools: in", "exotic.md");
    await refused({ agent: "nested" }, "Agent profile nested lists delegation tools, and helpers can't delegate. Remove", "from tools: in");
    await refused({ role: "scout", model: "nonsense" }, "Model nonsense isn't loaded.", "Pass model as one of those, or omit model to use the thread's.");
    await refused({ thinking: "max-ish" }, /thinking/);
    assert.deepEqual(await h.call("result", {}), [], "none of them started anything");
  });
});

test("a thread with no model selected says to pass model", async () => {
  await withParent("nomodel", async (h) => {
    await assert.rejects(h.call("start", { task: "x" }), /No model is selected in this thread.*Pass model as provider\/id, or select a model in the thread first\./);
  }, { models: [] });
});
