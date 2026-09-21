import Foundation
import ShepherdProtocol

/// Installs the opt-in, extension-owned native child runtime.
enum ChildrenExtension {
    static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in sources {
            let url = directory.appendingPathComponent(name)
            let source = Data(text.utf8)
            if (try? Data(contentsOf: url)) != source {
                try source.write(to: url, options: .atomic)
            }
        }
        let url = directory.appendingPathComponent("shepherd-children.ts")
        return url.path
    }

    static var sources: [(String, String)] {
        [("shepherd-children.ts", extensionSource), ("shepherd-children-config.ts", configSource),
         ("shepherd-workflow.ts", workflowSource), ("shepherd-missions.ts", missionsSource),
         ("shepherd-children-ui.ts", uiSource), ("shepherd-inspect.mjs", InspectExtension.extensionSource)]
    }

    /// Extensions/shepherd-children.ts is canonical.
    static let extensionSource = #"""
        // @ts-nocheck -- loaded by pi/jiti; no separate Node workspace is required.
        // Execution belongs to this extension. shepherd-subagents.ts is the only sidebar publisher.
        import { spawn, execFileSync } from "node:child_process";
        import * as fs from "node:fs";
        import * as path from "node:path";
        import { randomUUID } from "node:crypto";
        import { StringDecoder } from "node:string_decoder";
        import { SessionManager, createBashTool, getPackageDir, resolveCliModel } from "@earendil-works/pi-coding-agent";
        import { Type } from "typebox";
        import { bundledAgents as ROLES, childDefaults, discoverChildAgents, childSkills, childTargetContext, defaultChildTools, thinkingLevels } from "./shepherd-children-config.ts";
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
            pi.registerTool(createBashTool(process.cwd(), { operations: childBashOperations() }));
            if (process.env.SHEPHERD_CHILD_TOOLS) {
              const allowed = new Set(JSON.parse(process.env.SHEPHERD_CHILD_TOOLS));
              pi.on("tool_call", (event) => allowed.has(event.toolName) ? undefined : { block: true, reason: "Tool exceeds the parent child allowlist" });
              pi.on("session_start", (_event, ctx) => ctx.ui.notify(JSON.stringify({ shepherdChildTools: pi.getActiveTools() }), "info"));
            }
            pi.registerTool({
              name: "shepherd_parent_message", label: "message parent",
              description: "Send a bounded progress message or question to your parent. For a question, set needsReply and finish this turn; the parent can continue your session with an answer.",
              parameters: Type.Object({ message: textSchema, needsReply: Type.Optional(Type.Boolean()) }),
              async execute(_id, params) { return result({ shepherdParentMessage: params.message, needsReply: params.needsReply === true }); },
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
          const summary = (run) => ({ id: run.id, role: run.role, state: run.state, task: run.task, startedAt: run.startedAt, endedAt: run.endedAt, currentTool: run.currentTool, latestTool: run.latestTool, model: run.model, cwd: run.cwd,
            workflowId: run.workflowId, settled: run.settled, missionId: run.missionId, missionWarning: run.missionWarning, thinking: run.thinking, context: run.context, tools: run.tools, sessionFile: run.sessionFile, output: run.output, error: run.error, needsReply: run.needsReply, stopReason: run.lastStop, omittedInFlight: run.omittedInFlight });
          function publish() {
            if (!active) return;
            pi.events.emit(EVENT, { owner, children: [...runs.values()].sort((a, b) =>
              Number(b.state === "running" || b.state === "queued") - Number(a.state === "running" || a.state === "queued")
              || Number(b.needsReply === true) - Number(a.needsReply === true) || b.startedAt - a.startedAt).slice(0, 20).map((run) => ({
              runID: run.id, label: `${run.role}: ${clip(run.task, 100)}`, state: run.state,
              startedAt: run.startedAt, endedAt: run.endedAt, currentTool: run.currentTool,
              needsAttention: run.needsReply === true, attentionText: run.needsReply ? clip(run.output, 160) : undefined, asyncDir: run.dir,
            })) });
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
            run.cancelled = true; run.error = reason; run.state = "running";
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
            if (run.cancelled) run.state = "stopped";
            else if (!run.settled || run.error || (code !== 0 && code !== null) || signal) {
              run.state = "failed";
              run.error ||= `Child exited before clean settlement (${signal ?? code}): ${run.stderr}`;
            } else run.state = "complete";
            run.endedAt = Date.now(); run.currentTool = undefined;
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
              run.currentTool = clip(event.toolName, 160); run.latestTool = run.currentTool; save(run);
            } else if (event.type === "tool_execution_end") {
              run.currentTool = undefined;
              if (event.toolName === "shepherd_parent_message") {
                const details = event.result?.details;
                if (typeof details?.shepherdParentMessage === "string") {
                  run.needsReply = details.needsReply === true;
                  run.output = clip(details.shepherdParentMessage);
                  notify(run, `${run.needsReply ? "Needs reply: " : ""}${run.output}`);
                }
              }
              save(run);
            } else if (event.type === "message_end" && event.message?.role === "assistant") {
              const message = event.message;
              run.output = clip((message.content ?? []).filter((p) => p.type === "text").map((p) => p.text).join("\n"));
              run.error = ["error", "aborted"].includes(message.stopReason) ? clip(message.errorMessage || message.stopReason) : undefined;
              run.lastStop = message.stopReason;
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
            run.stopping = undefined; run.output = ""; run.error = undefined; run.stderr = ""; run.lastStop = undefined; run.availableTools = undefined;
            run.needsReply = false; run.endedAt = undefined; run.startedAt = Date.now(); run.state = "running";
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
            for (const extension of run.extensions ?? []) args.push("-e", extension);
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
                throw new Error(`Model ${run.model} is unavailable in isolated Pi. Choose a built-in or models.json provider; parent extension-only providers are not inherited.`);
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
          pi.on("session_start", (_event, ctx) => {
            owner = ctx.sessionManager.getSessionId(); active = true; sessionContext = ctx;
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
            active = false; clearInterval(timer);
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
          async function start(params, signal, ctx, workflowId) {
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
                tools: requestedTools.filter((name) => pi.getActiveTools().includes(name)), state: "queued", startedAt: Date.now(), sessionFile: path.join(dir, "session.jsonl"), output: "" };
              runs.set(id, run);
              try {
                if (run.context === "fork") Object.assign(run, forkSession(ctx.sessionManager, cwd, run.sessionFile));
                else {
                  const sm = SessionManager.inMemory(cwd);
                  fs.writeFileSync(run.sessionFile, JSON.stringify(sm.getHeader()) + "\n", { mode: 0o600 });
                }
                fs.writeFileSync(path.join(dir, "prompt.md"), `You are a Shepherd child, not the parent. ${profile.prompt}\nWork only on the delegated task. No nested helpers, workflows, schedules, or worktree management. Use shepherd_parent_message for progress or questions. For a question set needsReply and finish your turn. Your parent can resume with an answer.\n`, { mode: 0o600 });
                const { dir: _dir, output: _output, ...descriptor } = run;
                pi.appendEntry("shepherd-child", descriptor);
                return await launch(run, params.task, signal);
              } catch (error) { if (!run.proc) { run.state = "failed"; run.endedAt = Date.now(); run.error = clip(error.message); save(run); } throw error; }
          }
          pi.registerTool({ name: "shepherd_child_agents", label: "child agents", description: "List effective agent profiles, sources and unsupported-field diagnostics. Reads user files and trusted project files without changing them.",
            parameters: Type.Object({}), async execute(_id, _p, _s, _u, ctx) { return result({ defaults, ...discoverChildAgents(ctx, defaults.scope) }); } });
          pi.registerTool({ name: "shepherd_child_start", label: "start child", parameters: startSchema,
            description: "Start an owned background Pi helper. Use shepherd_child_agents for discovered profiles. Explicit call overrides profile, then Shepherd defaults, then parent model/thinking. Fresh or fork context; tools intersect the parent allowlist. Cwd is not a sandbox. Completion wakes the parent. Default creates a mission; mission:false opts out. No nested delegation or automatic worktrees.",
            async execute(_id, p, signal, _update, ctx) { return result(await start(p, signal, ctx)); } });
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
            async execute(_id, params, signal, _update, ctx) { return runWorkflow(params, signal, ctx); } });
          async function runWorkflow(params, signal, ctx, onSlashComplete) {
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
              const w = { id: `workflow-${randomUUID()}`, owner, state: "running", keys: new Map(), claims: new Set(), starts: new Set(), controller: new AbortController(),
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
                const promise = start({ ...params, ...(w.missionId ? { missionId: w.missionId } : { mission: false }) }, w.controller.signal, ctx, w.id);
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

        """#

    /// Extensions/shepherd-children-config.ts is canonical.
    static let configSource = #"""
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

        """#

    /// Extensions/shepherd-workflow.ts is canonical.
    static let workflowSource = #"""
        // @ts-nocheck -- Pi loads this module through jiti.
        import { Worker } from "node:worker_threads";

        // The VM receives only strings, never worker objects, callbacks, promises or errors.
        // This restricts the scripting API; neither node:vm nor a Worker is an OS sandbox.
        function workflowWorker() {
          const { parentPort, workerData } = require("node:worker_threads");
          const vm = require("node:vm");
          const context = vm.createContext(Object.create(null), { codeGeneration: { strings: false, wasm: false } });
          const bootstrap = `
            "use strict";
            const pending = new Map();
            const outbox = [];
            let sequence = 0, outcome;
            const encode = JSON.stringify.bind(JSON);
            function request(method, args) {
              if (sequence >= 512) return Promise.reject(new Error("Workflow call limit exceeded"));
              if (pending.size >= 64) return Promise.reject(new Error("Workflow request queue is full"));
              const id = ++sequence;
              const text = encode({ id, method, args });
              if (text.length > 65536) return Promise.reject(new Error("Workflow request exceeds 64 KiB"));
              outbox.push(text);
              return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
            }
            const runs = Object.freeze({
              run: (key, params) => request("run", { key, params }),
              all: (items) => request("all", { items }),
              steer: (key, message, options = {}) => request("steer", { key, message, options }),
              status: (key) => request("status", { key }),
              cancel: (key) => request("cancel", { key })
            });
            const state = ${workerData.stateEnabled ? 'Object.freeze({ get: (key) => request("state.get", { key }), set: (key, value) => request("state.set", { key, value }) })' : 'undefined'};
            function receive() {
              const message = JSON.parse(incoming);
              const entry = pending.get(message.id);
              if (!entry) return;
              pending.delete(message.id);
              message.error === undefined ? entry.resolve(message.value) : entry.reject(new Error(message.error));
            }
            function drain() {
              const messages = outbox.splice(0);
              return encode({ messages, outcome });
            }
          `;
          const run = (code) => new vm.Script(code).runInContext(context, { timeout: 100 });
          try {
            run(bootstrap);
            run(`(async () => {\n${workerData.script}\n})().then(value => {
              if (pending.size) throw new Error("Workflow returned with pending calls; await or return every runs/state call");
              const text = encode(value === undefined ? null : value);
              if (text.length > 65536) throw new Error("Workflow result exceeds 64 KiB");
              outcome = { value: JSON.parse(text) };
            }).catch(error => { outcome = { error: String(error?.message || error).slice(0, 16384) }; }); void 0;`);
            const flush = () => {
              try {
                const text = run("drain()");
                if (typeof text !== "string" || text.length > 1024 * 1024) throw Error("Invalid workflow output");
                const { messages, outcome } = JSON.parse(text);
                for (const message of messages) parentPort.postMessage({ type: "call", text: message });
                if (outcome) { clearInterval(timer); parentPort.postMessage({ type: "done", text: JSON.stringify(outcome) }); }
              } catch (error) { clearInterval(timer); parentPort.postMessage({ type: "done", text: JSON.stringify({ error: "Workflow VM execution failed or exceeded its synchronous limit" }) }); }
            };
            parentPort.on("message", (text) => {
              try { context.incoming = text; run("receive(); void 0"); delete context.incoming; }
              catch (error) { parentPort.postMessage({ type: "done", text: JSON.stringify({ error: "Workflow VM execution failed or exceeded its synchronous limit" }) }); }
            });
            const timer = setInterval(flush, 10);
          } catch (error) { parentPort.postMessage({ type: "done", text: JSON.stringify({ error: "Workflow VM execution failed or exceeded its synchronous limit" }) }); }
        }

        export async function executeWorkflow(script, call, { signal, timeoutMs = 30 * 60 * 1000, stateEnabled = false } = {}) {
          signal?.throwIfAborted();
          const worker = new Worker(`(${workflowWorker.toString()})()`, { eval: true, workerData: { script, stateEnabled }, env: {},
            resourceLimits: { maxOldGenerationSizeMb: 64, maxYoungGenerationSizeMb: 16, stackSizeMb: 4 } });
          let timer, abort, ended = false, count = 0;
          try {
            return await new Promise((resolve, reject) => {
              const fail = (error) => { ended = true; reject(error); };
              abort = () => fail(Error("Workflow cancelled"));
              signal?.addEventListener("abort", abort, { once: true });
              if (signal?.aborted) { abort(); return; }
              timer = setTimeout(() => fail(Error("Workflow deadline exceeded")), timeoutMs);
              worker.on("error", fail);
              worker.on("exit", (code) => { if (!ended) fail(Error(`Workflow worker exited (${code})`)); });
              worker.on("message", async (message) => {
                if (ended) return;
                try {
                  if (typeof message.text !== "string" || Buffer.byteLength(message.text) > 128 * 1024) throw Error("Invalid workflow frame");
                  const data = JSON.parse(message.text);
                  if (message.type === "done") { ended = true; data.error === undefined ? resolve(data.value) : reject(Error(data.error)); return; }
                  if (message.type !== "call" || ++count > 512) throw Error("Workflow call limit exceeded");
                  let reply;
                  try { reply = { id: data.id, value: await call(data.method, data.args) }; }
                  catch (error) { reply = { id: data.id, error: String(error.message).slice(0, 16384) }; }
                  const text = JSON.stringify(reply);
                  if (Buffer.byteLength(text) > 512 * 1024) throw Error("Workflow response exceeds 512 KiB");
                  if (!ended) worker.postMessage(text);
                } catch (error) { fail(error); }
              });
            });
          } finally {
            ended = true; clearTimeout(timer); signal?.removeEventListener("abort", abort);
            await worker.terminate();
          }
        }

        """#

    /// Extensions/shepherd-missions.ts is canonical.
    static let missionsSource = #"""
        // @ts-nocheck -- Pi loads this module through jiti.
        import * as fs from "node:fs";
        import * as path from "node:path";
        import { createHash, randomUUID } from "node:crypto";

        // Separate from pi-subagents data. Records carry no executable configuration.
        export function missionStore(root, cwd) {
          const project = fs.realpathSync(cwd);
          const dir = path.join(root, "missions", createHash("sha256").update(project).digest("hex"));
          const file = (id) => {
            if (typeof id !== "string" || !/^mission-[0-9a-f-]{36}$/.test(id)) throw Error("Invalid mission id");
            return path.join(dir, `${id}.json`);
          };
          const read = (id) => {
            const target = file(id);
            if (fs.statSync(target).size > 256 * 1024) throw Error("Mission exceeds 256 KiB");
            const record = JSON.parse(fs.readFileSync(target, "utf8"));
            if (record.id !== id || record.project !== project) throw Error("Mission project mismatch");
            return record;
          };
          function write(record) {
            const text = JSON.stringify(record);
            if (Buffer.byteLength(text) > 256 * 1024) throw Error("Mission exceeds 256 KiB");
            const target = file(record.id), tmp = `${target}.${randomUUID()}.tmp`;
            try { fs.writeFileSync(tmp, text, { mode: 0o600, flag: "wx" }); fs.renameSync(tmp, target); }
            finally { try { fs.unlinkSync(tmp); } catch {} }
            return record;
          }
          return {
            read,
            list() { return fs.existsSync(dir) ? fs.readdirSync(dir).filter((name) => /^mission-[0-9a-f-]{36}\.json$/.test(name)).sort().slice(-200).map((name) => read(name.slice(0, -5))) : []; },
            create(title, objective = title) {
              fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
              return write({ id: `mission-${randomUUID()}`, project, title, objective, status: "planned", runs: [], attachments: [], state: {}, createdAt: Date.now(), updatedAt: Date.now() });
            },
            update(id, change) {
              // Synchronous read/modify/write is atomic within a parent; mkdir excludes other parents.
              fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
              const lock = `${file(id)}.lock`;
              try { fs.mkdirSync(lock, { mode: 0o700 }); }
              catch (error) { if (error.code === "EEXIST") throw Error("Mission is locked; retry after the other writer finishes. Crash locks require manual verification."); throw error; }
              try { const record = read(id); change(record); record.updatedAt = Date.now(); return write(record); }
              finally { fs.rmdirSync(lock); }
            },
          };
        }

        """#

    /// Extensions/shepherd-children-ui.ts is canonical.
    static let uiSource = #"""
        // @ts-nocheck -- Pi loads this module through jiti. Native commands never dispatch a parent prompt.
        import { Input, Text, matchesKey, truncateToWidth } from "@earendil-works/pi-tui";
        import { cleanText, clipColumns, duration, endTime, readTranscript, TranscriptViewport, wrapColumns, displayWidth, identityLine, composerLabel, repliesByResume, statusColor, stopScope } from "./shepherd-inspect.mjs";

        export const commandNames = ["subagents", "run", "subagents-fleet", "subagents-stop", "subagents-models", "subagents-doctor", "missions", "workflows"];
        export function nativeCommandNames(commands, tools) {
          const occupied = new Set(commands.map((c) => c.name.split(":")[0]));
          const legacy = tools.some((t) => t.name === "subagent" || /(?:^|[/:])pi-subagents(?:[@/]|$)/.test(t.sourceInfo?.source ?? ""));
          const collisions = legacy || commandNames.some((name) => occupied.has(name));
          return Object.fromEntries(commandNames.map((name) => {
            let chosen = collisions ? `shepherd-${name}` : name;
            while (occupied.has(chosen)) chosen = `shepherd-${chosen}`;
            return [name, chosen];
          }));
        }
        export function parseRunCommand(args) {
          let text = args.trim(), background = false, fork = false;
          for (;;) {
            const flag = text.match(/(?:^|\s)(--bg|--fork)$/);
            if (!flag) break;
            if (flag[1] === "--bg") background = true; else fork = true;
            text = text.slice(0, flag.index).trimEnd();
          }
          const match = text.match(/^(\S+)(?:\s+([\s\S]*))?$/);
          if (match?.[1].includes("[") || match?.[1].includes("]") || /^\s*\[[^\]]*=/.test(match?.[2] ?? "")) throw Error("Inline [config] is unsupported by native /run. Put supported settings in an agent file.");
          if (!match?.[2]?.trim()) throw Error("Usage: /run <agent> <task...> [--bg] [--fork]");
          if (match[1].startsWith("--")) throw Error("Specify an agent before the task; flags belong at the end.");
          if (match[1].length > 80 || match[2].length > 16384) throw Error("Agent or task exceeds the native input limit");
          const params = { agent: match[1], task: match[2].trim(), ...(fork ? { context: "fork" } : {}) };
          return { task: params.task, async: background, workflowScript: `return await runs.run("run", ${JSON.stringify(params)});` };
        }
        export function orderedFleet(runs) {
          const rank = (r) => r.needsReply ? 0 : ["running", "queued"].includes(r.state) ? 1 : r.state === "failed" ? 2 : 3;
          return [...runs].sort((a, b) => rank(a) - rank(b) || (b.startedAt ?? 0) - (a.startedAt ?? 0) || a.id.localeCompare(b.id));
        }
        export function fleetRow(run, width, selected, now = Date.now()) {
          const state = run.needsReply ? "needs reply" : run.state;
          const age = duration(run.startedAt, endTime(run), now) || "?";
          const taskWidth = Math.max(1, width - 42);
          const task = clipColumns(run.task, taskWidth);
          return clipColumns(`${selected ? ">" : " "} ● ${state.padEnd(11)} | ${task}${" ".repeat(Math.max(0, taskWidth - displayWidth(task)))} | ${(age === "duration unavailable" ? "?" : age).padStart(7)} | ${run.currentTool ?? run.latestTool ?? ""}`, width);
        }
        const oneArgument = (args) => {
          const words = args.trim().split(/\s+/).filter(Boolean);
          if (words.length > 1) throw Error("Expected one optional name or id");
          return words[0];
        };
        const profileNamed = (agents, name) => {
          const exact = agents.filter((a) => a.name === name);
          const matches = exact.length ? exact : agents.filter((a) => a.aliases?.includes(name));
          if (matches.length !== 1) throw Error(`Unknown or ambiguous agent: ${name}`);
          return matches[0];
        };
        const diagnosticLines = (catalog) => catalog.diagnostics.map((d) => `${d.name ?? d.source}: ${d.error ?? d.warning}${d.filePath ? ` · ${d.filePath}` : ""}`);
        export function profileLines(profile, defaults) {
          return [profile.name, profile.description ?? "", `source · ${profile.source}${profile.filePath ? ` · ${profile.filePath}` : ""}`,
            `model · ${profile.model ?? defaults.model ?? "inherit parent"}`, `thinking · ${profile.thinking ?? defaults.thinking ?? "inherit parent"}`,
            `context · ${profile.context ?? defaults.context}`, `tools · ${Array.isArray(profile.tools) ? profile.tools.join(", ") || "none" : profile.tools ?? "Pi builtin defaults"}`,
            ...(profile.disabled ? ["disabled"] : []), ...(profile.error ? [`error · ${profile.error}`] : []), "", profile.prompt ?? ""].map(cleanText);
        }

        // Per-child viewport and drafts survive selection changes and attention sorting.
        export class FleetView {
          selectedID;
          views = new Map();
          drafts = new Map();
          input = new Input();
          composing = false;
          mode = "steer";
          expanded = false;
          showPath = false;
          confirming = undefined;
          notice = "";
          busy = false;
          closed = false;
          _focused = false;
          constructor(runtime, tui, theme, keys, done, id) {
            Object.assign(this, { runtime, tui, theme, keys, done, selectedID: id });
            this.input.onSubmit = () => { void this.submit(); };
          }
          get focused() { return this._focused; }
          set focused(value) { this._focused = value; this.input.focused = value && this.composing; }
          dispose() { this.closed = true; }
          invalidate() { this.input.invalidate(); }
          rows() {
            const rows = orderedFleet(this.runtime.list());
            if (!rows.some((r) => r.id === this.selectedID)) this.selectedID = rows[0]?.id;
            return rows;
          }
          view() {
            if (!this.views.has(this.selectedID)) this.views.set(this.selectedID, new TranscriptViewport());
            return this.views.get(this.selectedID);
          }
          async submit() {
            if (this.busy || !this.selectedID || !this.input.getValue().trim()) return;
            const id = this.selectedID, text = this.input.getValue().trim(), mode = this.mode;
            if (text.length > 16384) { this.notice = "message exceeds 16 KiB character limit"; this.tui.requestRender(); return; }
            this.busy = true;
            try {
              const receipt = await this.runtime.send(id, text, mode);
              this.notice = `${receipt.delivery} · ${receipt.mode}`;
              this.input.setValue(""); this.drafts.delete(id); this.composing = false; this.focused = this._focused;
            } catch (error) { this.notice = `message failed · ${error.message}`; }
            finally { this.busy = false; if (!this.closed) this.tui.requestRender(); }
          }
          async stop(id) {
            this.busy = true; this.confirming = undefined; this.notice = `stopping ${id}`;
            this.tui.requestRender();
            try { const receipt = await this.runtime.stop(id); this.notice = `${receipt.id} · ${receipt.state}`; }
            catch (error) { this.notice = `stop failed · ${error.message}`; }
            finally { this.busy = false; if (!this.closed) this.tui.requestRender(); }
          }
          handleInput(data) {
            const cancel = this.keys.matches(data, "tui.select.cancel");
            if (matchesKey(data, "ctrl+c")) { this.done(); return; }
            if (this.confirming) {
              if (data === "y" && !this.busy) void this.stop(this.confirming);
              else if (cancel || data === "n") this.confirming = undefined;
            } else if (this.composing) {
              if (cancel && !this.busy) {
                this.drafts.set(this.selectedID, { text: this.input.getValue(), mode: this.mode });
                this.composing = false; this.focused = this._focused;
              } else if (this.keys.matches(data, "tui.input.tab") && !repliesByResume(this.rows().find((r) => r.id === this.selectedID))) this.mode = this.mode === "steer" ? "followUp" : "steer";
              else if (!this.busy && this.keys.matches(data, "tui.input.submit")) void this.submit();
              else if (!this.busy) this.input.handleInput(data);
            } else if (cancel || data === "q") this.done();
            else if (this.keys.matches(data, "tui.select.up") || this.keys.matches(data, "tui.select.down") || data === "j" || data === "k") {
              const rows = this.rows(), at = rows.findIndex((r) => r.id === this.selectedID);
              const delta = data === "k" || this.keys.matches(data, "tui.select.up") ? -1 : 1;
              this.selectedID = rows[Math.max(0, Math.min(rows.length - 1, at + delta))]?.id;
              this.notice = "";
            } else if (matchesKey(data, "pageUp")) this.view().scroll(-this.view().height);
            else if (matchesKey(data, "pageDown")) this.view().scroll(this.view().height);
            else if (matchesKey(data, "end")) this.view().follow();
            else if (data === "p") { this.showPath = !this.showPath; this.view().follow(); }
            else if (data === "e") { this.expanded = !this.expanded; this.view().follow(); }
            else if (data === "s" && this.selectedID) {
              const draft = this.drafts.get(this.selectedID);
              this.mode = draft?.mode ?? "steer"; this.input.setValue(draft?.text ?? "");
              this.composing = true; this.focused = this._focused;
            } else if (data === "x" && this.selectedID && !this.busy) this.confirming = this.selectedID;
            this.tui.requestRender();
          }
          render(width) {
            const rows = this.rows(), selected = rows.find((r) => r.id === this.selectedID);
            const height = Math.max(8, Math.floor((this.tui.terminal.rows || 30) * 0.85));
            const listSize = Math.min(rows.length, Math.max(1, Math.min(6, Math.floor(height / 4))));
            const at = rows.findIndex((r) => r.id === this.selectedID), first = Math.max(0, Math.min(rows.length - listSize, at - Math.floor(listSize / 2)));
            const footer = [];
            if (this.notice) footer.push(...wrapColumns(this.notice, width));
            if (this.confirming) {
              const target = rows.find((r) => r.id === this.confirming);
              footer.push(...wrapColumns(`stop child ${this.confirming}?`, width), ...wrapColumns(stopScope(target), width),
                `y confirm · ${this.hint("tui.select.cancel")} cancel`);
            } else if (this.composing) {
              footer.push(composerLabel(selected, this.mode, width));
              if (this.busy) footer.push("awaiting acknowledgement");
              footer.push(...this.input.render(width));
              footer.push(...wrapColumns(`${this.hint("tui.input.submit")} send${repliesByResume(selected) ? "" : ` · ${this.hint("tui.input.tab")} mode`} · ${this.hint("tui.select.cancel")} keep draft`, width));
            } else footer.push(...wrapColumns(`${this.hint("tui.select.up")}/${this.hint("tui.select.down")} select · pgup/pgdn scroll · end follow`, width),
              ...wrapColumns(`e tools · p file · s message · x stop · ${this.hint("tui.select.cancel")} close`, width));
            const visibleRows = rows.slice(first, first + listSize);
            const frame = [`NATIVE SUBAGENTS · ${rows.length} retained`,
              ...(rows.length ? visibleRows.map((r) => fleetRow(r, width, r.id === this.selectedID)) : ["no native children yet"]),
              "─".repeat(width)];
            if (selected) {
              frame.push(identityLine(selected, width));
              if (selected.needsReply) frame.push(...wrapColumns(`needs parent reply · ${selected.output ?? ""}`, width));
              if (selected.error) frame.push(...wrapColumns(`error · ${selected.error}`, width));
              const transcript = readTranscript(selected.sessionFile, width, this.expanded);
              if (transcript.omitted) frame.push(...wrapColumns(transcript.omitted, width));
              const view = this.view();
              const detail = this.showPath ? wrapColumns(`full transcript: ${selected.sessionFile ?? "unavailable"}`, width).map((text, i) => ({key:`path:${i}`,text})) : transcript.lines;
              const body = view.update(detail, Math.max(1, height - frame.length - footer.length - 1));
              frame.push(...body);
              while (frame.length < height - footer.length - 1) frame.push("");
              frame.push(`${view.label} · p ${this.showPath ? "transcript" : "saved file path"}`);
            }
            if (frame.length > height - footer.length) frame.splice(Math.max(1, height - footer.length));
            const bodyHeight = frame.length;
            frame.push(...footer);
            return frame.slice(0, height).map((line, i) => {
              // Input owns its cursor marker; sanitize everything else before styling.
              const text = truncateToWidth(i < bodyHeight ? cleanText(line).replace(/\n/g, " ") : line, width);
              const run = i > 0 && i <= visibleRows.length && i < bodyHeight ? visibleRows[i - 1] : undefined;
              if (!run) return this.theme.fg("text", text);
              const dot = text.indexOf("●");
              return dot < 0 ? this.theme.fg("text", text) : this.theme.fg("text", text.slice(0, dot)) + this.theme.fg(statusColor(run), "●") + this.theme.fg("text", text.slice(dot + 1));
            });
          }
          hint(id) { return this.keys.getKeys(id).join("/"); }
        }

        export function registerNativeCommands(pi, runtime) {
          const names = nativeCommandNames(pi.getCommands(), pi.getAllTools());
          const aliasNote = names.run !== "run" ? `command collision detected · native commands use /${names.run} and /${names["subagents-fleet"]}; existing commands are unchanged` : "native command names available without aliases";
          pi.registerEntryRenderer("shepherd-native-report", (entry) => new Text(cleanText(entry.data.text), 0, 0));
          const report = (ctx, text) => {
            text = cleanText(text);
            pi.appendEntry("shepherd-native-report", { text });
            if (ctx.mode !== "tui") {
              if (ctx.hasUI) ctx.ui.notify(text, "info");
              else pi.sendMessage({ customType: "shepherd-native-report", content: text, display: true }, { triggerTurn: false });
            }
          };
          const register = (name, handler) => pi.registerCommand(names[name], {
            description: `Native ${name} · ${name === "run" ? "launch child workflow" : "inspect owned runtime"}`,
            handler: async (args, ctx) => { try { await handler(args, ctx); } catch (error) { report(ctx, `error · ${error.message}`); } },
          });
          register("subagents", async (args, ctx) => {
            const catalog = runtime.catalog(ctx); let name = oneArgument(args);
            if (!name && !catalog.agents.length) { report(ctx, ["no native agents", ...diagnosticLines(catalog)].join("\n")); return; }
            if (!name && ctx.mode === "tui") name = await ctx.ui.select("native agents · read only", catalog.agents.map((a) => a.name));
            if (name) report(ctx, [...profileLines(profileNamed(catalog.agents, name), runtime.defaults), ...diagnosticLines(catalog)].join("\n"));
            else if (ctx.mode !== "tui") report(ctx, [...catalog.agents.map((a) => `${a.name} · ${a.source} · ${a.error ?? a.description ?? ""}`), ...diagnosticLines(catalog)].join("\n") || "no native agents");
          });
          register("run", async (args, ctx) => {
            const params = parseRunCommand(args);
            const value = await runtime.workflow(params, ctx, (value) => { try { report(ctx, `workflow ${value.id} · ${value.state}\n${value.error ?? JSON.stringify(value.output) ?? ""}`); } catch { /* Workflow status remains retrievable. */ } });
            report(ctx, `workflow ${value.id} · ${value.state}${params.async ? ` · /${names.workflows} ${value.id}` : `\n${value.error ?? JSON.stringify(value.output) ?? ""}`}`);
          });
          let overlayOpen = false;
          register("subagents-fleet", async (args, ctx) => {
            const id = oneArgument(args);
            if (id) runtime.get(id);
            if (ctx.mode !== "tui") { report(ctx, id ? JSON.stringify(runtime.get(id), null, 2) : orderedFleet(runtime.list()).map((r) => `${r.id}\n${fleetRow(r, 120, false)}`).join("\n") || "no native children yet"); return; }
            if (overlayOpen) { ctx.ui.notify("native fleet is already open", "info"); return; }
            overlayOpen = true; let timer, view;
            try {
              await ctx.ui.custom((tui, theme, keys, done) => {
                view = new FleetView(runtime, tui, theme, keys, done, id);
                timer = setInterval(() => tui.requestRender(), 1000); timer.unref();
                return view;
              }, { overlay: true, overlayOptions: { width: "95%", maxHeight: "85%", anchor: "center" } });
            } finally { clearInterval(timer); view?.dispose(); overlayOpen = false; }
          });
          register("subagents-stop", async (args, ctx) => {
            let id = oneArgument(args);
            const active = runtime.list().filter((r) => ["running", "queued"].includes(r.state));
            if (id) runtime.get(id);
            if (!ctx.hasUI) { report(ctx, `stop requires interactive confirmation; no child stopped\n${active.map((r) => `${r.id} · ${r.task}`).join("\n")}`); return; }
            if (!id) {
              if (!active.length) { report(ctx, "no active native children"); return; }
              const choices = active.map((r) => `${r.id} · ${cleanText(r.task)}`);
              const choice = await ctx.ui.select("stop one native child", choices);
              id = active[choices.indexOf(choice)]?.id;
            }
            if (id && await ctx.ui.confirm("stop native child", `${id}\n${cleanText(runtime.get(id).task)}\n${stopScope(runtime.get(id))}`)) {
              const receipt = await runtime.stop(id); report(ctx, `${receipt.id} · ${receipt.state}`);
            }
          });
          register("subagents-models", (args, ctx) => {
            const name = oneArgument(args), catalog = runtime.catalog(ctx);
            const profiles = name ? [profileNamed(catalog.agents, name)] : catalog.agents;
            report(ctx, ["native models · local catalog only · isolated child verifies availability at launch", ...profiles.map((p) => {
              try { const model = runtime.resolveModel(p, ctx); return `${p.name} · ${model.model.provider}/${model.model.id} · ${p.model ?? runtime.defaults.model ?? "inherit parent"}${p.error ? ` · error: ${p.error}` : ""}`; }
              catch (error) { return `${p.name} · error: ${error.message}`; }
            })].join("\n"));
          });
          register("subagents-doctor", (args, ctx) => {
            if (args.trim()) throw Error("Doctor takes no arguments");
            let diagnostics;
            try { diagnostics = diagnosticLines(runtime.catalog(ctx)); }
            catch (error) { diagnostics = [`discovery error · ${error.message}`]; }
            report(ctx, ["NATIVE SUBAGENTS", ...runtime.doctor(ctx), aliasNote, ...commandNames.map((n) => `/${names[n]}`), ...diagnostics].join("\n"));
          });
          register("missions", (args, ctx) => {
            const id = oneArgument(args), records = runtime.missions(id);
            report(ctx, id ? JSON.stringify(records, null, 2) : records.map((m) => `${m.id} · ${m.status} · ${m.title}`).join("\n") || "no native missions · records do not control processes");
          });
          register("workflows", (args, ctx) => {
            const id = oneArgument(args), records = runtime.workflows(id);
            report(ctx, id ? JSON.stringify(records, null, 2) : records.map((w) => `${w.id} · ${w.state} · ${w.children.length} children${w.error ? ` · ${w.error}` : ""}`).join("\n") || "no retained workflows · previous workflows are not replayed");
          });
          return names;
        }

        """#

}
