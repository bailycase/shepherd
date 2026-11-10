// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd's subproject MCP extension (Settings ▸ Projects, parents and subprojects): a project inside another
// project's folder shares the parent's MCP servers. pi reads project MCP files only in the folder it runs in, so this reads the
// parent's files, the folder Shepherd names in SHEPHERD_PARENT_PROJECT, and registers their servers for the session with
// pi.registerMcpServer. The subproject's own MCP files and the user's `mcp.json` are pi's own configuration, which wins
// over a registered server of the same name, so the subproject's own entry overrides the parent's.
//
// A space's configuration always loads (adding a space is the decision to run it). The home folder is never a parent:
// its `.pi` is the user's own pi. It runs no server, speaks no MCP and writes nothing. For an owned worktree, the host
// names SHEPHERD_MCP_OWNING_SPACE and binds it to the exact SHEPHERD_MCP_WORKTREE_CWD.
//
// A subproject also loads the parent's skills (its `.shepherd`, `.pi` and `.agents` skill folders) and prompt templates (its
// `.shepherd` and `.pi` prompt folders) through resources_discover, after its own, so the subproject's own of the same name wins.
// SHEPHERD_PARENT_EXCLUDE, JSON `{"mcp":[…],"skills":[…],"prompts":[…]}`, names the parent servers, skills and templates the
// subproject turned off for itself (Settings ▸ Spaces); they are never registered. The parent's extensions can't load this
// late: Shepherd passes them to pi with `-e` at launch (`ProjectSettingsStore.inheritance`).
//
// Inert unless SHEPHERD_PARENT_PROJECT is set. Nothing throws into pi.
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** A parent's servers and skills apply unless it is the home folder (pi's own global config). */
function trusted(parent: string, _cwd?: string, _ownedWorktree = false): boolean {
  return fs.realpathSync(parent) !== fs.realpathSync(os.homedir());
}

function isObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function projectServers(root: string): Record<string, unknown> {
  const servers: Record<string, unknown> = {};
  for (const base of [".pi", ".shepherd"]) {
    try {
      const parsed = JSON.parse(fs.readFileSync(path.join(root, base, "mcp.json"), "utf8"));
      if (isObject(parsed) && isObject(parsed.mcpServers)) Object.assign(servers, parsed.mcpServers);
    } catch { /* Missing or invalid files contribute no servers. */ }
  }
  return servers;
}

/** Both parent MCP files, with Shepherd winning duplicate server names. */
export function parentServers(parent: string | undefined, cwd: string): Record<string, unknown> {
  const root = parentRoot(parent, cwd);
  return root ? projectServers(root) : {};
}

/** The parent holds the subproject, never the other way round, and a project is not its own parent. */
function parentRoot(parent: string | undefined, cwd: string): string | undefined {
  if (!parent || !path.isAbsolute(parent)) return undefined;
  const root = path.resolve(parent);
  const here = path.resolve(cwd);
  return here === root || !here.startsWith(root + path.sep) ? undefined : root;
}

/** The parent's skill folders, each holding a SKILL.md, by folder name, minus `excluded`. Linked folders are skipped. */
export function parentSkills(parent: string | undefined, cwd: string, excluded: string[] = []): string[] {
  const root = parentRoot(parent, cwd);
  if (!root) return [];
  const found: string[] = [];
  for (const base of [".shepherd", ".pi", ".agents"]) {
    const folder = path.join(root, base, "skills");
    let names: string[] = [];
    try {
      if (fs.lstatSync(folder).isSymbolicLink()) continue;
      names = fs.readdirSync(folder).sort();
    } catch { continue; }
    for (const name of names) {
      if (name.startsWith(".") || excluded.includes(name)) continue;
      const dir = path.join(folder, name);
      try {
        if (fs.lstatSync(dir).isDirectory() && fs.lstatSync(path.join(dir, "SKILL.md")).isFile()) found.push(dir);
      } catch { /* Not a skill folder. */ }
    }
  }
  return found;
}

/** The parent's prompt templates (slash commands), `<name>.md` directly in its `.shepherd` and `.pi` prompt folders, minus `excluded` names. */
export function parentPrompts(parent: string | undefined, cwd: string, excluded: string[] = []): string[] {
  const root = parentRoot(parent, cwd);
  if (!root) return [];
  const found: string[] = [];
  for (const base of [".shepherd", ".pi"]) {
    const folder = path.join(root, base, "prompts");
    let names: string[] = [];
    try {
      if (fs.lstatSync(folder).isSymbolicLink()) continue;
      names = fs.readdirSync(folder).sort();
    } catch { continue; }
    for (const name of names) {
      if (name.startsWith(".") || !name.endsWith(".md") || excluded.includes(name.slice(0, -3))) continue;
      try {
        if (fs.lstatSync(path.join(folder, name)).isFile()) found.push(path.join(folder, name));
      } catch { /* Gone since the listing. */ }
    }
  }
  return found;
}

/** The names SHEPHERD_PARENT_EXCLUDE turns off; anything malformed turns nothing off. */
export function exclusions(value: string | undefined): { mcp: string[]; skills: string[]; prompts: string[] } {
  try {
    const parsed = JSON.parse(value ?? "{}");
    const names = (list: unknown) => (Array.isArray(list) ? list.filter((name) => typeof name === "string") : []);
    return { mcp: names(parsed?.mcp), skills: names(parsed?.skills), prompts: names(parsed?.prompts) };
  } catch {
    return { mcp: [], skills: [], prompts: [] };
  }
}

/** The host's owning-space grant is bound to one canonical checkout, never arbitrary sibling folders. */
export function owningSpaceServers(owner: string | undefined, checkout: string | undefined, cwd: string): Record<string, unknown> {
  if (!owner || !checkout || !path.isAbsolute(owner) || !path.isAbsolute(checkout)) return {};
  try {
    const here = fs.realpathSync(cwd);
    const root = fs.realpathSync(owner);
    const home = fs.realpathSync(os.homedir());
    if (here !== fs.realpathSync(checkout) || here === root || here === home || root === home || root === path.parse(root).root) return {};
    return projectServers(root);
  } catch {
    return {};
  }
}

export default function shepherdMcpParent(pi: ExtensionAPI) {
  const parent = process.env.SHEPHERD_PARENT_PROJECT;
  const owner = process.env.SHEPHERD_MCP_OWNING_SPACE;
  const checkout = process.env.SHEPHERD_MCP_WORKTREE_CWD;
  if (!parent && !owner) return;
  const excluded = exclusions(process.env.SHEPHERD_PARENT_EXCLUDE);
  if (parent) {
    pi.on("resources_discover", (event) => {
      try {
        const skillPaths = parentSkills(parent, event.cwd, excluded.skills);
        const promptPaths = parentPrompts(parent, event.cwd, excluded.prompts);
        if ((skillPaths.length === 0 && promptPaths.length === 0) || !trusted(parent, event.cwd)) return;
        return { skillPaths, promptPaths };
      } catch {
        return;
      }
    });
  }
  pi.on("session_start", (_event, ctx) => {
    try {
      const servers = owner ? owningSpaceServers(owner, checkout, ctx.cwd) : parentServers(parent, ctx.cwd);
      if (Object.keys(servers).length === 0 || !trusted(owner || parent, ctx.cwd, !!owner)) return;
      for (const [name, entry] of Object.entries(servers)) {
        if (!isObject(entry) || (!owner && excluded.mcp.includes(name))) continue;
        try {
          // Owned worktrees never execute relative server scripts from unapproved branch files.
          // Descendant subprojects retain their existing session-relative behavior.
          let config = entry;
          if (owner && typeof entry.command === "string" && (entry.cwd === undefined || typeof entry.cwd === "string")) {
            let cwd = entry.cwd ?? ".";
            if (cwd === "~") cwd = os.homedir();
            else if (cwd.startsWith("~/")) cwd = path.join(os.homedir(), cwd.slice(2));
            config = { ...entry, cwd: path.resolve(fs.realpathSync(owner), cwd) };
          }
          pi.registerMcpServer(name, config);
        } catch {
          // pi refuses a name or a config it cannot use; the others still register.
        }
      }
    } catch {
      // Nothing of this reaches pi.
    }
  });
}
