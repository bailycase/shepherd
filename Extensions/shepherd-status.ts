// Shepherd status extension: reports pi lifecycle status for one agent to the
// Shepherd extension socket as newline-delimited JSON setAgentStatus messages.
// Inert unless SHEPHERD_AGENT_ID and SHEPHERD_SOCKET are set; every failure is
// swallowed so this extension can never break or slow the pi session.
//
// It also hands pi the user's own global instructions (Settings ▸ Pi ▸ From your
// pi): pi reads a global context file only from its own agent folder, which is
// Shepherd's, so before each run the winning file in SHEPHERD_YOUR_PI_INSTRUCTIONS
// (AGENTS.override.md, AGENTS.md, …, as pi picks it) is read afresh and joins the
// context files right after pi's own root file, with its real path. Inert without
// that variable.
import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const CONTEXT_FILES = ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"];
const MAX_CONTEXT_BYTES = 256 * 1024;

// The user's winning global context file, read now; undefined when there is none, it is too
// large, or it can't be read.
function yourPiInstructions(): { path: string; content: string } | undefined {
  const folder = process.env.SHEPHERD_YOUR_PI_INSTRUCTIONS ?? "";
  if (!folder) return undefined;
  for (const name of CONTEXT_FILES) {
    const file = path.join(folder, name);
    try {
      const info = fs.statSync(file);
      if (!info.isFile()) continue;
      if (info.size > MAX_CONTEXT_BYTES) return undefined;
      return { path: file, content: fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "") };
    } catch {
      continue;
    }
  }
  return undefined;
}

// Adds the user's global instructions to one run's context files, after pi's own root file.
export function addYourPiInstructions(options: { contextFiles?: unknown } | undefined) {
  try {
    const files = options?.contextFiles;
    if (!Array.isArray(files)) return;
    const found = yourPiInstructions();
    if (!found || files.some((file) => file?.path === found.path)) return;
    const own = process.env.PI_CODING_AGENT_DIR ? path.resolve(process.env.PI_CODING_AGENT_DIR) : "";
    const root = files.findIndex((file) => typeof file?.path === "string" && path.dirname(file.path) === own);
    files.splice(root + 1, 0, found);
  } catch {
    // Instructions are never worth a failed turn.
  }
}

type Status = "working" | "blocked" | "idle" | "done";

// Tools that wait on the user (e.g. ask_user from the human extension,
// question-style tools). While one is executing the agent is blocked.
const USER_WAIT_TOOL = /(?:^|[^a-z0-9])(?:ask|question)(?:[^a-z0-9]|$)/i;

// Shepherd's sidebar says in a word or two why an agent waits ("retention?").
// The asking tools belong to other extensions, so each gets an optional
// `short` parameter, described so a model fills it. Shepherd reads it from
// the call's arguments; the tool itself never receives it.
const SHORT_REASON = {
  type: "string",
  description:
    "Optional: what you need from the user in 1-3 words, shown beside this thread in Shepherd's sidebar while it waits (e.g. \"retention?\", \"approve plan\").",
};

export default function shepherdStatus(pi: ExtensionAPI) {
  if (process.env.SHEPHERD_YOUR_PI_INSTRUCTIONS) {
    pi.on("before_agent_start", (event) => addYourPiInstructions(event?.systemPromptOptions));
  }
  const agentID = process.env.SHEPHERD_AGENT_ID ?? "";
  const socketPath = process.env.SHEPHERD_SOCKET ?? "";
  if (!agentID || !socketPath) return;

  let socket: net.Socket | undefined;
  let connected = false;
  let stopped = true;
  let retryDelay = 500;
  let retryTimer: ReturnType<typeof setTimeout> | undefined;
  let status: Status | undefined;
  let reportedSession: string | undefined;
  let sentSession: string | undefined;
  const pendingWaits = new Set<string>();
  // Asking tools whose schema carries the `short` added here (a tool with its
  // own `short` keeps it, and receives it).
  const shortTools = new Set<string>();
  const shortSchemas = new WeakSet<object>();

  // Idempotent; rerun before each prompt so a tool registered or reloaded
  // since is covered too.
  function offerShortReason() {
    try {
      shortTools.clear();
      for (const tool of pi.getAllTools()) {
        if (!USER_WAIT_TOOL.test(tool.name)) continue;
        const schema = tool.parameters as unknown as { properties?: Record<string, unknown> } | undefined;
        const properties = schema?.properties;
        if (!schema || !properties || typeof properties !== "object") continue;
        if (!shortSchemas.has(schema)) {
          if ("short" in properties) continue;
          properties.short = { ...SHORT_REASON };
          shortSchemas.add(schema);
        }
        shortTools.add(tool.name);
      }
    } catch {
      // Swallow; the sidebar falls back to the question itself.
    }
  }

  function flush() {
    if (!connected || !socket) return;
    try {
      // Session first: it decides which conversation a relaunch reopens, and
      // connect() may land after session_start already reported it. Sent once
      // per value, then re-sent only after a reconnect.
      if (reportedSession !== undefined && reportedSession !== sentSession) {
        socket.write(
          JSON.stringify({ type: "setAgentSession", agentID, piSessionID: reportedSession }) + "\n",
        );
        sentSession = reportedSession;
      }
      if (status !== undefined) {
        socket.write(
          JSON.stringify({ type: "setAgentStatus", agentID, status }) + "\n",
        );
      }
    } catch {
      // Swallow; reconnect is driven by socket error/close events.
    }
  }

  function send(next: Status) {
    if (next === status) return;
    status = next;
    flush();
  }

  // `/new` and `/resume` move pi to a different session. Report it so Shepherd
  // reopens what the user was last working in instead of the session the
  // agent originally started in.
  function sendSession(piSessionID: string | undefined) {
    if (!piSessionID || piSessionID === reportedSession) return;
    reportedSession = piSessionID;
    flush();
  }

  function scheduleReconnect() {
    if (stopped || retryTimer) return;
    retryTimer = setTimeout(() => {
      retryTimer = undefined;
      connect();
    }, retryDelay);
    retryDelay = Math.min(retryDelay * 2, 10_000);
    retryTimer.unref?.();
  }

  function connect() {
    if (stopped || socket) return;
    try {
      const s = net.createConnection(socketPath);
      socket = s;
      s.on("connect", () => {
        connected = true;
        retryDelay = 500;
        flush();
      });
      s.on("error", () => {});
      s.on("close", () => {
        connected = false;
        socket = undefined;
        sentSession = undefined;
        scheduleReconnect();
      });
      s.unref();
    } catch {
      scheduleReconnect();
    }
  }

  function disconnect() {
    if (retryTimer) {
      clearTimeout(retryTimer);
      retryTimer = undefined;
    }
    try {
      socket?.end();
    } catch {}
    connected = false;
    socket = undefined;
  }

  pi.on("session_start", (_event, ctx) => {
    stopped = false;
    retryDelay = 500;
    pendingWaits.clear();
    connect();
    send("idle");
    offerShortReason();
    // Fires for startup, /new, /resume, and /reload, so this covers every way
    // the current session can change.
    try {
      sendSession(ctx.sessionManager.getSessionId());
    } catch {
      // Swallow; session tracking must never break the session.
    }
  });

  pi.on("before_agent_start", () => {
    offerShortReason();
  });

  pi.on("tool_call", (event) => {
    try {
      if (shortTools.has(event.toolName) && event.input && typeof event.input === "object") {
        delete (event.input as Record<string, unknown>).short;
      }
    } catch {}
  });

  pi.on("agent_start", () => {
    pendingWaits.clear();
    send("working");
  });

  pi.on("agent_settled", () => {
    pendingWaits.clear();
    send("done");
  });

  pi.on("tool_execution_start", (event) => {
    if (!USER_WAIT_TOOL.test(event.toolName)) return;
    pendingWaits.add(event.toolCallId);
    send("blocked");
  });

  pi.on("tool_execution_end", (event) => {
    if (!pendingWaits.delete(event.toolCallId)) return;
    if (pendingWaits.size === 0 && status === "blocked") send("working");
  });

  pi.on("session_shutdown", () => {
    pendingWaits.clear();
    send("idle");
    stopped = true;
    disconnect();
  });
}
