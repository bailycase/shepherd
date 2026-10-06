// @ts-nocheck -- Pi loads this module through jiti.
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { CONFIG_DIR_NAME, getAgentDir, parseFrontmatter, SettingsManager, DefaultPackageManager, ProjectTrustStore, loadSkills } from "@earendil-works/pi-coding-agent";

export const bundledAgents = {
  scout: { description: "Find relevant code and facts. Do not edit files.", tools: ["read", "grep", "find", "ls"], prompt: "Find relevant code and facts. Return concise findings with file paths. Do not edit files." },
  reviewer: { description: "Review for correctness and security. Do not edit files.", tools: ["read", "grep", "find", "ls"], prompt: "Review for correctness and security. Report actionable findings with paths and evidence. Do not edit files." },
  planner: { description: "Reads the code and proposes a bounded plan before anyone starts editing.", tools: ["read", "grep", "find", "ls"], prompt: "Inspect the code and propose a bounded implementation plan. Do not edit files." },
  worker: { description: "Implement only the assigned task and run focused checks.", tools: ["read", "grep", "find", "ls", "bash", "edit", "write"], prompt: "Implement only the assigned task. Inspect local conventions, preserve unrelated work, and run focused checks. Never commit or push." },
};
export const thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
export function childDefaults(env = process.env) {
  const concurrency = Number(env.SHEPHERD_CHILD_CONCURRENCY ?? 4);
  const thinking = env.SHEPHERD_CHILD_THINKING || undefined;
  const context = env.SHEPHERD_CHILD_CONTEXT || "fresh";
  const scope = "shepherd";
  if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 16) throw Error("Child concurrency must be 1..16");
  if (thinking && !thinkingLevels.includes(thinking)) throw Error("Invalid child thinking default");
  if (!["fresh", "fork"].includes(context)) throw Error("Invalid child context default");
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

// Settings and launches use this exact parser. Invalid files remain visible, never a fallback.
export function parseChildAgent(text, file) {
  const { frontmatter: f, body } = parseFrontmatter(text);
  if (!f || typeof f !== "object" || Array.isArray(f)) throw Error("Agent frontmatter must be an object");
  const unknown = Object.keys(f).filter((key) => !supported.has(key));
  if (unknown.length) throw Error(`Unsupported agent fields: ${unknown.join(", ")}`);
  if (typeof f.name !== "string" || !f.name.trim() || typeof f.description !== "string" || !f.description.trim()) throw Error("An agent needs a name and description");
  if (f.package !== undefined && (typeof f.package !== "string" || !/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(f.package))) throw Error("Invalid agent package");
  const name = f.package ? `${f.package}.${f.name}` : f.name;
  if (name.length > 80 || f.description.length > 16384) throw Error("Agent name or description is too long");
  for (const field of ["inheritProjectContext", "inheritSkills", "disabled"]) if (f[field] !== undefined && typeof f[field] !== "boolean") throw Error(`Invalid ${field}`);
  const thinking = f.thinking === false ? "off" : f.thinking;
  if (thinking !== undefined && !thinkingLevels.includes(thinking)) throw Error("Invalid thinking");
  const context = f.defaultContext ?? f.context;
  if (context !== undefined && !["fresh", "fork"].includes(context)) throw Error("Invalid defaultContext");
  const systemPromptMode = f.systemPromptMode ?? (name === "delegate" ? "append" : "replace");
  if (!["append", "replace"].includes(systemPromptMode)) throw Error("Invalid systemPromptMode");
  const prompt = f.prompt ?? f.systemPrompt ?? body;
  if (typeof prompt !== "string" || !prompt.trim() || prompt.length > 65536 || (f.model !== undefined && typeof f.model !== "string")) throw Error("Invalid or empty prompt/model");
  if (f.tools === "inherit") throw Error("tools: inherit is unsupported. Omit tools for Pi builtins or list tools and explicit extension files.");
  const tools = f.tools === undefined ? undefined : list(f.tools, "tools");
  const extensions = [...list(f.extensions, "extensions"), ...list(f.subagentOnlyExtensions, "subagentOnlyExtensions")].map((p) => resolvePath(p, path.dirname(file)));
  if (extensions.some((p) => !fs.statSync(p).isFile())) throw Error("Extensions must name explicit local files, not packages or directories");
  return { name, description: f.description, source: "shepherd", filePath: file, prompt, model: f.model, thinking, context, systemPromptMode,
    inheritProjectContext: f.inheritProjectContext ?? name === "delegate", inheritSkills: f.inheritSkills ?? false, tools,
    skills: list(f.skills ?? f.skill, "skills"), skillPaths: list(f.skillPath, "skillPath").map((p) => resolvePath(p, path.dirname(file))),
    extensions, aliases: list(f.aliases ?? f.alias, "aliases"), disabled: f.disabled === true };
}

export function childAgentError(text, file, error) {
  let name = path.basename(file, ".md");
  try {
    const { frontmatter: f } = parseFrontmatter(text);
    if (typeof f?.name === "string" && f.name.trim() && f.name.length <= 80) name = f.package ? `${f.package}.${f.name}` : f.name;
  } catch {}
  return { name, filePath: file, source: "shepherd", error: error.message };
}

export const childAgentDefaults = Object.fromEntries(Object.entries(bundledAgents).map(([name, a]) => [name + ".md",
  `---\nname: ${name}\ndescription: ${JSON.stringify(a.description)}\ntools: [${a.tools.join(", ")}]\nsystemPromptMode: append\ninheritProjectContext: true\n---\n\n${a.prompt}\n`]));
export const childAgentsSeedMarker = ".shepherd-defaults-v1";

export function ensureChildAgents() {
  const home = getAgentDir();
  fs.mkdirSync(home, { recursive: true, mode: 0o700 });
  if (fs.lstatSync(home).isSymbolicLink() || !fs.lstatSync(home).isDirectory()) throw Error("Shepherd's pi home cannot be a symbolic link");
  const dir = path.join(home, "agents");
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  if (fs.lstatSync(dir).isSymbolicLink() || !fs.lstatSync(dir).isDirectory()) throw Error("The subagent folder cannot be a symbolic link");
  const homeIdentity = fs.lstatSync(home), dirIdentity = fs.lstatSync(dir);
  function create(file, text) {
    let fd;
    try {
      const before = fs.lstatSync(dir);
      if (before.isSymbolicLink() || before.dev !== dirIdentity.dev || before.ino !== dirIdentity.ino) throw Error("The subagent folder changed during initialization");
      fd = fs.openSync(path.join(dir,file), fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
      const current = fs.lstatSync(dir), currentHome = fs.lstatSync(home);
      if (current.isSymbolicLink() || current.dev !== dirIdentity.dev || current.ino !== dirIdentity.ino || currentHome.isSymbolicLink() || currentHome.dev !== homeIdentity.dev || currentHome.ino !== homeIdentity.ino) throw Error("The subagent folder changed during initialization");
      fs.writeFileSync(fd,text);
    } catch (error) { if (error.code !== "EEXIST") throw error; }
    finally { if (fd !== undefined) fs.closeSync(fd); }
  }
  if (!fs.existsSync(path.join(dir, childAgentsSeedMarker))) {
    for (const [file, text] of Object.entries(childAgentDefaults)) create(file,text);
    create(childAgentsSeedMarker,"1\n");
  }
  return dir;
}

export function discoverChildAgents(_ctx, _scope) {
  const agents = [], diagnostics = [];
  let root, folders = 0;
  try { root = ensureChildAgents(); }
  catch (error) { return { agents, diagnostics: [{ source: "shepherd", error: error.message }] }; }
  const canonicalRoot = fs.realpathSync(root), rootIdentity = fs.lstatSync(root), homeIdentity = fs.lstatSync(getAgentDir());
  function checkRoot() {
    const current = fs.lstatSync(root), home = fs.lstatSync(getAgentDir());
    if (current.isSymbolicLink() || home.isSymbolicLink() || current.dev !== rootIdentity.dev || current.ino !== rootIdentity.ino || home.dev !== homeIdentity.dev || home.ino !== homeIdentity.ino) throw Error("The subagent folder changed during discovery");
  }
  function scan(dir, depth = 0) {
    checkRoot();
    if (fs.lstatSync(dir).isSymbolicLink() || path.relative(canonicalRoot, fs.realpathSync(dir)).startsWith("..")) throw Error("Subagent folders cannot follow symbolic links");
    if (++folders > 512) throw Error("At most 512 subagent folders can be scanned");
    if (depth > 16) throw Error("Subagent folders can nest at most 16 levels");
    for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (entry.name.startsWith(".") || ["node_modules", "skills"].includes(entry.name)) continue;
      const file = path.join(dir, entry.name);
      if (entry.isDirectory()) { scan(file, depth + 1); continue; }
      if (!entry.name.endsWith(".md") || entry.name.endsWith(".chain.md")) continue;
      if (agents.length >= 512) throw Error("At most 512 subagent files can load");
      let fd, text = "";
      try {
        fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
        const info = fs.fstatSync(fd);
        if (!info.isFile() || info.size > 128 * 1024) throw Error("Choose a regular UTF-8 agent file of at most 128 KiB");
        checkRoot();
        const observed = fs.lstatSync(file);
        if (observed.isSymbolicLink() || observed.dev !== info.dev || observed.ino !== info.ino || path.relative(canonicalRoot, fs.realpathSync(file)).startsWith("..")) throw Error("Agent path escapes or changed in its folder");
        const bytes = Buffer.alloc(128 * 1024 + 1);
        let length = 0, count;
        while (length < bytes.length && (count = fs.readSync(fd, bytes, length, bytes.length-length, null)) > 0) length += count;
        if (length > 128 * 1024) throw Error("Agent file exceeds 128 KiB");
        text = new TextDecoder("utf-8", {fatal:true}).decode(bytes.subarray(0,length));
        agents.push(parseChildAgent(text, file));
      } catch (error) {
        const failed = childAgentError(text, file, error);
        agents.push(failed); diagnostics.push(failed);
      } finally { if (fd !== undefined) fs.closeSync(fd); }
    }
  }
  try { scan(root); }
  catch (error) { return { agents: [], diagnostics: [{ source: "shepherd", error: error.message }] }; }
  // No last-file-wins ambiguity: every duplicate refuses to launch.
  const counts = new Map();
  for (const agent of agents) counts.set(agent.name, (counts.get(agent.name) ?? 0) + 1);
  for (const agent of agents) if (counts.get(agent.name) > 1) {
    agent.error = `Duplicate subagent name: ${agent.name}`;
    diagnostics.push({ name: agent.name, source: agent.source, filePath: agent.filePath, error: agent.error });
  }
  return { agents, diagnostics };
}

export function childSkills(profile, ctx) {
  if (!profile.inheritSkills && !profile.skills?.length && !profile.skillPaths?.length) return [];
  const settings = SettingsManager.create(ctx.cwd, getAgentDir(), { projectTrusted: ctx.isProjectTrusted?.() === true });
  const errors = settings.drainErrors();
  if (errors.length) throw Error(`Cannot read Pi skill settings: ${errors[0].error.message}`);
  const global = settings.getGlobalSettings(), project = settings.getProjectSettings();
  // Shepherd's pi reads skills only from its own home, never ~/.agents/skills: its settings turn
  // that folder off for the parent, and a filter entry ("!…") names no folder.
  const paths = [path.join(getAgentDir(), "skills"),
    ...(global.skills ?? []).filter((p) => !/^[!+-]/.test(p)).map((p) => path.resolve(getAgentDir(), p.replace(/^~\//, `${os.homedir()}/`)))];
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
