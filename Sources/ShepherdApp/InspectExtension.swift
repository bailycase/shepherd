import Foundation
import ShepherdProtocol

/// View helpers shared by the children extension's in-pi fleet view
/// (`shepherd-children-ui.ts` imports them). Installed beside the children extension by
/// `ChildrenExtension`. Extensions/shepherd-inspect.mjs is canonical; keep this literal
/// byte-identical to it.
enum InspectExtension {
    static let extensionSource = #"""
        #!/usr/bin/env node
        // Flat terminal inspector over native or pi-subagents artifacts. Importable view
        // helpers are also used by the in-parent fleet. No socket or process ownership.
        import * as fs from "node:fs";
        import * as path from "node:path";
        import { fileURLToPath } from "node:url";
        import { stripVTControlCharacters } from "node:util";
        import { randomUUID } from "node:crypto";
        import { StringDecoder } from "node:string_decoder";

        export const cleanText = (value) => stripVTControlCharacters(String(value ?? "")).replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, "").replace(/\t/g, "  ");
        const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });
        const cellWidth = (s) => /\p{Extended_Pictographic}|[\u1100-\u115f\u2329\u232a\u2e80-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe10-\ufe6f\uff01-\uff60\uffe0-\uffe6]/u.test(s) ? 2 : /^\p{Mark}+$/u.test(s) ? 0 : 1;
        export const displayWidth = (value) => [...graphemes.segment(cleanText(value))].reduce((n, { segment }) => n + cellWidth(segment), 0);
        export function clipColumns(value, width) {
          let line = "", cells = 0;
          for (const { segment } of graphemes.segment(cleanText(value).replace(/\n/g, " "))) {
            const size = cellWidth(segment);
            if (cells + size > Math.max(0, width)) break;
            line += segment; cells += size;
          }
          return line;
        }
        export function wrapColumns(value, width) {
          width = Math.max(1, width);
          const out = [];
          for (const paragraph of cleanText(value).split("\n")) {
            let line = "", cells = 0;
            for (const { segment } of graphemes.segment(paragraph)) {
              const size = cellWidth(segment);
              if (cells + size > width) {
                const space = line.search(/\s+\S*$/u);
                const cut = space > 0 && segment !== " " ? space : line.length;
                if (line) out.push(line.slice(0, cut).trimEnd());
                line = line.slice(cut).replace(/^ +/, ""); cells = displayWidth(line);
                if (segment === " " && !line) continue;
              }
              if (size <= width) { line += segment; cells += size; }
            }
            out.push(line);
          }
          return out;
        }
        // The old inspector's minimal inline pass, kept neutral and escape-free.
        export const inlineText = (text) => cleanText(text).replace(/\*\*([^*]+)\*\*/g, "$1").replace(/`([^`]+)`/g, "$1").replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");
        export const shortID = (id) => cleanText(id).replace(/^(native-[^-]{8}).*$/, "$1");
        export const repliesByResume = (run) => run?.settled || terminalState(run?.state);
        export const statusWord = (run) => run?.needsReply ? "needs reply" : run?.state ?? "unavailable";
        // Existing Pi tokens: success green, accent orange, dim idle, mdLink slate blue.
        // Failed/stopped use orange too; only the dot receives status color.
        export const statusColor = (run) => run?.needsReply || ["failed", "stopped", "cancelled", "rejected"].includes(run?.state) ? "accent"
          : ["running", "queued"].includes(run?.state) ? "success" : ["complete", "completed"].includes(run?.state) ? "mdLink" : "dim";
        export function readThemeColors(file) {
          try { return JSON.parse(fs.readFileSync(file, "utf8")).colors; } catch { return undefined; }
        }
        export function ansiStatusDot(run, colors) {
          const role = statusColor(run), hex = colors?.[role];
          const color = typeof hex === "string" && /^#[0-9a-f]{6}$/i.test(hex)
            ? `38;2;${hex.slice(1).match(/../g).map((part) => parseInt(part, 16)).join(";")}`
            : ({ success: "38;5;107", accent: "38;5;173", mdLink: "38;5;103", dim: "38;5;240" })[role];
          return `\x1b[${color}m●\x1b[0m`;
        }
        export function identityLine(run, width) {
          const id = shortID(run?.id ?? run?.runId ?? ""), metadata = cleanText(`${run?.role ?? "child"} · ${run?.model ?? ""}`);
          return clipColumns(`${id} · ${clipColumns(metadata, width - displayWidth(id) - 3)}`, width);
        }
        export function composerLabel(run, mode = "steer", width = 80) {
          const action = repliesByResume(run) ? `reply · resumes ${shortID(run.id ?? run.runId)}` : `${mode} · ${shortID(run.id ?? run.runId)}`;
          return clipColumns(`${action} · to ${run.role ?? "child"}`, width);
        }
        export function stopScope(run) {
          return run?.workflowId ? `owned by workflow ${run.workflowId}\nStopping this child may cancel workflow siblings.` : "Stops this child's owned process tree. Saved transcript remains.";
        }
        export function draftTail(prompt, width) {
          const chars = [...graphemes.segment(cleanText(prompt))].map(({segment}) => segment);
          let tail = "", cells = 0;
          for (let i = chars.length - 1; i >= 0; i--) {
            const size = cellWidth(chars[i]);
            if (cells + size > Math.max(0, width - 4)) return `…${tail}`;
            tail = chars[i] + tail; cells += size;
          }
          return tail;
        }

        // stdin is a byte stream, not a key stream. Keep UTF-8, CSI and paste framing
        // across chunks; pasted newlines are draft text, never submission.
        export class InspectorInput {
          decoder = new StringDecoder("utf8");
          buffer = "";
          pasting = false;
          constructor(key, text) { this.key = key; this.text = text; }
          feed(chunk) {
            this.buffer += typeof chunk === "string" ? chunk : this.decoder.write(chunk);
            while (this.buffer) {
              if (this.buffer[0] === "\x03") { this.buffer = this.buffer.slice(1); this.key("\x03"); continue; }
              if (this.buffer[0] === "\x1b") {
                if (this.buffer.length === 1 || this.buffer === "\x1bO" || /^\x1b\[[0-?]*[ -/]*$/.test(this.buffer)) return;
                const sequence = this.buffer.match(/^\x1b(?:\[[0-?]*[ -/]*[@-~]|O.)/);
                if (sequence) {
                  this.buffer = this.buffer.slice(sequence[0].length);
                  if (sequence[0] === "\x1b[200~") this.pasting = true;
                  else if (sequence[0] === "\x1b[201~") this.pasting = false;
                  else if (!this.pasting) this.key(sequence[0]);
                  continue;
                }
                this.buffer = this.buffer.slice(1); if (!this.pasting) this.key("\x1b"); continue;
              }
              const char = String.fromCodePoint(this.buffer.codePointAt(0)); this.buffer = this.buffer.slice(char.length);
              if (!this.pasting && /[\r\n\x7f\b]/.test(char)) this.key(char);
              else this.text(this.pasting && /[\r\n]/.test(char) ? " " : cleanText(char), this.pasting);
            }
          }
          flushEscape() { if (this.buffer === "\x1b") { this.buffer = ""; if (!this.pasting) this.key("\x1b"); } }
        }
        export function duration(start, end, now = Date.now()) {
          if (!Number.isFinite(start)) return "";
          if (end === null) return "duration unavailable";
          const s = Math.max(0, Math.floor(((end ?? now) - start) / 1000));
          return s < 60 ? `${s}s` : s < 3600 ? `${Math.floor(s / 60)}m ${s % 60}s` : `${Math.floor(s / 3600)}h ${Math.floor(s % 3600 / 60)}m`;
        }
        export const terminalState = (state) => ["complete", "completed", "failed", "stopped", "rejected", "cancelled"].includes(state);
        export function endTime(record, state = record?.state) {
          return record?.endedAt ?? record?.completedAt ?? (terminalState(state) ? null : undefined);
        }

        // Bounded tail read; stable entry/byte identities keep an appended transcript
        // from moving the passage being read. The saved file remains the full evidence.
        export function readTranscript(file, width, expanded = false, byteBudget = 2 * 1024 * 1024, lineBudget = 8000) {
          let raw, start, bytes;
          try {
            bytes = fs.statSync(file).size; start = Math.max(0, bytes - byteBudget);
            const fd = fs.openSync(file, "r");
            try { const buffer = Buffer.alloc(bytes - start); fs.readSync(fd, buffer, 0, buffer.length, start); raw = buffer.toString("utf8"); }
            finally { fs.closeSync(fd); }
            if (start) { const cut = raw.indexOf("\n") + 1; start += Buffer.byteLength(raw.slice(0, cut)); raw = raw.slice(cut); }
          } catch { return { lines: [{ key: "empty", text: "no transcript yet" }], omitted: "", bytes: 0 }; }
          const lines = [];
          let offset = start, hidden = 0, malformed = 0;
          for (const line of raw.split("\n")) {
            const key = String(offset); offset += Buffer.byteLength(line) + 1;
            if (!line.trim()) continue;
            let entry;
            try { entry = JSON.parse(line); } catch { malformed++; continue; }
            if (entry.type !== "message") continue;
            const message = entry.message ?? {};
            let n = 0;
            const add = (text) => { for (const textLine of wrapColumns(text, width)) lines.push({ key: `${entry.id ?? key}:${n++}`, text: textLine }); };
            const content = typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content ?? [];
            if (message.role === "assistant") {
              for (const part of content) {
                if (part.type === "text" && part.text?.trim()) { add(""); add(inlineText(part.text.trim())); }
                if (part.type === "toolCall") {
                  const a = part.arguments ?? {}, hint = a.command ?? a.path ?? a.pattern ?? a.query ?? "";
                  add(`▸ ${part.name} ${clipColumns(typeof hint === "string" ? hint : "", Math.max(1, width - 20))}`);
                }
              }
            } else if (message.role === "toolResult") {
              const text = content.filter((p) => p.type === "text").map((p) => p.text).join("\n");
              const label = message.isError ? "error" : "result";
              add(`  ${label} · ${message.toolName ?? "tool"}${expanded ? "" : " · collapsed · e expands"}`);
              if (expanded) add(text || "  no text output");
              else if (message.isError) add(`  ${clipColumns(text, Math.max(1, width - 2))}`);
              if (content.some((p) => p.type !== "text")) add("  non-text content omitted · see saved transcript");
            } else if (message.role === "user") { add(""); add("user"); add(content.map((p) => p.text ?? "").join("\n")); }
            if (lines.length > lineBudget) { hidden += lines.length - lineBudget; lines.splice(0, lines.length - lineBudget); }
          }
          const omitted = [start ? `${start} older bytes omitted` : "", hidden ? `${hidden} older lines omitted` : "", malformed ? `${malformed} incomplete or invalid records omitted` : ""].filter(Boolean).join(" · ");
          return { lines, omitted, bytes };
        }

        export class TranscriptViewport {
          top = null;
          anchor = undefined;
          newLines = 0;
          lost = false;
          lines = [];
          height = 1;
          update(lines, height) {
            this.height = Math.max(1, height);
            if (this.top !== null) {
              const found = lines.findIndex((line) => line.key === this.anchor);
              this.lost = !!this.anchor && found < 0;
              this.top = found < 0 ? Math.min(this.top, Math.max(0, lines.length - this.height)) : found;
              const previousLast = this.lines.at(-1)?.key;
              const last = lines.findIndex((line) => line.key === previousLast);
              if (last >= 0) this.newLines += lines.length - last - 1;
            }
            this.lines = lines;
            if (this.top !== null) this.anchor = lines[this.top]?.key;
            return lines.slice(this.top ?? Math.max(0, lines.length - this.height), (this.top ?? Math.max(0, lines.length - this.height)) + this.height).map((line) => line.text);
          }
          scroll(delta) {
            const tail = Math.max(0, this.lines.length - this.height);
            this.top = Math.max(0, Math.min(tail, (this.top ?? tail) + delta));
            this.anchor = this.lines[this.top]?.key;
            if (delta > 0 && this.top === tail) this.follow();
          }
          follow() { this.top = null; this.anchor = undefined; this.newLines = 0; this.lost = false; }
          get label() { return this.top === null ? "following" : `paused · ${this.newLines} new${this.lost ? " · older anchor omitted" : ""}`; }
        }

        export function inspectorFrame(s, { id, index, width, height, view, prompt = "", notice = "", confirming = false, expanded = false, showPath = false, colors }) {
          const step = index !== undefined ? s?.steps?.[index] : s?.steps?.length === 1 ? s.steps[0] : undefined;
          const run = { ...s, id, role: step?.agent ?? s?.role, model: step?.model ?? s?.model, state: step?.status ?? s?.state ?? "unavailable" };
          const file = step?.sessionFile ?? s?.sessionFile;
          const transcript = readTranscript(file, width, expanded);
          const stateAge = `● ${statusWord(run)} · ${duration(step?.startedAt ?? s?.startedAt, step?.endedAt ?? step?.completedAt ?? endTime(s, run.state))}`;
          const header = [clipColumns(`${stateAge} · ${step?.label ?? s?.task ?? "run"}`, width), identityLine(run, width)];
          if (s?.needsReply) header.push(...wrapColumns(`needs parent reply · ${s.output ?? ""}`, width));
          if (s?.error) header.push(...wrapColumns(`error · ${s.error}`, width));
          if (notice || s?.controlNotice) header.push(...wrapColumns(notice || s.controlNotice, width));
          if (transcript.omitted) header.push(...wrapColumns(`${transcript.omitted} · :path for full file`, width));
          const footer = confirming
            ? [...wrapColumns(`stop entire run ${id}${(s?.steps?.length ?? 0) > 1 ? ` · all ${s.steps.length} lanes` : ""}?`, width),
              ...(s?.workflowId ? wrapColumns(stopScope(s), width) : []), "y confirm · esc cancel"]
            : [...wrapColumns("↑↓/pgup/pgdn scroll · end follow · :tools expand · :path file · :stop confirm · ctrl+c close", width),
              composerLabel(s?.id ? run : { ...run, state: "running", settled: false }, "steer", width), `> ${draftTail(prompt, width)}_`];
          const detail = showPath ? wrapColumns(`full transcript: ${file ?? "unavailable"}`, width).map((text, i) => ({key:`path:${i}`,text})) : transcript.lines;
          const body = view.update(detail.map((line) => ({ ...line, text: line.text.replace(" · e expands", " · :tools expands") })), Math.max(1, height - header.length - footer.length - 2));
          while (body.length < view.height) body.push("");
          const frame = [...header, "─".repeat(width), ...body, view.label];
          frame.splice(Math.max(2, height - footer.length));
          frame.push(...footer);
          return frame.slice(0, height).map((line, i) => {
            const text = clipColumns(line, width);
            return i === 0 ? text.replace("●", ansiStatusDot(run, colors)) : text;
          });
        }

        export function runInspector(argv = process.argv.slice(2)) {
          const args = new Map();
          for (let i = 0; i < argv.length; i += 2) args.set(argv[i], argv[i + 1]);
          const dir = args.get("--async-dir"), id = args.get("--run-id");
          const index = args.has("--index") ? Number(args.get("--index")) : undefined;
          const themePath = args.get("--theme-path") ?? process.env.SHEPHERD_PI_THEME_PATH;
          if (!dir || !id || (index !== undefined && (!Number.isInteger(index) || index < 0))) {
            process.stderr.write("usage: shepherd-inspect --async-dir <dir> --run-id <id> [--index <n>] [--theme-path <file>]\n"); process.exitCode = 1; return;
          }
          const view = new TranscriptViewport();
          let prompt = "", request, confirming = false, expanded = false, showPath = false;
          const cols = () => Math.max(1, (process.stdout.columns || 100) - 1);
          const rows = () => Math.max(1, process.stdout.rows || 40);
          const readStatus = () => { try { const s = JSON.parse(fs.readFileSync(path.join(dir, "status.json"), "utf8")); return s.runId === id ? s : undefined; } catch {} };
          const write = (file, data) => {
            fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
            const tmp = `${file}.${process.pid}.tmp`;
            fs.writeFileSync(tmp, JSON.stringify(data), { mode: 0o600 }); fs.renameSync(tmp, file);
          };
          function render() {
            const s = readStatus();
            const acknowledged = request && !request.error && (s?.controlRequestID === request.id || (s?.controlNotice && !s?.controlRequestID && s.controlNotice !== request.baseline));
            const notice = request && !acknowledged ? request.text : "";
            const frame = inspectorFrame(s, { id, index, width: cols(), height: rows(), view, prompt, notice, confirming, expanded, showPath, colors: readThemeColors(themePath) });
            process.stdout.write(`\x1b[H${frame.map((line) => `${line}\x1b[K`).join("\n")}\x1b[J`);
          }
          function writeRequest(file, data, label) {
            request = { id: data.id, baseline: readStatus()?.controlNotice, text: `${label} request written · awaiting runtime` };
            try { write(file, data); }
            catch (error) { request.error = true; request.text = `control failed: ${error.message}`; }
          }
          const close = () => { clearInterval(timer); clearTimeout(escapeTimer); process.stdin.setRawMode?.(false); process.stdout.write("\x1b[?2004l\x1b[?1049l"); process.exit(0); };
          process.stdin.setRawMode?.(true); process.stdin.resume();
          process.stdout.write("\x1b[?1049h\x1b[?2004h");
          const input = new InspectorInput((key) => {
            if (key === "\x03") return close();
            if (confirming) {
              if (key === "y") {
                writeRequest(path.join(dir, "control", "stop.json"), { type: "stop", id: randomUUID(), ts: Date.now(), source: "shepherd-inspect" }, "stop");
                confirming = false;
              } else if (key === "\x1b" || key === "n") confirming = false;
            } else if (key === "\x1b[A") view.scroll(-1);
            else if (key === "\x1b[B") view.scroll(1);
            else if (key === "\x1b[5~") view.scroll(-view.height);
            else if (key === "\x1b[6~") view.scroll(view.height);
            else if (["\x1b", "\x1b[F", "\x1b[4~"].includes(key)) view.follow();
            else if (key === "\r" || key === "\n") {
              const text = prompt.trim(); prompt = "";
              if (text === ":tools") { expanded = !expanded; view.follow(); }
              else if (text === ":path") { showPath = !showPath; view.follow(); }
              else if (text === ":stop") confirming = true;
              else if (text) {
                const requestID = randomUUID();
                writeRequest(path.join(dir, "control", "steer-requests", `${requestID}.json`), { type: "steer", id: requestID, ts: Date.now(), message: text,
                  ...(index !== undefined ? { targetIndex: index } : {}), source: "shepherd-inspect" }, "message");
              }
            } else if (key === "\x7f" || key === "\b") prompt = [...prompt].slice(0, -1).join("");
          }, (text, pasted) => { if (confirming) { if (!pasted && (text === "y" || text === "n")) input.key(text); } else prompt = (prompt + text).slice(0, 16 * 1024); });
          let escapeTimer;
          process.stdin.on("data", (chunk) => {
            clearTimeout(escapeTimer); input.feed(chunk); render();
            escapeTimer = setTimeout(() => { input.flushEscape(); render(); }, 80); escapeTimer.unref();
          });
          const timer = setInterval(render, 1000); timer.unref();
          process.stdout.on("resize", render); render();
        }

        if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) runInspector();

        """#
}
