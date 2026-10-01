// @ts-nocheck -- loaded by pi/jiti; no separate Node workspace is required.
// Execution belongs to this extension. shepherd-subagents.ts is the only setAgentChildren publisher.
import { spawn, execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";
import { randomUUID } from "node:crypto";
import { StringDecoder } from "node:string_decoder";
import { SessionManager, createBashTool, getPackageDir, resolveCliModel } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { bundledAgents as ROLES, childDefaults, discoverChildAgents, childSkills, childTargetContext, defaultChildTools, childUserExtensions, thinkingLevels } from "./shepherd-children-config.ts";
import { executeWorkflow } from "./shepherd-workflow.ts";
import { missionStore } from "./shepherd-missions.ts";
import { registerNativeCommands } from "./shepherd-children-ui.ts";
import { StringEnum, validateToolArguments } from "@earendil-works/pi-ai";

const EVENT = "shepherd:children:v1";
const MAX_RUNS = 64;
const MAX_TEXT = 16 * 1024;
const MAX_FRAME = 8 * 1024 * 1024;
const clip = (text, limit = MAX_TEXT) => {
  const value = String(text ?? "");
  return Buffer.byteLength(value) <= limit ? value : Buffer.from(value).subarray(0, limit).toString("utf8").replace(/\uFFFD$/, "");
};
// A question's sidebar reason ("retention?"): one line, or undefined when not given.
const shortReason = (value) => typeof value === "string" && value.trim() ? clip(value.trim().replace(/\s+/g, " "), 120) : undefined;
const result = (data) => ({ content: [{ type: "text", text: JSON.stringify(data) }], details: data });
// Same rule as the desktop tool row preview: an obvious action field first, then the first result line.
export function toolPreview(args, resultText) {
  const first = (value) => typeof value === "string" && value.trim() ? value.split("\n")[0].slice(0, 120) : undefined;
  return first(args?.path) ?? first(args?.command) ?? first(args?.pattern) ?? first(args?.url) ?? first(args?.query)
    ?? first((resultText ?? "").split("\n").find((line) => line.trim()));
}
// Multiset line difference per edit, so moved lines cancel (mirrors NativeDiffStat).
export function editDiff(args) {
  const edits = Array.isArray(args?.edits) ? args.edits : typeof args?.oldText === "string" && typeof args?.newText === "string" ? [args] : [];
  let added = 0, removed = 0;
  for (const edit of edits) {
    if (typeof edit?.oldText !== "string" || typeof edit?.newText !== "string") continue;
    const counts = new Map();
    for (const line of edit.oldText ? edit.oldText.split("\n") : []) counts.set(line, (counts.get(line) ?? 0) + 1);
    for (const line of edit.newText ? edit.newText.split("\n") : []) counts.set(line, (counts.get(line) ?? 0) - 1);
    for (const value of counts.values()) { if (value > 0) removed += value; else added -= value; }
  }
  return edits.length ? { added, removed } : undefined;
}
// First two sentences of a child's final output, ≤ 240 chars, for the ledger row and RESULT block.
export function summarize(text, limit = 240) {
  const flat = String(text ?? "").replace(/\s+/g, " ").trim();
  if (!flat) return undefined;
  // A sentence ends at punctuation followed by space or the end, so "View.swift" or "v1.2" stay whole.
  const sentences = flat.match(/.+?[.!?]+(?=\s|$)|.+$/g) ?? [flat];
  const out = sentences.slice(0, 2).map((s) => s.trim()).join(" ");
  return out.length > limit ? out.slice(0, limit - 1).trimEnd() + "…" : out;
}
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code !== "ESRCH"; } };
const signalPID = (pid, signal) => { try { process.kill(pid, signal); } catch (e) { if (e.code !== "ESRCH") throw e; } };

// Only descendants of the supplied live process, never its shared PTY group.
export function descendants(pid) {
  const rows = execFileSync("/bin/ps", ["-axo", "pid=,ppid="], { encoding: "utf8", timeout: 2000, maxBuffer: 4 * 1024 * 1024 })
    .trim().split("\n").map((line) => line.trim().split(/\s+/).map(Number));
  const owned = new Set([pid]);
  for (let changed = true; changed;) {
    changed = false;
    for (const [child, parent] of rows) if (owned.has(parent) && !owned.has(child)) { owned.add(child); changed = true; }
  }
  return [...owned].reverse();
}

export function jsonLines(onEvent, onError) {
  const decoder = new StringDecoder("utf8");
  let buffer = "", failed = false;
  return (chunk) => {
    if (failed) return;
    buffer += decoder.write(chunk);
    for (;;) {
      const end = buffer.indexOf("\n");
      if (end < 0) break;
      if (Buffer.byteLength(buffer.slice(0, end)) > MAX_FRAME) { failed = true; buffer = ""; onError(new Error("RPC frame exceeds 8 MiB")); return; }
      const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      if (!line.trim()) continue;
      try { onEvent(JSON.parse(line)); }
      catch (error) { failed = true; buffer = ""; onError(error); return; }
    }
    if (Buffer.byteLength(buffer) > MAX_FRAME) { failed = true; buffer = ""; onError(new Error("RPC frame exceeds 8 MiB")); }
  };
}

function atomic(file, data) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data), { mode: 0o600 });
  fs.renameSync(tmp, file);
}

// A fork is the active branch through the last complete tool batch. In-flight
// tool calls and their partial results are omitted, including the spawning call.
export function forkSession(manager, cwd, file) {
  const branch = structuredClone(manager.getBranch());
  let cut = branch.length;
  const pending = new Map();
  for (let i = 0; i < branch.length; i++) {
    const message = branch[i].message;
    if (message?.role === "assistant") {
      for (const item of message.content ?? []) if (item.type === "toolCall") pending.set(item.id, i);
    } else if (message?.role === "toolResult") pending.delete(message.toolCallId);
  }
  if (pending.size) cut = Math.min(...pending.values());
  const entries = branch.slice(0, cut);
  const snapshot = SessionManager.inMemory(cwd, { parentSession: manager.getSessionFile() }, entries);
  if (entries.length) snapshot.createBranchedSession(entries.at(-1).id);
  // Serialize the supported manager's extracted branch, not a raw parent file.
  const header = { ...snapshot.getHeader(), cwd, parentSession: manager.getSessionFile() };
  fs.writeFileSync(file, [header, ...snapshot.getEntries()].map((e) => JSON.stringify(e)).join("\n") + "\n", { mode: 0o600 });
  return { omittedInFlight: branch.length - cut };
}

// Pi's default bash backend detaches its process group. Keep normal commands in
// Shepherd's PTY group so hard app shutdown also kills shell-tool descendants.
// createBashTool still owns schema, rendering, output truncation, and diagnostics.
export function childBashOperations() {
  return {
    async exec(command, cwd, { onData, signal, timeout, env }) {
      signal?.throwIfAborted();
      if (timeout !== undefined && (!Number.isFinite(timeout) || timeout <= 0 || timeout > 2147483.647)) throw new Error("Invalid bash timeout");
      const proc = spawn("/bin/bash", ["-c", 'trap \'wait\' EXIT\neval "$1"', "shepherd-bash", command], { cwd, env, detached: false, stdio: ["ignore", "pipe", "pipe"] });
      let timedOut = false;
      const stop = () => {
        if (proc.exitCode !== null || proc.signalCode !== null || !proc.pid) return;
        try { for (const pid of descendants(proc.pid)) signalPID(pid, "SIGKILL"); }
        catch { proc.kill("SIGKILL"); }
      };
      const timer = timeout === undefined ? undefined : setTimeout(() => { timedOut = true; stop(); }, timeout * 1000);
      signal?.addEventListener("abort", stop, { once: true });
      proc.stdout.on("data", onData); proc.stderr.on("data", onData);
      try {
        const exitCode = await new Promise((resolve, reject) => {
          proc.once("error", reject);
          proc.once("close", resolve);
        });
        signal?.throwIfAborted();
        if (timedOut) throw new Error(`timeout:${timeout}`);
        return { exitCode };
      } finally {
        clearTimeout(timer); signal?.removeEventListener("abort", stop);
        proc.stdout.destroy(); proc.stderr.destroy();
      }
    },
  };
}

const textSchema = Type.String({ minLength: 1, maxLength: MAX_TEXT });
const idSchema = Type.String({ minLength: 1, maxLength: 80 });

// The managed CLIProxyAPI provider (docs/pi-home.md) is loaded by Shepherd's launcher, `<home>/bin/pi`,
// which passes `-e <home>/shepherd-cliproxyapi.ts` and pins `SHEPHERD_CLIPROXYAPI_CONFIG`, the
// connection file beside it. A helper isn't started through the launcher, so it gets both here from the
// parent's pinned path, and only while both files exist: with no connection it is launched as it
// always was, and a launch never fails on a missing extension file.
export function managedProvider(env = process.env) {
  const config = env.SHEPHERD_CLIPROXYAPI_CONFIG;
  if (!config || !path.isAbsolute(config)) return undefined;
  const extension = path.join(path.dirname(config), "shepherd-cliproxyapi.ts");
  try { return fs.statSync(extension).isFile() && fs.statSync(config).isFile() ? { extension, config } : undefined; }
  catch { return undefined; }
}

// What a helper is started with: its arguments and its environment, built from the parent's.
// Pure (it reads files only to name them), so a test can pin exactly which `-e` and which
// SHEPHERD_* variables a helper gets. `inherited` are the user's enabled extensions, `relay` the
// design tools its bridge proxies to the parent (relaySpecs).
export function childLaunch({ run, bridge, inherited = [], parentEnv = process.env, relay = [] }) {
  const env = { ...parentEnv };
  // A helper is cut off from the host: none of the parent's SHEPHERD_* reaches it (its agent id,
  // socket and design are the parent's alone), nor the parent's session or model variables.
  for (const key of Object.keys(env)) if (key.startsWith("SHEPHERD_") || key.startsWith("PI_SUBAGENT") || ["PI_SESSION_ID", "PI_SESSION_FILE", "PI_PROVIDER", "PI_MODEL", "PI_REASONING_LEVEL"].includes(key)) delete env[key];
  env.SHEPHERD_CHILD = "1"; env.PI_OFFLINE = "1";
  env.SHEPHERD_CHILD_TOOLS = JSON.stringify([...run.tools, "shepherd_parent_message"]);
  if (relay.length) env.SHEPHERD_CHILD_RELAY = JSON.stringify(relay);
  const args = ["--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-approve",
    "-e", bridge, "--session", run.sessionFile, "--model", run.model, "--thinking", run.thinking,
    "--tools", [...run.tools, "shepherd_parent_message"].join(","),
    run.systemPromptMode === "replace" ? "--system-prompt" : "--append-system-prompt", path.join(run.dir, "prompt.md")];
  if (run.inheritProjectContext === false) args.push("--no-context-files");
  for (const skill of run.skills ?? []) args.push("--skill", skill);
  const loaded = new Set([fs.realpathSync(bridge)]);
  const load = (extension) => {
    const real = fs.realpathSync(extension);
    if (loaded.has(real)) return;
    loaded.add(real); args.push("-e", extension);
  };
  // Resolved at each launch, including resume, so Pi resource enable/disable changes apply.
  // Other providers come from the user's extensions (Pi loads those under --no-extensions when
  // named); the managed one is Shepherd's own and comes from its home.
  const managed = managedProvider(parentEnv);
  if (managed) { load(managed.extension); env.SHEPHERD_CLIPROXYAPI_CONFIG = managed.config; }
  for (const extension of new Set([...inherited, ...(run.extensions ?? [])])) load(extension);
  return { args, env };
}

// ---- Errors that say what to do ----

const nameTokens = (name) => new Set(String(name).toLowerCase().split(/[^a-z0-9]+/).filter(Boolean));
const within = (a, b) => [...a].every((token) => b.has(token));

// A role or profile that isn't one thing: every name that would work, and the nearest to what was passed.
export function unknownAgentMessage(name, agents, matches = []) {
  if (matches.length > 1) {
    return `Ambiguous agent "${name}": it names ${matches.map((a) => `${a.name} (${a.source}${a.filePath ? `, ${a.filePath}` : ""})`).join(" and ")}. Pass one profile's full name.`;
  }
  const roles = agents.filter((a) => a.source === "bundled").map((a) => a.name);
  const profiles = agents.filter((a) => a.source !== "bundled").map((a) => a.name);
  const wanted = nameTokens(name);
  const close = agents.map((a) => a.name).filter((other) => { const tokens = nameTokens(other); return within(wanted, tokens) || within(tokens, wanted); }).slice(0, 3);
  return `Unknown agent "${name}". Roles: ${roles.join(", ") || "none (Shepherd's bundled roles are disabled)"}. `
    + `Profiles: ${profiles.join(", ") || "none discovered"}. `
    + (close.length ? `Did you mean ${close.join(" or ")}? ` : "")
    + "Pass one of them as agent (role is an alias); shepherd_child_agents lists each with its source.";
}

// A helper whose pi died before it served says why on stderr (finish() returns that to the pending
// command). When it refused a `--model` the parent could resolve, this says what that means: the helper
// doesn't load that provider.
export function missingProviderHint(model, message) {
  return /Model ".*" not found/.test(String(message ?? ""))
    ? ` ${model} resolves in this Pi, so its provider is one the helper doesn't load: a helper loads Shepherd's managed provider, the user's enabled extensions and a profile's own extensions, not a project's or another CLI-only one.`
    : "";
}

const THINKING_SUFFIX = /:(off|minimal|low|medium|high|xhigh|max)$/;

// A model the Pi that would run it can't see: which provider prefixes it does have, where the same
// id does exist, and (for the old `cpa` provider) what replaced it. `models` is that Pi's catalog.
export function modelNotFound(requested, models, { origin, where = "this Pi" } = {}) {
  const named = String(requested).replace(THINKING_SUFFIX, "");
  const providers = [...new Set(models.map((model) => model.provider))].sort();
  const slash = named.indexOf("/");
  const provider = slash > 0 ? named.slice(0, slash) : undefined, id = slash > 0 ? named.slice(slash + 1) : named;
  const shown = providers.length > 24 ? `${providers.slice(0, 24).join(", ")} and ${providers.length - 24} more` : providers.join(", ") || "none";
  const said = (problem) => origin ? `${origin} names ${requested}, but ${problem}.` : `${problem[0].toUpperCase()}${problem.slice(1)}.`;
  const parts = [];
  if (provider && !providers.includes(provider)) {
    parts.push(said(`provider "${provider}" isn't loaded in ${where}`));
    const elsewhere = models.filter((model) => model.id === id).map((model) => `${model.provider}/${model.id}`).slice(0, 3);
    if (elsewhere.length) parts.push(`Did you mean ${elsewhere.join(" or ")}?`);
    if (provider === "cpa") parts.push("\"cpa\" was the provider of the old pi-cliproxyapi-provider package, which Shepherd's pi doesn't load; its managed provider is \"cliproxyapi\" (Settings ▸ Pi ▸ Sign-in).");
  } else if (provider) {
    const first = id.toLowerCase().split(/[^a-z0-9]+/)[0] ?? "";
    const similar = models.filter((model) => model.provider === provider && first && model.id.toLowerCase().includes(first)).map((model) => model.id).slice(0, 5);
    parts.push(said(`provider "${provider}" has no model "${id}" in ${where}`));
    if (similar.length) parts.push(`Its models that look like it: ${similar.join(", ")}.`);
  } else {
    parts.push(said(`no provider of ${where} lists "${requested}"; name a model as provider/id`));
  }
  parts.push(`Providers ${where} has: ${shown}.`);
  return parts.join(" ");
}

// ---- A design agent's helpers: its design tools, through their parent ----
//
// A helper has none of its parent's identity (every SHEPHERD_* variable is stripped), and Shepherd serves
// a design message only on a connection the design agent's own pi opened, so a helper can't call the
// design tools itself. The parent's pi can, and this extension runs in it, beside shepherd-design.ts, which
// publishes its tools on `globalThis[RELAY_KEY]` (only a design agent's pi does, and only the tools in
// DESIGN_RELAYED). A helper whose profile lists some in `tools:` gets a proxy for each, registered by its
// bridge; a call goes up the channel a helper already has to its parent (an `input` request on its RPC
// stdout, answered on its stdin) and runs here, through the design extension's own tool, on its connection.
// The parent holds the allowlist: a call for a tool the profile didn't list is refused.

const RELAY_KEY = Symbol.for("shepherd.design.relay.v1");
// The design tools a helper may use. comment_reply and markup_propose are the design agent's own voice
// toward the viewer (it answers a comment once every helper has finished), and checkpoint_restore rewinds
// every board, siblings' work included, so none of the three is ever relayed.
const DESIGN_RELAYED = [
  "design_read", "design_check", "system_read", "comment_list", "board_write", "board_edit", "boards_edit", "board_search",
  "board_render", "board_extract", "checkpoint_create", "checkpoint_list", "canvas_update", "system_write",
];
const DESIGN_TOOLS = [...DESIGN_RELAYED, "comment_reply", "markup_propose", "checkpoint_restore"];
const RELAY_TITLE = "shepherd-relay:v1:";
// A request or a result: the extension socket's own frame cap, since a board is at most 900,000 bytes.
const MAX_RELAY_BYTES = 1024 * 1024;
const MAX_RELAY_CALLS = 8;
const RELAY_TIMEOUT_MS = 120_000;

// The registry a live design agent's pi published, for its own design; else nothing.
export function designRelay(env = process.env) {
  const relay = globalThis[RELAY_KEY];
  return relay && relay.active?.() === true && typeof relay.designID === "string" && relay.designID === env.SHEPHERD_DESIGN_ID ? relay : undefined;
}

// Why a profile's design tools can't be given to a helper, or undefined when they can.
export function designToolsProblem(names, relay) {
  if (!relay) return `${names.join(", ")}: design tools are relayed only to the helpers of a design agent, and this session draws no design. Drop them from the profile's tools.`;
  const own = names.filter((name) => !DESIGN_RELAYED.includes(name));
  if (own.length) return `${own.join(", ")} can't be relayed to a helper: the design agent answers the viewer's comments, proposes their markup and restores checkpoints itself, once its helpers are done. Relayed: ${DESIGN_RELAYED.join(", ")}.`;
  const absent = names.filter((name) => !relay.tools.has(name));
  if (absent.length) return `${absent.join(", ")} isn't available from this design agent's extension.`;
  return undefined;
}

// What a helper's bridge registers for each relayed tool: its name and schema, as JSON (no function crosses).
export function relaySpecs(names, relay) {
  return names.map((name) => {
    const tool = relay.tools.get(name);
    return { name, label: tool.label ?? name, promptSnippet: tool.promptSnippet,
      description: `${tool.description} (Relayed: your parent draws this design and runs the call for you.)`,
      parameters: JSON.parse(JSON.stringify(tool.parameters)) };
  });
}

// The helper's side of a relayed call: one `input` request to the parent, answered with the tool's result.
export async function relayedCall(tool, params, signal, ctx) {
  signal?.throwIfAborted();
  const callId = randomUUID();
  const payload = JSON.stringify({ tool, params });
  if (Buffer.byteLength(payload) > MAX_RELAY_BYTES) throw new Error(`${tool}: the call is larger than the ${MAX_RELAY_BYTES} byte relay limit; send less at once`);
  if (typeof ctx?.ui?.input !== "function") throw new Error(`${tool}: this helper has no channel to its parent`);
  const answer = await ctx.ui.input(RELAY_TITLE + callId, payload, { signal, timeout: RELAY_TIMEOUT_MS });
  if (typeof answer !== "string") {
    // Cancelled or timed out: tell the parent, which is running the call, to drop it.
    try { ctx.ui.notify(JSON.stringify({ shepherdRelayCancel: callId }), "info"); } catch { /* The parent drops it when this helper exits. */ }
    signal?.throwIfAborted();
    throw new Error(`${tool}: the parent did not answer within ${RELAY_TIMEOUT_MS / 1000} seconds`);
  }
  let reply;
  try { reply = JSON.parse(answer); } catch { throw new Error(`${tool}: the parent's answer was not understood`); }
  if (!reply?.ok) throw new Error(typeof reply?.error === "string" ? reply.error : `${tool} failed`);
  return { content: Array.isArray(reply.content) ? reply.content : [], details: reply.details };
}

function registerRelayTools(pi) {
  let specs;
  try { specs = JSON.parse(process.env.SHEPHERD_CHILD_RELAY); } catch { return; }
  for (const spec of Array.isArray(specs) ? specs : []) {
    // The helper registers only names the parent may relay, whatever its environment says.
    if (typeof spec?.name !== "string" || !DESIGN_RELAYED.includes(spec.name) || !spec.parameters || typeof spec.parameters !== "object") continue;
    pi.registerTool({ name: spec.name, label: String(spec.label ?? spec.name), description: String(spec.description ?? spec.name),
      promptSnippet: typeof spec.promptSnippet === "string" ? spec.promptSnippet : undefined, parameters: spec.parameters,
      async execute(_id, params, signal, _update, ctx) { return relayedCall(spec.name, params, signal, ctx); } });
  }
}

// The parent's side: serves one relayed call (a helper's `input` request) and answers it on the helper's
// stdin. `run.relayTools` is what the helper's profile listed, `run.relays` its calls in flight; a call
// for anything else, past the cap, or once the session draws no design is refused. Never throws.
export async function serveRelay(run, event, { relay, ctx, answer }) {
  const reply = (value) => { try { answer(JSON.stringify(value)); } catch { /* The helper is gone. */ } };
  const fail = (error) => reply({ ok: false, error });
  run.relays ??= new Map();
  const callId = String(event.title).slice(RELAY_TITLE.length);
  if (!/^[\w-]{1,64}$/.test(callId) || run.relays.has(callId)) return fail("invalid or repeated relay call id");
  const payload = typeof event.placeholder === "string" ? event.placeholder : "";
  if (Buffer.byteLength(payload) > MAX_RELAY_BYTES) return fail(`the call is larger than the ${MAX_RELAY_BYTES} byte relay limit; send less at once`);
  let request;
  try { request = JSON.parse(payload); } catch { return fail("the relayed call is not JSON"); }
  const name = request?.tool;
  if (typeof name !== "string" || !(run.relayTools ?? []).includes(name) || !DESIGN_RELAYED.includes(name)) {
    return fail(`${typeof name === "string" ? name : "that tool"} is not relayed to this helper (its profile's design tools: ${(run.relayTools ?? []).join(", ") || "none"})`);
  }
  const tool = relay?.tools.get(name);
  if (!tool) return fail("this session no longer draws a design, so its design tools can't be relayed");
  if (run.relays.size >= MAX_RELAY_CALLS) return fail(`${MAX_RELAY_CALLS} design calls are already in flight for this helper; wait for one to finish`);
  const controller = new AbortController();
  run.relays.set(callId, controller);
  try {
    const params = validateToolArguments({ name, parameters: tool.parameters }, { id: callId, name, arguments: request.params ?? {} });
    const result = await tool.execute(`relay-${run.id}-${callId}`, params, controller.signal, undefined, ctx);
    // A cancelled call has no one left to answer.
    if (controller.signal.aborted) return;
    // Text, and a picture (board_render) as long as it is a small base64 image: nothing else crosses.
    const content = (result?.content ?? []).flatMap((part) => {
      if (part?.type === "text") return [{ type: "text", text: String(part.text ?? "") }];
      if (part?.type === "image" && typeof part.data === "string" && typeof part.mimeType === "string" && /^image\/(png|jpeg)$/.test(part.mimeType)) {
        return [{ type: "image", data: part.data, mimeType: part.mimeType }];
      }
      return [];
    });
    const size = content.reduce((total, part) => total + Buffer.byteLength(part.type === "text" ? part.text : part.data), 0);
    if (size > MAX_RELAY_BYTES) return fail(`${name}'s result is ${size} bytes; the relay carries at most ${MAX_RELAY_BYTES}`);
    reply({ ok: true, content, details: result?.details });
  } catch (error) {
    if (!controller.signal.aborted) fail(clip(error?.message ?? String(error), 4000));
  } finally { run.relays.delete(callId); }
}

// A helper cancelled a call of its own (its tool call was aborted, or the parent never answered): the
// notice it sends names the call, and the parent drops it. Anything else is not one, and is ignored.
export function relayCancel(run, message) {
  try {
    const data = JSON.parse(message);
    if (typeof data?.shepherdRelayCancel !== "string") return false;
    run.relays?.get(data.shepherdRelayCancel)?.abort();
    return true;
  } catch { return false; }
}

// Drops every call a helper has in flight: it was stopped, it exited, or the session ended.
function abortRelays(run) {
  for (const controller of run.relays?.values() ?? []) controller.abort();
  run.relays?.clear();
}

// `timers` lets tests observe the control tick; pi passes only `pi`.
export default function shepherdChildren(pi, timers = { setInterval, clearInterval }) {
  if (process.env.SHEPHERD_CHILD === "1") {
    // Cooperative pause at the next model-request boundary. In-flight tools finish normally;
    // the RPC reader remains available for continue/cancel while the context hook waits.
    let paused = false, releasePause;
    const continueRun = () => { paused = false; releasePause?.(); releasePause = undefined; };
    pi.registerCommand("shepherd-child-pause", { description: "Pause before the next model request", handler: async () => { paused = true; } });
    pi.registerCommand("shepherd-child-continue", { description: "Continue a paused child", handler: async () => { continueRun(); } });
    pi.on("context", async (_event, ctx) => {
      if (!paused) return;
      await new Promise((resolve) => {
        const done = () => { ctx.signal?.removeEventListener("abort", done); resolve(); };
        releasePause = done;
        if (ctx.signal?.aborted) done(); else ctx.signal?.addEventListener("abort", done, { once: true });
      });
    });
    pi.on("session_shutdown", continueRun);
    pi.registerTool(createBashTool(process.cwd(), { operations: childBashOperations() }));
    if (process.env.SHEPHERD_CHILD_RELAY) registerRelayTools(pi);
    if (process.env.SHEPHERD_CHILD_TOOLS) {
      const allowed = new Set(JSON.parse(process.env.SHEPHERD_CHILD_TOOLS));
      pi.on("tool_call", (event) => allowed.has(event.toolName) ? undefined : { block: true, reason: "Tool exceeds the parent child allowlist" });
      const constrainTools = () => {
        const selected = pi.getActiveTools().filter((name) => allowed.has(name));
        pi.setActiveTools(selected);
        return selected;
      };
      pi.on("session_start", (_event, ctx) => ctx.ui.notify(JSON.stringify({ shepherdChildTools: constrainTools() }), "info"));
      pi.on("before_agent_start", () => { constrainTools(); });
    }
    pi.registerTool({
      name: "shepherd_parent_message", label: "message parent",
      description: "Update your child record with progress without interrupting the parent. For a blocking question, set needsReply and finish this turn; the parent is notified and can resume with an answer. Your final answer is delivered automatically; do not also send it here.",
      parameters: Type.Object({ message: textSchema, needsReply: Type.Optional(Type.Boolean()), options: Type.Optional(Type.Array(Type.String({ minLength: 1, maxLength: 200 }), { maxItems: 6 })),
        short: Type.Optional(Type.String({ description: "For a question: what you need in 1-3 words, shown beside your parent's thread in Shepherd's sidebar while you wait (e.g. \"retention?\", \"approve plan\")." })) }),
      async execute(_id, params) { return result({ shepherdParentMessage: params.message, needsReply: params.needsReply === true, options: params.needsReply === true ? params.options : undefined, short: params.needsReply === true ? shortReason(params.short) : undefined }); },
    });
    return;
  }
  if (process.env.SHEPHERD_NATIVE_CHILDREN !== "1" || !process.env.SHEPHERD_AGENT_ID || !process.env.SHEPHERD_SOCKET) return;

  const runs = new Map(), workflows = new Map();
  const defaults = childDefaults();
  let missions;
  let owner, active = false, timer, sessionContext;
  // Inspector requests to settled runs, while no tick runs: run id -> watcher of its control dir.
  const controlWatchers = new Map();
  const root = path.join(path.dirname(process.env.SHEPHERD_SOCKET), "children");
  const bridge = process.env.SHEPHERD_EXT_CHILDREN;
  let supported = false;
  try {
    const version = JSON.parse(fs.readFileSync(path.join(getPackageDir(), "package.json"), "utf8")).version.split(".").map(Number);
    supported = version[0] > 0 || version[1] > 85 || (version[1] === 85 && version[2] >= 1);
  } catch { /* Unknown distributions must establish the supported Pi version. */ }
  const current = (run) => active && run.owner === owner;
  // Per-path edit/write totals in first-touched order, capped at 32 entries.
  const fileChanges = (run) => [...(run.files ?? new Map())].slice(0, 32).map(([path, diff]) => ({ path, ...diff }));
  // The child's pi session id from its JSONL header (first line only; cached once read).
  const sessionID = (run) => {
    if (run.sessionID) return run.sessionID;
    let fd; try {
      fd = fs.openSync(run.sessionFile, "r"); const head = Buffer.alloc(4096); const n = fs.readSync(fd, head, 0, 4096, 0);
      const line = head.subarray(0, n).toString("utf8").split("\n")[0];
      if (line) run.sessionID = JSON.parse(line).id;
    } catch { /* No header yet; the card publishes without it. */ } finally { if (fd !== undefined) fs.closeSync(fd); }
    return run.sessionID;
  };
  const summary = (run) => ({ id: run.id, role: run.role, state: run.state, task: run.task, startedAt: run.startedAt, endedAt: run.endedAt, currentTool: run.currentTool, latestTool: run.latestTool, model: run.model, cwd: run.cwd,
    workflowId: run.workflowId, delivery: run.delivery ?? "continue", settled: run.settled, missionId: run.missionId, missionWarning: run.missionWarning, thinking: run.thinking, context: run.context, tools: run.tools, sessionFile: run.sessionFile, output: run.output, error: run.error, needsReply: run.needsReply, stopReason: run.lastStop, omittedInFlight: run.omittedInFlight,
    turns: run.turns, toolCalls: run.toolCalls, tokens: run.tokens, contextPercent: run.contextPercent, files: fileChanges(run), added: run.added, removed: run.removed, lastActivity: run.lastActivity, questionOptions: run.questionOptions, questionText: run.questionText, questionShort: run.questionShort,
    attempt: run.attempt, questionID: run.questionID, exitCode: run.exitCode, toolCallID: run.toolCallID, stepIndex: run.stepIndex,
    relaying: run.relays?.size || undefined });
  // Card projection for the native thread (DESIGN.md › Subagents). Every field
  // past asyncDir is optional on the Swift side; undefined keys vanish in JSON.stringify.
  function card(run) {
    const workflow = run.workflowId ? workflows.get(run.workflowId) : undefined;
    return {
      runID: run.id, label: `${run.role}: ${clip(run.task, 100)}`, state: run.state,
      startedAt: run.startedAt, endedAt: run.endedAt, currentTool: run.currentTool,
      needsAttention: run.needsReply === true, attentionText: run.needsReply ? clip(run.questionText ?? run.output, 160) : undefined, asyncDir: run.dir,
      role: run.role, model: run.model, thinking: run.thinking, context: workflow?.async ? "async" : "background",
      step: workflow && run.stepIndex ? { index: run.stepIndex, total: Math.max(workflow.claims.size, run.stepIndex) } : undefined,
      turns: run.turns, toolCalls: run.toolCalls, tokens: run.tokens, contextPercent: run.contextPercent, lastActivity: run.lastActivity,
      paused: run.paused === true,
      question: run.needsReply ? { text: run.questionText ?? clip(run.output, 600), options: run.questionOptions, short: run.questionShort } : undefined,
      result: run.state === "complete" ? { files: run.files?.size ?? 0, added: run.added ?? 0, removed: run.removed ?? 0, tools: run.toolCalls ?? 0, tokens: run.tokens ?? 0 } : undefined,
      exitReason: run.state === "failed" ? [run.exitCode ? `exit ${run.exitCode}` : undefined, clip(run.error, 200)].filter(Boolean).join(" · ") : undefined,
      toolCallID: run.toolCallID, task: clip(run.task, 600), output: run.state === "complete" ? clip(run.output, 600) : undefined,
      sessionFile: run.sessionFile, cwd: run.cwd,
      files: run.files?.size ? fileChanges(run) : undefined,
      summary: run.state === "complete" ? summarize(run.output) : undefined,
      sessionID: ["complete", "failed", "stopped"].includes(run.state) ? sessionID(run) : undefined,
    };
  }
  function publish() {
    if (!active) return;
    pi.events.emit(EVENT, { owner, children: [...runs.values()].sort((a, b) =>
      Number(b.state === "running" || b.state === "queued") - Number(a.state === "running" || a.state === "queued")
      || Number(b.needsReply === true) - Number(a.needsReply === true) || b.startedAt - a.startedAt).slice(0, 20).map(card) });
    syncTick();
  }
  // The one-second tick (inspector controls, then a publish) runs only while a run is live, so
  // an idle parent never wakes. Settled runs keep taking inspector requests through a watch on
  // their control directory, which costs nothing until a request is written.
  function syncTick() {
    const live = active && [...runs.values()].some((run) => run.state === "running" || run.state === "queued");
    if (live && !timer) {
      timer = timers.setInterval(() => { for (const run of runs.values()) void controls(run); publish(); }, 1000);
      timer.unref?.();
    } else if (!live && timer) {
      timers.clearInterval(timer); timer = undefined;
    }
    if (live || !active) {
      for (const watcher of controlWatchers.values()) watcher?.close();
      controlWatchers.clear();
      return;
    }
    for (const run of runs.values()) {
      if (controlWatchers.has(run.id)) continue;
      let watcher = null;
      try {
        watcher = fs.watch(path.join(run.dir, "control"), { recursive: true, persistent: false }, () => void controls(run));
        watcher.on("error", () => { watcher.close(); controlWatchers.set(run.id, null); });
      } catch { /* A run without a control directory takes no inspector requests. */ }
      controlWatchers.set(run.id, watcher);
      // A request written since the last tick raises no watch event.
      void controls(run);
    }
  }
  function save(run) {
    try {
      atomic(path.join(run.dir, "status.json"), { runId: run.id, state: run.state, startedAt: run.startedAt,
        ...summary(run), owner: run.owner, controlNotice: run.controlNotice, controlRequestID: run.controlRequestID,
        steps: [{ label: run.task, agent: run.role, model: run.model, status: run.state, sessionFile: run.sessionFile,
          startedAt: run.startedAt, endedAt: run.endedAt, recentTools: run.currentTool ? [{ tool: run.currentTool }] : [] }] });
    } catch (error) { run.error = `Cannot persist child status: ${clip(error.message)}`; }
    if (run.missionId && missions) {
      try { missions.update(run.missionId, (m) => {
        if (m.status === "planned" && run.state === "running") m.status = "active";
        const link = { id: run.id, task: run.task, agent: run.role, state: run.state, sessionFile: run.sessionFile, updatedAt: Date.now() };
        const index = m.runs.findIndex((r) => r.id === run.id);
        if (index < 0) m.runs.push(link); else m.runs[index] = link;
      }); } catch (error) { run.missionWarning = clip(error.message); }
    }
    publish();
  }
  let parentWorking = false, parentInterrupted = false, parentInputVersion = 0, userInputWaiting = false;
  let directInputWaiting = false;
  function parentInput() { parentInputVersion += 1; userInputWaiting = true; }
  pi.on("input", (event) => {
    if (event.streamingBehavior) { parentInputVersion += 1; directInputWaiting = true; }
  });
  pi.on("message_end", (event) => { if (event.message?.role === "user") directInputWaiting = false; });
  const pendingNotices = new Map();
  let noticeTimer;
  function flushIdleNotices() {
    noticeTimer = undefined;
    if (!active || parentWorking || parentInterrupted || sessionContext?.isIdle?.() === false || !pendingNotices.size) return;
    const notices = [...pendingNotices.values()];
    const content = notices.map((n) => n.content).join("\n\n");
    pendingNotices.clear();
    try { pi.sendMessage(noticeMessage(content), { triggerTurn: !userInputWaiting && !directInputWaiting && notices.some((n) => n.wake), deliverAs: "followUp" }); }
    catch { /* Results remain retrievable by id. */ }
  }
  const noticeMessage = (content) => ({ customType: "shepherd-child", content,
    display: false, details: { backgroundReport: true } });
  function notify(run, message) {
    if (!current(run) || run.workflowId) return;
    const content = `Child ${run.id} (${run.role}): ${clip(message)}\nAttempt: ${run.attempt ?? "unknown"}${run.questionID ? `\nQuestion: ${run.questionID}` : ""}\nUse this result to continue the task. Do not acknowledge receipt or repeat it unless it changes the user's outcome.`;
    enqueueNotice(run.id, content, run.needsReply || run.delivery !== "report");
  }
  function enqueueNotice(id, content, wake = true) {
    pendingNotices.set(id, { content, wake });
    if (!noticeTimer) { noticeTimer = setTimeout(flushIdleNotices, 0); noticeTimer.unref(); }
  }
  pi.on("before_agent_start", () => { userInputWaiting = false; directInputWaiting = false; });
  pi.on("agent_start", () => { parentWorking = true; parentInterrupted = false; });
  pi.on("agent_settled", () => {
    parentWorking = false;
    // A notice can arrive after the final actionable boundary but before settled.
    if (pendingNotices.size && !noticeTimer) { noticeTimer = setTimeout(flushIdleNotices, 0); noticeTimer.unref(); }
  });
  // The actionable boundary batches unread results into one continuation, not one queued
  // follow-up turn per child. Explicit result/wait reads remove their pending notices.
  pi.on("agent_before_settle", (event) => {
    if (event.outcome !== "completed") { parentInterrupted = true; return; }
    if (!pendingNotices.size) return;
    const notices = [...pendingNotices.values()];
    const content = notices.map((n) => n.content).join("\n\n");
    pendingNotices.clear();
    return { entries: [...event.entries, { type: "custom_message", ...noticeMessage(content) }],
      continue: event.continue || (!userInputWaiting && !directInputWaiting && notices.some((n) => n.wake)) };
  });
  // Run id -> the shepherd_child_wait calls watching it. A completion inside a wait is that
  // wait's result: a notice as well would wake the parent for a second turn on it.
  const waiters = new Map();
  function command(run, type, fields = {}, timeout = 10_000) {
    if (!run.proc || run.exited) return Promise.reject(new Error("Child is not running"));
    if (run.pending.size >= 20) return Promise.reject(new Error("Child command queue is full"));
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { run.pending.delete(id); reject(new Error(`Child ${type} acknowledgement timed out`)); }, timeout);
      timer.unref();
      run.pending.set(id, { resolve, reject, timer });
      run.proc.stdin.write(JSON.stringify({ id, type, ...fields }) + "\n", (error) => {
        if (error) { clearTimeout(timer); run.pending.delete(id); reject(error); }
      });
    });
  }
  async function stop(run, reason = "Cancelled") {
    if (run.stopping) return run.stopping;
    if (!run.proc) return;
    abortRelays(run);
    run.cancelled = true; run.paused = false; run.error = reason; run.state = "running";
    run.stopping = (async () => {
      try { await command(run, "clear_queue", {}, 500); await command(run, "abort", {}, 1000); } catch { /* Escalate below. */ }
      if (!run.exited) {
        // Snapshot while the parent PID is still owned; never signal a process group.
        let owned = [];
        try { owned = descendants(run.proc.pid); } catch (error) { run.error += `; descendant cleanup unavailable: ${clip(error.message, 200)}`; }
        for (const pid of owned) if (pid !== run.proc.pid) { try { signalPID(pid, "SIGKILL"); } catch {} }
        run.proc.kill("SIGTERM");
        await Promise.race([run.closed, new Promise((r) => setTimeout(r, 500))]);
        if (!run.exited) {
          try { for (const pid of descendants(run.proc.pid)) signalPID(pid, "SIGKILL"); } catch {}
          run.proc.kill("SIGKILL");
        }
      }
      await run.closed;
    })();
    return run.stopping;
  }
  function releaseWriter(run) {
    const dir = path.join(run.dir, "writer"), owner = path.join(dir, "owner.json");
    try {
      const lease = JSON.parse(fs.readFileSync(owner, "utf8"));
      if (lease.token !== run.token) return;
      fs.unlinkSync(owner);
    } catch (error) { if (error.code !== "ENOENT") return; }
    try { fs.rmdirSync(dir); } catch {}
  }
  function finish(run, code, signal) {
    if (run.exited) return;
    run.exited = true;
    abortRelays(run);
    clearTimeout(run.drainTimer);
    run.exitCode = code ?? undefined;
    if (run.cancelled) run.state = "stopped";
    else if (!run.settled || run.error || (code !== 0 && code !== null) || signal) {
      run.state = "failed";
      run.error ||= `Child exited before clean settlement (${signal ?? code}): ${run.stderr}`;
    } else run.state = "complete";
    for (const pending of run.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error(run.error || "Child exited")); }
    run.pending.clear();
    run.endedAt = Date.now(); run.currentTool = undefined; run.paused = false;
    if (run.lastActivity?.kind === "running") run.lastActivity = { ...run.lastActivity, kind: "tool" };
    releaseWriter(run);
    run.proc = undefined;
    save(run); run.resolveClosed();
    const notice = `${run.state}\n${run.error || run.output || "No text result"}\nSession: ${run.sessionFile}`;
    if (run.state === "complete" && run.needsReply && run.questionNotified) return;
    if (waiters.get(run.id)) run.heldNotice = notice; else notify(run, notice);
  }
  function receive(run, event) {
    if (run.exited) return;
    if (event.type === "response") {
      const pending = run.pending.get(event.id);
      if (pending) {
        clearTimeout(pending.timer); run.pending.delete(event.id);
        event.success ? pending.resolve(event.data) : pending.reject(new Error(clip(event.error)));
      }
    } else if (event.type === "tool_execution_start") {
      run.currentTool = clip(event.toolName, 160); run.latestTool = run.currentTool;
      if (event.toolCallId) run.toolArgs.set(event.toolCallId, event.args);
      // The card and the inspector name the call in flight ("bash swift test"), not just its tool.
      run.lastActivity = { kind: "running", tool: clip(event.toolName, 80), preview: toolPreview(event.args), at: Date.now() };
      save(run);
    } else if (event.type === "tool_execution_end") {
      run.currentTool = undefined;
      run.toolCalls = (run.toolCalls ?? 0) + 1;
      const args = run.toolArgs.get(event.toolCallId); run.toolArgs.delete(event.toolCallId);
      const text = (event.result?.content ?? []).filter((p) => p.type === "text").map((p) => p.text).join("\n");
      const diff = event.toolName === "edit" && !event.isError ? editDiff(args) : undefined;
      if (diff) { run.added = (run.added ?? 0) + diff.added; run.removed = (run.removed ?? 0) + diff.removed; }
      if (["edit", "write"].includes(event.toolName) && !event.isError && typeof args?.path === "string" && (run.files.has(args.path) || run.files.size < 32)) {
        const entry = run.files.get(args.path) ?? { added: 0, removed: 0 };
        run.files.set(args.path, { added: entry.added + (diff?.added ?? 0), removed: entry.removed + (diff?.removed ?? 0) });
      }
      run.lastActivity = { kind: "tool", tool: clip(event.toolName, 80), preview: toolPreview(args, text), diff, at: Date.now() };
      if (event.toolName === "shepherd_parent_message") {
        const details = event.result?.details;
        if (typeof details?.shepherdParentMessage === "string") {
          run.needsReply = details.needsReply === true;
          run.questionID = run.needsReply ? `${run.attempt}/${event.toolCallId}` : undefined;
          run.questionOptions = run.needsReply && Array.isArray(details.options) ? details.options.filter((o) => typeof o === "string").slice(0, 6) : undefined;
          run.output = clip(details.shepherdParentMessage);
          run.questionText = run.needsReply ? clip(run.output, 600) : undefined;
          run.questionShort = run.needsReply ? shortReason(details.short) : undefined;
          if (run.needsReply) {
            run.questionNotified = true;
            notify(run, `Needs reply: ${run.output}`);
          }
        }
      }
      save(run);
    } else if (event.type === "message_end" && event.message?.role === "assistant") {
      const message = event.message;
      run.output = clip((message.content ?? []).filter((p) => p.type === "text").map((p) => p.text).join("\n"));
      run.error = ["error", "aborted"].includes(message.stopReason) ? clip(message.errorMessage || message.stopReason) : undefined;
      run.lastStop = message.stopReason;
      run.turns = (run.turns ?? 0) + 1;
      if (Number.isFinite(message.usage?.totalTokens)) run.tokens = (run.tokens ?? 0) + message.usage.totalTokens;
      // Context fill is the child's own estimate; best-effort, the card renders without it.
      command(run, "get_session_stats", {}, 2000).then((stats) => {
        if (Number.isFinite(stats?.contextUsage?.percent)) { run.contextPercent = stats.contextUsage.percent; save(run); }
      }).catch(() => {});
      save(run);
    } else if (event.type === "extension_ui_request" && event.method === "notify") {
      try { const data = JSON.parse(event.message); if (Array.isArray(data.shepherdChildTools)) run.availableTools = data.shepherdChildTools; } catch {}
      relayCancel(run, event.message);
    } else if (event.type === "extension_ui_request" && event.method === "input" && typeof event.title === "string" && event.title.startsWith(RELAY_TITLE)) {
      // A design tool a helper's profile listed, relayed through this process (see serveRelay).
      void serveRelay(run, event, { relay: designRelay(), ctx: sessionContext, answer: (value) => {
        if (run.proc && !run.exited) run.proc.stdin.write(JSON.stringify({ type: "extension_ui_response", id: event.id, value }) + "\n");
      } });
    } else if (event.type === "extension_ui_request" && ["select", "confirm", "input", "editor"].includes(event.method)) {
      run.proc.stdin.write(JSON.stringify({ type: "extension_ui_response", id: event.id, cancelled: true }) + "\n");
      void stop(run, `Child requested unsupported human interaction: ${clip(event.title, 200)}. Ask through shepherd_parent_message.`);
    } else if (event.type === "agent_settled" && !run.cancelled && !run.settled) {
      run.settled = true;
      if (run.lastStop === "length") run.error ||= "Incomplete answer: child reached its output token limit; resume to continue";
      else if (run.lastStop !== "stop") run.error ||= "Child settled without a final assistant response";
      // EOF shuts RPC down and flushes its session. Resume only after actual exit.
      run.proc.stdin.end();
      run.drainTimer = setTimeout(() => { void stop(run, "Child did not exit after settlement"); }, 3000);
      run.drainTimer.unref();
    }
  }
  async function launch(run, message, signal) {
    signal?.throwIfAborted();
    const inherited = await childUserExtensions(run.cwd);
    signal?.throwIfAborted();
    run.pending = new Map(); run.exited = false; run.cancelled = false; run.settled = false;
    run.paused = false;
    run.stopping = undefined; run.output = ""; run.error = undefined; run.stderr = ""; run.lastStop = undefined; run.availableTools = undefined;
    pendingNotices.delete(run.id);
    run.questionNotified = false; run.attempt = randomUUID(); run.questionID = undefined;
    run.needsReply = false; run.questionOptions = undefined; run.questionText = undefined; run.questionShort = undefined; run.exitCode = undefined; run.endedAt = undefined; run.startedAt = Date.now(); run.state = "running";
    run.toolArgs = new Map(); run.files ??= new Map();
    run.closed = new Promise((resolve) => { run.resolveClosed = resolve; });
    // A design agent's helper gets a proxy for each design tool its profile listed (the parent's tool
    // allowlist already narrowed run.tools), and the parent's allowlist for what it may relay.
    const relayTools = run.tools.filter((name) => DESIGN_RELAYED.includes(name));
    let relay = [];
    if (relayTools.length) {
      const registry = designRelay();
      const problem = designToolsProblem(relayTools, registry);
      if (problem) throw new Error(problem);
      relay = relaySpecs(relayTools, registry);
    }
    run.relayTools = relayTools; run.relays = new Map();
    const { args, env } = childLaunch({ run, bridge, inherited, relay });
    // The parent's own engine: the node it runs on and its pi's bundle, never a `pi` from PATH
    // (Shepherd's pi ships both; its launcher pins the rest, which the child inherits).
    const script = path.join(getPackageDir(), "dist", "bundle", "cli.js");
    if (!/^node(\.exe)?$/i.test(path.basename(process.execPath)) || !fs.existsSync(script)) {
      throw new Error(`Native subagents run on pi's own node and bundle, and this pi has none (${process.execPath}, ${script})`);
    }
    const leaseDir = path.join(run.dir, "writer");
    try { fs.mkdirSync(leaseDir, { mode: 0o700 }); }
    catch (error) {
      if (error.code !== "EEXIST") throw error;
      const lease = JSON.parse(fs.readFileSync(path.join(leaseDir, "owner.json"), "utf8"));
      if (alive(lease.pid)) throw new Error("Child session already has a live writer");
      throw new Error(`Child has an interrupted writer lease at ${leaseDir}. Verify the old process has exited before removing that lease directory; automatic crash recovery is disabled.`);
    }
    run.token = randomUUID();
    try {
      atomic(path.join(leaseDir, "owner.json"), { pid: process.pid, token: run.token });
      run.proc = spawn(process.execPath, [script, ...args], { cwd: run.cwd, env, detached: false, stdio: ["pipe", "pipe", "pipe"] });
    } catch (error) { releaseWriter(run); throw error; }
    if (run.proc.pid) atomic(path.join(leaseDir, "owner.json"), { pid: run.proc.pid, token: run.token });
    const proc = run.proc;
    proc.stdin.on("error", () => {});
    proc.stdout.on("data", jsonLines((event) => receive(run, event), (error) => { void stop(run, `Invalid child protocol: ${clip(error.message)}`); }));
    proc.stderr.on("data", (chunk) => { run.stderr = (run.stderr + chunk.toString("utf8")).slice(-MAX_TEXT); });
    proc.once("error", (error) => { run.error = clip(error.message); finish(run, 1, null); });
    proc.once("exit", () => {
      // Drain buffered protocol bytes before finalizing; don't wait indefinitely
      // for a command that intentionally left inherited stdio open.
      const drain = setTimeout(() => { proc.stdout.destroy(); proc.stderr.destroy(); }, 500);
      drain.unref(); proc.once("close", () => clearTimeout(drain));
    });
    proc.once("close", (code, signal) => finish(run, code, signal));
    const abort = () => { void stop(run); };
    signal?.addEventListener("abort", abort, { once: true });
    save(run);
    try {
      const state = await command(run, "get_state", {}, 20_000);
      const catalog = await command(run, "get_available_models");
      const missingTools = run.tools.filter((name) => !run.availableTools?.includes(name));
      if (missingTools.length) throw Error(`Tools unavailable in child Pi: ${missingTools.join(", ")}. Supply their explicit local extension providers.`);
      if (!state?.model || `${state.model.provider}/${state.model.id}` !== run.model
        || !catalog?.models?.some((model) => `${model.provider}/${model.id}` === run.model)) {
        // The parent could resolve it; the helper's own Pi can't. Its catalog is what names the providers it has.
        throw new Error(`Model ${run.model} is unavailable in isolated Pi. ${modelNotFound(run.model, catalog?.models ?? [], { where: "the helper's Pi" })} Check the model id and enabled Pi user extensions; project or CLI-only providers require an explicit profile extension.`);
      }
      if (!current(run) || signal?.aborted) throw new Error("Parent session ended or dispatch cancelled");
      await command(run, "prompt", { message });
    } catch (error) {
      const hint = missingProviderHint(run.model, error.message);
      if (hint) error = new Error(error.message.trimEnd() + hint);
      await stop(run, clip(error.message)); throw error;
    }
    finally { signal?.removeEventListener("abort", abort); }
    return summary(run);
  }
  function get(id) { const run = runs.get(id); if (!run) throw new Error("Unknown child id in this parent session"); return run; }
  function capacity() { if ([...runs.values()].filter((r) => r.state === "running" || r.state === "queued").length >= defaults.concurrency) throw new Error(`${defaults.concurrency === 4 ? "Four" : defaults.concurrency} children are already active; wait or cancel first`); }
  async function send(run, message, mode = "steer") {
    if (!run.proc || run.exited || run.cancelled || run.settled) throw new Error("Child is not accepting messages; use shepherd_child_resume after it exits");
    const question = run.questionID;
    await command(run, "prompt", { message, streamingBehavior: mode });
    if (question && run.questionID === question) {
      run.needsReply = false; run.questionID = undefined; run.questionText = undefined;
      run.questionShort = undefined; run.questionOptions = undefined;
      pendingNotices.delete(run.id); save(run);
    }
    return { id: run.id, delivery: "accepted or queued", mode };
  }
  async function controls(run) {
    if (run.controlBusy || !current(run)) return;
    run.controlBusy = true;
    try {
      const stopFile = path.join(run.dir, "control", "stop.json");
      if (fs.existsSync(stopFile)) {
        let requestID;
        try {
          if (fs.statSync(stopFile).size > 1024) throw new Error("Control request too large");
          const request = JSON.parse(fs.readFileSync(stopFile, "utf8"));
          if (typeof request.id === "string" && /^[\w-]{1,80}$/.test(request.id)) requestID = request.id;
          fs.unlinkSync(stopFile);
          await stop(run);
          run.controlNotice = `stop accepted · ${run.state}`;
        } catch (error) { run.controlNotice = `control failed: ${clip(error.message)}`; try { fs.unlinkSync(stopFile); } catch {} }
        run.controlRequestID = requestID;
        save(run);
        return;
      }
      const inbox = path.join(run.dir, "control", "steer-requests");
      for (const name of fs.readdirSync(inbox).filter((name) => /^[\w-]+\.json$/.test(name)).slice(0, 20)) {
        const file = path.join(inbox, name);
        try {
          if (fs.statSync(file).size > MAX_TEXT + 1024) throw new Error("Control request too large");
          const request = JSON.parse(fs.readFileSync(file, "utf8"));
          fs.unlinkSync(file);
          if (typeof request.message !== "string" || !request.message.trim() || request.message.length > MAX_TEXT) throw new Error("Invalid control message");
          const receipt = await messageChild(run, request.message, "steer", sessionContext);
          run.controlNotice = `${receipt.mode === "reply" ? "reply" : "message"} accepted or queued`;
        } catch (error) { run.controlNotice = `control failed: ${clip(error.message)}`; try { fs.unlinkSync(file); } catch {} }
        // Launch can save intermediate state. Publish this ID only with its own outcome.
        run.controlRequestID = name.slice(0, -5);
        save(run);
      }
    } catch { /* The inspector may not have created an inbox yet. */ }
    finally { run.controlBusy = false; }
  }
  // The app's native thread cards drive children over the extension socket: Shepherd sends
  // childCommand frames, this replies childCommandResult, calling the same functions the tools use.
  // The parent model is never involved. Failures reconnect; nothing here can throw into pi.
  let control, controlRetry;
  async function childCommand(frame) {
    const run = get(String(frame.runID ?? ""));
    const text = typeof frame.text === "string" ? frame.text : "";
    if (frame.action === "cancel") { await stop(run); return; }
    if (frame.action === "resume") { await resume(run, run.task, undefined, sessionContext); return; }
    if (frame.action === "pause" || frame.action === "continue") {
      if (!run.proc || run.exited || run.settled || run.cancelled) throw Error("Child is not running");
      await command(run, "prompt", { message: `/shepherd-child-${frame.action}`, streamingBehavior: "steer" });
      if (!run.exited && !run.settled) { run.paused = frame.action === "pause"; save(run); }
      return;
    }
    if (frame.action !== "message") throw new Error("Unsupported child command");
    if (!text.trim() || text.length > MAX_TEXT) throw new Error("Invalid child message");
    await messageChild(run, text, frame.mode === "followUp" ? "followUp" : "steer", sessionContext);
  }
  function connectControl() {
    if (!active || control) return;
    try {
      const s = net.createConnection(process.env.SHEPHERD_SOCKET);
      control = s; s.unref();
      s.on("connect", () => { try { s.write(JSON.stringify({ type: "helloChildren", agentID: process.env.SHEPHERD_AGENT_ID }) + "\n"); } catch { s.destroy(); } });
      s.on("data", jsonLines((frame) => {
        if (frame?.type === "parentInput") { parentInput(); return; }
        if (frame?.type !== "childCommand" || !Number.isSafeInteger(frame.id)) return;
        childCommand(frame).then(() => undefined, (error) => clip(error.message, 500)).then((error) => {
          if (control === s) { try { s.write(JSON.stringify({ type: "childCommandResult", id: frame.id, error }) + "\n"); } catch {} }
        });
      }, () => s.destroy()));
      s.on("error", () => {});
      s.on("close", () => {
        if (control !== s) return;
        control = undefined;
        if (active) { controlRetry = setTimeout(connectControl, 2000); controlRetry.unref(); }
      });
    } catch { control = undefined; }
  }
  pi.on("session_start", (_event, ctx) => {
    owner = ctx.sessionManager.getSessionId(); active = true; sessionContext = ctx;
    parentWorking = false; parentInterrupted = false; userInputWaiting = false; directInputWaiting = false; parentInputVersion += 1; pendingNotices.clear(); clearTimeout(noticeTimer); noticeTimer = undefined;
    connectControl();
    missions = missionStore(path.join(path.dirname(root), "shepherd-native"), ctx.cwd);
    fs.mkdirSync(root, { recursive: true, mode: 0o700 });
    for (const entry of ctx.sessionManager.getEntries()) {
      if (entry.type === "custom" && entry.customType === "shepherd-workflow" && entry.data?.owner === owner && entry.data.missionId) {
        const data = entry.data;
        // A live previous owner is not ours to reconcile. No PID is ever signalled from metadata.
        if (!Number.isInteger(data.ownerPID) || (data.ownerPID !== process.pid && alive(data.ownerPID))) continue;
        try { missions.update(data.missionId, (m) => {
          if (m.workflow?.id === data.id && m.workflow.state === "running") {
            m.workflow.state = "stopped"; m.workflow.error = "Interrupted with previous parent; workflows are not replayed";
            if (!["complete", "cancelled"].includes(m.status)) m.status = "needs_decision";
          }
        }); } catch { /* Missing or locked mission records remain inspectable by id. */ }
      }
      if (entry.type !== "custom" || entry.customType !== "shepherd-child" || entry.data?.owner !== owner || runs.size >= MAX_RUNS) continue;
      const data = entry.data;
      if (!/^native-[\w-]+$/.test(data.id) || typeof data.role !== "string") continue;
      const dir = path.join(root, data.id);
      try {
        const status = JSON.parse(fs.readFileSync(path.join(dir, "status.json"), "utf8"));
        let interrupted = !["complete", "failed", "stopped"].includes(status.state);
        if (interrupted) {
          try { const lease = JSON.parse(fs.readFileSync(path.join(dir, "writer", "owner.json"), "utf8")); if (alive(lease.pid)) interrupted = false; } catch {}
        }
        runs.set(data.id, { ...data, dir, sessionFile: path.join(dir, "session.jsonl"), output: clip(status.output), error: status.error,
          needsReply: status.needsReply === true, lastStop: status.stopReason,
          turns: status.turns, toolCalls: status.toolCalls, tokens: status.tokens, contextPercent: status.contextPercent, added: status.added, removed: status.removed,
          files: new Map((Array.isArray(status.files) ? status.files : []).map((f) => typeof f === "string" ? [f, { added: 0, removed: 0 }] : [f.path, { added: f.added ?? 0, removed: f.removed ?? 0 }])), lastActivity: status.lastActivity?.kind === "running" ? { ...status.lastActivity, kind: "tool" } : status.lastActivity, questionOptions: status.questionOptions, questionText: status.questionText, questionShort: shortReason(status.questionShort), attempt: status.attempt, questionID: status.questionID, exitCode: status.exitCode,
          tools: Array.isArray(status.tools) ? data.tools.filter((name) => status.tools.includes(name)) : data.tools,
          missionId: status.missionId ?? data.missionId,
          state: ["complete", "failed", "stopped"].includes(status.state) ? status.state : "stopped", startedAt: status.startedAt ?? data.startedAt, endedAt: status.endedAt, latestTool: status.latestTool });
        if (interrupted) {
          const restored = runs.get(data.id); restored.endedAt ??= Date.now(); restored.error = "Interrupted with previous parent; explicit resume required";
          save(restored);
          if (restored.missionId) try { missions.update(restored.missionId, (m) => {
            if (m.workflow?.id === restored.workflowId && m.workflow?.state === "running") m.workflow.state = "stopped";
            if (!["complete", "cancelled"].includes(m.status)) m.status = "needs_decision";
          }); } catch (error) { restored.missionWarning = clip(error.message); }
        }
      } catch { /* Missing artifacts cannot be resumed. */ }
    }
    publish();
    registerCommands();
  });
  pi.on("session_shutdown", async () => {
    active = false; pendingNotices.clear(); parentWorking = false; clearTimeout(noticeTimer); noticeTimer = undefined; syncTick(); clearTimeout(controlRetry);
    const socket = control; control = undefined; socket?.destroy();
    for (const workflow of workflows.values()) workflow.controller.abort();
    await Promise.all([...workflows.values()].map((w) => w.done));
    await Promise.all([...runs.values()].map((run) => stop(run, "Parent session ended")));
  });

  const missionSchema = Type.Object({ title: textSchema, objective: Type.Optional(textSchema) }, { additionalProperties: false });
  const startSchema = Type.Object({ task: textSchema,
    delivery: Type.Optional(StringEnum(["report", "continue"], { description: "report stores the result without starting a parent turn; continue resumes the parent to finish dependent work (default). Blocking questions may notify in either mode." })), role: Type.Optional(idSchema), agent: Type.Optional(idSchema), context: Type.Optional(StringEnum(["fresh", "fork"])),
    cwd: Type.Optional(Type.String({ maxLength: 4096 })), model: Type.Optional(Type.String({ maxLength: 256 })),
    thinking: Type.Optional(StringEnum(thinkingLevels)), missionId: Type.Optional(idSchema), mission: Type.Optional(Type.Union([Type.Boolean(), missionSchema])) }, { additionalProperties: false });
  function checked(schema, params) { return validateToolArguments({ name: "shepherd", parameters: schema }, { id: "check", name: "shepherd", arguments: params }); }
  function missionFor(params, title) {
    if (params.missionId && params.mission !== undefined) throw Error("Use missionId or mission, not both");
    if (params.mission === false) return {};
    try {
      const mission = params.missionId ? missions.read(params.missionId) : missions.create(typeof params.mission === "object" ? params.mission.title : title,
        typeof params.mission === "object" ? params.mission.objective : title);
      if (["complete", "cancelled"].includes(mission.status)) throw Error("Mission is closed");
      return { missionId: mission.id };
    } catch (error) { if (params.missionId || params.mission !== undefined) throw error; return { missionWarning: clip(error.message) }; }
  }
  function resolveModel(profile, ctx, explicit) {
    const requestedModel = explicit ?? profile.model ?? defaults.model ?? "inherit";
    const resolved = requestedModel === "inherit" ? { model: ctx.model } : resolveCliModel({ cliModel: requestedModel,
      modelRuntime: { getModels: () => ctx.modelRegistry.getAll(), hasConfiguredAuth: (provider) => ctx.modelRegistry.getAll().some((m) => m.provider === provider && ctx.modelRegistry.hasConfiguredAuth?.(m)) } });
    if (requestedModel === "inherit" && !resolved.model) throw Error("Select a model in the parent first");
    // Pi takes an id a known provider doesn't list as a custom model (and says so in `warning`), but a
    // helper's catalog never holds it, so it would fail after launching: refuse it here, once, saying who
    // named the model and what is loaded instead.
    const listed = resolved.model && ctx.modelRegistry.getAll().some((m) => m.provider === resolved.model.provider && m.id === resolved.model.id);
    if (requestedModel !== "inherit" && (resolved.error || !resolved.model || !listed)) {
      const origin = explicit ? "The model argument" : profile.model ? `Agent profile ${profile.name}` : "Shepherd's native-subagent model default";
      throw Error(modelNotFound(requestedModel, ctx.modelRegistry.getAll(), { origin, where: "this Pi" }));
    }
    return resolved;
  }
  async function start(params, signal, ctx, workflowId, toolCallID, stepIndex) {
      params = checked(startSchema, params);
      if (!active) throw new Error("No active parent session");
      if (!supported) throw new Error("Shepherd native children require Pi 0.85.1 or newer");
      signal?.throwIfAborted(); capacity();
      if (runs.size >= MAX_RUNS) throw new Error("64 retained children reached; start a new parent session");
      if (params.agent && params.role) throw Error("Pass either an agent profile or a role, not both: agent and role name the same thing (role is an alias for agent). Use agent for a profile from shepherd_child_agents, or role for one of the bundled roles (scout, reviewer, planner, worker).");
      const cwd = fs.realpathSync(path.resolve(ctx.cwd, params.cwd ?? "."));
      if (!fs.statSync(cwd).isDirectory()) throw new Error("Child cwd must be a directory");
      const targetContext = childTargetContext(ctx, cwd);
      const catalog = discoverChildAgents(targetContext, defaults.scope);
      const name = params.agent ?? params.role ?? "worker";
      const exact = catalog.agents.filter((a) => a.name === name);
      const matches = exact.length ? exact : catalog.agents.filter((a) => a.aliases?.includes(name));
      if (matches.length !== 1) throw Error(unknownAgentMessage(name, catalog.agents, matches));
      const profile = matches[0], role = profile.name;
      if (profile.error || profile.disabled) throw Error(profile.error || `Agent ${role} is disabled`);
      if (profile.tools === "inherit") throw Error("tools: inherit requires ambient extensions, which native children do not inherit. Omit tools for Pi builtins or list tools and explicit extension files.");
      const requestedTools = profile.tools ?? defaultChildTools(cwd);
      // A design agent's helpers get its design tools through their parent (see serveRelay); a profile's
      // `extensions` can't supply them (shepherd-design.ts is inert without the design agent's environment).
      const designNames = requestedTools.filter((name) => DESIGN_TOOLS.includes(name));
      const designProblem = designNames.length ? designToolsProblem(designNames, designRelay()) : undefined;
      if (designProblem) throw Error(designProblem);
      const unknownTools = requestedTools.filter((name) => !ROLES.worker.tools.includes(name) && name !== "shepherd_parent_message" && !DESIGN_TOOLS.includes(name));
      if (unknownTools.length && !profile.extensions?.length) throw Error(`Unsupported agent tools without explicit extensions: ${unknownTools.join(", ")}`);
      if (requestedTools.some((name) => /^(shepherd_child_|shepherd_workflow|subagent$)/.test(name))) throw Error("Nested delegation tools are unsupported");
      const resolved = resolveModel(profile, ctx, params.model);
      const model = `${resolved.model.provider}/${resolved.model.id}`;
      if (!bridge) throw new Error("Shepherd child extension path is missing");
      const id = `native-${randomUUID()}`, dir = path.join(root, id);
      fs.mkdirSync(path.join(dir, "control", "steer-requests"), { recursive: true, mode: 0o700 });
      const run = { id, dir, owner, role, model, cwd, thinking: params.thinking ?? resolved.thinkingLevel ?? profile.thinking ?? defaults.thinking ?? ctx.thinkingLevel ?? "off", task: params.task,
        context: params.context ?? profile.context ?? defaults.context, delivery: params.delivery ?? "continue",
        requiresProjectTrust: profile.requiresProjectTrust || (targetContext.isProjectTrusted() && (profile.inheritSkills || profile.skills?.length)), profileSource: profile.source, systemPromptMode: profile.systemPromptMode, inheritProjectContext: profile.inheritProjectContext,
        extensions: profile.extensions ?? [], skills: childSkills(profile, targetContext), workflowId, ...missionFor(params, params.task),
        tools: requestedTools.filter((name) => pi.getActiveTools().includes(name)), state: "queued", startedAt: Date.now(), sessionFile: path.join(dir, "session.jsonl"), output: "",
        toolCallID: typeof toolCallID === "string" ? toolCallID : undefined, stepIndex, turns: 0, toolCalls: 0, tokens: 0, added: 0, removed: 0, files: new Map() };
      runs.set(id, run);
      try {
        if (run.context === "fork") Object.assign(run, forkSession(ctx.sessionManager, cwd, run.sessionFile));
        else {
          const sm = SessionManager.inMemory(cwd);
          fs.writeFileSync(run.sessionFile, JSON.stringify(sm.getHeader()) + "\n", { mode: 0o600 });
        }
        fs.writeFileSync(path.join(dir, "prompt.md"), `You are a Shepherd child, not the parent. ${profile.prompt}\nWork only on the delegated task. No nested helpers, workflows, schedules, or worktree management. Routine progress stays in your child record; do not send a separate completion message, your final answer is delivered automatically. Use shepherd_parent_message for a question that blocks work, set needsReply and finish your turn. Your parent can resume with an answer.\n`, { mode: 0o600 });
        const { dir: _dir, output: _output, files: _files, ...descriptor } = run;
        pi.appendEntry("shepherd-child", descriptor);
        return await launch(run, params.task, signal);
      } catch (error) { if (!run.proc) { run.state = "failed"; run.endedAt = Date.now(); run.error = clip(error.message); save(run); } throw error; }
  }
  pi.registerTool({ name: "shepherd_child_agents", label: "child agents", description: "List effective agent profiles, sources and unsupported-field diagnostics. Reads user files and trusted project files without changing them.",
    parameters: Type.Object({}), async execute(_id, _p, _s, _u, ctx) { return result({ defaults, ...discoverChildAgents(ctx, defaults.scope) }); } });
  pi.registerTool({ name: "shepherd_child_start", label: "start child", parameters: startSchema,
    description: "Start an owned background Pi helper. Use shepherd_child_agents for discovered profiles. Explicit call overrides profile, then Shepherd defaults, then parent model/thinking. Fresh or fork context; tools intersect the parent allowlist. Cwd is not a sandbox. Progress stays in the child record. delivery:report stores completion without waking the parent, so the user can keep chatting; delivery:continue resumes dependent work. Result/wait reads consume pending notices. Default creates a mission; mission:false opts out. No nested delegation or automatic worktrees.",
    async execute(id, p, signal, _update, ctx) { return result(await start(p, signal, ctx, undefined, id)); } });
  pi.registerTool({ name: "shepherd_child_message", label: "message child", description: "Message a running child. Acceptance is not completion. Steer runs after current tools; followUp waits for the turn to end.",
    parameters: Type.Object({ id: idSchema, message: textSchema, mode: Type.Optional(StringEnum(["steer", "followUp"])),
      questionID: Type.Optional(Type.String({ description: "Question identity returned by child_result. Rejects an answer to an obsolete question or attempt." })) }),
    async execute(_id, p) {
      const run = get(p.id);
      if (p.questionID && (!run.needsReply || p.questionID !== run.questionID)) throw Error("Child question changed; read its current result before answering");
      return result(await send(run, p.message, p.mode));
    } });
  pi.registerTool({ name: "shepherd_child_result", label: "child results", description: "Read one child result or list this parent's retained children. Output is capped at 16 KiB per result and may be truncated; full conversation is in sessionFile. No live work survives parent shutdown.",
    parameters: Type.Object({ id: Type.Optional(idSchema) }),
    async execute(_id, p) {
      if (p.id) pendingNotices.delete(p.id);
      return result(p.id ? summary(get(p.id)) : [...runs.values()].map((r) => ({ id: r.id, role: r.role, state: r.state, task: clip(r.task, 160) })));
    } });
  pi.registerTool({ name: "shepherd_child_wait", label: "wait for children", description: "Wait for selected children, up to 60 seconds. New user input ends the wait immediately without stopping children; waitInterrupted names this outcome. Timeout or cancellation also leaves children running. Returns bounded results for up to 16 ids.",
    parameters: Type.Object({ ids: Type.Array(idSchema, { minItems: 1, maxItems: 16 }), all: Type.Optional(Type.Boolean()), timeoutSeconds: Type.Optional(Type.Number({ minimum: 0, maximum: 60 })) }),
    async execute(_id, p, signal) {
      const selected = p.ids.map(get), watched = [...new Set(selected)], deadline = Date.now() + (p.timeoutSeconds ?? 30) * 1000;
      const inputVersion = parentInputVersion;
      for (const r of watched) waiters.set(r.id, (waiters.get(r.id) ?? 0) + 1);
      let answered = false;
      try {
        while (Date.now() < deadline) {
          signal?.throwIfAborted();
          if (userInputWaiting || directInputWaiting || parentInputVersion !== inputVersion) break;
          const done = selected.map((r) => !["running", "queued"].includes(r.state));
          if (p.all ? done.every(Boolean) : done.some(Boolean)) break;
          await new Promise((r) => setTimeout(r, 100));
        }
        const interrupted = userInputWaiting || directInputWaiting || parentInputVersion !== inputVersion;
        const value = { ...result(selected.map((r) => ({ ...summary(r), output: clip(r.output, 4096),
          ...(interrupted ? { waitInterrupted: "user_input" } : {}) }))), ...(interrupted ? { terminate: true } : {}) };
        answered = true;
        return value;
      } finally {
        for (const r of watched) {
          const left = waiters.get(r.id) - 1;
          if (left > 0) waiters.set(r.id, left); else waiters.delete(r.id);
          // This wait's result carries a completion it saw; a cancelled wait hands it back.
          if (answered) { r.heldNotice = undefined; pendingNotices.delete(r.id); }
          else if (left <= 0 && r.heldNotice) { const notice = r.heldNotice; r.heldNotice = undefined; notify(r, notice); }
        }
      }
    } });
  pi.registerTool({ name: "shepherd_child_cancel", label: "cancel child", description: "Clear queued work, abort, and terminate an owned child. Returns only after its process exits. Session history remains available for explicit continuation.",
    parameters: Type.Object({ id: idSchema }), async execute(_id, p) { const run = get(p.id); await stop(run); pendingNotices.delete(run.id); return result(summary(run)); } });
  pi.registerTool({ name: "shepherd_child_resume", label: "continue child", description: "Continue a completed, failed, or stopped child session with a new task or answer. Keeps its role, model, cwd, and history. Rejects concurrent writers and missing transcripts. Does not replay interrupted work automatically.",
    parameters: Type.Object({ id: idSchema, message: textSchema, questionID: Type.Optional(Type.String({ description: "Question identity returned by child_result; refuses stale answers." })) }), async execute(_id, p, signal, _update, ctx) {
      const run = get(p.id);
      if (p.questionID && (!run.needsReply || p.questionID !== run.questionID)) throw Error("Child question changed; read its current result before answering");
      return result(await resume(run, p.message, signal, ctx));
    } });
  async function resume(run, message, signal, ctx) {
    if (!active) throw Error("No active parent session");
    if ((run.requiresProjectTrust || run.profileSource === "project") && childTargetContext(ctx, run.cwd).isProjectTrusted() !== true) throw Error("Project profile continuation requires Pi project trust");
    if (run.workflowId && workflows.has(run.workflowId) && !workflows.get(run.workflowId).cleaned) throw Error("Child is still owned by an active workflow");
    if (run.settled && run.proc) await run.closed;
    if (run.proc || ["running", "queued"].includes(run.state)) throw new Error("Child already active");
    capacity(); signal?.throwIfAborted();
    if (!fs.existsSync(run.sessionFile)) throw new Error("Child transcript is missing");
    run.workflowId = undefined;
    run.tools = run.tools.filter((name) => pi.getActiveTools().includes(name));
    run.state = "queued";
    try { return await launch(run, message, signal); }
    catch (error) { if (!run.proc) { run.state = "failed"; run.endedAt = Date.now(); run.error = clip(error.message); save(run); } throw error; }
  }
  // Every caller is the user (the app's cards and inspector, shepherd-inspect, the fleet view),
  // never the parent's tools. Recorded beside the session before it is sent, so Shepherd's
  // inspector captions only the parent's messages "from parent".
  async function messageChild(run, message, mode, ctx) {
    try { fs.appendFileSync(path.join(run.dir, "user-messages.jsonl"), JSON.stringify({ text: message, at: Date.now() }) + "\n", { mode: 0o600 }); }
    catch { /* Without the record the message reads as the parent's. */ }
    if (run.settled || !run.proc || run.exited) {
      await resume(run, message, undefined, ctx);
      return { id: run.id, delivery: "accepted or queued", mode: "reply" };
    }
    return send(run, message, mode);
  }
  const missionToolSchema = Type.Object({ action: StringEnum(["create", "list", "show", "update", "close", "attach-run", "attachment"]),
    id: Type.Optional(idSchema), title: Type.Optional(textSchema), objective: Type.Optional(textSchema), summary: Type.Optional(textSchema),
    status: Type.Optional(StringEnum(["planned", "active", "waiting", "needs_decision", "complete", "cancelled"])),
    runId: Type.Optional(idSchema), attachment: Type.Optional(Type.Object({ title: textSchema, uri: textSchema }, { additionalProperties: false })) }, { additionalProperties: false });
  pi.registerTool({ name: "shepherd_mission", label: "missions", description: "Create/list/show/update/close durable project-scoped records, attach an owned run or a descriptive attachment URI. Records do not execute files, grant permissions or restart work. Close does not cancel processes. At most 200 records listed; show by id for older records.",
    parameters: missionToolSchema, async execute(_id, params) {
      if (!active) throw Error("No active parent session");
      const p = checked(missionToolSchema, params);
      if (p.action === "create") { if (!p.title) throw Error("Mission title is required"); return result(missions.create(p.title, p.objective)); }
      if (p.action === "list") return result(missions.list().map(({ id, title, status, updatedAt }) => ({ id, title, status, updatedAt })));
      if (p.action === "show") return result(missions.read(p.id));
      const run = p.action === "attach-run" ? get(p.runId) : undefined;
      if (run?.missionId && run.missionId !== p.id) throw Error("Run already belongs to another mission");
      const record = missions.update(p.id, (m) => {
        if (p.action === "close") {
          if (p.status && !["complete", "cancelled"].includes(p.status)) throw Error("Close requires complete or cancelled status");
          m.status = p.status ?? "complete";
        } else if (p.action === "attachment") {
          if (!p.attachment) throw Error("Attachment is required");
          if (m.attachments.length >= 64) throw Error("64 attachments reached");
          m.attachments.push(p.attachment);
        } else if (p.action === "update") {
          if (p.title !== undefined) m.title = p.title;
          if (p.objective !== undefined) m.objective = p.objective;
          if (p.status !== undefined) m.status = p.status;
        }
        if (p.summary !== undefined) m.summary = p.summary;
        if (run && !m.runs.some((r) => r.id === run.id)) m.runs.push({ id: run.id, task: run.task, agent: run.role, state: run.state });
      });
      if (run) { run.missionId = p.id; save(run); }
      return result(record);
    } });

  const workflowSchema = Type.Object({ delivery: Type.Optional(StringEnum(["report", "continue"])), action: Type.Optional(StringEnum(["start", "status", "cancel", "wait"])), id: Type.Optional(idSchema),
    workflowScript: Type.Optional(Type.String({ minLength: 1, maxLength: 32768 })), task: Type.Optional(textSchema),
    async: Type.Optional(Type.Boolean()), timeoutSeconds: Type.Optional(Type.Number({ minimum: 0.1, maximum: 1800 })),
    missionId: Type.Optional(idSchema), mission: Type.Optional(Type.Union([Type.Boolean(), missionSchema])) }, { additionalProperties: false });
  const workflowSummary = (w) => ({ id: w.id, state: w.state, output: w.output, error: w.error, missionId: w.missionId, missionWarning: w.missionWarning,
    children: [...w.keys].map(([key, run]) => ({ key, id: run.id, state: run.state })) });
  pi.registerTool({ name: "shepherd_workflow", label: "workflow", parameters: workflowSchema,
    description: "Start a background JavaScript statement body with runs.run(key,{agent,task,...}), runs.all([{key,agent,task,...}]), runs.steer(key,message,{mode}), runs.status(key), runs.cancel(key). Await or return calls. Use ordinary sequencing/branching; no imports, process or filesystem API. This is restricted execution, NOT an OS sandbox. Children retain their normal tools. Default 30-minute deadline and enclosing mission; mission:false disables persistence and state.get/set. delivery:report records completion without waking the parent; continue resumes dependent work. async:false waits; new user input interrupts action:wait without stopping children. status/wait/cancel target this parent's workflow id. No automatic retries, worktrees or scheduling.",
    async execute(id, params, signal, _update, ctx) { return runWorkflow(params, signal, ctx, undefined, id); } });
  async function runWorkflow(params, signal, ctx, onSlashComplete, toolCallID) {
      const p = checked(workflowSchema, params), action = p.action ?? "start";
      if (!active) throw Error("No active parent session");
      signal?.throwIfAborted();
      if (action !== "start") {
        const w = workflows.get(p.id); if (!w) throw Error("Unknown workflow in this parent session");
        if (action === "cancel") { w.controller.abort(); await w.done; }
        if (action === "wait") {
          const deadline = Date.now() + Math.min(p.timeoutSeconds ?? 30, 60) * 1000;
          const inputVersion = parentInputVersion;
          while (w.state === "running" && Date.now() < deadline) {
            signal?.throwIfAborted();
            if (userInputWaiting || directInputWaiting || parentInputVersion !== inputVersion) {
              return { ...result({ ...workflowSummary(w), waitInterrupted: "user_input" }), terminate: true };
            }
            await new Promise((r) => setTimeout(r, 50));
          }
        }
        pendingNotices.delete(w.id);
        return result(workflowSummary(w));
      }
      if (!p.workflowScript) throw Error("workflowScript is required");
      if (workflows.size >= 32 || [...workflows.values()].filter((w) => w.state === "running").length >= 4) throw Error("Workflow limit reached: four active, 32 retained per parent");
      const w = { id: `workflow-${randomUUID()}`, owner, state: "running", async: p.async !== false, keys: new Map(), claims: new Set(), starts: new Set(), controller: new AbortController(),
        ...missionFor(p, p.task ?? "Scripted workflow") };
      workflows.set(w.id, w);
      pi.appendEntry("shepherd-workflow", { id: w.id, owner, ownerPID: process.pid, missionId: w.missionId });
      if (w.missionId) try { missions.update(w.missionId, (m) => { m.workflow = { id: w.id, state: "running" }; }); }
      catch (error) { workflows.delete(w.id); throw error; }
      const guard = () => { w.controller.signal.throwIfAborted(); if (!active || w.state !== "running") throw Error("Workflow is no longer accepting calls"); };
      const keySchema = Type.String({ minLength: 1, maxLength: 128, pattern: "^[a-zA-Z0-9][a-zA-Z0-9._-]*$" });
      async function runChild(key, params) {
        checked(Type.Object({ key: keySchema, params: startSchema }, { additionalProperties: false }), { key, params });
        if (params.mission !== undefined || params.missionId !== undefined) throw Error("Workflow owns its children's mission");
        guard();
        if (w.claims.has(key)) throw Error(`Duplicate workflow key: ${key}`);
        if (w.claims.size >= 64) throw Error("64 workflow children reached");
        w.claims.add(key);
        while ([...runs.values()].filter((r) => ["running", "queued"].includes(r.state)).length >= defaults.concurrency) {
          await new Promise((r) => setTimeout(r, 50)); guard();
        }
        guard();
        const promise = start({ ...params, ...(w.missionId ? { missionId: w.missionId } : { mission: false }) }, w.controller.signal, ctx, w.id, toolCallID, w.claims.size);
        w.starts.add(promise);
        let receipt;
        try { receipt = await promise; } finally { w.starts.delete(promise); }
        const run = get(receipt.id); w.keys.set(key, run);
        guard();
        await run.closed;
        guard();
        const value = { key, id: run.id, runId: run.id, agent: run.role, ok: run.state === "complete", state: run.state, output: run.output, error: run.error };
        if (run.state !== "complete") throw Error(`Child ${key} ${run.state}: ${run.error || run.output}`);
        return value;
      }
      async function call(method, args) {
        guard();
        if (method === "run") {
          checked(Type.Object({ key: keySchema, params: startSchema }, { additionalProperties: false }), args);
          return runChild(args.key, args.params);
        }
        if (method === "all") {
          const itemSchema = Type.Object({ key: keySchema, ...startSchema.properties }, { additionalProperties: false, required: ["key", "task"] });
          checked(Type.Object({ items: Type.Array(itemSchema, { minItems: 1, maxItems: 16 }) }, { additionalProperties: false }), args);
          return Promise.all(args.items.map(({ key, ...params }) => runChild(key, params).catch((error) => ({ key, ok: false, state: "failed", error: clip(error.message) }))));
        }
        if (method === "state.get" || method === "state.set") {
          checked(Type.Object({ key: keySchema, ...(method === "state.set" ? { value: Type.Unknown() } : {}) }, { additionalProperties: false }), args);
          if (["constructor", "prototype", "__proto__"].includes(args.key)) throw Error("Reserved state key");
          if (!w.missionId) throw Error("Workflow has no mission state");
          guard();
          if (method === "state.get") return Object.hasOwn(missions.read(w.missionId).state, args.key) ? missions.read(w.missionId).state[args.key] : undefined;
          return missions.update(w.missionId, (m) => { Object.defineProperty(m.state, args.key, { value: args.value, enumerable: true, configurable: true, writable: true }); }).state[args.key];
        }
        if (!["steer", "status", "cancel"].includes(method)) throw Error("Unsupported workflow operation");
        checked(Type.Object({ key: keySchema, ...(method === "steer" ? { message: textSchema, options: Type.Object({ mode: Type.Optional(StringEnum(["steer", "follow_up", "followUp", "auto"])) }, { additionalProperties: false }) } : {}) }, { additionalProperties: false }), args);
        // Keys are claimed before asynchronous Pi startup, so steering may wait for acceptance.
        while (w.claims.has(args.key) && !w.keys.has(args.key) && [...runs.values()].some((r) => r.workflowId === w.id && ["running", "queued"].includes(r.state))) {
          await new Promise((r) => setTimeout(r, 50)); guard();
        }
        const run = w.keys.get(args.key); if (!run) throw Error("Unknown workflow child key");
        guard();
        if (method === "steer") return send(run, args.message, ["follow_up", "followUp"].includes(args.options.mode) ? "followUp" : "steer");
        if (method === "cancel") await stop(run);
        return { key: args.key, id: run.id, state: run.state, output: run.output, error: run.error };
      }
      w.done = (async () => {
        try {
          w.output = await executeWorkflow(p.workflowScript, call, { signal: w.controller.signal, timeoutMs: (p.timeoutSeconds ?? 1800) * 1000, stateEnabled: !!w.missionId });
          guard();
          if (w.starts.size || [...runs.values()].some((r) => r.workflowId === w.id && ["running", "queued"].includes(r.state))) throw Error("Workflow returned with unfinished children");
          w.state = "complete";
        } catch (error) { w.state = w.controller.signal.aborted ? "stopped" : "failed"; w.error = clip(error.message); }
        finally {
          w.controller.abort();
          await Promise.allSettled([...w.starts]);
          await Promise.all([...runs.values()].filter((r) => r.workflowId === w.id).map((r) => stop(r, "Workflow ended")));
          w.cleaned = true;
          if (w.missionId) try { missions.update(w.missionId, (m) => {
            if (!["complete", "cancelled"].includes(m.status)) m.status = w.state === "complete" ? "waiting" : "needs_decision";
            m.workflow = { id: w.id, state: w.state, error: w.error };
          }); } catch (error) { w.missionWarning = clip(error.message); }
          if (active && owner === w.owner && onSlashComplete) { if (w.async) onSlashComplete(workflowSummary(w)); }
          else if (active && owner === w.owner && w.async) enqueueNotice(w.id,
            `Workflow ${w.id}: ${w.state}\n${w.error || clip(JSON.stringify(w.output))}\nUse this result to continue the task; do not acknowledge receipt.`, p.delivery !== "report");
        }
      })();
      if (p.async === false) {
        const abort = () => w.controller.abort(); signal?.addEventListener("abort", abort, { once: true });
        try {
          if (signal?.aborted) abort();
          const inputVersion = parentInputVersion;
          while (!w.cleaned) {
            if (userInputWaiting || directInputWaiting || parentInputVersion !== inputVersion) {
              w.async = true;
              return { ...result({ ...workflowSummary(w), waitInterrupted: "user_input" }), terminate: true };
            }
            await Promise.race([w.done, new Promise((resolve) => setTimeout(resolve, 50))]);
          }
        } finally { signal?.removeEventListener("abort", abort); }
      }
      return result(workflowSummary(w));
  }

  // session_start runs after every extension factory, so load order cannot
  // produce numeric /run collisions with pi-subagents' factory registrations.
  const registerCommands = () => registerNativeCommands(pi, {
    defaults, catalog: (ctx) => discoverChildAgents(ctx, defaults.scope), resolveModel,
    list: () => [...runs.values()].map(summary), get: (id) => summary(get(id)),
    send: (id, message, mode) => messageChild(get(id), checked(Type.Object({ message: textSchema }), { message }).message, mode, sessionContext),
    stop: async (id) => { const run = get(id); await stop(run); return summary(run); },
    workflow: (params, ctx, onComplete) => runWorkflow(params, undefined, ctx, onComplete).then((r) => r.details),
    missions: (id) => id ? missions.read(id) : missions.list(),
    workflows: (id) => {
      if (!id) return [...workflows.values()].map(workflowSummary);
      const workflow = workflows.get(id); if (!workflow) throw Error("Unknown workflow in this parent session");
      return workflowSummary(workflow);
    },
    doctor: (ctx) => [`Pi >= 0.85.1 · ${supported ? "supported" : "unsupported"}`,
      `child bridge · ${bridge && fs.existsSync(bridge) ? "available" : "missing"}`,
      `project trust · ${ctx.isProjectTrusted?.() === true ? "active" : "not granted"}`,
      `scope · ${defaults.scope} · context · ${defaults.context} · concurrency · ${defaults.concurrency}`,
      `${runs.size} retained children · ${[...runs.values()].filter((r) => ["running", "queued"].includes(r.state)).length} active · ${workflows.size} workflows`,
      "no provider probes · no configuration changes · children stop with this parent"],
  });
}
