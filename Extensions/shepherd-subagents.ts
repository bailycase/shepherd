// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Publish only Shepherd-owned child runs to the parent's extension socket.
import * as net from "node:net";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PUBLISH_DEBOUNCE_MS = 400;
const REFRESH_MS = 5_000;
const MAX_CHILDREN = 20;

export default function shepherdSubagents(pi: ExtensionAPI) {
  const agentID = process.env.SHEPHERD_AGENT_ID ?? "";
  const socketPath = process.env.SHEPHERD_SOCKET ?? "";
  if (!agentID || !socketPath) return;

  let rootSession = false;
  let parentSessionID = "";
  let children: any[] = [];
  let childrenKey = "[]";
  let publishTimer: ReturnType<typeof setTimeout> | undefined;
  let refreshTimer: ReturnType<typeof setInterval> | undefined;
  let pendingReport: unknown[] | undefined;
  let reporting = false;

  // Coalesce full replacements while preserving socket delivery order.
  function report(rows: unknown[]) {
    pendingReport = rows;
    if (reporting) return;
    reporting = true;
    const flush = () => {
      const next = pendingReport;
      if (!next) {
        reporting = false;
        return;
      }
      pendingReport = undefined;
      try {
        const socket = net.createConnection(socketPath, () => {
          try {
            socket.end(JSON.stringify({ type: "setAgentChildren", agentID, children: next }) + "\n");
          } catch {
            socket.destroy();
          }
        });
        socket.on("error", () => {});
        socket.on("close", flush);
        socket.unref();
      } catch {
        reporting = false;
      }
    };
    flush();
  }

  function publish() {
    if (!rootSession) return;
    report([...children].sort((a, b) =>
      Number(b.state === "running" || b.state === "queued") - Number(a.state === "running" || a.state === "queued")
      || Number(b.needsAttention === true) - Number(a.needsAttention === true)).slice(0, MAX_CHILDREN));
    // Keep the app's staleness guard fed while rows are visible.
    if (children.length && !refreshTimer) {
      refreshTimer = setInterval(publish, REFRESH_MS);
      refreshTimer.unref?.();
    } else if (!children.length && refreshTimer) {
      clearInterval(refreshTimer);
      refreshTimer = undefined;
    }
  }

  pi.events.on("shepherd:children:v1", (data: any) => {
    if (!rootSession || data?.owner !== parentSessionID || !Array.isArray(data.children)) return;
    const next = data.children;
    const key = JSON.stringify(next);
    if (key === childrenKey) return;
    childrenKey = key;
    children = next;
    if (publishTimer) return;
    publishTimer = setTimeout(() => {
      publishTimer = undefined;
      publish();
    }, PUBLISH_DEBOUNCE_MS);
    publishTimer.unref?.();
  });

  function clear() {
    children = [];
    childrenKey = "[]";
    if (publishTimer) clearTimeout(publishTimer);
    if (refreshTimer) clearInterval(refreshTimer);
    publishTimer = undefined;
    refreshTimer = undefined;
  }

  pi.on("session_start", (_event, ctx) => {
    const wasRootSession = rootSession;
    clear();
    rootSession = !process.env.SHEPHERD_CHILD && (ctx as { hasUI?: boolean }).hasUI !== false;
    parentSessionID = ctx.sessionManager.getSessionId();
    if (wasRootSession) report([]);
  });

  pi.on("session_shutdown", () => {
    const wasRootSession = rootSession;
    rootSession = false;
    clear();
    if (wasRootSession) report([]);
  });
}
