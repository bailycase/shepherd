// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd's repo MCP extension: Settings ▸ MCP servers ▸ Also use a repo's .mcp.json. pi's own MCP reads the
// servers Shepherd derives from the user's file and a trusted project's .pi/mcp.json, never a repo's .mcp.json (the
// file Claude Code, Cursor and VS Code share). With the switch on, this registers that file's servers for the
// session with pi.registerMcpServer, reached through tool_search like the page's own; a server of the same name in
// the user's file wins. It runs no server, speaks no MCP, reads nothing of the Keychain and writes nothing: pi's MCP
// connects what is registered here, and the values it expands from the environment stay in memory.
//
// Inert unless SHEPHERD_EXT_MCP_PROJECT=1. Nothing throws into pi.
import * as fs from "node:fs";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** The repo's `.mcp.json`: at `cwd`, or at the nearest ancestor holding `.git`, where the search stops. */
export function projectConfigPath(cwd: string): string | undefined {
  let dir = path.resolve(cwd);
  for (;;) {
    const candidate = path.join(dir, ".mcp.json");
    if (fs.existsSync(candidate)) return candidate;
    if (fs.existsSync(path.join(dir, ".git"))) return undefined;
    const parent = path.dirname(dir);
    if (parent === dir) return undefined;
    dir = parent;
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

const REFERENCE = /\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/g;

/** `${VAR}` and `${VAR:-default}` from the environment; a variable that is not set stays as written when it has no default. */
export function expand(text: string, env: Record<string, string | undefined> = process.env): string {
  return text.replace(REFERENCE, (whole, name, fallback) => env[name] ?? fallback ?? whole);
}

/** A value of `env` or `headers`: pi expands `${VAR}` itself, but not a default, so only defaults are settled here. */
function settleDefaults(map: unknown, env: Record<string, string | undefined> = process.env): Record<string, string> | undefined {
  if (!isObject(map)) return undefined;
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(map)) {
    if (typeof value === "string") out[key] = value.replace(REFERENCE, (whole, name, fallback) => (fallback !== undefined ? env[name] ?? fallback : whole));
  }
  return out;
}

/** What pi's `registerMcpServer` takes for one `.mcp.json` entry, or nothing when pi's MCP cannot run it. */
export function registration(entry: unknown, env: Record<string, string | undefined> = process.env): Record<string, unknown> | undefined {
  if (!isObject(entry) || entry.disabled === true) return undefined;
  const type = typeof entry.type === "string" ? entry.type.toLowerCase() : "";
  if (type === "sse") return undefined;
  const config: Record<string, unknown> = { exposure: "deferred" };
  if (typeof entry.command === "string" && typeof entry.url !== "string") {
    config.command = expand(entry.command, env);
    if (Array.isArray(entry.args)) config.args = entry.args.filter((a) => typeof a === "string").map((a) => expand(a, env));
    const settled = settleDefaults(entry.env, env);
    if (settled) config.env = settled;
    if (typeof entry.cwd === "string") config.cwd = expand(entry.cwd, env);
  } else if (typeof entry.url === "string") {
    config.url = expand(entry.url, env);
    const settled = settleDefaults(entry.headers, env);
    if (settled) config.headers = settled;
  } else {
    return undefined;
  }
  return config;
}

export default function shepherdMcpProject(pi: ExtensionAPI) {
  if (process.env.SHEPHERD_EXT_MCP_PROJECT !== "1") return;
  pi.on("session_start", (_event, ctx) => {
    try {
      const file = projectConfigPath(ctx.cwd);
      if (!file) return;
      const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
      for (const [name, entry] of Object.entries(isObject(parsed) && isObject(parsed.mcpServers) ? parsed.mcpServers : {})) {
        try {
          const config = registration(entry);
          if (config) pi.registerMcpServer(name, config);
        } catch {
          // pi refuses a name or a config it cannot use; the others still register.
        }
      }
    } catch {
      // An unreadable or invalid file registers nothing.
    }
  });
}
