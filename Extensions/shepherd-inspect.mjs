#!/usr/bin/env node
// Shepherd's subagent inspector: a terminal dashboard over a pi-subagents
// async run's lifecycle artifacts. Read-only on status.json and the child's
// session transcript; steer/stop write the same control-inbox files
// pi-subagents' own inspector uses. Dependency-free by design.
//
// Renders markdown (headers, bold, inline code, fenced blocks with a gutter),
// keeps the full transcript in a scrollable viewport (↑/↓ or PgUp/PgDn;
// typing still goes to the prompt), and pins to the tail until you scroll.
//
// Usage: node shepherd-inspect.mjs --async-dir <dir> --run-id <id> [--index <n>]
import * as fs from "node:fs";
import * as path from "node:path";
import { randomUUID } from "node:crypto";

// ---- args -------------------------------------------------------------------

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) {
  args.set(process.argv[i], process.argv[i + 1]);
}
const asyncDir = args.get("--async-dir");
const runId = args.get("--run-id");
const index = args.get("--index") !== undefined ? Number(args.get("--index")) : undefined;
if (!asyncDir || !runId) {
  process.stderr.write("usage: shepherd-inspect --async-dir <dir> --run-id <id> [--index <n>]\n");
  process.exit(1);
}

// ---- ansi -------------------------------------------------------------------

const tty = process.stdout.isTTY;
const style = (code) => (s) => (tty ? `\x1b[${code}m${s}\x1b[0m` : s);
const dim = style("2");
const bold = style("1");
const fgGreen = style("32");
const fgYellow = style("33");
const fgRed = style("31");
const fgCyan = style("36");
const fgMagenta = style("35");
const fgBlue = style("34");
const fgGray = style("90");
// Visible width of a styled string (strip SGR sequences).
const width = (s) => s.replace(/\x1b\[[0-9;]*m/g, "").length;

const stateColor = (s) =>
  s === "running" || s === "queued" ? fgYellow(s)
    : s === "complete" ? fgGreen(s)
      : s === "failed" || s === "stopped" || s === "rejected" ? fgRed(s)
        : dim(s ?? "unknown");

const cols = () => process.stdout.columns || 100;
const rows = () => process.stdout.rows || 40;
const rule = (label = "") => {
  const w = Math.max(10, cols() - 2);
  if (!label) return dim("─".repeat(w));
  return dim(`── ${label} ${"─".repeat(Math.max(2, w - label.length - 4))}`);
};
const elapsed = (ms) => {
  if (!ms) return "";
  const s = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  return s < 60 ? `${s}s` : s < 3600 ? `${Math.floor(s / 60)}m ${s % 60}s` : `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
};

// ---- markdown-ish rendering -------------------------------------------------

// Inline spans: **bold**, `code`, [link](url) → link text.
function inline(text) {
  return text
    .replace(/\*\*([^*]+)\*\*/g, (_, s) => bold(s))
    .replace(/`([^`]+)`/g, (_, s) => fgCyan(s))
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");
}

// Crude but useful code coloring: comments dim, strings green — enough to
// break up a block without pretending to be a real highlighter.
function codeLine(line) {
  const commentAt = (() => {
    for (const marker of ["//", "# ", "-- "]) {
      const at = line.indexOf(marker);
      if (at >= 0) return at;
    }
    return line.trim().startsWith("#") ? line.indexOf("#") : -1;
  })();
  let head = commentAt >= 0 ? line.slice(0, commentAt) : line;
  const tail = commentAt >= 0 ? fgGray(line.slice(commentAt)) : "";
  head = head.replace(/("[^"]*"|'[^']*')/g, (s) => fgGreen(s));
  return head + tail;
}

// Word-wrap `text` to `w`, continuation lines indented to `indent`.
function wrap(text, w, indent = "") {
  const out = [];
  for (const paragraph of text.split("\n")) {
    let line = paragraph;
    let prefix = "";
    while (width(prefix + line) > w && w > 10) {
      const room = w - width(prefix);
      let cut = line.lastIndexOf(" ", room);
      if (cut < room * 0.4) cut = room;
      out.push(prefix + line.slice(0, cut));
      line = line.slice(cut).trimStart();
      prefix = indent;
    }
    out.push(prefix + line);
    prefix = indent;
  }
  return out;
}

// Markdown block renderer for assistant text: headers, bullets, fences.
function markdown(text, w) {
  const out = [];
  let inFence = false;
  for (const raw of text.split("\n")) {
    const fence = raw.match(/^\s*```(\w*)/);
    if (fence) {
      inFence = !inFence;
      out.push(fgGray("  ╎ ") + dim(inFence ? (fence[1] || "code") : ""));
      continue;
    }
    if (inFence) {
      // Code keeps its own indentation; clip rather than wrap.
      const line = raw.length > w - 4 ? raw.slice(0, w - 5) + "…" : raw;
      out.push(fgGray("  ╎ ") + codeLine(line));
      continue;
    }
    const header = raw.match(/^(#{1,4})\s+(.*)/);
    if (header) {
      out.push("");
      out.push(bold(inline(header[2])));
      continue;
    }
    const bullet = raw.match(/^(\s*)[-*]\s+(.*)/);
    if (bullet) {
      out.push(...wrap(`${bullet[1]}• ${inline(bullet[2])}`, w, bullet[1] + "  "));
      continue;
    }
    const numbered = raw.match(/^(\s*)(\d+\.)\s+(.*)/);
    if (numbered) {
      out.push(...wrap(`${numbered[1]}${numbered[2]} ${inline(numbered[3])}`, w, numbered[1] + "   "));
      continue;
    }
    if (!raw.trim()) {
      out.push("");
      continue;
    }
    out.push(...wrap(inline(raw), w));
  }
  return out;
}

// ---- artifacts --------------------------------------------------------------

function readStatus() {
  try {
    return JSON.parse(fs.readFileSync(path.join(asyncDir, "status.json"), "utf8"));
  } catch {
    return undefined;
  }
}

function pickStep(status) {
  const steps = status?.steps ?? [];
  if (index !== undefined && steps[index]) return steps[index];
  if (steps.length === 1) return steps[0];
  return undefined;
}

const TRANSCRIPT_BYTE_BUDGET = 2 * 1024 * 1024;
const MAX_RENDERED_LINES = 8000;

// Full transcript rendered to styled lines (bounded), rebuilt each refresh.
function transcriptLines(sessionFile, w) {
  let raw;
  try {
    const size = fs.statSync(sessionFile).size;
    const fd = fs.openSync(sessionFile, "r");
    const start = size > TRANSCRIPT_BYTE_BUDGET ? size - TRANSCRIPT_BYTE_BUDGET : 0;
    const buffer = Buffer.alloc(size - start);
    fs.readSync(fd, buffer, 0, buffer.length, start);
    fs.closeSync(fd);
    raw = buffer.toString("utf8");
    if (start > 0) raw = raw.slice(raw.indexOf("\n") + 1);
  } catch {
    return [dim("(no transcript yet)")];
  }

  const out = [];
  for (const entry of raw.split("\n")) {
    if (!entry.trim()) continue;
    let obj;
    try { obj = JSON.parse(entry); } catch { continue; }
    if (obj.type !== "message") continue;
    const message = obj.message ?? {};
    if (message.role === "assistant") {
      for (const item of message.content ?? []) {
        if (item.type === "text" && item.text?.trim()) {
          out.push("");
          out.push(...markdown(item.text.trim(), w));
        } else if (item.type === "toolCall") {
          const a = item.arguments ?? {};
          const hint = a.command ?? a.path ?? a.pattern ?? a.query ?? a.file_path ?? "";
          const hintText = typeof hint === "string" && hint
            ? " " + dim(hint.length > w - 20 ? hint.slice(0, w - 21) + "…" : hint)
            : "";
          out.push("");
          out.push(fgCyan(`▸ ${item.name}`) + hintText);
        }
      }
    } else if (message.role === "toolResult") {
      const text = (message.content ?? [])
        .map((c) => (c.type === "text" ? c.text : ""))
        .join(" ")
        .replace(/\s+/g, " ")
        .trim();
      if (text) {
        // Two clipped lines of result: enough to see what came back
        // without drowning the conversation.
        const room = w - 6;
        out.push(fgGray(`  ⎿ ${text.slice(0, room)}`));
        if (text.length > room) {
          out.push(fgGray(`    ${text.slice(room, room * 2)}${text.length > room * 2 ? "…" : ""}`));
        }
      }
    } else if (message.role === "user") {
      const text = typeof message.content === "string"
        ? message.content
        : (message.content ?? []).map((c) => c.text ?? "").join("\n");
      const trimmed = text.trim();
      if (trimmed) {
        out.push("");
        for (const line of wrap(trimmed.split("\n").slice(0, 6).join("\n"), w - 2)) {
          out.push(fgMagenta("┃ ") + fgMagenta(line));
        }
      }
    }
    if (out.length > MAX_RENDERED_LINES) out.splice(0, out.length - MAX_RENDERED_LINES);
  }
  return out;
}

// ---- control inbox ----------------------------------------------------------

function writeAtomic(file, object) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(object));
  fs.renameSync(tmp, file);
}

function requestStop() {
  writeAtomic(path.join(asyncDir, "control", "stop.json"), {
    type: "stop", ts: Date.now(), source: "shepherd-inspect",
  });
}

function requestSteer(message) {
  const id = randomUUID();
  writeAtomic(path.join(asyncDir, "control", "steer-requests", `${id}.json`), {
    type: "steer", id, ts: Date.now(), message,
    ...(index !== undefined ? { targetIndex: index } : {}),
    source: "shepherd-inspect",
  });
}

// ---- render -----------------------------------------------------------------

let notice = "";
let promptBuffer = "";
// Lines scrolled up from the tail; 0 = pinned to the newest output.
let scrollFromTail = 0;
let cachedBody = [];

function refreshBody() {
  const status = readStatus();
  const step = pickStep(status);
  cachedBody = step?.sessionFile
    ? transcriptLines(step.sessionFile, cols() - 2)
    : [dim("(no per-lane session file yet)")];
  return { status, step };
}

function render(reread = true) {
  let status;
  let step;
  if (reread) {
    ({ status, step } = refreshBody());
  } else {
    status = readStatus();
    step = pickStep(status);
  }

  const header = [];
  if (!status || status.runId !== runId) {
    header.push(fgRed(`run ${runId} unavailable`), dim(asyncDir));
  } else {
    const state = step?.status ?? status.state;
    const label = step?.label ?? step?.workflowKey ?? status.mode ?? "run";
    const agent = step?.agent ? dim(` · ${step.agent}`) : "";
    const model = step?.model ? dim(` · ${step.model}`) : "";
    const age = elapsed(step?.startedAt ?? status.startedAt);
    header.push(`${bold(label)}${agent}${model}  ${stateColor(state)}${age ? dim(` · ${age}`) : ""}`);
    const live = state === "running" || state === "queued";
    const recent = (step?.recentTools ?? []).slice(-3);
    if (live && recent.length) {
      header.push(recent.map((t) => fgCyan(`▸ ${t.tool}`)).join(dim("  ·  ")));
    }
  }

  const footerLines = 2;
  const viewport = Math.max(5, rows() - header.length - footerLines - 2);
  const body = cachedBody;
  scrollFromTail = Math.min(scrollFromTail, Math.max(0, body.length - viewport));
  const end = body.length - scrollFromTail;
  const slice = body.slice(Math.max(0, end - viewport), end);

  const scrollTag = scrollFromTail > 0
    ? fgYellow(`↑ ${scrollFromTail} lines up — ↓/esc to tail`)
    : "";
  const parts = [
    ...header,
    rule(scrollTag ? "" : "transcript"),
    ...(scrollTag ? [scrollTag] : []),
    ...slice,
    rule(),
    `${notice ? notice + "  " : ""}${dim("↑↓ scroll · type to steer · :stop stops · ctrl+c closes viewer")}`,
    fgYellow("> ") + promptBuffer,
  ];
  process.stdout.write("\x1b[2J\x1b[H" + parts.join("\n"));
}

// ---- input ------------------------------------------------------------------

process.stdin.setRawMode?.(true);
process.stdin.resume();
process.stdin.on("data", (chunk) => {
  const s = chunk.toString("utf8");
  const page = Math.max(5, rows() - 8);

  if (s === "\x03") { // ctrl+c
    process.stdout.write("\x1b[2J\x1b[H");
    process.exit(0);
  } else if (s === "\x1b[A") { // up
    scrollFromTail += 1;
    render(false);
  } else if (s === "\x1b[B") { // down
    scrollFromTail = Math.max(0, scrollFromTail - 1);
    render(false);
  } else if (s === "\x1b[5~") { // page up
    scrollFromTail += page;
    render(false);
  } else if (s === "\x1b[6~") { // page down
    scrollFromTail = Math.max(0, scrollFromTail - page);
    render(false);
  } else if (s === "\x1b") { // bare esc: jump to tail
    scrollFromTail = 0;
    render(false);
  } else if (s === "\r" || s === "\n") {
    const line = promptBuffer.trim();
    promptBuffer = "";
    if (!line) { render(false); return; }
    try {
      if (line === ":stop" || line === "stop") {
        requestStop();
        notice = fgRed("stop requested");
      } else {
        requestSteer(line);
        notice = fgGreen("steer queued");
        scrollFromTail = 0;
      }
    } catch (error) {
      notice = fgRed(`control failed: ${error?.message ?? error}`);
    }
    setTimeout(() => { notice = ""; render(false); }, 4000).unref?.();
    render(false);
  } else if (s === "\x7f" || s === "\b") {
    promptBuffer = promptBuffer.slice(0, -1);
    render(false);
  } else if (s >= " " && !s.startsWith("\x1b")) {
    promptBuffer += s;
    render(false);
  }
});

render();
const timer = setInterval(() => {
  // Live refresh keeps the tail moving but never yanks a scrolled-back view.
  const pinned = scrollFromTail === 0;
  refreshBody();
  if (pinned) render(false);
}, 1500);
timer.unref?.();
process.stdout.on("resize", () => render());
