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

export default function shepherdChildren(pi) {
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
      description: "Send a bounded progress message or question to your parent. For a question, set needsReply and finish this turn; the parent can continue your session with an answer.",
      parameters: Type.Object({ message: textSchema, needsReply: Type.Optional(Type.Boolean()), options: Type.Optional(Type.Array(Type.String({ minLength: 1, maxLength: 200 }), { maxItems: 6 })) }),
      async execute(_id, params) { return result({ shepherdParentMessage: params.message, needsReply: params.needsReply === true, options: params.needsReply === true ? params.options : undefined }); },
    });
    return;
  }
  if (process.env.SHEPHERD_NATIVE_CHILDREN !== "1" || !process.env.SHEPHERD_AGENT_ID || !process.env.SHEPHERD_SOCKET) return;

  const runs = new Map(), workflows = new Map();
  const defaults = childDefaults();
  let missions;
  let owner, active = false, timer, sessionContext;
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
    workflowId: run.workflowId, settled: run.settled, missionId: run.missionId, missionWarning: run.missionWarning, thinking: run.thinking, context: run.context, tools: run.tools, sessionFile: run.sessionFile, output: run.output, error: run.error, needsReply: run.needsReply, stopReason: run.lastStop, omittedInFlight: run.omittedInFlight,
    turns: run.turns, toolCalls: run.toolCalls, tokens: run.tokens, contextPercent: run.contextPercent, files: fileChanges(run), added: run.added, removed: run.removed, lastActivity: run.lastActivity, questionOptions: run.questionOptions, questionText: run.questionText, exitCode: run.exitCode, toolCallID: run.toolCallID, stepIndex: run.stepIndex });
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
      question: run.needsReply ? { text: run.questionText ?? clip(run.output, 600), options: run.questionOptions } : undefined,
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
  function notify(run, message) {
    if (!current(run) || run.workflowId) return;
    try { pi.sendMessage({ customType: "shepherd-child", content: `Child ${run.id} (${run.role}): ${clip(message)}`, display: true },
      { triggerTurn: true, deliverAs: "followUp" }); } catch { /* Result remains retrievable by id. */ }
  }
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
  function finish(run, code, signal) {
    if (run.exited) return;
    run.exited = true;
    clearTimeout(run.drainTimer);
    for (const pending of run.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error("Child exited")); }
    run.pending.clear();
    run.exitCode = code ?? undefined;
    if (run.cancelled) run.state = "stopped";
    else if (!run.settled || run.error || (code !== 0 && code !== null) || signal) {
      run.state = "failed";
      run.error ||= `Child exited before clean settlement (${signal ?? code}): ${run.stderr}`;
    } else run.state = "complete";
    run.endedAt = Date.now(); run.currentTool = undefined; run.paused = false;
    try {
      const lease = JSON.parse(fs.readFileSync(path.join(run.dir, "writer", "owner.json"), "utf8"));
      if (lease.token === run.token) { fs.unlinkSync(path.join(run.dir, "writer", "owner.json")); fs.rmdirSync(path.join(run.dir, "writer")); }
    } catch {}
    run.proc = undefined;
    save(run); run.resolveClosed();
    notify(run, `${run.state}\n${run.error || run.output || "No text result"}\nSession: ${run.sessionFile}`);
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
          run.questionOptions = run.needsReply && Array.isArray(details.options) ? details.options.filter((o) => typeof o === "string").slice(0, 6) : undefined;
          run.output = clip(details.shepherdParentMessage);
          run.questionText = run.needsReply ? clip(run.output, 600) : undefined;
          notify(run, `${run.needsReply ? "Needs reply: " : ""}${run.output}`);
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
    const leaseDir = path.join(run.dir, "writer");
    try { fs.mkdirSync(leaseDir, { mode: 0o700 }); }
    catch (error) {
      if (error.code !== "EEXIST") throw error;
      const lease = JSON.parse(fs.readFileSync(path.join(leaseDir, "owner.json"), "utf8"));
      if (alive(lease.pid)) throw new Error("Child session already has a live writer");
      throw new Error(`Child has an interrupted writer lease at ${leaseDir}. Verify the old process has exited before removing that lease directory; automatic crash recovery is disabled.`);
    }
    run.token = randomUUID();
    atomic(path.join(leaseDir, "owner.json"), { pid: process.pid, token: run.token });
    run.pending = new Map(); run.exited = false; run.cancelled = false; run.settled = false;
    run.paused = false;
    run.stopping = undefined; run.output = ""; run.error = undefined; run.stderr = ""; run.lastStop = undefined; run.availableTools = undefined;
    run.needsReply = false; run.questionOptions = undefined; run.questionText = undefined; run.exitCode = undefined; run.endedAt = undefined; run.startedAt = Date.now(); run.state = "running";
    run.toolArgs = new Map(); run.files ??= new Map();
    run.closed = new Promise((resolve) => { run.resolveClosed = resolve; });
    const env = { ...process.env };
    for (const key of Object.keys(env)) if (key.startsWith("SHEPHERD_") || key.startsWith("PI_SUBAGENT") || ["PI_SESSION_ID", "PI_SESSION_FILE", "PI_PROVIDER", "PI_MODEL", "PI_REASONING_LEVEL"].includes(key)) delete env[key];
    env.SHEPHERD_CHILD = "1"; env.PI_OFFLINE = "1";
    env.SHEPHERD_CHILD_TOOLS = JSON.stringify([...run.tools, "shepherd_parent_message"]);
    const args = ["--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-approve",
      "-e", bridge, "--session", run.sessionFile, "--model", run.model, "--thinking", run.thinking,
      "--tools", [...run.tools, "shepherd_parent_message"].join(","),
      run.systemPromptMode === "replace" ? "--system-prompt" : "--append-system-prompt", path.join(run.dir, "prompt.md")];
    if (run.inheritProjectContext === false) args.push("--no-context-files");
    for (const skill of run.skills ?? []) args.push("--skill", skill);
    // Resolve at each launch, including resume, so Pi resource enable/disable changes apply.
    // No provider-specific lookup or credential export: Pi loads its own provider extensions.
    for (const extension of new Set([...inherited, ...(run.extensions ?? [])])) {
      if (fs.realpathSync(extension) !== fs.realpathSync(bridge)) args.push("-e", extension);
    }
    const script = path.join(getPackageDir(), "dist", "cli.js");
    const executable = /^(node|bun)(\.exe)?$/i.test(path.basename(process.execPath)) ? process.execPath : "pi";
    run.proc = spawn(executable, executable === process.execPath ? [script, ...args] : args,
      { cwd: run.cwd, env, detached: false, stdio: ["pipe", "pipe", "pipe"] });
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
        throw new Error(`Model ${run.model} is unavailable in isolated Pi. Check the model id and enabled Pi user extensions; project or CLI-only providers require an explicit profile extension.`);
      }
      if (!current(run) || signal?.aborted) throw new Error("Parent session ended or dispatch cancelled");
      await command(run, "prompt", { message });
    } catch (error) { await stop(run, clip(error.message)); throw error; }
    finally { signal?.removeEventListener("abort", abort); }
    return summary(run);
  }
  function get(id) { const run = runs.get(id); if (!run) throw new Error("Unknown child id in this parent session"); return run; }
  function capacity() { if ([...runs.values()].filter((r) => r.state === "running" || r.state === "queued").length >= defaults.concurrency) throw new Error(`${defaults.concurrency === 4 ? "Four" : defaults.concurrency} children are already active; wait or cancel first`); }
  async function send(run, message, mode = "steer") {
    if (!run.proc || run.exited || run.cancelled || run.settled) throw new Error("Child is not accepting messages; use shepherd_child_resume after it exits");
    await command(run, "prompt", { message, streamingBehavior: mode });
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
          files: new Map((Array.isArray(status.files) ? status.files : []).map((f) => typeof f === "string" ? [f, { added: 0, removed: 0 }] : [f.path, { added: f.added ?? 0, removed: f.removed ?? 0 }])), lastActivity: status.lastActivity, questionOptions: status.questionOptions, questionText: status.questionText, exitCode: status.exitCode,
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
    timer = setInterval(() => { for (const run of runs.values()) void controls(run); publish(); }, 1000);
    timer.unref(); publish();
    registerCommands();
  });
  pi.on("session_shutdown", async () => {
    active = false; clearInterval(timer); clearTimeout(controlRetry);
    const socket = control; control = undefined; socket?.destroy();
    for (const workflow of workflows.values()) workflow.controller.abort();
    await Promise.all([...workflows.values()].map((w) => w.done));
    await Promise.all([...runs.values()].map((run) => stop(run, "Parent session ended")));
  });

  const missionSchema = Type.Object({ title: textSchema, objective: Type.Optional(textSchema) }, { additionalProperties: false });
  const startSchema = Type.Object({ task: textSchema, role: Type.Optional(idSchema), agent: Type.Optional(idSchema), context: Type.Optional(StringEnum(["fresh", "fork"])),
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
    if (resolved.error || !resolved.model) throw Error(resolved.error || "Select a model in the parent first");
    return resolved;
  }
  async function start(params, signal, ctx, workflowId, toolCallID, stepIndex) {
      params = checked(startSchema, params);
      if (!active) throw new Error("No active parent session");
      if (!supported) throw new Error("Shepherd native children require Pi 0.85.1 or newer");
      signal?.throwIfAborted(); capacity();
      if (runs.size >= MAX_RUNS) throw new Error("64 retained children reached; start a new parent session");
      if (params.agent && params.role) throw Error("Use agent or role, not both");
      const cwd = fs.realpathSync(path.resolve(ctx.cwd, params.cwd ?? "."));
      if (!fs.statSync(cwd).isDirectory()) throw new Error("Child cwd must be a directory");
      const targetContext = childTargetContext(ctx, cwd);
      const catalog = discoverChildAgents(targetContext, defaults.scope);
      const name = params.agent ?? params.role ?? "worker";
      const exact = catalog.agents.filter((a) => a.name === name);
      const matches = exact.length ? exact : catalog.agents.filter((a) => a.aliases?.includes(name));
      if (matches.length !== 1) throw Error(`Unknown or ambiguous agent: ${name}; use shepherd_child_agents`);
      const profile = matches[0], role = profile.name;
      if (profile.error || profile.disabled) throw Error(profile.error || `Agent ${role} is disabled`);
      if (profile.tools === "inherit") throw Error("tools: inherit requires ambient extensions, which native children do not inherit. Omit tools for Pi builtins or list tools and explicit extension files.");
      const requestedTools = profile.tools ?? defaultChildTools(cwd);
      const unknownTools = requestedTools.filter((name) => !ROLES.worker.tools.includes(name) && name !== "shepherd_parent_message");
      if (unknownTools.length && !profile.extensions?.length) throw Error(`Unsupported agent tools without explicit extensions: ${unknownTools.join(", ")}`);
      if (requestedTools.some((name) => /^(shepherd_child_|shepherd_workflow|subagent$)/.test(name))) throw Error("Nested delegation tools are unsupported");
      const resolved = resolveModel(profile, ctx, params.model);
      const model = `${resolved.model.provider}/${resolved.model.id}`;
      if (!bridge) throw new Error("Shepherd child extension path is missing");
      const id = `native-${randomUUID()}`, dir = path.join(root, id);
      fs.mkdirSync(path.join(dir, "control", "steer-requests"), { recursive: true, mode: 0o700 });
      const run = { id, dir, owner, role, model, cwd, thinking: params.thinking ?? resolved.thinkingLevel ?? profile.thinking ?? defaults.thinking ?? ctx.thinkingLevel ?? "off", task: params.task,
        context: params.context ?? profile.context ?? defaults.context,
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
        fs.writeFileSync(path.join(dir, "prompt.md"), `You are a Shepherd child, not the parent. ${profile.prompt}\nWork only on the delegated task. No nested helpers, workflows, schedules, or worktree management. Use shepherd_parent_message for progress or questions. For a question set needsReply and finish your turn. Your parent can resume with an answer.\n`, { mode: 0o600 });
        const { dir: _dir, output: _output, files: _files, ...descriptor } = run;
        pi.appendEntry("shepherd-child", descriptor);
        return await launch(run, params.task, signal);
      } catch (error) { if (!run.proc) { run.state = "failed"; run.endedAt = Date.now(); run.error = clip(error.message); save(run); } throw error; }
  }
  pi.registerTool({ name: "shepherd_child_agents", label: "child agents", description: "List effective agent profiles, sources and unsupported-field diagnostics. Reads user files and trusted project files without changing them.",
    parameters: Type.Object({}), async execute(_id, _p, _s, _u, ctx) { return result({ defaults, ...discoverChildAgents(ctx, defaults.scope) }); } });
  pi.registerTool({ name: "shepherd_child_start", label: "start child", parameters: startSchema,
    description: "Start an owned background Pi helper. Use shepherd_child_agents for discovered profiles. Explicit call overrides profile, then Shepherd defaults, then parent model/thinking. Fresh or fork context; tools intersect the parent allowlist. Cwd is not a sandbox. Completion wakes the parent. Default creates a mission; mission:false opts out. No nested delegation or automatic worktrees.",
    async execute(id, p, signal, _update, ctx) { return result(await start(p, signal, ctx, undefined, id)); } });
  pi.registerTool({ name: "shepherd_child_message", label: "message child", description: "Message a running child. Acceptance is not completion. Steer runs after current tools; followUp waits for the turn to end.",
    parameters: Type.Object({ id: idSchema, message: textSchema, mode: Type.Optional(StringEnum(["steer", "followUp"])) }),
    async execute(_id, p) { return result(await send(get(p.id), p.message, p.mode)); } });
  pi.registerTool({ name: "shepherd_child_result", label: "child results", description: "Read one child result or list this parent's retained children. Output is capped at 16 KiB per result and may be truncated; full conversation is in sessionFile. No live work survives parent shutdown.",
    parameters: Type.Object({ id: Type.Optional(idSchema) }),
    async execute(_id, p) { return result(p.id ? summary(get(p.id)) : [...runs.values()].map((r) => ({ id: r.id, role: r.role, state: r.state, task: clip(r.task, 160) }))); } });
  pi.registerTool({ name: "shepherd_child_wait", label: "wait for children", description: "Wait for any or all selected children to exit, up to 60 seconds. Timeout or cancelling this wait does not stop the children. Returns bounded results for up to 16 ids.",
    parameters: Type.Object({ ids: Type.Array(idSchema, { minItems: 1, maxItems: 16 }), all: Type.Optional(Type.Boolean()), timeoutSeconds: Type.Optional(Type.Number({ minimum: 0, maximum: 60 })) }),
    async execute(_id, p, signal) {
      const selected = p.ids.map(get), deadline = Date.now() + (p.timeoutSeconds ?? 30) * 1000;
      while (Date.now() < deadline) {
        signal?.throwIfAborted();
        const done = selected.map((r) => !["running", "queued"].includes(r.state));
        if (p.all ? done.every(Boolean) : done.some(Boolean)) break;
        await new Promise((r) => setTimeout(r, 100));
      }
      return result(selected.map((r) => ({ ...summary(r), output: clip(r.output, 4096) })));
    } });
  pi.registerTool({ name: "shepherd_child_cancel", label: "cancel child", description: "Clear queued work, abort, and terminate an owned child. Returns only after its process exits. Session history remains available for explicit continuation.",
    parameters: Type.Object({ id: idSchema }), async execute(_id, p) { const run = get(p.id); await stop(run); return result(summary(run)); } });
  pi.registerTool({ name: "shepherd_child_resume", label: "continue child", description: "Continue a completed, failed, or stopped child session with a new task or answer. Keeps its role, model, cwd, and history. Rejects concurrent writers and missing transcripts. Does not replay interrupted work automatically.",
    parameters: Type.Object({ id: idSchema, message: textSchema }), async execute(_id, p, signal, _update, ctx) {
      return result(await resume(get(p.id), p.message, signal, ctx));
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
  async function messageChild(run, message, mode, ctx) {
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

  const workflowSchema = Type.Object({ action: Type.Optional(StringEnum(["start", "status", "cancel", "wait"])), id: Type.Optional(idSchema),
    workflowScript: Type.Optional(Type.String({ minLength: 1, maxLength: 32768 })), task: Type.Optional(textSchema),
    async: Type.Optional(Type.Boolean()), timeoutSeconds: Type.Optional(Type.Number({ minimum: 0.1, maximum: 1800 })),
    missionId: Type.Optional(idSchema), mission: Type.Optional(Type.Union([Type.Boolean(), missionSchema])) }, { additionalProperties: false });
  const workflowSummary = (w) => ({ id: w.id, state: w.state, output: w.output, error: w.error, missionId: w.missionId, missionWarning: w.missionWarning,
    children: [...w.keys].map(([key, run]) => ({ key, id: run.id, state: run.state })) });
  pi.registerTool({ name: "shepherd_workflow", label: "workflow", parameters: workflowSchema,
    description: "Start a background JavaScript statement body with runs.run(key,{agent,task,...}), runs.all([{key,agent,task,...}]), runs.steer(key,message,{mode}), runs.status(key), runs.cancel(key). Await or return calls. Use ordinary sequencing/branching; no imports, process or filesystem API. This is restricted execution, NOT an OS sandbox. Children retain their normal tools. Default 30-minute deadline and enclosing mission; mission:false disables persistence and state.get/set. async:false waits. status/wait/cancel target this parent's workflow id. No automatic retries, worktrees or scheduling.",
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
          while (w.state === "running" && Date.now() < deadline) { signal?.throwIfAborted(); await new Promise((r) => setTimeout(r, 50)); }
        }
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
          if (active && owner === w.owner && onSlashComplete) { if (p.async !== false) onSlashComplete(workflowSummary(w)); }
          else if (active && owner === w.owner) try { pi.sendMessage({ customType: "shepherd-workflow", content: `Workflow ${w.id}: ${w.state}\n${w.error || clip(JSON.stringify(w.output))}`, display: true }, { triggerTurn: true, deliverAs: "followUp" }); } catch {}
        }
      })();
      if (p.async === false) {
        const abort = () => w.controller.abort(); signal?.addEventListener("abort", abort, { once: true });
        try { if (signal?.aborted) abort(); await w.done; } finally { signal?.removeEventListener("abort", abort); }
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
