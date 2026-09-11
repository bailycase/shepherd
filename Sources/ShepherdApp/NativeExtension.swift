import Foundation
import ShepherdProtocol

enum NativeExtension {
    static func installedPath() throws -> String {
        let directory = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shepherd-native.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }

    // Extensions/shepherd-native.ts is canonical; keep this byte-identical.
    static let extensionSource = #"""
        // @ts-nocheck -- pi loads this dependency-free extension through jiti.
        import * as net from "node:net";
        import { createHash, randomUUID } from "node:crypto";
        
        const FRAME_LIMIT = 1024 * 1024;
        const SNAPSHOT_LIMIT = 240 * 1024;
        const TEXT_LIMIT = 16 * 1024;
        const failure = (code, message) => ({ failure: { code, message } });
        const bytes = (value) => Buffer.byteLength(JSON.stringify(value));
        
        export default function shepherdNative(pi) {
          const agentID = process.env.SHEPHERD_AGENT_ID;
          const socketPath = process.env.SHEPHERD_SOCKET;
          if (!agentID || !socketPath) return;
        
          let ctx, socket, retry, unsubscribe;
          let stopped = true, connected = false, retryDelay = 500;
          let generation = randomUUID(), sessionID, revision = 0, signature = "";
          let sequence = 0, currentAssistant, projectionClipped = false;
          let buffer = Buffer.alloc(0);
          const operations = new Map();
          const provisional = new Map();
          const tools = new Map();
        
          function project(entryID, message) {
            let remaining = TEXT_LIMIT, truncated = false;
            const clip = (value) => {
              const raw = Buffer.from(String(value ?? ""));
              if (raw.length <= remaining) { remaining -= raw.length; return raw.toString(); }
              truncated = true;
              let end = remaining;
              while (end > 0 && (raw[end] & 0xc0) === 0x80) end--;
              remaining = 0;
              return raw.subarray(0, end).toString();
            };
            const result = { entryID, role: message.role ?? "custom", blocks: [], truncated: false };
            for (const key of ["toolName", "toolCallId"]) {
              if (message[key] != null) result[key === "toolCallId" ? "toolCallID" : key] = clip(message[key]);
            }
            if (message.args != null) result.argumentsText = clip(JSON.stringify(message.args));
            const content = typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content ?? [];
            for (const block of content) {
              if (result.blocks.length >= 128 || remaining === 0) { truncated = true; break; }
              if (block.type === "text") result.blocks.push({ kind: "text", text: clip(block.text) });
              else if (block.type === "thinking") result.blocks.push({ kind: "thinking", text: clip(block.thinking) });
              else if (block.type === "image") result.blocks.push({ kind: "unsupportedImage", text: clip("[Image unavailable in native thread]") });
              else if (block.type === "toolCall") result.blocks.push({ kind: "text", text: clip(`${block.name} [${block.id}]\n${JSON.stringify(block.arguments ?? {})}`) });
            }
            if (message.errorMessage) result.blocks.push({ kind: "text", text: clip(message.errorMessage) });
            if (message.isError != null) result.isError = !!message.isError;
            if (message.stopReason) result.status = clip(message.stopReason);
            result.truncated = truncated;
            return result;
          }
        
          function historyMessage(entry) {
            if (entry.type === "message") {
              if (entry.message.role === "custom" && !entry.message.display) return;
              return project(entry.id, entry.message);
            }
            if (entry.type === "custom_message" && entry.display) return project(entry.id, { role: "custom", content: entry.content });
            if (entry.type === "compaction" || entry.type === "branch_summary") return project(entry.id, { role: entry.type, content: entry.summary });
          }
        
          function dialogsSupported() {
            return ["getPendingDialogs", "onDialog", "resolveDialog"].every((name) => typeof ctx?.ui?.[name] === "function");
          }
        
          function refreshContext(context, reset = false) {
            ctx = context;
            const current = ctx.sessionManager.getSessionId();
            if (reset || sessionID !== current) {
              sessionID = current;
              generation = randomUUID();
              operations.clear(); provisional.clear(); tools.clear(); currentAssistant = undefined;
              projectionClipped = false;
              signature = "";
              revision++;
              try { unsubscribe?.(); } catch {}
              unsubscribe = undefined;
              if (dialogsSupported()) unsubscribe = ctx.ui.onDialog(() => { revision++; });
            }
          }
        
          function snapshot(request) {
            if (request.expectedSessionID != null && request.expectedSessionID !== sessionID) return failure("stale_session", "Refresh the thread before acting.");
            const branch = ctx.sessionManager.getBranch();
            for (const entry of branch) {
              if (entry.type !== "message") continue;
              const message = entry.message;
              if (message.role === "toolResult") tools.delete(message.toolCallId);
            }
            for (const [id, pending] of provisional) {
              const boundary = pending.afterEntryID == null ? -1 : branch.findIndex((entry) => entry.id === pending.afterEntryID);
              // message_end precedes persistence; later handlers may replace its text and timestamp.
              if (pending.ended && (pending.afterEntryID == null || boundary >= 0) &&
                  branch.slice(boundary + 1).some((entry) => entry.type === "message" && entry.message.role === "assistant")) {
                provisional.delete(id);
              }
            }
            const dialogs = dialogsSupported() ? ctx.ui.getPendingDialogs().filter((d) => ["select", "confirm", "input", "editor"].includes(d.kind)).map((d) => {
              const result = {};
              for (const key of ["id", "kind", "title", "options", "message", "placeholder", "prefill", "timeout", "unavailable"]) {
                if (d[key] != null) result[key] = d[key];
              }
              if (bytes(result) > 48 * 1024) return { id: d.id, kind: d.kind, title: "Dialog too large for native thread", unavailable: "payload-limit" };
              return result;
            }).slice(0, 8) : [];
            const running = !ctx.isIdle();
            const model = ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined;
            const thinking = typeof pi.getThinkingLevel === "function" ? pi.getThinkingLevel() : undefined;
            const active = [...provisional.values()].map((p) => p.value).concat([...tools.values()]);
            const nextSignature = createHash("sha256").update(JSON.stringify([branch.map((e) => e.id), active, dialogs, running, model, thinking])).digest("hex");
            if (nextSignature !== signature) { signature = nextSignature; revision++; }
            if (request.beforeEntryID == null && request.afterRevision === revision) return { unchanged: { piSessionID: sessionID, generation, revision } };
            let end = branch.length;
            if (request.beforeEntryID != null) {
              end = branch.findIndex((e) => e.id === request.beforeEntryID);
              if (end < 0) return failure("stale_cursor", "History changed. Refresh the recent page.");
            }
            const value = { piSessionID: sessionID, generation, revision, running, model, thinking,
              supportedActions: dialogsSupported() ? ["send", "abort", "answer"] : ["send", "abort"],
              dialogsSupported: dialogsSupported(), dialogs, messages: [], provisional: active,
              clipped: projectionClipped || dialogs.some((d) => d.unavailable === "payload-limit") };
            // Keep active output bounded before filling the remaining budget with history.
            while (bytes(value) > 120 * 1024 && value.provisional.length) { value.provisional.shift(); value.clipped = true; }
            while (bytes(value) > 120 * 1024 && value.dialogs.length) { value.dialogs.pop(); value.clipped = true; }
            let index = end - 1;
            for (; index >= 0; index--) {
              const message = historyMessage(branch[index]);
              if (!message) continue;
              value.messages.unshift(message);
              if (bytes(value) > SNAPSHOT_LIMIT) {
                value.messages.shift(); value.clipped = true;
                break;
              }
              if (value.messages.length === 50) { index--; break; }
            }
            if (index >= 0 && value.messages.length) value.olderCursor = value.messages[0].entryID;
            return { snapshot: { value } };
          }
        
          function command(request) {
            if (!ctx) return failure("native_unavailable", "Session is not ready.");
            refreshContext(ctx);
            if (!request || typeof request !== "object" || Object.keys(request).length !== 1) return failure("invalid", "Invalid native request.");
            const [kind, args] = Object.entries(request)[0];
            if (!args || typeof args !== "object") return failure("invalid", "Invalid native payload.");
            if (kind === "snapshot") return snapshot(args);
            if (!["send", "abort", "answer"].includes(kind)) return failure("unsupported", "Unknown native action.");
            if (args.expectedSessionID !== sessionID || args.generation !== generation) return failure("stale_session", "Refresh the thread before acting.");
            if (typeof args.operationID !== "string" || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(args.operationID)) return failure("invalid", "operationID must be a UUID.");
            const operationID = args.operationID.toUpperCase();
            const fingerprint = createHash("sha256").update(JSON.stringify([kind, args.expectedSessionID, args.generation, args.text, args.delivery, args.dialogID, args.answer])).digest("hex");
            const previous = operations.get(operationID);
            if (previous) return previous.fingerprint === fingerprint ? previous.result : failure("operation_conflict", "Operation ID was reused with a different payload.");
            let result;
            try {
              if (kind === "send") {
                if (typeof args.text !== "string" || !args.text.trim() || Buffer.byteLength(args.text) > TEXT_LIMIT || !["followUp", "steer"].includes(args.delivery)) return failure("invalid", "Send requires text up to 16 KiB and a valid delivery mode.");
                pi.sendUserMessage(args.text, { deliverAs: args.delivery });
              } else if (kind === "abort") {
                ctx.abort();
              } else {
                if (!dialogsSupported()) return failure("dialogs_unsupported", "Update pi to answer standard dialogs. Use the desktop for this dialog.");
                if (!args.answer || Object.keys(args.answer).length !== 1) return failure("invalid", "Invalid dialog answer.");
                const [answerKind, payload] = Object.entries(args.answer)[0];
                if (!["select", "confirm", "input", "editor", "cancel"].includes(answerKind)) return failure("invalid", "Invalid dialog answer kind.");
                if (ctx.ui.getPendingDialogs().some((dialog) => dialog.id === args.dialogID && dialog.unavailable)) return failure("dialog_unavailable", "Answer this dialog on the desktop while the external editor is open.");
                const outcome = ctx.ui.resolveDialog(args.dialogID, { kind: answerKind, ...(answerKind === "cancel" ? {} : { value: payload?.value }) });
                if (outcome !== "accepted") result = failure(outcome === "unavailable" ? "dialog_unavailable" : `dialog_${outcome}`, "Dialog answer not accepted. Refresh the thread.");
              }
              result ??= { accepted: { operationID } };
            } catch {
              result = failure("dispatch_failed", "Pi rejected native dispatch. Refresh before acting.");
            }
            operations.set(operationID, { fingerprint, result });
            if (operations.size > 256) operations.delete(operations.keys().next().value);
            revision++;
            return result;
          }
        
          function send(value) {
            if (!socket || !connected) return;
            const line = JSON.stringify(value);
            if (Buffer.byteLength(line) >= FRAME_LIMIT || socket.writableLength + Buffer.byteLength(line) > 2 * FRAME_LIMIT) { socket.destroy(); return; }
            socket.write(line + "\n");
          }
        
          function connect() {
            if (stopped || socket) return;
            try {
              const s = net.createConnection(socketPath);
              socket = s;
              s.unref();
              s.on("connect", () => {
                connected = true; retryDelay = 500;
                try { send({ type: "helloNativeAgent", agentID }); } catch { s.destroy(); }
              });
              s.on("data", (chunk) => {
                try {
                  buffer = Buffer.concat([buffer, chunk]);
                  let newline;
                  while ((newline = buffer.indexOf(10)) >= 0) {
                    if (newline > FRAME_LIMIT || buffer.subarray(0, newline).includes(13)) { s.destroy(); return; }
                    const line = buffer.subarray(0, newline);
                    buffer = buffer.subarray(newline + 1);
                    const frame = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(line));
                    if (frame.type !== "nativeThreadCommand" || !Number.isSafeInteger(frame.id)) continue;
                    let result;
                    try { result = command(frame.request); } catch { result = failure("bridge_failed", "Native snapshot unavailable. Refresh the thread."); }
                    send({ type: "nativeThreadResult", id: frame.id, result });
                  }
                  if (buffer.length > FRAME_LIMIT) s.destroy();
                } catch { s.destroy(); }
              });
              s.on("error", () => {});
              s.on("close", () => {
                if (socket !== s) return;
                socket = undefined; connected = false; buffer = Buffer.alloc(0);
                scheduleReconnect();
              });
            } catch { scheduleReconnect(); }
          }
        
          function scheduleReconnect() {
            if (stopped || retry) return;
            retry = setTimeout(() => { retry = undefined; connect(); }, retryDelay);
            retryDelay = Math.min(retryDelay * 2, 10_000);
            retry.unref();
          }
        
          function stop() {
            stopped = true;
            clearTimeout(retry); retry = undefined;
            try { unsubscribe?.(); } catch {}
            unsubscribe = undefined;
            const old = socket; socket = undefined; connected = false;
            buffer = Buffer.alloc(0);
            old?.destroy();
          }
        
          const on = (name, handler) => pi.on(name, (event, context) => {
            try { handler(event, context); } catch {}
          });
          on("session_start", (_, context) => { refreshContext(context, true); stopped = false; connect(); });
          on("session_tree", (_, context) => { refreshContext(context, true); });
          on("session_shutdown", () => { stop(); ctx = undefined; });
          for (const name of ["agent_start", "agent_end", "agent_settled", "model_select", "session_compact", "ui_prompt_start", "ui_prompt_end"]) {
            on(name, (_, context) => { refreshContext(context); revision++; });
          }
          for (const name of ["message_start", "message_update", "message_end"]) on(name, (event, context) => {
            refreshContext(context);
            const message = event.message;
            if (message.role !== "assistant") { revision++; return; }
            if (name === "message_start" || currentAssistant == null) currentAssistant = ++sequence;
            const key = currentAssistant;
            const previous = provisional.get(key);
            const afterEntryID = previous ? previous.afterEntryID : ctx.sessionManager.getLeafId();
            const value = project(`provisional:assistant:${key}`, message);
            value.status = name === "message_end" ? message.stopReason ?? "complete" : "streaming";
            provisional.set(key, { value, ended: name === "message_end", afterEntryID });
            if (name === "message_end") currentAssistant = undefined;
            if (provisional.size > 50) { provisional.delete(provisional.keys().next().value); projectionClipped = true; }
            revision++;
          });
          for (const name of ["tool_execution_start", "tool_execution_update", "tool_execution_end"]) on(name, (event, context) => {
            refreshContext(context);
            const value = project(`provisional:tool:${event.toolCallId}`, { role: "toolResult", toolName: event.toolName, toolCallId: event.toolCallId,
              args: event.args, content: (event.partialResult ?? event.result)?.content ?? [], isError: event.isError });
            value.status = name === "tool_execution_end" ? "complete" : "running";
            tools.set(event.toolCallId, value);
            if (tools.size > 50) { tools.delete(tools.keys().next().value); projectionClipped = true; }
            revision++;
          });
        }

        """#
}
