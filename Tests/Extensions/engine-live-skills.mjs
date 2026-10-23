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

test("trusted projects load Pi and Shepherd prompts with Shepherd winning duplicate names", { timeout: 30000 }, async t => {
  await withPi(t, {
    settings: { extensions: OFF },
    files: (_dir, work) => ({ "trust.json": { [work]: true } }),
    project: (dir, work) => {
      write(path.join(work, ".pi/prompts/speckit.specify.md"), [
        "---", "description: Create a feature specification.", "handoffs:",
        "  - label: Build Technical Plan", "    agent: speckit.plan", "    prompt: Create a plan", "    send: true",
        "tools: ['github/github-mcp-server/list_issues']", "---",
        "Pi specification: $ARGUMENTS", "Read .specify/memory/constitution.md.", "Context: $ARGUMENTS",
      ].join("\n"));
      write(path.join(work, ".pi/prompts/shared.md"), "Pi duplicate");
      write(path.join(work, ".shepherd/prompts/shared.md"), "Shepherd duplicate: $ARGUMENTS");
      write(path.join(work, ".shepherd/prompts/local.md"), "Shepherd local");
      write(path.join(dir, ".pi/agent/prompts/global-pi.md"), "Must stay isolated");
      write(path.join(work, ".pi/settings.json"), JSON.stringify({ prompts: ["extra"] }));
      write(path.join(work, ".pi/extra/not-loaded.md"), "Must not load Pi settings");
      write(path.join(work, ".pi/extensions/probe.ts"), `import fs from "node:fs"; fs.writeFileSync(${JSON.stringify(path.join(dir, "pi-extension-ran"))}, "ran"); export default function() {}`);
    },
  }, async pi => {
    const commands = await pi.commands();
    assert.equal(commands.find(c => c.name === "speckit.specify")?.description, "Create a feature specification.");
    assert.ok(commands.some(c => c.name === "local"));
    assert.equal(commands.filter(c => c.name === "shared").length, 1);
    assert.ok(!commands.some(c => c.name === "global-pi"));
    assert.ok(commands.some(c => c.name === "not-loaded"));
    assert.equal(fs.existsSync(path.join(pi.dir, "pi-extension-ran")), true);
    const specify = await pi.promptSent('/speckit.specify "I\'m Groot" preserve-$1');
    const specification = specify.messages.filter(m => m.role === "user").at(-1);
    assert.deepEqual(specification.content, [{ type: "text", text: "Pi specification: I'm Groot preserve-$1\nRead .specify/memory/constitution.md.\nContext: I'm Groot preserve-$1" }]);
    const shared = await pi.promptSent("/shared test");
    assert.ok(shared.messages.some(m => m.role === "user" && JSON.stringify(m.content).includes("Shepherd duplicate: test")));
    assert.ok(!shared.messages.some(m => JSON.stringify(m.content).includes("Pi duplicate")));
  });
});

test("Pi-only projects require approval and respect saved trust denials", { timeout: 30000 }, async t => {
  for (const entrypoint of ["dist/cli.js", "dist/bundle/cli.js"]) for (const decision of [null, false, true]) {
    await withPi(t, {
      entrypoint,
      settings: { extensions: [...OFF, "./probe.ts"] },
      files: (_dir, work) => ({ "probe.ts": probe, ...(decision === null ? {} : { "trust.json": { [work]: decision } }) }),
      project: (dir, work) => {
        write(path.join(work, ".pi/prompts/speckit.specify.md"), "Pi specification");
        write(path.join(work, ".pi/skills/pi-only/SKILL.md"), skill("pi-only"));
        write(path.join(work, ".pi/settings.json"), JSON.stringify({ defaultProjectTrust: "always" }));
        write(path.join(work, ".pi/SYSTEM.md"), "PI_TRUST_SENTINEL");
        write(path.join(work, ".pi/extensions/trust.ts"), `import fs from "node:fs"; export default () => fs.writeFileSync(${JSON.stringify(path.join(dir, "pi-executed"))}, "ran");`);
      },
    }, async pi => {
      const names = (await pi.commands()).map(c => c.name);
      for (const name of ["speckit.specify", "skill:pi-only"]) assert.equal(names.includes(name), decision === true, `trust: ${decision}`);
      assert.equal(fs.existsSync(path.join(pi.dir, "pi-executed")), decision === true);
      assert.equal((await inspect(pi)).prompt.includes("PI_TRUST_SENTINEL"), decision === true);
    });
  }
});

test("Pi prompts obey project trust, no-prompt-templates and Shepherd exclusions", { timeout: 30000 }, async t => {
  for (const mode of ["untrusted", "disabled", "excluded"]) {
    await withPi(t, {
      settings: { extensions: OFF },
      args: mode === "untrusted" ? ["--no-approve"] : mode === "disabled" ? ["--no-prompt-templates"] : [],
      files: (_dir, work) => mode === "untrusted" ? {} : { "trust.json": { [work]: true } },
      project: (_dir, work) => {
        write(path.join(work, ".pi/prompts/speckit.specify.md"), "Pi specification");
        write(path.join(work, ".shepherd/prompts/local.md"), "Shepherd local");
        if (mode === "excluded") {
          write(path.join(work, ".shepherd/settings.json"), JSON.stringify({ prompts: ["!../.pi/prompts/**"] }));
        }
      },
    }, async pi => {
      const names = (await pi.commands()).map(c => c.name);
      assert.ok(!names.includes("speckit.specify"), mode);
      assert.equal(names.includes("local"), mode === "excluded", mode);
    });
  }
});

test("project aliases cover settings, relative packages, extensions, skills, themes and system prompts", { timeout: 30000 }, async t => {
  for (const entrypoint of ["dist/cli.js", "dist/bundle/cli.js"]) await withPi(t, {
    entrypoint,
    settings: { extensions: [...OFF, "./probe.ts"] },
    files: (_dir, work) => ({
      "trust.json": { [work]: true },
      "probe.ts": `import { DefaultResourceLoader, SettingsManager, getAgentDir } from "@earendil-works/pi-coding-agent";
        export default function(pi) { pi.registerCommand("inspect-aliases", { handler: async (_, ctx) => {
          const settings = SettingsManager.create(ctx.cwd, getAgentDir(), { projectTrusted: ctx.isProjectTrusted() });
          const loader = new DefaultResourceLoader({ cwd: ctx.cwd, agentDir: getAgentDir(), settingsManager: settings, noExtensions: true, noContextFiles: true });
          await loader.reload();
          ctx.ui.notify(JSON.stringify({ effectiveSystem: ctx.getSystemPrompt(), settings: settings.getProjectSettings(), skills: loader.getSkills().skills,
            themes: loader.getThemes().themes.map(t => t.name), system: loader.getSystemPrompt(), append: loader.getAppendSystemPrompt(),
            watch: loader.getSkillWatchPaths?.() ?? [] }), "info");
        }}); }`,
    }),
    project: (dir, work) => {
      write(path.join(work, ".pi/settings.json"), JSON.stringify({ quietStartup: true, extensions: ["./configured.ts"], packages: ["./local-package"] }));
      write(path.join(work, ".pi/configured.ts"), `export default pi => pi.registerCommand("configured-extension", { handler: async () => {} });`);
      write(path.join(work, ".pi/local-package/package.json"), JSON.stringify({ name: "alias-local", pi: { prompts: ["prompts"] } }));
      write(path.join(work, ".pi/local-package/prompts/package-alias.md"), "Local Pi package prompt.");
      for (const base of [".pi", ".shepherd"]) {
        write(path.join(work, base, "skills/shared/SKILL.md"), skill("shared", base));
        write(path.join(work, base, "skills", base.slice(1), "SKILL.md"), skill(base.slice(1)));
        write(path.join(work, base, "extensions/collision.ts"), `import fs from "node:fs"; export default () => fs.appendFileSync(${JSON.stringify(path.join(dir, "loaded-extensions"))}, ${JSON.stringify(base + "\n")});`);
      }
      write(path.join(work, ".pi/extensions/pi-only.ts"), `export default pi => pi.registerCommand("pi-only-extension", { handler: async () => {} });`);
      const theme = JSON.parse(fs.readFileSync(path.join(pkg, "dist/modes/interactive/theme/dark.json"), "utf8"));
      theme.name = "alias-theme";
      write(path.join(work, ".pi/themes/alias-theme.json"), JSON.stringify(theme));
      write(path.join(work, ".pi/SYSTEM.md"), "PI_SYSTEM_SENTINEL");
      write(path.join(work, ".pi/APPEND_SYSTEM.md"), "PI_APPEND_SENTINEL");
    },
  }, async pi => {
    const names = (await pi.commands()).map(c => c.name);
    for (const name of ["configured-extension", "pi-only-extension", "package-alias"]) assert.ok(names.includes(name), name);
    assert.equal(fs.readFileSync(path.join(pi.dir, "loaded-extensions"), "utf8"), ".shepherd\n");
    const inspectAliases = async () => {
      const mark = pi.events.length;
      assert.equal((await pi.request({ type: "prompt", message: "/inspect-aliases" })).success, true);
      await until("alias inspection to finish", () => {
        const error = pi.events.slice(mark).find(e => e.type === "extension_error");
        if (error) throw Error(JSON.stringify(error));
        return pi.events.slice(mark).some(e => e.method === "notify");
      }, 10000);
      return JSON.parse(pi.events.slice(mark).find(e => e.method === "notify").message);
    };
    let state = await inspectAliases();
    assert.equal(state.settings.quietStartup, true);
    assert.equal(state.skills.find(s => s.name === "shared").description, ".shepherd");
    for (const name of ["pi", "shepherd"]) assert.ok(state.skills.some(s => s.name === name));
    assert.ok(state.themes.includes("alias-theme"));
    assert.equal(state.system, "PI_SYSTEM_SENTINEL");
    assert.ok(state.effectiveSystem.includes("PI_SYSTEM_SENTINEL"));
    assert.ok(state.append.includes("PI_APPEND_SENTINEL"));
    if (entrypoint === "dist/cli.js") for (const base of [".pi", ".shepherd"]) assert.ok(state.watch.includes(path.join(pi.work, base, "skills")));
    write(path.join(pi.work, ".shepherd/SYSTEM.md"), "SHEPHERD_SYSTEM_SENTINEL");
    write(path.join(pi.work, ".shepherd/settings.json"), JSON.stringify({ quietStartup: false }));
    state = await inspectAliases();
    assert.equal(state.settings.quietStartup, false);
    assert.equal(state.system, "SHEPHERD_SYSTEM_SENTINEL");
    assert.equal(fs.readFileSync(path.join(pi.work, ".pi/SYSTEM.md"), "utf8"), "PI_SYSTEM_SENTINEL");
    if (entrypoint === "dist/cli.js") {
      write(path.join(pi.work, ".pi/skills/pi/SKILL.md"), skill("pi", "edited live"));
      assert.equal(await refresh(pi), true);
      assert.equal((await inspectAliases()).skills.find(s => s.name === "pi").description, "edited live");
    }
  });
});

test("every executable or instructional alias resource requires project approval", async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-trust-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const { hasTrustRequiringProjectResources } = await import(pathToFileURL(path.join(pkg, "dist/core/trust-manager.js")));
  for (const base of [".pi", ".shepherd"]) {
    for (const resource of ["settings.json", "mcp.json", "extensions", "skills", "prompts", "themes", "SYSTEM.md", "APPEND_SYSTEM.md"]) {
      const cwd = fs.mkdtempSync(path.join(dir, "project-"));
      assert.equal(hasTrustRequiringProjectResources(cwd), false);
      write(path.join(cwd, base, resource), "fixture");
      assert.equal(hasTrustRequiringProjectResources(cwd), true, `${base}/${resource}`);
    }
  }
});

test("MCP aliases merge server names with Shepherd precedence and the same trust boundary", async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-config-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const cwd = path.join(dir, "project"), agentDir = path.join(dir, "agent");
  write(path.join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: { global: { command: "global-fixture" } } }));
  write(path.join(cwd, ".pi/mcp.json"), JSON.stringify({ mcpServers: { pi: { command: "pi-fixture" }, shared: { command: "pi-shared" }, forbidden: { url: "https://fixture.invalid/mcp", auth: { provider: "fixture" } } } }));
  write(path.join(cwd, ".shepherd/mcp.json"), JSON.stringify({ mcpServers: { shepherd: { command: "shepherd-fixture" }, shared: { command: "shepherd-shared" } } }));
  for (const entrypoint of ["dist/extensions/mcp/config.js", "dist/bundle/chunks/chunk-KDN6RCEQ.js"]) {
    const { loadMcpConfig } = await import(pathToFileURL(path.join(pkg, entrypoint)));
    const trusted = loadMcpConfig({ cwd, agentDir, projectTrusted: true });
    assert.deepEqual(trusted.servers.map(s => s.name).sort(), ["global", "pi", "shared", "shepherd"]);
    assert.equal(trusted.servers.find(s => s.name === "shared").config.command, "shepherd-shared");
    assert.ok(trusted.errors.some(e => e.includes("auth is only allowed")));
    assert.deepEqual(loadMcpConfig({ cwd, agentDir, projectTrusted: false }).servers.map(s => s.name), ["global"]);
  }
});

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
      write(path.join(pi.work, ".pi/skills/untrusted-pi/SKILL.md"), skill("untrusted-pi"));
      write(path.join(pi.work, ".agents/skills/untrusted-agent/SKILL.md"), skill("untrusted-agent"));
      await refresh(pi);
      const names = (await pi.commands()).map(c => c.name);
      assert.equal(names.includes("skill:global"), args.length === 0);
      assert.ok(!names.includes("skill:untrusted") && !names.includes("skill:untrusted-agent") && !names.includes("skill:untrusted-pi"));
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
  // macOS can install the native watches after this turn; flush startup notifications
  // with an observed source event before checking that an ignored edit stays silent.
  await new Promise(resolve => setImmediate(resolve));
  write(path.join(root, "ready"), "watch registration barrier");
  await until("the source watch to be ready", () => changes > 0, 3000);
  const beforeIgnoredEdit = changes;
  write(path.join(target, "example/SKILL.md"), skill("still-ignored"));
  await delivered;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(changes, beforeIgnoredEdit);
  write(path.join(root, ".gitignore"), "");
  await until("ignore-rule edit to reconcile sources", () => changes > beforeIgnoredEdit, 3000);
  const mark = changes;
  write(path.join(target, "example/SKILL.md"), skill("now-observed"));
  await until("the newly allowed target edit", () => changes > mark, 3000);
  assert.deepEqual(errors, []);
});
