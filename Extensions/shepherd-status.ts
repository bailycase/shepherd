// Shepherd status extension: reports pi lifecycle status for one agent to the
// Shepherd extension socket as newline-delimited JSON setAgentStatus messages.
// Inert unless SHEPHERD_AGENT_ID and SHEPHERD_SOCKET are set; every failure is
// swallowed so this extension can never break or slow the pi session.
import * as net from "node:net";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type Status = "working" | "blocked" | "idle" | "done";

// Tools that wait on the user (e.g. ask_user from the human extension,
// question-style tools). While one is executing the agent is blocked.
const USER_WAIT_TOOL = /(?:^|[^a-z0-9])(?:ask|question)(?:[^a-z0-9]|$)/i;

export default function shepherdStatus(pi: ExtensionAPI) {
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
    // Fires for startup, /new, /resume, and /reload, so this covers every way
    // the current session can change.
    try {
      sendSession(ctx.sessionManager.getSessionId());
    } catch {
      // Swallow; session tracking must never break the session.
    }
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
