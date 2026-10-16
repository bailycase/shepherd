// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd's subproject MCP extension (Settings ▸ Projects, parents and subprojects; docs/mcp.md): a project inside another
// project's folder shares the parent's MCP servers. pi reads `.shepherd/mcp.json` only in the folder it runs in, so this reads the
// parent's file, the folder Shepherd names in SHEPHERD_PARENT_PROJECT, and registers its servers for the session with
// pi.registerMcpServer. The subproject's own `.shepherd/mcp.json` and the user's `mcp.json` are pi's own configuration, which wins
// over a registered server of the same name, so the subproject's own entry overrides the parent's.
//
// Only from a parent pi trusts: its servers run commands. pi's own check passes a subproject with no `.shepherd` of its own (it
// has nothing to trust), so the parent's decision is read from pi's trust store, which a saved decision on a folder above
// also answers. The home folder is never a parent: its `.pi` is the user's own pi. It runs no server, speaks no MCP and
// writes nothing. For an owned worktree, the host instead names SHEPHERD_MCP_OWNING_SPACE and binds it to the exact
// SHEPHERD_MCP_WORKTREE_CWD. This authorization is only for that space's MCP file, never checkout extensions or settings.
// The checkout's independent trust decision still controls its own config and same-named overrides.
//
// Inert unless SHEPHERD_PARENT_PROJECT is set. Nothing throws into pi.
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { getAgentDir, ProjectTrustStore, SettingsManager } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Whether pi trusts `parent` with its project resources (a saved decision, else pi's global default of "always"), and
 *  the user hasn't refused the subproject itself. */
function trusted(parent: string, cwd: string, ownedWorktree = false): boolean {
  const real = fs.realpathSync(parent);
  if (real === fs.realpathSync(os.homedir())) return false;
  const store = new ProjectTrustStore(getAgentDir());
  if (!ownedWorktree && store.get(fs.realpathSync(cwd)) === false) return false;
  const decision = store.get(real);
  if (decision !== null) return decision;
  return SettingsManager.create(real, getAgentDir(), { projectTrusted: false }).getDefaultProjectTrust() === "always";
}

function isObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

/** The parent's servers as its `.shepherd/mcp.json` holds them, or none when it has no such file, or the session runs outside it. */
export function parentServers(parent: string | undefined, cwd: string): Record<string, unknown> {
  if (!parent || !path.isAbsolute(parent)) return {};
  const root = path.resolve(parent);
  const here = path.resolve(cwd);
  // The parent holds the subproject, never the other way round, and a project is not its own parent.
  if (here === root || !here.startsWith(root + path.sep)) return {};
  try {
    const parsed = JSON.parse(fs.readFileSync(path.join(root, ".shepherd", "mcp.json"), "utf8"));
    return isObject(parsed) && isObject(parsed.mcpServers) ? parsed.mcpServers : {};
  } catch {
    return {};
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
    const parsed = JSON.parse(fs.readFileSync(path.join(root, ".shepherd", "mcp.json"), "utf8"));
    return isObject(parsed) && isObject(parsed.mcpServers) ? parsed.mcpServers : {};
  } catch {
    return {};
  }
}

export default function shepherdMcpParent(pi: ExtensionAPI) {
  const parent = process.env.SHEPHERD_PARENT_PROJECT;
  const owner = process.env.SHEPHERD_MCP_OWNING_SPACE;
  const checkout = process.env.SHEPHERD_MCP_WORKTREE_CWD;
  if (!parent && !owner) return;
  pi.on("session_start", (_event, ctx) => {
    try {
      const servers = owner ? owningSpaceServers(owner, checkout, ctx.cwd) : parentServers(parent, ctx.cwd);
      if (Object.keys(servers).length === 0 || !trusted(owner || parent, ctx.cwd, !!owner)) return;
      for (const [name, entry] of Object.entries(servers)) {
        if (!isObject(entry)) continue;
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
