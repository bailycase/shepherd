// @ts-nocheck -- Pi loads this module through jiti.
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { CONFIG_DIR_NAME, getAgentDir, parseFrontmatter, SettingsManager, DefaultPackageManager, ProjectTrustStore, loadSkills } from "@earendil-works/pi-coding-agent";

export const bundledAgents = {
  scout: { tools: ["read", "grep", "find", "ls"], prompt: "Find relevant code and facts. Return concise findings with file paths. Do not edit files." },
  reviewer: { tools: ["read", "grep", "find", "ls"], prompt: "Review for correctness and security. Report actionable findings with paths and evidence. Do not edit files." },
  planner: { tools: ["read", "grep", "find", "ls"], prompt: "Inspect the code and propose a bounded implementation plan. Do not edit files." },
  worker: { tools: ["read", "grep", "find", "ls", "bash", "edit", "write"], prompt: "Implement only the assigned task. Inspect local conventions, preserve unrelated work, and run focused checks. Never commit or push." },
};
export const thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
export function childDefaults(env = process.env) {
  const concurrency = Number(env.SHEPHERD_CHILD_CONCURRENCY ?? 4);
  const thinking = env.SHEPHERD_CHILD_THINKING || undefined;
  const context = env.SHEPHERD_CHILD_CONTEXT || "fresh";
  const scope = env.SHEPHERD_CHILD_SCOPE || "both";
  if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 16) throw Error("Child concurrency must be 1..16");
  if (thinking && !thinkingLevels.includes(thinking)) throw Error("Invalid child thinking default");
  if (!["fresh", "fork"].includes(context) || !["user", "project", "both", "bundled"].includes(scope)) throw Error("Invalid child discovery/context defaults");
  return { concurrency, thinking, context, scope, model: env.SHEPHERD_CHILD_MODEL || undefined };
}
const list = (value, field) => {
  if (value === undefined || value === null || value === false) return [];
  const values = typeof value === "string" ? value.split(",").map((s) => s.trim()).filter(Boolean) : value;
  if (!Array.isArray(values) || values.some((v) => typeof v !== "string" || !v.trim())) throw Error(`${field} must be a string list`);
  return values;
};
const directory = (p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };
const resolvePath = (p, base) => fs.realpathSync(path.resolve(base, p.startsWith("~/") ? path.join(os.homedir(), p.slice(2)) : p));
const supported = new Set(["package", "name", "description", "model", "thinking", "tools", "prompt", "systemPrompt", "systemPromptMode", "inheritProjectContext", "inheritSkills", "defaultContext", "context", "skills", "skill", "skillPath", "extensions", "subagentOnlyExtensions", "aliases", "alias", "disabled"]);

export function defaultChildTools(cwd) {
  const settings = SettingsManager.create(cwd, getAgentDir(), { projectTrusted: false });
  const errors = settings.drainErrors(); if (errors.length) throw Error(errors[0].error.message);
  return settings.getDefaultTools() ?? ["read", "bash", "edit", "write"];
}

/// Resolve enabled user extensions using Pi's package filters and discovery rules. Keep
/// --no-extensions on the child and pass these paths explicitly: a different cwd must not
/// implicitly load project code. Missing packages are skipped, never installed here.
export async function childUserExtensions(cwd) {
  const agentDir = getAgentDir();
  const settings = SettingsManager.create(cwd, agentDir, { projectTrusted: false });
  const errors = settings.drainErrors();
  if (errors.length) throw Error(`Cannot read Pi extension settings: ${errors[0].error.message}`);
  const packages = new DefaultPackageManager({ cwd, agentDir, settingsManager: settings });
  const resources = await packages.resolve(async () => "skip");
  return [...new Set(resources.extensions
    .filter((resource) => resource.enabled && resource.metadata.scope === "user")
    .map((resource) => fs.realpathSync(resource.path)))];
}

export function childTargetContext(ctx, cwd) {
  const trusted = cwd === fs.realpathSync(ctx.cwd) ? ctx.isProjectTrusted?.() === true : new ProjectTrustStore(getAgentDir()).get(cwd) === true;
  return { ...ctx, cwd, isProjectTrusted: () => trusted };
}

export function discoverChildAgents(ctx, scope) {
  const agents = new Map(Object.entries(bundledAgents).map(([name, a]) => [name, { ...a, name, description: a.prompt, source: "bundled", inheritProjectContext: true, systemPromptMode: "append" }]));
  const diagnostics = [], roots = [];
  const agentDir = getAgentDir();
  const trusted = ctx.isProjectTrusted?.() === true;
  let projectRoot = ctx.cwd;
  while (!directory(path.join(projectRoot, CONFIG_DIR_NAME)) && !directory(path.join(projectRoot, ".agents"))) {
    const parent = path.dirname(projectRoot); if (parent === projectRoot) { projectRoot = undefined; break; } projectRoot = parent;
  }
  if (["user", "both"].includes(scope)) {
    roots.push(...(process.env.PI_SUBAGENT_EXTRA_AGENT_DIRS || "").split(path.delimiter).filter(Boolean).map((dir) => ({ dir, source: "user" })));
    roots.push({ dir: path.join(agentDir, "agents"), source: "user" }, { dir: path.join(os.homedir(), ".agents"), source: "user" });
  }
  if (["project", "both"].includes(scope) && projectRoot) {
    if (trusted) roots.push({ dir: path.join(projectRoot, ".agents"), source: "project" }, { dir: path.join(projectRoot, CONFIG_DIR_NAME, "agents"), source: "project" });
    else diagnostics.push({ source: "project", error: "Project agent discovery requires Pi project trust; project definitions were not loaded" });
  }
  const settings = SettingsManager.create(projectRoot ?? ctx.cwd, agentDir, { projectTrusted: trusted });
  const settingsErrors = settings.drainErrors();
  if (settingsErrors.length) throw Error(`Cannot read Pi agent settings: ${settingsErrors[0].error.message}`);
  const userSettings = ["both", "user"].includes(scope) ? settings.getGlobalSettings().subagents ?? {} : {};
  const projectSettings = ["both", "project"].includes(scope) ? settings.getProjectSettings().subagents ?? {} : {};
  const overrides = { ...(userSettings.agentOverrides ?? {}), ...(projectSettings.agentOverrides ?? {}) };
  if (scope !== "bundled") {
    const packages = new DefaultPackageManager({ cwd: projectRoot ?? ctx.cwd, agentDir, settingsManager: settings });
    for (const pkg of packages.listConfiguredPackages()) {
      if (!pkg.installedPath || (pkg.scope === "user" && scope === "project") || (pkg.scope === "project" && scope === "user")) continue;
      try {
        const manifest = JSON.parse(fs.readFileSync(path.join(pkg.installedPath, "package.json"), "utf8"));
        const paths = manifest["pi-subagents"]?.agents ?? manifest.pi?.subagents?.agents ?? [];
        for (const entry of list(paths, "package agents")) roots.unshift({ dir: path.resolve(pkg.installedPath, entry), source: "package", requiresProjectTrust: pkg.scope === "project" });
      } catch (error) { diagnostics.push({ source: "package", filePath: pkg.installedPath, error: error.message }); }
    }
  }
  function scan(dir, root, source, depth = 0, requiresProjectTrust = source === "project") {
    if (depth > 16) { diagnostics.push({ source, filePath: dir, error: "Agent discovery nesting exceeds 16 directories" }); return; }
    if (!directory(dir)) return;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const file = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (![".git", "node_modules", "skills"].includes(entry.name) && !directory(path.join(file, CONFIG_DIR_NAME)) && !directory(path.join(file, ".agents")) && !fs.existsSync(path.join(file, ".git"))) scan(file, root, source, depth + 1, requiresProjectTrust);
        continue;
      }
      if (!entry.name.endsWith(".md") || entry.name.endsWith(".chain.md")) continue;
      let name;
      try {
        if (source === "project" && path.relative(fs.realpathSync(root), fs.realpathSync(file)).startsWith("..")) throw Error("Project agent symlink escapes its discovery directory");
        if (fs.statSync(file).size > 128 * 1024) throw Error("Agent file exceeds 128 KiB");
        const { frontmatter: raw, body } = parseFrontmatter(fs.readFileSync(file, "utf8"));
        if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw Error("Agent frontmatter must be an object");
        if (raw.package !== undefined && (typeof raw.package !== "string" || !/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(raw.package))) throw Error("Invalid agent package");
        name = raw.package ? `${raw.package}.${raw.name}` : raw.name;
        const f = { ...(overrides[name] ?? {}), ...raw, name };
        if (overrides[name]) diagnostics.push({ name, source, filePath: file, warning: "Supported settings override fields fill fields omitted by this agent file" });
        if (typeof raw.name !== "string" || typeof name !== "string" || !name.trim() || typeof f.description !== "string") continue;
        if (name.length > 80 || f.description.length > 16384) throw Error("Agent name or description is too long");
        const unknown = Object.keys(f).filter((key) => !supported.has(key));
        if (unknown.length) throw Error(`Unsupported agent fields: ${unknown.join(", ")}`);
        for (const field of ["inheritProjectContext", "inheritSkills", "disabled"]) if (f[field] !== undefined && typeof f[field] !== "boolean") throw Error(`Invalid ${field}`);
        const thinking = f.thinking === false ? "off" : f.thinking;
        if (thinking !== undefined && !thinkingLevels.includes(thinking)) throw Error("Invalid thinking");
        const context = f.defaultContext ?? f.context;
        if (context !== undefined && !["fresh", "fork"].includes(context)) throw Error("Invalid defaultContext");
        const systemPromptMode = f.systemPromptMode ?? (name === "delegate" ? "append" : "replace");
        if (!["append", "replace"].includes(systemPromptMode)) throw Error("Invalid systemPromptMode");
        const prompt = f.prompt ?? f.systemPrompt ?? body;
        if (typeof prompt !== "string" || prompt.length > 65536 || (f.model !== undefined && typeof f.model !== "string")) throw Error("Invalid prompt/model");
        const extensions = [...list(f.extensions, "extensions"), ...list(f.subagentOnlyExtensions, "subagentOnlyExtensions")].map((p) => resolvePath(p, path.dirname(file)));
        if (extensions.some((p) => !fs.statSync(p).isFile())) throw Error("Extensions must name explicit local files, not packages or directories");
        agents.set(name, { name, requiresProjectTrust, description: f.description, source, filePath: file, prompt, model: f.model, thinking, context, systemPromptMode,
          inheritProjectContext: f.inheritProjectContext ?? name === "delegate", inheritSkills: f.inheritSkills ?? false,
          tools: f.tools === "inherit" ? "inherit" : f.tools === undefined ? undefined : list(f.tools, "tools"),
          skills: list(f.skills ?? f.skill, "skills"), skillPaths: list(f.skillPath, "skillPath").map((p) => resolvePath(p, path.dirname(file))),
          extensions, aliases: list(f.aliases ?? f.alias, "aliases"), disabled: f.disabled === true });
      } catch (error) {
        diagnostics.push({ name, filePath: file, source, error: error.message });
        // A broken higher-priority definition must not fall back to a more permissive one.
        if (typeof name === "string") agents.set(name, { name, source, filePath: file, error: error.message });
      }
    }
  }
  for (const { dir, source, requiresProjectTrust = source === "project" } of roots) scan(dir, dir, source, 0, requiresProjectTrust);
  for (const [name, override] of Object.entries(overrides)) {
    const agent = agents.get(name);
    if (!agent || agent.source !== "bundled") continue;
    // Settings-managed builtins must never bypass disabled/tool policies.
    agents.set(name, { ...agent, error: `Settings override for bundled agent ${name} is unsupported; define a user agent file with the supported fields instead` });
    diagnostics.push({ name, source: "settings", error: agents.get(name).error });
  }
  if (userSettings.disableBuiltins === true || projectSettings.disableBuiltins === true) for (const [name, agent] of agents) if (agent.source === "bundled") agents.delete(name);
  for (const [source, values] of [["user", userSettings], ["project", projectSettings]]) {
    const unknown = Object.keys(values).filter((key) => !["agentOverrides", "disableBuiltins"].includes(key));
    if (unknown.length) diagnostics.push({ source, warning: `Unsupported pi-subagents settings: ${unknown.join(", ")}. Shepherd defaults apply; these settings are not imported.` });
  }
  return { agents: [...agents.values()], diagnostics, projectRoot };
}

export function childSkills(profile, ctx) {
  if (!profile.inheritSkills && !profile.skills?.length && !profile.skillPaths?.length) return [];
  const settings = SettingsManager.create(ctx.cwd, getAgentDir(), { projectTrusted: ctx.isProjectTrusted?.() === true });
  const errors = settings.drainErrors();
  if (errors.length) throw Error(`Cannot read Pi skill settings: ${errors[0].error.message}`);
  const global = settings.getGlobalSettings(), project = settings.getProjectSettings();
  const paths = [path.join(getAgentDir(), "skills"), path.join(os.homedir(), ".agents", "skills"),
    ...(global.skills ?? []).map((p) => path.resolve(getAgentDir(), p.replace(/^~\//, `${os.homedir()}/`)))];
  if (ctx.isProjectTrusted?.() === true) paths.unshift(path.join(ctx.cwd, CONFIG_DIR_NAME, "skills"), path.join(ctx.cwd, ".agents", "skills"),
    ...(project.skills ?? []).map((p) => path.resolve(ctx.cwd, CONFIG_DIR_NAME, p.replace(/^~\//, `${os.homedir()}/`))));
  const loaded = loadSkills({ cwd: ctx.cwd, agentDir: getAgentDir(), skillPaths: [...(profile.skillPaths ?? []), ...paths.filter((p) => fs.existsSync(p))], includeDefaults: false });
  if (loaded.diagnostics.some((d) => d.type === "error")) throw Error("Pi skill discovery reported errors");
  const names = profile.skills ?? [];
  const explicit = loadSkills({ cwd: ctx.cwd, agentDir: getAgentDir(), skillPaths: profile.skillPaths ?? [], includeDefaults: false }).skills;
  const chosen = profile.inheritSkills ? loaded.skills : loaded.skills.filter((skill) => names.includes(skill.name) || explicit.some((s) => s.filePath === skill.filePath));
  for (const name of names) if (!chosen.some((skill) => skill.name === name)) throw Error(`Unknown or unavailable skill: ${name}`);
  return chosen.map((skill) => skill.filePath);
}
