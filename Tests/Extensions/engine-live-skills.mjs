// Invoked by EngineSmokeTests against Shepherd's patched, staged engine (not stock npm pi).
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { withPi, until } from "./fixtures/pi-rpc-harness.mjs";

const skill = (name, description = name, extra = "") => `---\nname: ${name}\ndescription: ${description}\n${extra}---\n${description}\n`;
const write = (file, text) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); };
const OFF = ["-builtin:mcp", "-builtin:codemode", "-builtin:tool-search"];
const probe = `export default function(pi) {
  let starts = 0;
  pi.on("session_start", () => { starts++; });
  pi.registerCommand("inspect-skills", { handler: async (_, ctx) => {
    ctx.ui.notify(JSON.stringify({ starts, prompt: ctx.getSystemPrompt() }), "info");
  }});
  pi.registerCommand("hold", { handler: async (_, ctx) => {
    ctx.ui.notify("holding", "info");
    await new Promise(resolve => { pi.events.on("release", resolve); });
  }});
  pi.registerCommand("release", { handler: async () => { pi.events.emit("release"); }});
}`;
async function inspect(pi) {
  const mark = pi.events.length;
  assert.equal((await pi.request({ type: "prompt", message: "/inspect-skills" })).success, true);
  return JSON.parse(pi.events.slice(mark).find(e => e.method === "notify").message);
}
async function refresh(pi) {
  const result = await pi.request({ type: "refresh_skills" });
  assert.equal(result.success, true, JSON.stringify(result));
  return result.data.changed;
}

test("refresh reparses global, trusted project and linked skills without replacing extensions or history", { timeout: 30000 }, async t => {
  await withPi(t, {
    settings: { extensions: OFF },
    files: (dir, work) => ({ "extensions/probe.ts": probe, "trust.json": { [work]: true },
      "settings.json": { extensions: OFF, skills: [`!${dir}/.agents/skills/**`] } }),
  }, async pi => {
    await inspect(pi);
    const history = await pi.request({ type: "get_messages" });
    const initial = await inspect(pi);
    assert.equal(initial.starts, 1);
    write(path.join(pi.home, "skills/global/SKILL.md"), skill("global", "Global metadata"));
    write(path.join(pi.work, ".pi/skills/project/SKILL.md"), skill("project", "Project metadata"));
    write(path.join(pi.work, ".agents/skills/agents/SKILL.md"), skill("agents"));
    write(path.join(pi.dir, ".agents/skills/excluded/SKILL.md"), skill("excluded"));
    write(path.join(pi.dir, "linked/SKILL.md"), skill("linked"));
    fs.symlinkSync(path.join(pi.dir, "linked"), path.join(pi.home, "skills/link"));
    assert.equal(await refresh(pi), true);
    let names = (await pi.commands()).map(c => c.name);
    for (const name of ["global", "project", "agents", "linked"]) assert.ok(names.includes(`skill:${name}`), name);
    assert.ok(!names.includes("skill:excluded"));
    let current = await inspect(pi);
    assert.equal(current.starts, 1);
    assert.match(current.prompt, /Global metadata/);
    assert.match(current.prompt, /Project metadata/);
    assert.equal(await refresh(pi), false);
    write(path.join(pi.home, "skills/global/SKILL.md"), skill("global", "Manual only", "disable-model-invocation: true\n"));
    write(path.join(pi.work, ".pi/skills/project/SKILL.md"), skill("renamed", "Changed metadata"));
    fs.unlinkSync(path.join(pi.dir, "linked/SKILL.md"));
    assert.equal(await refresh(pi), true);
    current = await inspect(pi);
    assert.equal(current.starts, 1);
    assert.ok(!current.prompt.includes("Global metadata") && !current.prompt.includes("Manual only"));
    assert.match(current.prompt, /Changed metadata/);
    names = (await pi.commands()).map(c => c.name);
    assert.ok(names.includes("skill:global") && names.includes("skill:renamed"));
    assert.ok(!names.includes("skill:project") && !names.includes("skill:linked"));
    assert.deepEqual((await pi.request({ type: "get_messages" })).data, history.data);
  });
});

test("refresh preserves untrusted-project and no-skills exclusions", { timeout: 30000 }, async t => {
  for (const args of [[], ["--no-skills"]]) {
    await withPi(t, { settings: { extensions: OFF }, args: ["--no-approve", ...args] }, async pi => {
      await pi.commands();
      write(path.join(pi.home, "skills/global/SKILL.md"), skill("global"));
      write(path.join(pi.work, ".pi/skills/untrusted/SKILL.md"), skill("untrusted"));
      write(path.join(pi.work, ".agents/skills/untrusted-agent/SKILL.md"), skill("untrusted-agent"));
      await refresh(pi);
      const names = (await pi.commands()).map(c => c.name);
      assert.equal(names.includes("skill:global"), args.length === 0);
      assert.ok(!names.includes("skill:untrusted") && !names.includes("skill:untrusted-agent"));
    });
  }
});

test("refresh rejects pending extension commands and succeeds after they finish", { timeout: 30000 }, async t => {
  await withPi(t, { settings: { extensions: OFF }, files: () => ({ "extensions/probe.ts": probe }) }, async pi => {
    await pi.commands();
    const pending = pi.request({ type: "prompt", message: "/hold" });
    await until("command preflight to hold", () => pi.events.some(e => e.message === "holding"));
    write(path.join(pi.home, "skills/later/SKILL.md"), skill("later"));
    const busy = await pi.request({ type: "refresh_skills" });
    assert.equal(busy.success, false);
    assert.equal(busy.error, "skills_busy");
    assert.ok(!(await pi.commands()).some(c => c.name === "skill:later"));
    await pi.request({ type: "prompt", message: "/release" });
    await pending;
    assert.equal(await refresh(pi), true);
    assert.equal((await inspect(pi)).starts, 1);
  });
});

test("refresh waits through a model turn and Stop leaves it safe to refresh", { timeout: 30000 }, async t => {
  let release;
  const held = new Promise(resolve => { release = resolve; });
  await withPi(t, { settings: { extensions: OFF, compaction: { enabled: false } }, onRequest: async () => { await held; return {}; } }, async pi => {
    try {
      await pi.commands();
      await pi.request({ type: "prompt", message: "hold the turn" });
      await until("the model request", () => pi.provider.requests.length === 1);
      write(path.join(pi.home, "skills/after-stop/SKILL.md"), skill("after-stop"));
      assert.equal((await pi.request({ type: "refresh_skills" })).error, "skills_busy");
      await pi.request({ type: "abort" });
      await until("the abort to settle", () => pi.events.some(e => e.type === "agent_settled"));
      assert.equal(await refresh(pi), true);
      assert.ok((await pi.commands()).some(c => c.name === "skill:after-stop"));
    } finally { release(); }
  });
});

for (const source of ["cli", "package", "extension"]) {
  test(`refresh retains ${source} skills and preserves collision precedence through edits and removal`, { timeout: 30000 }, async t => {
    await withPi(t, {
      settings: { extensions: OFF },
      args: source === "cli" ? ["--skill", "../extra-skills"] : [],
      files: (dir, work) => ({
        "settings.json": { extensions: OFF, ...(source === "package" ? { packages: [path.join(dir, "local-package")] } : {}) },
        "trust.json": { [work]: true },
        "extensions/probe.ts": probe,
        ...(source === "extension" ? { "extensions/resources.ts": `import path from "node:path";
          export default pi => pi.on("resources_discover", (_event, ctx) => ({skillPaths: [path.resolve(ctx.cwd, "../extra-skills")]}));` } : {}),
        [path.join(dir, "local-package/package.json")]: { name: "scratch-skills", version: "1.0.0", pi: { skills: ["../extra-skills"] } },
        [path.join(dir, "extra-skills/only/SKILL.md")]: skill("extra-only", "Original extra instructions"),
        [path.join(dir, "extra-skills/conflict/SKILL.md")]: skill("conflict", "Extra collision winner"),
        "skills/conflict/SKILL.md": skill("conflict", "Global collision winner"),
        [path.join(work, ".pi/skills/conflict/SKILL.md")]: skill("conflict", "Project collision winner"),
      }),
    }, async pi => {
      const initialCommands = await pi.commands();
      assert.equal(initialCommands.filter(c => c.name === "skill:extra-only").length, 1, source);
      assert.equal(initialCommands.filter(c => c.name === "skill:conflict").length, 1);
      const initial = await inspect(pi);
      const winners = ["Extra collision winner", "Global collision winner", "Project collision winner"];
      const winner = winners.find(text => initial.prompt.includes(text));
      assert.ok(winner);
      const extra = path.join(pi.dir, "extra-skills/only/SKILL.md");
      write(extra, skill("extra-only", "Edited extra instructions"));
      assert.equal(await refresh(pi), true);
      let current = await inspect(pi);
      assert.equal(current.starts, 1);
      assert.match(current.prompt, /Edited extra instructions/);
      assert.ok(!current.prompt.includes("Original extra instructions"));
      assert.deepEqual(winners.filter(text => current.prompt.includes(text)), [winner], "refresh must preserve startup precedence");
      assert.equal((await pi.commands()).filter(c => c.name === "skill:conflict").length, 1);
      fs.unlinkSync(extra);
      assert.equal(await refresh(pi), true);
      current = await inspect(pi);
      assert.equal(current.starts, 1);
      assert.ok(!current.prompt.includes("Edited extra instructions"));
      assert.ok(!(await pi.commands()).some(c => c.name === "skill:extra-only"));
      assert.deepEqual(winners.filter(text => current.prompt.includes(text)), [winner]);
      fs.unlinkSync(path.join(pi.work, ".pi/skills/conflict/SKILL.md"));
      await refresh(pi);
      current = await inspect(pi);
      assert.deepEqual(winners.filter(text => current.prompt.includes(text)), ["Global collision winner"]);
      fs.unlinkSync(path.join(pi.home, "skills/conflict/SKILL.md"));
      await refresh(pi);
      current = await inspect(pi);
      assert.deepEqual(winners.filter(text => current.prompt.includes(text)), ["Extra collision winner"]);
      assert.equal((await pi.commands()).filter(c => c.name === "skill:conflict").length, 1);
    });
  });
}
