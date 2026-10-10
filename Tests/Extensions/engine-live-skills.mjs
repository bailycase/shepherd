// Invoked by EngineSmokeTests against Shepherd's patched, staged engine (not stock npm pi).
import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { pathToFileURL } from "node:url";
import { withPi, until, pkg } from "./fixtures/pi-rpc-harness.mjs";

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
    write(path.join(pi.work, ".shepherd/skills/project/SKILL.md"), skill("project", "Project metadata"));
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
    write(path.join(pi.work, ".shepherd/skills/project/SKILL.md"), skill("renamed", "Changed metadata"));
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
      write(path.join(pi.work, ".shepherd/skills/untrusted/SKILL.md"), skill("untrusted"));
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
        [path.join(work, ".shepherd/skills/conflict/SKILL.md")]: skill("conflict", "Project collision winner"),
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
      fs.unlinkSync(path.join(pi.work, ".shepherd/skills/conflict/SKILL.md"));
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

test("native events observe absent sources, atomic directory replacement and dangling symlink recovery", { timeout: 30000 }, async t => {
  await withPi(t, { settings: { extensions: OFF }, files: (_dir, work) => ({ "trust.json": { [work]: true } }) }, async pi => {
    await pi.commands();
    const observe = async mutate => {
      const mark = pi.events.length;
      mutate();
      await until("a native skill invalidation", () => pi.events.slice(mark).some(e => e.type === "skills_changed"), 3000);
      assert.equal((await pi.request({ type: "refresh_skills" })).success, true);
    };
    await observe(() => write(path.join(pi.work, ".agents/skills/event/SKILL.md"), skill("agents-event")));
    assert.ok((await pi.commands()).some(c => c.name === "skill:agents-event"));
    const folder = path.join(pi.work, ".shepherd/skills/event");
    await observe(() => write(path.join(folder, "SKILL.md"), skill("event-one")));
    assert.ok((await pi.commands()).some(c => c.name === "skill:event-one"));
    const replacement = path.join(pi.dir, "replacement");
    write(path.join(replacement, "SKILL.md"), skill("event-two"));
    await observe(() => {
      fs.renameSync(folder, path.join(pi.dir, "old-skill"));
      fs.renameSync(replacement, folder);
    });
    assert.ok((await pi.commands()).some(c => c.name === "skill:event-two"));
    await observe(() => fs.rmSync(path.join(pi.work, ".shepherd/skills"), { recursive: true }));
    assert.ok(!(await pi.commands()).some(c => c.name.startsWith("skill:event-")));
    const linked = path.join(pi.dir, "linked-target");
    await observe(() => {
      fs.mkdirSync(path.join(pi.work, ".shepherd/skills"), { recursive: true });
      fs.symlinkSync(linked, path.join(pi.work, ".shepherd/skills/link"));
    });
    await observe(() => write(path.join(linked, "nested/SKILL.md"), skill("linked-event")));
    assert.ok((await pi.commands()).some(c => c.name === "skill:linked-event"));
    await observe(() => fs.rmSync(linked, { recursive: true }));
    assert.ok(!(await pi.commands()).some(c => c.name === "skill:linked-event"));
    await observe(() => write(path.join(linked, "nested/SKILL.md"), skill("linked-back")));
    assert.ok((await pi.commands()).some(c => c.name === "skill:linked-back"));
    assert.ok(!pi.events.some(e => e.type === "skills_watch_error"), JSON.stringify(pi.events.filter(e => e.type === "skills_watch_error")));
  });
});

test("closing native skill observation releases its watchers and suppresses later callbacks", { timeout: 10000 }, async t => {
  const { watchSkillPaths } = await import(pathToFileURL(path.join(pkg, "dist/core/shepherd-skill-watch.js")));
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "skill-watch-close-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  let changes = 0;
  const errors = [];
  const close = watchSkillPaths([directory], () => { changes++; }, error => errors.push(error));
  close();
  close();
  // A separate native watcher proves the filesystem delivered this edit after disposal.
  const delivered = new Promise(resolve => {
    const control = fs.watch(directory, () => { control.close(); resolve(); });
    t.after(() => control.close());
  });
  write(path.join(directory, "SKILL.md"), skill("after-close"));
  await delivered;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(changes, 0);
  assert.deepEqual(errors, []);
});

test("shallow missing-source anchors ignore unrelated repository edits", { timeout: 10000 }, async t => {
  const { watchSkillPaths } = await import(pathToFileURL(path.join(pkg, "dist/core/shepherd-skill-watch.js")));
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "skill-watch-scope-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  let changes = 0;
  const errors = [];
  const close = watchSkillPaths([path.join(directory, ".pi/skills")], () => { changes++; }, error => errors.push(error));
  t.after(close);
  const delivered = new Promise(resolve => {
    const control = fs.watch(directory, () => { control.close(); resolve(); });
    t.after(() => control.close());
  });
  write(path.join(directory, "unrelated.txt"), "not a skill");
  await delivered;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(changes, 0);
  write(path.join(directory, ".pi/skills/new/SKILL.md"), skill("in-scope"));
  await until("the selected source event", () => changes > 0, 3000);
  assert.deepEqual(errors, []);
});

test("ancestor symlink retargets and dangling recovery invalidate the new skill source", { timeout: 30000 }, async t => {
  await withPi(t, {
    settings: { extensions: OFF }, files: (_dir, work) => ({ "trust.json": { [work]: true } }),
    project: (dir, work) => {
      write(path.join(dir, "one/skills/example/SKILL.md"), skill("from-one"));
      write(path.join(dir, "two/skills/example/SKILL.md"), skill("from-two"));
      fs.symlinkSync(path.join(dir, "one"), path.join(work, ".shepherd"));
    },
  }, async pi => {
    assert.ok((await pi.commands()).some(c => c.name === "skill:from-one"));
    const observe = async mutate => {
      const mark = pi.events.length;
      mutate();
      await until("ancestor-link skill notification", () => pi.events.slice(mark).some(e => e.type === "skills_changed"), 3000);
      await refresh(pi);
    };
    const retarget = target => {
      fs.symlinkSync(path.join(pi.dir, target), path.join(pi.work, "replacement-link"));
      fs.renameSync(path.join(pi.work, "replacement-link"), path.join(pi.work, ".shepherd"));
    };
    await observe(() => retarget("two"));
    assert.ok((await pi.commands()).some(c => c.name === "skill:from-two"));
    assert.ok(!(await pi.commands()).some(c => c.name === "skill:from-one"));
    await observe(() => write(path.join(pi.dir, "two/skills/example/SKILL.md"), skill("edited-two")));
    assert.ok((await pi.commands()).some(c => c.name === "skill:edited-two"));
    await observe(() => retarget("missing"));
    assert.ok(!(await pi.commands()).some(c => c.name === "skill:edited-two"));
    await observe(() => write(path.join(pi.dir, "missing/skills/example/SKILL.md"), skill("recovered-ancestor")));
    assert.ok((await pi.commands()).some(c => c.name === "skill:recovered-ancestor"));
  });
});

test("explicit nested skill sources still signal edits and removal below an included SKILL.md", { timeout: 30000 }, async t => {
  for (const source of ["reference/SKILL.md", "reference"]) {
    await withPi(t, {
      settings: { extensions: OFF },
      args: ["--skill", `../home/skills/example/${source}`],
      files: () => ({
        "skills/example/SKILL.md": skill("parent"),
        "skills/example/reference/SKILL.md": skill("nested"),
      }),
    }, async pi => {
      assert.ok((await pi.commands()).some(c => c.name === "skill:nested"));
      const nested = path.join(pi.home, "skills/example/reference/SKILL.md");
      const observe = async mutate => {
        const mark = pi.events.length;
        mutate();
        await until("the explicit nested source notification", () => pi.events.slice(mark).some(e => e.type === "skills_changed"), 3000);
        await refresh(pi);
      };
      await observe(() => write(nested, skill("edited-nested")));
      assert.ok((await pi.commands()).some(c => c.name === "skill:edited-nested"));
      assert.ok(!(await pi.commands()).some(c => c.name === "skill:nested"));
      await observe(() => fs.unlinkSync(nested));
      assert.ok(!(await pi.commands()).some(c => c.name === "skill:edited-nested"));
      assert.ok((await pi.commands()).some(c => c.name === "skill:parent"));
      assert.ok(!pi.events.some(e => e.type === "skills_watch_error"));
      assert.equal(pi.provider.requests.length, 0);
    });
  }
});

test("reference symlinks below SKILL.md never observe unrelated repository contents", { timeout: 10000 }, async t => {
  const { watchSkillPaths } = await import(pathToFileURL(path.join(pkg, "dist/core/shepherd-skill-watch.js")));
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "skill-reference-scope-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const root = path.join(directory, "skills");
  const unrelated = path.join(directory, "unrelated-repo");
  write(path.join(root, "example/SKILL.md"), skill("example"));
  fs.mkdirSync(unrelated);
  fs.symlinkSync(unrelated, path.join(root, "example/reference"));
  let changes = 0;
  const errors = [];
  const close = watchSkillPaths([root], () => { changes++; }, error => errors.push(error));
  t.after(close);
  // macOS can deliver source-creation events after watch registration. Establish
  // observation with a real skill edit before measuring unrelated target events.
  await until("skill observation to be ready", () => {
    if (changes > 0) return true;
    write(path.join(root, "example/SKILL.md"), skill("ready-example"));
    return false;
  }, 3000);
  const mark = changes;
  const delivered = new Promise(resolve => {
    const control = fs.watch(unrelated, () => { control.close(); resolve(); });
    t.after(() => control.close());
  });
  write(path.join(unrelated, "source.txt"), "not a skill resource");
  await delivered;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(changes, mark);
  write(path.join(root, "example/SKILL.md"), skill("updated-example"));
  await until("the real skill instruction edit", () => changes > mark, 3000);
  assert.deepEqual(errors, []);
});

test("ignored symlinks stay out of observation until an ignore-file edit allows them", { timeout: 10000 }, async t => {
  const { watchSkillPaths } = await import(pathToFileURL(path.join(pkg, "dist/core/shepherd-skill-watch.js")));
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "skill-ignore-scope-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const root = path.join(directory, "skills");
  const target = path.join(directory, "outside");
  write(path.join(root, ".gitignore"), "linked/\n");
  write(path.join(target, "example/SKILL.md"), skill("ignored-example"));
  fs.symlinkSync(target, path.join(root, "linked"));
  let changes = 0;
  const errors = [];
  const close = watchSkillPaths([root], () => { changes++; }, error => errors.push(error));
  t.after(close);
  const delivered = new Promise(resolve => {
    const control = fs.watch(path.join(target, "example"), () => { control.close(); resolve(); });
    t.after(() => control.close());
  });
  write(path.join(target, "example/SKILL.md"), skill("still-ignored"));
  await delivered;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(changes, 0);
  write(path.join(root, ".gitignore"), "");
  await until("ignore-rule edit to reconcile sources", () => changes > 0, 3000);
  const mark = changes;
  write(path.join(target, "example/SKILL.md"), skill("now-observed"));
  await until("the newly allowed target edit", () => changes > mark, 3000);
  assert.deepEqual(errors, []);
});
