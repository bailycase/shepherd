// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd's hooks runtime (docs/hooks.md is the contract): finds the Shepherd, Claude Code and
// Codex hook files of this Mac and the thread's space, runs every handler the person hasn't
// switched off (<SHEPHERD_HOOKS_DIR>/settings.json) on pi's events, shows what each did as a
// `shepherd.hook` row, and offers `hook_propose`. Inert unless SHEPHERD_HOOKS_DIR is set; never
// throws into pi; every timer and child it leaves running is unref'd.
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as crypto from "node:crypto";
import { spawn } from "node:child_process";
import { Type } from "typebox";

export const EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact", "PostCompact",
  "SubagentStart", "SubagentStop", "Stop", "Notification", "SessionEnd"];
const CLAUDE_TO_PI = { Bash: "bash", Read: "read", Edit: "edit", MultiEdit: "edit", Write: "write", Grep: "grep", Glob: "find", LS: "ls" };
const PI_TO_CLAUDE = { bash: "Bash", read: "Read", edit: "Edit", write: "Write", grep: "Grep", find: "Glob", ls: "LS" };
const OUTPUT_CAP = 64 * 1024;
const CONTEXT_CAP = 10_000;
const STOP_SEND_BACK_LIMIT = 3;
// ponytail: a hook's own timeout is honored up to 10 minutes, so a typo can't hang a turn for hours.
const MAX_TIMEOUT_S = 600;
const CHILDREN_EVENT = "shepherd:children:v1";
const MARKER = "shepherd.hook.proposal";
const EDITED = "Added in Settings";

// MARK: Identity

/** Canonical JSON (docs/hooks.md, Identity and the off switch): sorted keys by UTF-16 code units, no whitespace. */
export function canonical(value) {
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  if (value && typeof value === "object") {
    return "{" + Object.keys(value).sort().filter((k) => value[k] !== undefined).map((k) => JSON.stringify(k) + ":" + canonical(value[k])).join(",") + "}";
  }
  return JSON.stringify(value) ?? "null";
}

export function hookHash(file, event, matcher, handler) {
  return crypto.createHash("sha256").update(`${file}\n${event}\n${matcher ?? ""}\n${canonical(handler)}`, "utf8").digest("hex");
}

// MARK: Parsing

const lineOf = (text, offset) => text.slice(0, offset).split("\n").length;

// ponytail: the TOML subset Codex hook tables need: `[[hooks.<Event>]]` and `[[hooks.<Event>.hooks]]`
// array tables whose keys hold basic or literal one-line strings, numbers and booleans. Other tables
// are skipped unread; inline tables, arrays, dates and multi-line strings inside a hook table are an
// error. A `[[hooks.` line inside another table's multi-line string would be misread. Swap in a real
// parser if Codex grows nested hook values.
export function parseTOML(text) {
  const hooks = {};
  let target = null;
  const lines = text.split(/\r?\n/);
  const fail = (i, why) => { throw new Error(`Couldn't read: line ${i + 1}, ${why}`); };
  for (let i = 0; i < lines.length; i++) {
    const line = stripTOMLComment(lines[i]).trim();
    if (!line) continue;
    let m = /^\[\[\s*hooks\.([A-Za-z]+)\s*\]\]$/.exec(line);
    if (m) { (hooks[m[1]] ??= []).push(target = {}); continue; }
    m = /^\[\[\s*hooks\.([A-Za-z]+)\.hooks\s*\]\]$/.exec(line);
    if (m) {
      const groups = hooks[m[1]];
      if (!groups?.length) fail(i, `[[hooks.${m[1]}.hooks]] before any [[hooks.${m[1]}]]`);
      (groups.at(-1).hooks ??= []).push(target = {});
      continue;
    }
    if (line.startsWith("[")) { target = null; continue; }
    if (!target) continue;
    m = /^([A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*"|'[^']*')\s*=\s*(.+)$/.exec(line);
    if (!m) fail(i, "expected key = value");
    const key = m[1].startsWith('"') ? JSON.parse(m[1]) : m[1].startsWith("'") ? m[1].slice(1, -1) : m[1];
    target[key] = tomlValue(m[2].trim(), (why) => fail(i, why));
  }
  return { hooks };
}

function stripTOMLComment(line) {
  let quote = "";
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quote) {
      if (quote === '"' && c === "\\") i++;
      else if (c === quote) quote = "";
    } else if (c === '"' || c === "'") quote = c;
    else if (c === "#") return line.slice(0, i);
  }
  return line;
}

function tomlValue(raw, fail) {
  if (raw === "true") return true;
  if (raw === "false") return false;
  if (raw.startsWith('"""') || raw.startsWith("'''")) return fail("multi-line strings aren't read in hook tables");
  if (/^'[^']*'$/.test(raw)) return raw.slice(1, -1);
  if (/^"(?:[^"\\]|\\.)*"$/.test(raw)) {
    try {
      return JSON.parse(raw.replace(/\\U([0-9A-Fa-f]{8})/g, (_, hex) => {
        const cp = parseInt(hex, 16);
        return cp > 0xffff ? JSON.stringify(String.fromCodePoint(cp)).slice(1, -1) : "\\u" + hex.slice(4);
      }).replace(/\t/g, "\\t"));
    } catch { return fail("a string with an unknown escape"); }
  }
  if (/^[+-]?\d[\d_]*(\.\d[\d_]*)?([eE][+-]?\d+)?$/.test(raw)) return Number(raw.replace(/_/g, ""));
  return fail(`unsupported value ${raw.slice(0, 20)}`);
}

/** Files larger than this are reported, not read (the catalog's `HookCatalog.fileLimit`). */
export const FILE_LIMIT = 1 << 20;

/**
 * One file's hooks: `{ hooks }` in the shared shape, or `{ error }` (contributing nothing) in exactly
 * the cases the catalog reports it unreadable: it doesn't parse, or any event list, group or handler
 * isn't the contract's shape. A leading UTF-8 BOM is dropped; an empty file has no hooks.
 */
export function parseHookFile(file, text) {
  try {
    text = text.replace(/^\uFEFF/, "");
    if (!text.trim()) return { hooks: {} };
    let doc;
    if (file.endsWith(".toml")) doc = parseTOML(text);
    else {
      try { doc = JSON.parse(text); } catch (error) {
        const at = /position (\d+)/.exec(String(error?.message))?.[1];
        throw new Error(`Couldn't read: line ${at ? lineOf(text, Number(at)) : 1}, ${String(error?.message ?? error).split("\n")[0]}`);
      }
    }
    return { hooks: hookShape(doc) };
  } catch (error) {
    return { hooks: {}, error: String(error?.message ?? error) };
  }
}

/** One file's bytes as the catalog reads them: over FILE_LIMIT or not UTF-8 is unreadable. */
export function parseHookBytes(file, bytes) {
  if (bytes.length > FILE_LIMIT) return { hooks: {}, error: "Couldn't read: the file is larger than 1 MiB" };
  let text;
  try { text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes); } catch { return { hooks: {}, error: "Couldn't read: the file isn't UTF-8 text" }; }
  return parseHookFile(file, text);
}

const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
/** The file's `hooks` object, checked whole as `HookCatalog.entries(of:)` checks it. */
function hookShape(doc) {
  const bad = (why) => { throw new Error(`Couldn't read: ${why}`); };
  if (!isObject(doc)) bad("the file isn't a JSON object");
  if (!Object.hasOwn(doc, "hooks")) return {};
  const hooks = doc.hooks;
  if (!isObject(hooks)) bad("“hooks” isn't an object");
  for (const [event, groups] of Object.entries(hooks)) {
    if (!Array.isArray(groups)) bad(`“hooks.${event}” isn't a list`);
    for (const group of groups) {
      if (!isObject(group) || !(group.hooks === undefined || Array.isArray(group.hooks))) bad(`a group in “${event}” isn't an object with a “hooks” list`);
      for (const handler of group.hooks ?? []) if (!isObject(handler)) bad(`a handler in “${event}” isn't an object`);
    }
  }
  return hooks;
}

/** Every handler of one parsed file, with its slot and hash. */
export function entriesOf(file, hooks, scope = "mac") {
  const out = [];
  // Every event the file names, as the catalog lists them; only known events ever fire.
  for (const [event, groups] of Object.entries(hooks ?? {})) {
    if (!Array.isArray(groups)) continue;
    groups.forEach((group, gi) => {
      if (!group || typeof group !== "object" || !Array.isArray(group.hooks)) return;
      const matcher = typeof group.matcher === "string" ? group.matcher : "";
      group.hooks.forEach((handler, hi) => {
        if (!handler || typeof handler !== "object" || Array.isArray(handler)) return;
        out.push({ file, scope, event, matcher, handler, slot: `${file}#${event}/${gi}/${hi}`, hash: hookHash(file, event, matcher, handler) });
      });
    });
  }
  return out;
}

// MARK: Matching

/** A matcher tested against the whole name (`^(?:…)$`), against the agent's name or a Claude Code alias. */
export function matcherMatches(matcher, name) {
  if (!matcher || matcher === "*") return true;
  if (name === undefined) return true;
  const names = [name, ...(PI_TO_CLAUDE[name] ? Object.entries(CLAUDE_TO_PI).filter(([, pi]) => pi === name).map(([claude]) => claude) : [])];
  try {
    const re = new RegExp(`^(?:${matcher})$`);
    return names.some((n) => re.test(n));
  } catch {
    return false;
  }
}

// MARK: Files and settings

const real = (dir) => { try { return fs.realpathSync(dir); } catch { return path.resolve(dir); } };
/** `dir` is the home folder or one of its ancestors: never a space. */
function atOrAboveHome(dir) {
  const home = real(os.homedir());
  return dir === home || home.startsWith(dir.endsWith(path.sep) ? dir : dir + path.sep);
}

/**
 * The thread's space root, as the catalog finds it: the nearest folder at or above the (real) cwd
 * holding `.git`, looking no higher than below the home folder, else the cwd. No git process.
 */
export function spaceRoot(cwd) {
  const start = real(cwd);
  for (let dir = start; !atOrAboveHome(dir); dir = path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, ".git"))) return dir;
    if (path.dirname(dir) === dir) break;
  }
  return start;
}
const isSpace = (root) => !!root && !atOrAboveHome(root);

// The path in a hook's slot and hash: $HOME as given (never resolved) for This Mac, the real root for a space.
export const macFile = (relative) => `${os.homedir().replace(/\/+$/, "")}/${relative}`;
export const spaceFile = (root, relative) => `${real(root).replace(/\/+$/, "")}/${relative}`;

export function hookFiles(root) {
  const files = [
    { path: macFile(".shepherd/hooks.json"), scope: "mac" },
    { path: macFile(".claude/settings.json"), scope: "mac", reader: "claude" },
    { path: macFile(".codex/hooks.json"), scope: "mac", reader: "codex" },
    { path: macFile(".codex/config.toml"), scope: "mac", reader: "codex" },
  ];
  if (isSpace(root)) {
    files.push(
      { path: spaceFile(root, ".shepherd/hooks.json"), scope: "space" },
      { path: spaceFile(root, ".claude/settings.json"), scope: "space", reader: "claude" },
      { path: spaceFile(root, ".claude/settings.local.json"), scope: "space", reader: "claude" },
      { path: spaceFile(root, ".codex/hooks.json"), scope: "space", reader: "codex" },
      { path: spaceFile(root, ".codex/config.toml"), scope: "space", reader: "codex" },
    );
  }
  return files;
}

// Re-read a file only when its mtime or size changes, so the app's edits apply to the next event.
const fileCache = new Map();
function readCached(file, parse) {
  let stat;
  try { stat = fs.statSync(file); } catch { fileCache.delete(file); return undefined; }
  const key = `${stat.mtimeMs}:${stat.size}`;
  const hit = fileCache.get(file);
  if (hit?.key === key) return hit.value;
  let value;
  try { value = parse(fs.readFileSync(file)); } catch { value = undefined; }
  fileCache.set(file, { key, value });
  return value;
}

/** `<hooksDir>/settings.json`: the hashes switched off and the readers; missing or invalid reads as all on. */
export function readSettings(hooksDir) {
  const raw = readCached(path.join(hooksDir, "settings.json"), (bytes) => JSON.parse(bytes.toString("utf8")));
  const valid = raw && typeof raw === "object" && !Array.isArray(raw);
  return {
    off: valid && Array.isArray(raw.off) ? raw.off : [],
    readers: valid && raw.readers && typeof raw.readers === "object" ? raw.readers : {},
  };
}

/** Every hook that would run for `root`: files found, readers on, not switched off. */
export function runnableHooks(root, hooksDir) {
  const settings = readSettings(hooksDir);
  const off = new Set(settings.off);
  const out = [];
  for (const file of hookFiles(root)) {
    if (file.reader && settings.readers[file.reader] === false) continue;
    const parsed = readCached(file.path, (bytes) => parseHookBytes(file.path, bytes));
    if (!parsed || parsed.error) continue;
    for (const entry of entriesOf(file.path, parsed.hooks, file.scope)) {
      if (!off.has(entry.hash)) out.push(entry);
    }
  }
  return out;
}

function writeAtomic(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.${crypto.randomUUID()}.tmp`);
  fs.writeFileSync(temp, text, { mode: 0o600 });
  fs.renameSync(temp, file);
}

// MARK: Running

/** What a hook never inherits from the agent: `PiHome.agentOnlyEnvironment`, plus every MCP secret value. */
export const AGENT_ONLY_ENV = [
  "SHEPHERD_AGENT_ID", "SHEPHERD_SOCKET", "SHEPHERD_EXT_STATUS",
  "SHEPHERD_EXT_PANES", "SHEPHERD_EXT_BROWSER", "SHEPHERD_NEEDS_NAME", "SHEPHERD_NAMER_MODELS", "SHEPHERD_AUTOMATION",
  "SHEPHERD_MODEL", "SHEPHERD_INSTRUCTIONS_DIR", "SHEPHERD_SUGGEST_FILES",
  "SHEPHERD_EXT_MCP_PROJECT", "SHEPHERD_PARENT_PROJECT", "SHEPHERD_MCP_SECRETS", "SHEPHERD_PI_EXECUTABLE", "SHEPHERD_DESIGN_REFS", "SHEPHERD_DESIGN_TOOLS", "SHEPHERD_EXT_SERVICE_TIER", "SHEPHERD_EXT_CONTEXT", "SHEPHERD_DEFER_TOOLS", "SHEPHERD_HOOKS_DIR",
  "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR", "PI_PACKAGE_DIR", "PI_OFFLINE",
];
export function hookEnv(env, extra) {
  const out = Object.fromEntries(Object.entries(env).filter(([key]) => !AGENT_ONLY_ENV.includes(key) && !key.startsWith("SHEPHERD_MCP_SECRET_")));
  return { ...out, ...extra };
}

function capped(stream) {
  const chunks = [];
  let size = 0;
  stream?.on("data", (chunk) => {
    if (size >= OUTPUT_CAP) return;
    chunks.push(chunk.subarray(0, OUTPUT_CAP - size));
    size += Math.min(chunk.length, OUTPUT_CAP - size);
  });
  return () => Buffer.concat(chunks).toString("utf8");
}

/** Runs one command handler: `sh -c` in root, the event on stdin; `signal` aborting kills its process group. Never rejects. */
export function runCommand(command, { cwd, event, input, timeoutMs, background = false, signal }) {
  const started = Date.now();
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn("sh", ["-c", command], {
        cwd, detached: true, stdio: ["pipe", "pipe", "pipe"],
        env: hookEnv(process.env, { CLAUDE_PROJECT_DIR: cwd, SHEPHERD_HOOK_EVENT: event }),
      });
    } catch (error) {
      resolve({ exit: null, stdout: "", stderr: String(error?.message ?? error), ms: Date.now() - started, error: true });
      return;
    }
    const stdout = capped(child.stdout), stderr = capped(child.stderr);
    let timedOut = false, done = false;
    const kill = () => { try { process.kill(-child.pid, "SIGKILL"); } catch { try { child.kill("SIGKILL"); } catch {} } };
    const timer = setTimeout(() => { timedOut = true; kill(); }, timeoutMs);
    timer.unref?.();
    signal?.addEventListener?.("abort", kill, { once: true });
    if (signal?.aborted) kill();
    const finish = (exit, error) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      signal?.removeEventListener?.("abort", kill);
      resolve({ exit, stdout: stdout(), stderr: error ? String(error?.message ?? error) : stderr(), ms: Date.now() - started, timedOut, error: !!error });
    };
    child.on("error", (error) => finish(null, error));
    child.on("close", (code) => finish(timedOut ? null : code));
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify(input));
    if (background) { child.unref(); child.stdout?.unref?.(); child.stderr?.unref?.(); }
  });
}

/** `${dotted.path}` placeholders from the event; a value that is only a placeholder keeps its type. */
export function expandPlaceholders(value, input) {
  const get = (dotted) => dotted.split(".").reduce((v, k) => (v == null ? undefined : v[k]), input);
  if (typeof value === "string") {
    const whole = /^\$\{([\w.]+)\}$/.exec(value);
    if (whole) return get(whole[1]) ?? "";
    return value.replace(/\$\{([\w.]+)\}/g, (_, p) => { const v = get(p); return v == null ? "" : typeof v === "string" ? v : JSON.stringify(v); });
  }
  if (Array.isArray(value)) return value.map((v) => expandPlaceholders(v, input));
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, expandPlaceholders(v, input)]));
  return value;
}

const mcpToolName = (server, tool) => `mcp__${String(server).replace(/[^A-Za-z0-9_]/g, "_")}__${String(tool).replace(/[^A-Za-z0-9_]/g, "_")}`;

export function hookName(handler) {
  if (handler.statusMessage) return String(handler.statusMessage);
  if (handler.type === "mcp_tool") return mcpToolName(handler.server, handler.tool);
  return String(handler.command ?? "").trim().split(/\s+/)[0] || "hook";
}

function timeoutFor(event, handler) {
  const asked = Number(handler.timeout);
  if (event === "SessionEnd") return Math.min(asked > 0 ? asked : 1, 3) * 1000;
  return Math.min(asked > 0 ? asked : 60, MAX_TIMEOUT_S) * 1000;
}

const clip = (text, n = 120) => { const s = String(text ?? "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n - 1) + "…" : s; };

/** One handler's raw result as the outcome docs/hooks.md defines. */
export function interpret(event, result) {
  const out = { failed: false, block: false, reason: "", permission: undefined, updatedInput: undefined, contexts: [], systemMessage: undefined, stop: false, stopReason: "" };
  if (result.exit === 2) {
    out.block = true;
    out.reason = result.stderr.trim() || "A hook blocked this.";
    if (event === "PreToolUse") out.permission = "deny";
    return out;
  }
  if (result.exit !== 0) { out.failed = true; return out; }
  const text = result.stdout.trim();
  let json;
  if (text.startsWith("{")) { try { json = JSON.parse(text); } catch {} }
  if (!json || typeof json !== "object") {
    if (text && (event === "SessionStart" || event === "UserPromptSubmit")) out.contexts.push(text);
    return out;
  }
  const specific = json.hookSpecificOutput && typeof json.hookSpecificOutput === "object" ? json.hookSpecificOutput : {};
  if (json.decision === "block") { out.block = true; out.reason = String(json.reason ?? "A hook blocked this."); }
  if (event === "PreToolUse") {
    const legacy = json.decision === "approve" ? "allow" : json.decision === "block" ? "deny" : undefined;
    const decision = ["allow", "deny", "ask"].includes(specific.permissionDecision) ? specific.permissionDecision : legacy;
    if (decision) { out.permission = decision; out.reason = String(specific.permissionDecisionReason ?? json.reason ?? out.reason ?? ""); }
    if (specific.updatedInput && typeof specific.updatedInput === "object") out.updatedInput = specific.updatedInput;
  }
  for (const context of [specific.additionalContext, json.additionalContext]) if (typeof context === "string" && context.trim()) out.contexts.push(context);
  if (typeof json.systemMessage === "string" && json.systemMessage.trim()) out.systemMessage = json.systemMessage;
  if (json.continue === false) { out.stop = true; out.stopReason = String(json.stopReason ?? ""); }
  return out;
}

/** Any deny wins over ask, ask over allow. */
export function mergePermission(decisions) {
  return ["deny", "ask", "allow"].find((d) => decisions.includes(d));
}

function contextText(name, event, context) {
  if (context.length <= CONTEXT_CAP) return `Hook context from ${name} (${event}):\n${context}`;
  const file = path.join(os.tmpdir(), `shepherd-hook-context-${crypto.randomUUID()}.md`);
  try { fs.writeFileSync(file, context, { mode: 0o600 }); } catch {}
  return `Hook context from ${name} (${event}) is ${context.length} characters, saved to ${file}. Read it.`;
}

// MARK: Extension

export default function shepherdHooks(pi) {
  const hooksDir = process.env.SHEPHERD_HOOKS_DIR;
  if (!hooksDir) return;
  // A project worker's dialogs reach its coordinator, not the person: no consent is asked there.
  const projectWorker = !!process.env.SHEPHERD_PROJECT_CONTEXT && process.env.SHEPHERD_PROJECT_COORDINATOR !== "1";
  const unattended = process.env.SHEPHERD_AUTOMATION === "1" || projectWorker;

  let root = undefined;
  let rootCwd = undefined;
  let ranThisRun = new Set();
  let stopStreak = 0;
  let running = 0;
  let shown = false;
  let lastCtx = undefined;
  const subagents = new Map();

  const rootFor = (cwd) => {
    if (rootCwd !== cwd) { rootCwd = cwd; root = spaceRoot(cwd); }
    return root;
  };

  const working = (ctx, text) => {
    try {
      ctx?.ui?.setWorkingMessage?.(text);
      ctx?.ui?.setStatus?.("shepherd.hook", text);
    } catch {}
  };

  const message = (kind, event, entry, { content, ...fields } = {}) => {
    const name = entry ? hookName(entry.handler) : "Hooks";
    const details = { kind, event, name, ...fields, ...(entry ? { hash: entry.hash, file: entry.file } : {}) };
    return { customType: "shepherd.hook", display: true, content: content ?? `${name} (${event})`, details };
  };
  const post = (rows, options = {}) => {
    for (const row of rows) {
      try { pi.sendMessage({ ...row, details: JSON.parse(JSON.stringify(row.details)) }, { triggerTurn: false, ...options }); } catch {}
    }
  };

  /**
   * Runs the hooks of one event that match `name`, concurrently, and merges what they say.
   * Returns the merged outcome and the rows to show; the caller posts them.
   */
  async function fire(event, ctx, extra = {}, { name, detail } = {}) {
    const merged = { block: false, reasons: [], permissions: [], updatedInput: undefined, contexts: [], stop: false, stopReason: "", rows: [], ran: 0 };
    let cwd;
    try {
      cwd = ctx?.cwd ?? process.cwd();
      const hooks = runnableHooks(rootFor(cwd), hooksDir).filter((h) => h.event === event && matcherMatches(h.matcher, name));
      if (!hooks.length) return merged;
      const input = {
        session_id: ctx?.sessionManager?.getSessionId?.() ?? "",
        transcript_path: ctx?.sessionManager?.getSessionFile?.() ?? "",
        cwd, hook_event_name: event, ...extra,
      };
      const workDir = rootFor(cwd);
      const status = hooks.map((h) => h.handler.statusMessage).find(Boolean);
      const awaited = [];
      for (const hook of hooks) {
        const handler = hook.handler;
        if (handler.type === "command" && typeof handler.command === "string") {
          const background = handler.async === true;
          // An aborted turn kills the hooks it waits on; a background hook outlives it.
          const run = runCommand(handler.command, { cwd: workDir, event, input, timeoutMs: timeoutFor(event, handler), background, signal: background ? undefined : ctx?.signal });
          if (handler.async === true) continue; // runs in the background; nothing waits for it or reads it
          awaited.push(run.then((result) => ({ hook, result })));
        } else if (handler.type === "mcp_tool" && handler.server && handler.tool) {
          awaited.push(runMCP(ctx, handler, input).then((result) => ({ hook, result })));
        }
        // prompt and agent handlers are listed but never run.
      }
      if (!awaited.length) return merged;
      running++;
      if (status) { shown = true; working(ctx, status); }
      let results;
      try { results = await Promise.all(awaited); }
      finally { if (--running === 0 && shown) { shown = false; working(ctx, undefined); } }
      for (const { hook, result } of results) {
        const outcome = interpret(event, result);
        const command = hook.handler.type === "mcp_tool" ? mcpToolName(hook.handler.server, hook.handler.tool) : hook.handler.command;
        const meta = `${clip(command, 80)} · ${result.timedOut ? "timed out" : result.exit === null ? "didn't start" : `exit ${result.exit}`} · ${result.ms} ms`;
        const rowDetail = [hook.matcher || undefined, detail].filter(Boolean).join(" · ") || undefined;
        if (outcome.failed) {
          merged.rows.push(message("failed", event, hook, { content: `A hook failed: ${hookName(hook.handler)} (${event})`, detail: rowDetail, meta,
            lines: (result.stderr || result.stdout).trim().split("\n").slice(-5).filter(Boolean) }));
          continue;
        }
        if (outcome.block) { merged.block = true; merged.reasons.push({ hook, reason: outcome.reason, meta, detail: rowDetail }); }
        if (outcome.permission) merged.permissions.push({ decision: outcome.permission, hook, reason: outcome.reason, meta, detail: rowDetail });
        if (outcome.updatedInput) merged.updatedInput = outcome.updatedInput;
        for (const context of outcome.contexts) {
          merged.contexts.push(context);
          merged.rows.push(message("context", event, hook, { content: contextText(hookName(hook.handler), event, context), detail: rowDetail, meta,
            lines: context.split("\n").slice(0, 5) }));
        }
        if (outcome.systemMessage) merged.rows.push(message("systemMessage", event, hook, { content: `${hookName(hook.handler)}: ${outcome.systemMessage}`, detail: rowDetail, meta, lines: [outcome.systemMessage] }));
        if (outcome.stop) { merged.stop = true; merged.stopReason = outcome.stopReason || merged.stopReason; }
        const visible = outcome.block || outcome.permission || outcome.updatedInput || outcome.contexts.length || outcome.systemMessage || outcome.stop;
        if (!visible) {
          merged.ran++;
          // Runs with no visible effect collapse into one row per event and agent run.
          if (!ranThisRun.has(event)) {
            ranThisRun.add(event);
            merged.rows.push(message("ran", event, hook, { content: `Hook ran: ${hookName(hook.handler)} (${event})`, detail: rowDetail, meta }));
          }
        }
      }
      if (merged.stop) merged.rows.push(message("systemMessage", event, null, { content: `A hook stopped the agent${merged.stopReason ? `: ${merged.stopReason}` : "."}`, lines: merged.stopReason ? [merged.stopReason] : [] }));
    } catch {
      // A broken hook setup never breaks the agent.
    }
    return merged;
  }

  async function runMCP(ctx, handler, input) {
    const started = Date.now();
    // ponytail: pi gives `executeTool` only to a tool's own context; an event handler's ctx lacks it,
    // so mcp_tool hooks fail visibly there until pi passes it to events.
    if (typeof ctx?.executeTool !== "function") {
      return { exit: null, stdout: "", stderr: "mcp_tool hooks need pi's executeTool, which this event doesn't offer", ms: 0, error: true };
    }
    try {
      let timer;
      const timeout = new Promise((resolve) => { timer = setTimeout(() => resolve("timeout"), timeoutFor(input.hook_event_name, handler)); timer.unref?.(); });
      const outcome = await Promise.race([ctx.executeTool(mcpToolName(handler.server, handler.tool), expandPlaceholders(handler.input ?? {}, input)), timeout]);
      clearTimeout(timer);
      if (outcome === "timeout") return { exit: null, stdout: "", stderr: "", ms: Date.now() - started, timedOut: true };
      const text = (outcome?.result?.content ?? []).filter((p) => p.type === "text").map((p) => p.text).join("\n").slice(0, OUTPUT_CAP);
      return outcome?.isError ? { exit: 1, stdout: "", stderr: text, ms: Date.now() - started } : { exit: 0, stdout: text, stderr: "", ms: Date.now() - started };
    } catch (error) {
      return { exit: null, stdout: "", stderr: String(error?.message ?? error), ms: Date.now() - started, error: true };
    }
  }

  /** A PreToolUse outcome as one verdict: any deny blocks; an ask asks the person (no one to answer: deny). Posts the rows. */
  async function permit(r, ctx, detail, call = detail) {
    const decision = mergePermission(r.permissions.map((p) => p.decision));
    if (decision === "deny") {
      const deny = r.permissions.find((p) => p.decision === "deny");
      post([...r.rows, message("denied", "PreToolUse", deny.hook, { content: `A hook denied ${detail}: ${deny.reason || "no reason given"}`, detail: deny.detail, meta: deny.meta, lines: deny.reason ? [deny.reason] : [] })]);
      return { block: true, reason: deny.reason || "A PreToolUse hook denied this call." };
    }
    if (decision === "ask") {
      const ask = r.permissions.find((p) => p.decision === "ask");
      const canAsk = ctx.hasUI && !unattended;
      let choice;
      if (canAsk) {
        // The whole call, never clipped: the person sees what they allow. The reason's blank lines fold so the parts stay apart.
        const reason = (ask.reason || "No reason given.").replace(/\n\s*\n/g, "\n");
        const title = `A hook asks before this runs\n\n${call}\n\n${reason}\n\n${ask.hook.file}`;
        choice = await ctx.ui.select(title, ["Deny", "Allow once"], { signal: ctx.signal });
      }
      const allowed = choice === "Allow once";
      post([...r.rows, message("asked", "PreToolUse", ask.hook, { content: `A hook asked before ${detail}: ${allowed ? "allowed once" : "denied"}`, detail: ask.detail, meta: ask.meta, lines: ask.reason ? [ask.reason] : [] })]);
      if (!allowed) return { block: true, reason: canAsk ? "The person denied this call after a hook asked." : "A hook asked for the person's approval and no one can answer here." };
      return { block: false };
    }
    post(r.rows);
    return { block: false };
  }

  const safe = (fn) => async (event, ctx) => { try { return await fn(event, ctx); } catch { return undefined; } };
  const toolCall = (toolName, input) => `${toolName} ${input?.path ?? input?.file_path ?? input?.command ?? input?.pattern ?? ""}`.trim();
  const toolDetail = (toolName, input) => clip(toolCall(toolName, input), 80);
  const claudeInput = (input) => (input && typeof input === "object" && typeof input.path === "string" && input.file_path === undefined ? { ...input, file_path: input.path } : input);

  // Shepherd's own rows reach the model only when they carry what the agent should read.
  pi.on("context", safe((event) => {
    if (!event.messages.some((m) => m.customType === "shepherd.hook")) return undefined;
    return { messages: event.messages.filter((m) => m.customType !== "shepherd.hook"
      || m.details?.kind === "context" || (m.details?.kind === "sentBack" && m.details?.event !== "PostToolUse")) };
  }));

  pi.on("session_start", safe(async (event, ctx) => {
    lastCtx = ctx;
    rootCwd = undefined;
    subagents.clear();
    if (event.reason !== "startup" && event.reason !== "resume") return;
    const r = await fire("SessionStart", ctx, { source: event.reason }, { name: event.reason });
    post(r.rows);
  }));

  pi.on("agent_start", safe(() => { ranThisRun = new Set(); }));

  pi.on("input", safe(async (event, ctx) => {
    if (event.source === "extension") return undefined;
    stopStreak = 0;
    const r = await fire("UserPromptSubmit", ctx, { prompt: event.text });
    if (r.block) {
      const { hook, reason, meta } = r.reasons[0];
      post([...r.rows.filter((row) => row.details.kind !== "context"),
        message("denied", "UserPromptSubmit", hook, { content: `A hook blocked this message: ${reason}`, lines: [reason], meta, detail: clip(event.text, 80) })]);
      return { action: "handled" };
    }
    post(r.stop ? r.rows.filter((row) => row.details.kind !== "context") : r.rows);
    return r.stop ? { action: "handled" } : undefined;
  }));

  pi.on("tool_call", safe(async (event, ctx) => {
    const name = event.toolName;
    const detail = toolDetail(name, event.input);
    const r = await fire("PreToolUse", ctx, { tool_name: PI_TO_CLAUDE[name] ?? name, tool_input: claudeInput(event.input), tool_use_id: event.toolCallId }, { name, detail });
    const verdict = await permit(r, ctx, detail, toolCall(name, event.input));
    if (verdict.block) return { block: true, reason: verdict.reason };
    if (r.updatedInput && event.input && typeof event.input === "object") {
      // Merged over the call's input; a Claude Code `file_path` goes back to the agent's `path`.
      const next = { ...r.updatedInput };
      if ("path" in event.input && !("file_path" in event.input) && "file_path" in next) {
        if (next.file_path !== event.input.path) next.path = next.file_path;
        delete next.file_path;
      }
      Object.assign(event.input, next);
    }
    if (r.stop) return { block: true, reason: r.stopReason || "A hook stopped the agent.", terminate: true };
    return undefined;
  }));

  pi.on("tool_result", safe(async (event, ctx) => {
    const name = event.toolName;
    const detail = toolDetail(name, event.input);
    const text = (event.content ?? []).filter((p) => p.type === "text").map((p) => p.text).join("\n");
    const r = await fire("PostToolUse", ctx, { tool_name: PI_TO_CLAUDE[name] ?? name, tool_input: claudeInput(event.input), tool_response: { content: text, isError: event.isError === true }, tool_use_id: event.toolCallId }, { name, detail });
    const rows = [...r.rows];
    let result;
    if (r.block) {
      const feedback = r.reasons.map(({ hook, reason }) => `PostToolUse hook ${hookName(hook.handler)}: ${reason}`).join("\n");
      for (const { hook, reason, meta, detail: d } of r.reasons) rows.push(message("sentBack", "PostToolUse", hook, { content: `A hook sent feedback on ${detail}: ${reason}`, detail: d, meta, lines: [reason] }));
      result = { content: [...(event.content ?? []), { type: "text", text: `\n\n${feedback}` }], ...(event.structuredContent !== undefined ? { structuredContent: event.structuredContent } : {}) };
    }
    post(rows);
    if (r.stop) ctx.abort?.();
    return result;
  }));

  pi.on("session_before_compact", safe(async (event, ctx) => {
    const trigger = event.reason === "manual" ? "manual" : "auto";
    post((await fire("PreCompact", ctx, { trigger, custom_instructions: event.customInstructions ?? "" }, { name: trigger })).rows);
    return undefined;
  }));

  pi.on("session_compact", safe(async (event, ctx) => {
    const trigger = event.reason === "manual" ? "manual" : "auto";
    post((await fire("PostCompact", ctx, { trigger }, { name: trigger })).rows);
    post((await fire("SessionStart", ctx, { source: "compact" }, { name: "compact" })).rows);
  }));

  pi.on("agent_before_settle", safe(async (event, ctx) => {
    if (event.outcome !== "completed" || event.continue || event.context?.canContinue === false) return undefined;
    const rowsAsEntries = (rows) => rows.map((row) => ({ type: "custom_message", ...row }));
    if (stopStreak >= STOP_SEND_BACK_LIMIT) {
      stopStreak = 0;
      return { entries: [...(event.entries ?? []), ...rowsAsEntries([message("systemMessage", "Stop", null, {
        content: `Stop hooks sent the agent back ${STOP_SEND_BACK_LIMIT} times in a row; it stops here.` })])] };
    }
    const r = await fire("Stop", ctx, { stop_hook_active: stopStreak > 0 });
    if (!r.block || r.stop) {
      stopStreak = 0;
      return r.rows.length ? { entries: [...(event.entries ?? []), ...rowsAsEntries(r.rows)] } : undefined;
    }
    stopStreak++;
    const sent = r.reasons.map(({ hook, reason, meta }) => message("sentBack", "Stop", hook, {
      content: `A Stop hook (${hookName(hook.handler)}) sent you back:\n${reason}`, meta, lines: [reason] }));
    return { entries: [...(event.entries ?? []), ...rowsAsEntries([...r.rows, ...sent])], continue: true };
  }));

  // Notification: the agent needs the person. Observable here: a question dialog opening (question),
  // a run ending in an error (failed), or one whose error reads as an auth failure (signed_out).
  const notify = (ctx, reason, text) => {
    void fire("Notification", ctx, { reason, message: text, notification_type: reason }, { name: reason }).then((r) => post(r.rows)).catch(() => {});
  };
  pi.on("ui_prompt_start", safe((event, ctx) => { notify(ctx, "question", String(event.title ?? "").split("\n")[0]); }));
  pi.on("agent_end", safe((event, ctx) => {
    const last = [...(event.messages ?? [])].reverse().find((m) => m.role === "assistant");
    if (last?.stopReason !== "error") return;
    const error = String(last.errorMessage ?? "");
    notify(ctx, /\b(401|unauthori[sz]ed|sign(ed)? ?(in|out)|log ?in|oauth|api key|credential|expired token)\b/i.test(error) ? "signed_out" : "failed", clip(error, 200));
  }));

  // SubagentStart / SubagentStop: the children extension's run list, diffed by run.
  pi.events?.on?.(CHILDREN_EVENT, (data) => {
    try {
      const ctx = lastCtx;
      if (!ctx || data?.owner !== ctx.sessionManager?.getSessionId?.() || !Array.isArray(data.children)) return;
      for (const run of data.children) {
        if (!run?.runID) continue;
        const live = run.state === "running" || run.state === "queued";
        const ended = ["complete", "failed", "stopped"].includes(run.state);
        const seen = subagents.get(run.runID);
        const input = { agent_id: run.runID, agent_type: run.role ?? "", task: run.task ?? "" };
        if (!seen && live) {
          subagents.set(run.runID, "live");
          void fire("SubagentStart", ctx, input, { name: run.role }).then((r) => post(r.rows)).catch(() => {});
        } else if (seen === "live" && ended) {
          subagents.set(run.runID, "ended");
          void fire("SubagentStop", ctx, { ...input, state: run.state, output: run.output ?? "", stop_hook_active: false }, { name: run.role }).then((r) => {
            const sent = r.reasons.map(({ hook, reason, meta }) => message("sentBack", "SubagentStop", hook, {
              content: `A SubagentStop hook (${hookName(hook.handler)}) on ${run.role}: ${reason}`, meta, lines: [reason] }));
            post([...r.rows, ...sent]);
          }).catch(() => {});
        }
      }
    } catch {}
  });

  pi.on("session_shutdown", safe(async (event, ctx) => {
    await fire("SessionEnd", ctx, { reason: event.reason });
    lastCtx = undefined;
    subagents.clear();
  }));

  // MARK: Proposals
  if (unattended || process.env.SHEPHERD_DESIGN_ID) return;
  const DEFER = process.env.SHEPHERD_DEFER_TOOLS === "1";
  pi.registerTool({
    name: "hook_propose",
    label: "Propose a hook",
    description: "Propose a hook (a command Shepherd runs at an agent event, e.g. after edits or on stop) for the person to add. "
      + "It's tested on a sample event, then they choose. If the request leaves the event open, ask one question first with ask_user.",
    ...(DEFER ? { exposure: "deferred", namespace: { name: "shepherd_hooks", description: "proposing hooks", instructions: "Propose a hook: a command run on agent events." } } : {}),
    parameters: Type.Object({
      name: Type.String({ minLength: 1, maxLength: 80 }),
      event: Type.String({ enum: EVENTS }),
      matcher: Type.Optional(Type.String({ maxLength: 200, description: "Regex on the tool name (Edit|Write) or source; omit for all" })),
      command: Type.String({ minLength: 1, maxLength: 4000 }),
      statusMessage: Type.Optional(Type.String({ maxLength: 120 })),
      timeout: Type.Optional(Type.Number({ minimum: 1, maximum: MAX_TIMEOUT_S })),
      scope: Type.Union([Type.Literal("space"), Type.Literal("mac")]),
      sample: Type.Optional(Type.Object({}, { additionalProperties: true, description: "Event JSON to test with" })),
    }),
    async execute(id, params, signal, _update, ctx) {
      return proposeHook(params, ctx, signal, id);
    },
  });

  async function proposeHook(params, ctx, signal, toolCallId) {
    const reply = (text, isError = false) => ({ content: [{ type: "text", text }], details: {}, ...(isError ? { isError: true } : {}) });
    const event = String(params?.event ?? "");
    const command = String(params?.command ?? "").trim();
    if (!EVENTS.includes(event) || !command) return reply("hook_propose needs a known event and a command.", true);
    if (!ctx.hasUI) return reply("No one can approve a hook here.", true);
    const matcher = typeof params.matcher === "string" ? params.matcher.trim() : "";
    const statusMessage = typeof params.statusMessage === "string" && params.statusMessage.trim() ? params.statusMessage.trim() : undefined;
    const timeout = Number.isFinite(params.timeout) && params.timeout > 0 ? Math.min(Math.round(params.timeout), MAX_TIMEOUT_S) : undefined;
    const projectRoot = rootFor(ctx.cwd);
    const scopes = { space: isSpace(projectRoot) ? spaceFile(projectRoot, ".shepherd/hooks.json") : null, mac: macFile(".shepherd/hooks.json") };

    // The test run: the given sample or a built-in one, on a scratch copy of the file it touches.
    const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "shepherd-hook-test-"));
    let test;
    try {
      const sample = sampleEvent(event, matcher, params.sample, scratch);
      const input = { session_id: ctx.sessionManager?.getSessionId?.() ?? "", transcript_path: ctx.sessionManager?.getSessionFile?.() ?? "", cwd: ctx.cwd, hook_event_name: event, ...sample };
      // The test is the agent's own bash call: the person's PreToolUse Bash hooks see it first.
      const bashDetail = clip(`bash ${command}`, 80);
      const gate = await fire("PreToolUse", ctx, { tool_name: "Bash", tool_input: { command }, tool_use_id: toolCallId ?? "" }, { name: "bash", detail: bashDetail });
      const verdict = await permit(gate, ctx, bashDetail, `bash ${command}`);
      if (verdict.block) {
        test = { ok: false, blocked: true, summary: `blocked by a PreToolUse hook: ${clip(verdict.reason)}`, exit: null, ms: 0 };
      } else {
        const result = await runCommand(command, { cwd: projectRoot, event, input, timeoutMs: Math.min(timeout ?? 60, 60) * 1000 });
        const ok = !result.timedOut && (result.exit === 0 || result.exit === 2);
        const said = (result.exit === 2 ? result.stderr : result.stdout || result.stderr).trim().split("\n")[0];
        const summary = result.timedOut ? "timed out" : result.exit === null ? `didn't start: ${clip(result.stderr)}`
          : `exit ${result.exit}${result.exit === 2 ? " (blocks)" : ""}${said ? `: ${clip(said)}` : ", no output"}`;
        test = { ok, summary, exit: result.exit, ms: result.ms };
      }
    } finally {
      try { fs.rmSync(scratch, { recursive: true, force: true }); } catch {}
    }

    const scope = params.scope === "space" && scopes.space ? "space" : "mac";
    const card = { name: String(params.name), event, matcher, command, statusMessage: statusMessage ?? null, timeout: timeout ?? null, scopes, scope, test };
    // "Added in Settings": the app saved an edited version from Edit… (written there); no button shows it.
    const options = [...(scopes.space ? ["Add to this space"] : []), "Add to this Mac", "Not now", EDITED];
    const choice = await ctx.ui.select(`${MARKER}\n${JSON.stringify(card)}`, options, { signal });
    const handler = { type: "command", command, ...(statusMessage ? { statusMessage } : {}), ...(timeout ? { timeout } : {}) };
    if (choice === EDITED) {
      post([message("added", event, { handler }, { content: `Hook added: ${hookName(handler)} (${event}), edited in Settings`, detail: "edited in Settings", meta: clip(command, 80) })]);
      return reply("The person added an edited version of the hook in Settings; it may differ from your proposal (event, matcher or command).");
    }
    if (choice !== "Add to this space" && choice !== "Add to this Mac") return reply(`The person didn't add the hook (test: ${test.summary}).`);
    const file = choice === "Add to this space" ? scopes.space : scopes.mac;
    let added;
    try {
      added = addHook(file, event, matcher, handler);
    } catch (error) {
      return reply(`Couldn't add the hook to ${file}: ${error?.message ?? error}`, true);
    }
    post([message("added", event, { handler, hash: added.hash, file }, { content: `Hook added: ${hookName(handler)} (${event}) in ${file}`, detail: matcher || undefined, meta: clip(command, 80) })]);
    return reply(`Added to ${file}; it runs on ${event}${matcher ? ` for ${matcher}` : ""} from now on.`);
  }

  /** Appends one group to the file (other content kept, written whole and atomically); returns its hash. */
  function addHook(file, event, matcher, handler) {
    let doc = {};
    if (fs.existsSync(file)) {
      doc = JSON.parse(fs.readFileSync(file, "utf8"));
      if (!doc || typeof doc !== "object" || Array.isArray(doc)) throw new Error("the file isn't a JSON object");
    }
    if (!doc.hooks || typeof doc.hooks !== "object" || Array.isArray(doc.hooks)) doc.hooks = {};
    if (!Array.isArray(doc.hooks[event])) doc.hooks[event] = [];
    doc.hooks[event].push({ ...(matcher ? { matcher } : {}), hooks: [handler] });
    writeAtomic(file, JSON.stringify(doc, null, 2) + "\n");
    return { hash: hookHash(file, event, matcher, handler) };
  }
}

/** The event a proposal is tested on: the model's sample, else a built-in one. A file it names is copied to scratch first. */
export function sampleEvent(event, matcher, given, scratch) {
  let sample = given && typeof given === "object" ? JSON.parse(JSON.stringify(given)) : undefined;
  if (!sample) {
    const first = (matcher.split("|")[0] || "").trim();
    const tool = /^\w+$/.test(first) ? first : "Bash";
    const piName = CLAUDE_TO_PI[tool] ?? tool;
    switch (event) {
      case "PreToolUse": case "PostToolUse": case "PermissionRequest":
      {
        // pi's own input names, with Claude Code's file_path mirrored, as a real call's stdin has them.
        const file = path.join(scratch, "sample.txt");
        const fileInput = { edit: { path: file, edits: [{ oldText: "hello", newText: "hello, world" }] }, write: { path: file, content: "hello\n" }, read: { path: file } }[piName];
        sample = fileInput ? { tool_name: tool, tool_input: { ...fileInput, file_path: file } }
          : { tool_name: tool, tool_input: piName === "bash" ? { command: "echo hello" } : {} };
        if (event === "PostToolUse") sample.tool_response = { content: "", isError: false };
        if (fileInput) fs.writeFileSync(file, "hello\n");
        return sample;
      }
      case "UserPromptSubmit": return { prompt: "Hello" };
      case "SessionStart": return { source: "startup" };
      case "PreCompact": case "PostCompact": return { trigger: "manual" };
      case "Stop": return { stop_hook_active: false };
      case "SubagentStart": case "SubagentStop": return { agent_id: "sample", agent_type: first || "worker" };
      case "Notification": return { reason: "question", message: "The agent needs you" };
      case "SessionEnd": return { reason: "quit" };
      default: return {};
    }
  }
  const input = sample.tool_input;
  const target = input && typeof input === "object" ? (input.file_path ?? input.path) : undefined;
  if (typeof target === "string") {
    const copy = path.join(scratch, path.basename(target) || "sample");
    try { fs.copyFileSync(target, copy); } catch { fs.writeFileSync(copy, ""); }
    input.path = copy;
    input.file_path = copy;
  }
  return sample;
}
