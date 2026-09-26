// Settings ▸ Skills' outside skills: every skill pi loads for a session outside any repository,
// read with pi's own loader, so the page lists exactly what the agent gets (docs/skills.md).
// Shepherd runs it with the node pi runs on, source on stdin:
//
//   node --input-type=module - <pi executable>
//
// SHEPHERD_PI_SKILLS_AGENT_DIR names pi's agent directory (~/.pi/agent, or PI_CODING_AGENT_DIR);
// SHEPHERD_PI_SKILLS_PACKAGE names pi's package directly, else it is found from the executable.
// It prints one JSON object and exits 0, even when it can't read pi's skills ("problem" says
// why). It only reads: pi's settings go through a storage that never writes, nothing missing is
// installed (PI_OFFLINE), and no extension runs, so skills an extension adds while it runs are
// not here.
import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const print = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);

function readJSON(file) {
  try { return JSON.parse(readFileSync(file, "utf8")); } catch { return undefined; }
}

// pi's package: the folder above its executable whose package.json names the coding agent.
function packageAbove(start) {
  let dir = start;
  for (let i = 0; i < 12; i++) {
    const manifest = readJSON(join(dir, "package.json"));
    if (manifest && typeof manifest.name === "string" && manifest.name.endsWith("/pi-coding-agent")) return dir;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return undefined;
}

function findPackage(executable) {
  const named = process.env.SHEPHERD_PI_SKILLS_PACKAGE;
  if (named) return existsSync(join(named, "package.json")) ? resolve(named) : undefined;
  if (!executable) return undefined;
  let real;
  try { real = realpathSync(executable); } catch { return undefined; }
  const found = packageAbove(dirname(real));
  if (found) return found;
  // A wrapper script (nix, a version manager) names the real entry point in its text.
  let text = "";
  try { if (statSync(real).size < 64 * 1024) text = readFileSync(real, "utf8"); } catch { return undefined; }
  for (const match of text.matchAll(/\/[^\s'"`;:]*pi-coding-agent[^\s'"`;:]*/g)) {
    try {
      const target = packageAbove(dirname(realpathSync(match[0])));
      if (target) return target;
    } catch {}
  }
  return undefined;
}

function entryOf(packageDir) {
  const manifest = readJSON(join(packageDir, "package.json")) ?? {};
  const root = manifest.exports?.["."];
  const entry = (typeof root === "string" ? root : root?.import ?? root?.default) ?? manifest.main ?? "dist/index.js";
  return { file: join(packageDir, entry), version: typeof manifest.version === "string" ? manifest.version : undefined };
}

// pi's settings, read and never written back: a lock or a migration would write.
function readOnlyStorage(agentDir, cwd) {
  const files = { global: join(agentDir, "settings.json"), project: join(cwd, ".pi", "settings.json") };
  return {
    withLock(scope, fn) {
      let current;
      try { current = readFileSync(files[scope], "utf8"); } catch {}
      fn(current);
    },
  };
}

function under(path, root) {
  const r = resolve(root);
  const p = resolve(path);
  return p === r || p.startsWith(r.endsWith(sep) ? r : r + sep);
}

async function main() {
  const agentDir = resolve(process.env.SHEPHERD_PI_SKILLS_AGENT_DIR || join(homedir(), ".pi", "agent"));
  const packageDir = findPackage(process.argv[2]);
  if (!packageDir) return print({ agentDir, skills: [], shadowed: [], problem: "pi_not_found" });
  const { file, version } = entryOf(packageDir);
  let pi;
  try { pi = await import(pathToFileURL(file).href); } catch (error) {
    return print({ agentDir, version, skills: [], shadowed: [], problem: "pi_unreadable", detail: String(error?.message ?? error) });
  }
  const { DefaultPackageManager, SettingsManager, loadSkills } = pi;
  if (typeof DefaultPackageManager !== "function" || typeof SettingsManager?.fromStorage !== "function" || typeof loadSkills !== "function") {
    return print({ agentDir, version, skills: [], shadowed: [], problem: "pi_unsupported" });
  }
  process.env.PI_OFFLINE = "1";
  // Outside any repository: a repository's own skills show in its threads, never here.
  const cwd = homedir();
  const settingsManager = SettingsManager.fromStorage(readOnlyStorage(agentDir, cwd), { projectTrusted: false });
  const manager = new DefaultPackageManager({ cwd, agentDir, settingsManager });
  const resolved = await manager.resolve(async () => "skip");

  // As pi's resource loader does: a folder from auto-discovery or a package that holds a
  // SKILL.md is that skill; the resolved list is already in pi's order of precedence.
  const metadataByPath = new Map();
  const paths = [];
  for (const resource of resolved.skills) {
    if (!metadataByPath.has(resource.path)) metadataByPath.set(resource.path, resource.metadata);
    if (!resource.enabled) continue;
    let path = resource.path;
    const { source, origin } = resource.metadata;
    if (source === "auto" || origin === "package") {
      try {
        if (statSync(path).isDirectory() && existsSync(join(path, "SKILL.md"))) {
          path = join(path, "SKILL.md");
          if (!metadataByPath.has(path)) metadataByPath.set(path, resource.metadata);
        }
      } catch {}
    }
    if (!paths.includes(path)) paths.push(path);
  }
  const metadataFor = (filePath) => {
    const exact = metadataByPath.get(resolve(filePath)) ?? metadataByPath.get(filePath);
    if (exact) return exact;
    for (const [path, metadata] of metadataByPath) if (under(filePath, path)) return metadata;
    return undefined;
  };
  const packageNames = new Map();
  const packageName = (baseDir) => {
    if (!baseDir) return undefined;
    if (!packageNames.has(baseDir)) packageNames.set(baseDir, readJSON(join(baseDir, "package.json"))?.name);
    return packageNames.get(baseDir);
  };
  const describe = (skill) => {
    const metadata = metadataFor(skill.filePath) ?? {};
    return {
      name: skill.name,
      description: skill.description ?? "",
      path: skill.filePath,
      source: metadata.source ?? "local",
      origin: metadata.origin ?? "top-level",
      scope: metadata.scope ?? "user",
      baseDir: metadata.baseDir,
      packageName: metadata.origin === "package" ? packageName(metadata.baseDir) : undefined,
      slashOnly: skill.disableModelInvocation === true,
    };
  };

  const loaded = loadSkills({ cwd, agentDir, skillPaths: paths, includeDefaults: false });
  const skills = loaded.skills.map(describe);
  // A name pi found twice: the first wins, and the agent never sees the other.
  const shadowed = [];
  for (const diagnostic of loaded.diagnostics ?? []) {
    const collision = diagnostic.collision;
    if (diagnostic.type !== "collision" || collision?.resourceType !== "skill") continue;
    const loser = loadSkills({ cwd, agentDir, skillPaths: [collision.loserPath], includeDefaults: false }).skills[0];
    const entry = loser ? describe(loser) : describe({ name: collision.name, description: "", filePath: collision.loserPath });
    shadowed.push({ ...entry, winner: collision.winnerPath });
  }
  print({ agentDir, version, skills, shadowed });
}

main().catch((error) => print({ skills: [], shadowed: [], problem: "failed", detail: String(error?.message ?? error) }));
