// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd subagents extension: mirrors pi-subagents child runs for one agent
// to the Shepherd extension socket as newline-delimited JSON setAgentChildren
// messages (full replace per publish). Modelled on pi-subagents' own Herdr
// status bridge: subscribe to the async lifecycle events, keep a small run
// map, and publish a bounded display projection. State detail comes from the
// versioned in-process RPC snapshot when pi-subagents offers it; without the
// RPC the bridge degrades to event-derived rows. Inert unless
// SHEPHERD_AGENT_ID and SHEPHERD_SOCKET are set, and inert without
// pi-subagents (no events ever fire). Every failure is swallowed so this
// extension can never break or slow the pi session.
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// pi-subagents' public event names (docs/extension-api.md). String literals
// on purpose: this extension must not import pi-subagents.
const STARTED_EVENT = "subagent:async-started";
const COMPLETE_EVENT = "subagent:async-complete";
const CONTROL_EVENT = "subagent:control-event";
const RPC_READY_EVENT = "subagents:rpc:v1:ready";
const RPC_REQUEST_EVENT = "subagents:rpc:v1:request";
const RPC_REPLY_PREFIX = "subagents:rpc:v1:reply:";

const PUBLISH_DEBOUNCE_MS = 400;
// Polling is the state transport for workflow runs (they emit no lifecycle
// events), so this is the effective UI update rate while rows are visible.
// The RPC status call is in-process and bounded.
const REFRESH_MS = 5_000;
const RPC_TIMEOUT_MS = 5_000;
const MAX_CHILDREN = 20;
const MAX_TEXT = 160;

export default function shepherdSubagents(pi: ExtensionAPI) {
  const agentID = process.env.SHEPHERD_AGENT_ID ?? "";
  const socketPath = process.env.SHEPHERD_SOCKET ?? "";
  if (!agentID || !socketPath) return;

  // Only the root interactive session publishes; a headless child runtime
  // must never fight the pane's agent over sidebar state.
  let rootSession = false;
  let sessionGeneration = 0;
  let rpcReady = false;
  // Event-sourced facts the snapshot lacks: asyncDir per run, and attention.
  const runs = new Map<string, { asyncDir?: string; agents?: string[]; startedAt: number }>();
  const attention = new Map<string, string>();
  const terminal = new Map<string, { state: string; endedAt: number }>();
  let publishTimer: ReturnType<typeof setTimeout> | undefined;
  let refreshTimer: ReturnType<typeof setInterval> | undefined;
  // Workflow runs never emit the async lifecycle events (only single/chain
  // spawns do), so event bookkeeping alone undercounts. Track whether the
  // last publish actually showed rows and keep polling until it empties.
  let lastPublishHadRows = false;
  // Terminal snapshot rows at or before this parent-turn boundary are history,
  // not current children. The RPC snapshot retains recent completed runs.
  let terminalCutoff = 0;
  let pendingReport: unknown[] | undefined;
  let reporting = false;

  // pi-subagents' async run directory layout (shared/types.ts): workflow
  // runs never emit the started event that carries asyncDir, but the path is
  // deterministic from the run id, so derive it for snapshot-only rows. The
  // inspector reads real artifacts, so a wrong guess just shows "status
  // unavailable" rather than anything harmful.
  const tempRoot = process.env.PI_SUBAGENTS_TEMP_ROOT?.trim()
    ? path.resolve(process.env.PI_SUBAGENTS_TEMP_ROOT.trim())
    : path.join(os.tmpdir(), `pi-subagents-uid-${process.getuid?.() ?? "shared"}`);
  const derivedAsyncDir = (runID: string) => path.join(tempRoot, "async-subagent-runs", runID);

  function clip(raw: unknown): string | undefined {
    if (typeof raw !== "string") return undefined;
    const text = raw.replace(/\s+/g, " ").trim();
    if (!text) return undefined;
    return text.length > MAX_TEXT ? text.slice(0, MAX_TEXT) : text;
  }

  // ---- socket (ordered, coalesced full-replacement publishes) --------------

  function report(children: unknown[]) {
    pendingReport = children;
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
        socket.on("error", () => { });
        socket.on("close", flush);
        socket.unref();
      } catch {
        reporting = false;
      }
    };
    flush();
  }

  // ---- children projection -------------------------------------------------

  function eventDerivedChildren(): unknown[] {
    const rows: unknown[] = [];
    for (const [id, run] of runs) {
      const done = terminal.get(id);
      rows.push({
        runID: id,
        label: clip(run.agents?.join(", ")) ?? "subagent",
        state: done?.state ?? "running",
        startedAt: run.startedAt,
        ...(done ? { endedAt: done.endedAt } : {}),
        needsAttention: attention.has(id),
        ...(attention.has(id) ? { attentionText: attention.get(id) } : {}),
        asyncDir: run.asyncDir ?? derivedAsyncDir(id),
      });
    }
    return rows.slice(0, MAX_CHILDREN);
  }

  // The RPC status reply carries a bounded, versioned display snapshot
  // (pi-subagents.async-status-snapshot v1). A workflow run flattens one
  // level so each lane gets its own sidebar row (the run key is the label);
  // a single-agent run is itself the row. Deeper nesting stays a pi concern.
  function snapshotChildren(snapshot: unknown): unknown[] | undefined {
    if (typeof snapshot !== "object" || snapshot === null) return undefined;
    const s = snapshot as Record<string, unknown>;
    if (s.kind !== "pi-subagents.async-status-snapshot" || s.version !== 1) return undefined;
    if (!Array.isArray(s.runs)) return undefined;
    const rows: unknown[] = [];
    const push = (n: Record<string, unknown>, runID: string, index?: number) => {
      const state = typeof n.state === "string" ? n.state : "running";
      const terminalAt = [n.endedAt, n.updatedAt, n.startedAt].find((value) => typeof value === "number") as number | undefined;
      if (["complete", "failed", "paused", "stopped", "rejected"].includes(state)
        && terminalAt !== undefined && terminalAt <= terminalCutoff) return;
      const activity =
        typeof n.activity === "object" && n.activity !== null ? (n.activity as Record<string, unknown>) : {};
      rows.push({
        runID,
        ...(index !== undefined ? { childIndex: index } : {}),
        label: clip(n.label) ?? "subagent",
        state,
        ...(typeof n.startedAt === "number" ? { startedAt: n.startedAt } : {}),
        ...(typeof n.endedAt === "number" ? { endedAt: n.endedAt } : {}),
        ...(clip(activity.currentTool) ? { currentTool: clip(activity.currentTool) } : {}),
        needsAttention: attention.has(runID),
        ...(attention.has(runID) ? { attentionText: attention.get(runID) } : {}),
        asyncDir: runs.get(runID)?.asyncDir ?? derivedAsyncDir(runID),
      });
    };
    for (const node of s.runs) {
      if (typeof node !== "object" || node === null) continue;
      const n = node as Record<string, unknown>;
      if (typeof n.id !== "string" || !n.id) continue;
      const kids = Array.isArray(n.children)
        ? (n.children as unknown[]).filter(
          (c): c is Record<string, unknown> => typeof c === "object" && c !== null,
        )
        : [];
      if (n.kind === "workflow" && kids.length > 0) {
        kids.forEach((kid, index) => {
          if (rows.length < MAX_CHILDREN) push(kid, n.id, index);
        });
      } else if (rows.length < MAX_CHILDREN) {
        push(n, n.id);
      }
      if (rows.length >= MAX_CHILDREN) break;
    }
    return rows;
  }

  function rpcStatus(): Promise<unknown[] | undefined> {
    return new Promise((resolve) => {
      const requestId = `shepherd-${Date.now()}-${Math.random().toString(36).slice(2)}`;
      let settled = false;
      const timer = setTimeout(() => {
        if (!settled) {
          settled = true;
          resolve(undefined);
        }
      }, RPC_TIMEOUT_MS);
      timer.unref?.();
      try {
        pi.events.on(`${RPC_REPLY_PREFIX}${requestId}`, (reply: unknown) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          const r = reply as Record<string, unknown> | undefined;
          const data =
            r && r.success === true && typeof r.data === "object" && r.data !== null
              ? (r.data as Record<string, unknown>)
              : undefined;
          resolve(data ? snapshotChildren(data.asyncSnapshot) : undefined);
        });
        pi.events.emit(RPC_REQUEST_EVENT, {
          version: 1,
          requestId,
          method: "status",
          params: {},
        });
      } catch {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(undefined);
        }
      }
    });
  }

  // ---- publishing ----------------------------------------------------------

  let publishing = false;

  async function publish() {
    if (!rootSession || publishing) return;
    const generation = sessionGeneration;
    publishing = true;
    try {
      let children: unknown[] | undefined;
      if (rpcReady) children = await rpcStatus();
      if (!rootSession || generation !== sessionGeneration) return;
      const rows = children ?? eventDerivedChildren();
      lastPublishHadRows = rows.length > 0;
      report(rows);
      syncRefreshTimer();
    } catch {
      // Swallow.
    } finally {
      publishing = false;
    }
  }

  function schedulePublish() {
    if (!rootSession || publishTimer) return;
    publishTimer = setTimeout(() => {
      publishTimer = undefined;
      void publish();
    }, PUBLISH_DEBOUNCE_MS);
    publishTimer.unref?.();
  }

  function syncRefreshTimer() {
    // A periodic re-publish keeps Shepherd's staleness guard fed while work
    // is visible, and stops (letting rows expire) once a publish comes back
    // empty. Keyed on published rows, not the event-derived run map, because
    // workflow runs are invisible to the lifecycle events.
    const active = lastPublishHadRows
      || (runs.size > 0 && [...runs.keys()].some((id) => !terminal.has(id)));
    if (active && !refreshTimer) {
      refreshTimer = setInterval(() => void publish(), REFRESH_MS);
      refreshTimer.unref?.();
    } else if (!active && refreshTimer) {
      clearInterval(refreshTimer);
      refreshTimer = undefined;
    }
  }

  function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
  }

  // ---- lifecycle events ----------------------------------------------------

  try {
    pi.events.on(RPC_READY_EVENT, () => {
      rpcReady = true;
    });

    pi.events.on(STARTED_EVENT, (data: unknown) => {
      if (!rootSession || !isRecord(data) || typeof data.id !== "string" || !data.id) return;
      runs.set(data.id, {
        ...(typeof data.asyncDir === "string" ? { asyncDir: data.asyncDir } : {}),
        ...(Array.isArray(data.agents)
          ? { agents: data.agents.filter((a: unknown) => typeof a === "string") }
          : typeof data.agent === "string"
            ? { agents: [data.agent] }
            : {}),
        startedAt: Date.now(),
      });
      terminal.delete(data.id);
      attention.delete(data.id);
      syncRefreshTimer();
      schedulePublish();
    });

    pi.events.on(COMPLETE_EVENT, (data: unknown) => {
      if (!rootSession || !isRecord(data)) return;
      const id = typeof data.runId === "string" ? data.runId : data.id;
      if (typeof id !== "string" || !id || !runs.has(id)) return;
      const state = typeof data.state === "string" && data.state ? data.state : "complete";
      terminal.set(id, { state, endedAt: Date.now() });
      attention.delete(id);
      syncRefreshTimer();
      schedulePublish();
    });

    pi.events.on(CONTROL_EVENT, (data: unknown) => {
      if (!rootSession || !isRecord(data) || data.source !== "async" || !isRecord(data.event)) return;
      if (data.event.type !== "needs_attention" || typeof data.event.runId !== "string") return;
      if (!runs.has(data.event.runId)) return;
      const label =
        clip(data.noticeText) ?? clip(data.event.message) ?? "subagent needs attention";
      attention.set(data.event.runId, label);
      schedulePublish();
    });
  } catch {
    // Swallow; without events this extension is inert.
  }

  pi.on("session_start", (_event, ctx) => {
    // hasUI distinguishes the interactive parent from a headless child
    // runtime; default to publishing when the field is absent.
    sessionGeneration += 1;
    rootSession = (ctx as { hasUI?: boolean }).hasUI !== false;
  });

  // The one reliable trigger for every spawn shape: workflows, singles, and
  // chains all go through the subagent tool. A publish after each call picks
  // up whatever the RPC snapshot now shows — including workflow runs that
  // fire no lifecycle events at all.
  pi.on("tool_execution_end", (event) => {
    if (!rootSession) return;
    if ((event as { toolName?: string }).toolName !== "subagent") return;
    schedulePublish();
  });

  // The parent consuming results and moving on is the batch boundary; clear
  // terminal rows so the sidebar only ever shows current work. Live rows
  // survive (a rolling fanout keeps its running children).
  pi.on("agent_start", () => {
    if (!rootSession) return;
    terminalCutoff = Date.now();
    let changed = false;
    for (const [id, done] of terminal) {
      if (runs.delete(id)) changed = true;
      terminal.delete(id);
      attention.delete(id);
      void done;
    }
    if (changed) syncRefreshTimer();
    if (changed || lastPublishHadRows) schedulePublish();
  });

  pi.on("session_shutdown", () => {
    const wasRootSession = rootSession;
    sessionGeneration += 1;
    rootSession = false;
    runs.clear();
    terminal.clear();
    attention.clear();
    if (publishTimer) {
      clearTimeout(publishTimer);
      publishTimer = undefined;
    }
    syncRefreshTimer();
    if (wasRootSession) report([]);
  });
}
