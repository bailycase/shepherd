// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd panes extension: lets an agent drive its own workspace — open panes
// beside itself, run commands in them, read what they printed, and close them.
// The agent's own pi pane is off limits (it cannot close or type into itself).
// Inert unless Shepherd's env is present.
import * as net from "node:net";
import { randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const REQUEST_TIMEOUT_MS = 15_000;

interface Reply {
  type: string;
  id: number;
  code?: string;
  message?: string;
  panes?: PaneInfo[];
  pane?: PaneInfo;
  paneID?: string;
  lines?: string[];
  automations?: AutomationInfo[];
  agents?: AgentPeerInfo[];
  text?: string;
  requestID?: string;
  targetAgentID?: string;
  request?: { operation: string; text?: string; after?: string; limit?: number };
  result?: { text: string; idle?: boolean; sessionID?: string; connectionID?: string; code?: string };
}

interface AgentPeerInfo {
  id: string;
  name: string;
  status: string;
  cwd: string;
  isSelf: boolean;
}

interface AutomationInfo {
  id: string;
  name: string;
  prompt: string;
  cwd: string;
  enabled: boolean;
  agentStatus?: string;
}

interface PaneInfo {
  id: string;
  cwd: string;
  isAgentPane: boolean;
  isFocused: boolean;
  isAlive: boolean;
}

export default function shepherdPanes(pi: ExtensionAPI) {
  const agentID = process.env.SHEPHERD_AGENT_ID ?? "";
  const socketPath = process.env.SHEPHERD_SOCKET ?? "";
  if (!agentID || !socketPath) return;

  // ---- socket client (request/reply, NDJSON) -------------------------------

  let socket: net.Socket | undefined;
  let connecting: Promise<net.Socket> | undefined;
  let liveContext;
  let nextID = 1;
  let connectionLosses = 0;
  const pending = new Map<number, (reply: Reply) => void>();

  function connect(): Promise<net.Socket> {
    if (socket && !socket.destroyed) return Promise.resolve(socket);
    if (connecting) return connecting;
    connecting = new Promise((resolve, reject) => {
      const s = net.createConnection(socketPath);
      const connectionID = randomUUID();
      let buffer = "";
      const timer = setTimeout(() => s.destroy(new Error("Shepherd connection timed out")), 5_000);
      timer.unref?.();
      s.setEncoding("utf8");
      s.on("connect", () => {
        clearTimeout(timer);
        socket = s;
        // Register for pushes: Shepherd may now deliver unsolicited
        // peer-thread message frames (id 0) on this connection.
        try {
          s.write(JSON.stringify({ type: "helloAgent", agentID }) + "\n");
        } catch {}
        resolve(s);
      });
      s.on("data", (chunk: string) => {
        buffer += chunk;
        let index = buffer.indexOf("\n");
        while (index >= 0) {
          const line = buffer.slice(0, index);
          buffer = buffer.slice(index + 1);
          if (line.trim().length > 0) {
            try {
              const reply = JSON.parse(line) as Reply;
              if (reply.type === "agentRequest" && reply.targetAgentID === agentID) {
                let result;
                try {
                  if (!liveContext) throw new Error("live session context unavailable");
                  const ctx = liveContext;
                  const req = reply.request;
                  switch (req?.operation) {
                    case "read": {
                      const branch = ctx.sessionManager.getBranch();
                      const after = req.after === undefined ? -1 : branch.findIndex((e) => e.id === req.after);
                      if (req.after !== undefined && after < 0) throw new Error("cursor is not on the current branch; read again without after");
                      const limit = Number.isInteger(req.limit) ? Math.max(1, Math.min(100, req.limit)) : 20;
                      const visible = branch.slice(after + 1).filter((e) =>
                        (e.type === "message" && ["user", "assistant", "toolResult", "bashExecution"].includes(e.message.role)) ||
                        (e.type === "custom_message" && e.display === true) ||
                        e.type === "compaction" || e.type === "branch_summary"
                      );
                      const selected = req.after === undefined ? visible.slice(-limit) : visible.slice(0, limit);
                      const messages = [];
                      let bytes = 0;
                      for (const entry of selected) {
                        const message = entry.type === "message" ? entry.message : entry;
                        const content = message.content;
                        // Only text blocks are copied. Never serialize thinking, image data, or tool arguments.
                        let body = typeof content === "string" ? content : Array.isArray(content)
                          ? content.filter((c) => c.type === "text").map((c) => c.text).join("\n") : "";
                        if (message.role === "bashExecution") body = `$ ${message.command}\n${message.output}`;
                        if (entry.type === "compaction" || entry.type === "branch_summary") body = entry.summary;
                        const row = { id: entry.id, role: message.role ?? entry.type,
                          text: body.slice(0, 4000), truncated: body.length > 4000 };
                        const size = Buffer.byteLength(JSON.stringify(row));
                        if (bytes + size > 48 * 1024) break;
                        messages.push(row);
                        bytes += size;
                      }
                      result = { text: JSON.stringify({ messages, nextCursor: messages.at(-1)?.id ?? req.after ?? null,
                        hasMore: messages.length < selected.length || (req.after !== undefined && visible.length > messages.length),
                        omittedEarlier: req.after === undefined && visible.length > selected.length }),
                        sessionID: ctx.sessionManager.getSessionId() };
                      break;
                    }
                    case "steer":
                      if (typeof req.text !== "string" || !req.text.trim()) throw new Error("steering text is required");
                      pi.sendUserMessage(req.text, { deliverAs: "steer" });
                      result = { text: "steering dispatch requested; acceptance and consumption are not confirmed" };
                      break;
                    case "interrupt":
                      ctx.abort();
                      result = { text: "current-turn cancellation requested, not confirmed stopped; tools must cooperate. In pi TUI queued messages move to the editor; retries and compaction are not cancelled." };
                      break;
                    case "status":
                      result = { text: "live activity snapshot", idle: ctx.isIdle() && !ctx.hasPendingMessages(),
                        sessionID: ctx.sessionManager.getSessionId(), connectionID };
                      break;
                    default: throw new Error("unsupported live agent operation");
                  }
                } catch (error) {
                  result = { text: String(error).slice(0, 1000), code: "recipient_error" };
                }
                try { s.write(JSON.stringify({ type: "agentResponse", agentID, requestID: reply.requestID, result }) + "\n"); } catch {}
              } else if (reply.type === "message" && typeof reply.text === "string") {
                // Unsolicited peer-thread message: inject as a real user
                // message. followUp queues politely mid-turn; triggerTurn
                // wakes an idle agent.
                try {
                  pi.sendUserMessage(reply.text, { deliverAs: "followUp" });
                } catch {
                  // Never let delivery break the session.
                }
              } else {
                const resolver = pending.get(reply.id);
                if (resolver) {
                  resolver(reply);
                }
              }
            } catch {
              // Ignore undecodable lines; the request times out.
            }
          }
          index = buffer.indexOf("\n");
        }
      });
      s.on("error", (error) => {
        clearTimeout(timer);
        if (socket === s) socket = undefined;
        reject(error);
      });
      s.on("close", () => {
        connectionLosses++;
        clearTimeout(timer);
        reject(new Error("Shepherd closed the connection"));
        if (socket && socket !== s) return;
        socket = undefined;
        // Fail everything still waiting rather than hanging the agent.
        for (const [id, resolver] of pending) {
          resolver({ type: "error", id, code: "disconnected", message: "Shepherd closed the connection" });
        }
      });
      s.unref();
    }).finally(() => { connecting = undefined; });
    return connecting;
  }

  // Throws on failure: pi marks a tool errored only when execute throws.
  async function request(payload: Record<string, unknown>, signal?: AbortSignal, timeout = REQUEST_TIMEOUT_MS): Promise<Reply> {
    if (signal?.aborted) throw new Error("request cancelled");
    const id = nextID++;
    const reply = await new Promise<Reply>((resolve) => {
      const finish = (received: Reply) => {
        if (!pending.delete(id)) return;
        clearTimeout(timer);
        signal?.removeEventListener("abort", abort);
        resolve(received);
      };
      const cancel = (code: string) => {
        try { socket?.write(JSON.stringify({ type: "cancelAgentRequest", id, agentID }) + "\n"); } catch {}
        finish({ type: "error", id, code, message: `Shepherd request ${code}` });
      };
      const abort = () => cancel("cancelled");
      const timer = setTimeout(() => cancel("timeout"), timeout);
      timer.unref?.();
      pending.set(id, finish);
      signal?.addEventListener("abort", abort, { once: true });
      connect().then((s) => {
        if (pending.has(id)) s.write(JSON.stringify({ ...payload, id, agentID }) + "\n");
      }).catch((error) => finish({ type: "error", id, code: "disconnected", message: String(error) }));
    });

    if (reply.type === "error" || reply.result?.code) {
      throw new Error(`${reply.result?.text ?? reply.message ?? "request failed"} (${reply.result?.code ?? reply.code})`);
    }
    return reply;
  }

  function text(body: string) {
    return { content: [{ type: "text" as const, text: body }] };
  }

  function describe(pane: PaneInfo): string {
    const tags = [
      pane.isAgentPane ? "your pi pane" : undefined,
      pane.isFocused ? "focused" : undefined,
      pane.isAlive ? undefined : "no process",
    ].filter(Boolean);
    return `${pane.id}  ${pane.cwd}${tags.length > 0 ? `  [${tags.join(", ")}]` : ""}`;
  }

  // ---- tools ---------------------------------------------------------------

  pi.registerTool({
    name: "pane_list",
    label: "List Panes",
    description:
      "List the panes in your Shepherd workspace: each pane's id, working directory, and whether " +
      "it is your own pi pane, focused, or has a running process.",
    promptSnippet: "List the terminal panes in your Shepherd workspace",
    parameters: Type.Object({}),
    async execute() {
      const reply = await request({ type: "listPanes" });
      const panes = reply.panes ?? [];
      return text(panes.length === 0 ? "no panes" : panes.map(describe).join("\n"));
    },
  });

  pi.registerTool({
    name: "pane_open",
    label: "Open Pane",
    description:
      "Open a new terminal pane in your Shepherd workspace without changing the user's focus, " +
      "splitting your own pane by default, and optionally run a command in it. Returns the new " +
      "pane's id for pane_run, pane_read, pane_focus, and pane_close.",
    promptSnippet: "Open a terminal pane beside you and optionally run a command in it",
    promptGuidelines: [
      "Use pane_open for long-running processes the user should see — dev servers, log tails, " +
      "test watchers — and use bash for one-off commands whose output you just need to read.",
    ],
    parameters: Type.Object({
      command: Type.Optional(
        Type.String({ description: "Shell command to run in the new pane once it starts" }),
      ),
      axis: Type.Optional(
        Type.String({
          description:
            "'vertical' splits side by side (default), 'horizontal' stacks the new pane below",
        }),
      ),
      cwd: Type.Optional(
        Type.String({ description: "Working directory; defaults to the split pane's directory" }),
      ),
      relativeTo: Type.Optional(
        Type.String({ description: "Pane id to split; defaults to your own pi pane" }),
      ),
    }),
    async execute(_toolCallId, params) {
      const reply = await request({
        type: "openPane",
        axis: params.axis === "horizontal" ? "horizontal" : "vertical",
        cwd: params.cwd,
        relativeTo: params.relativeTo,
        command: params.command,
      });
      const pane = reply.pane;
      if (!pane) return text("pane opened");
      return text(
        `opened pane ${pane.id} in ${pane.cwd}` +
        (params.command ? `\nrunning: ${params.command}` : "") +
        (pane.isAlive ? "" : "\nwarning: the pane has no running process yet"),
      );
    },
  });

  pi.registerTool({
    name: "pane_run",
    label: "Run in Pane",
    description:
      "Type text into one of your panes. By default it is submitted as a command (newline " +
      "appended); pass submit:false to type without running, e.g. to answer a prompt. You " +
      "cannot type into your own pi pane.",
    promptSnippet: "Type a command into one of your Shepherd panes",
    parameters: Type.Object({
      paneID: Type.String({ description: "Pane id from pane_open or pane_list" }),
      text: Type.String({ description: "Text to type into the pane" }),
      submit: Type.Optional(
        Type.Boolean({ description: "Append a newline so the text runs (default true)" }),
      ),
    }),
    async execute(_toolCallId, params) {
      await request({
        type: "sendPaneInput",
        paneID: params.paneID,
        text: params.text,
        submit: params.submit !== false,
      });
      return text(`sent to pane ${params.paneID}`);
    },
  });

  pi.registerTool({
    name: "pane_read",
    label: "Read Pane",
    description:
      "Read what is currently on a pane's screen, as plain text lines. This is the visible " +
      "screen rather than full scrollback, so read soon after running something.",
    promptSnippet: "Read the current screen of one of your Shepherd panes",
    parameters: Type.Object({
      paneID: Type.String({ description: "Pane id from pane_open or pane_list" }),
    }),
    async execute(_toolCallId, params) {
      const reply = await request({ type: "readPane", paneID: params.paneID });
      const lines = reply.lines ?? [];
      return text(lines.length === 0 ? "(pane is empty)" : lines.join("\n"));
    },
  });

  pi.registerTool({
    name: "pane_focus",
    label: "Focus Pane",
    description: "Focus a pane in the Shepherd window, moving the user's keyboard there.",
    promptSnippet: "Focus one of your Shepherd panes for the user",
    promptGuidelines: [
      "Use pane_focus sparingly: it moves the user's keyboard focus away from what they were doing.",
    ],
    parameters: Type.Object({
      paneID: Type.String({ description: "Pane id from pane_open or pane_list" }),
    }),
    async execute(_toolCallId, params) {
      await request({ type: "focusPane", paneID: params.paneID });
      return text(`focused pane ${params.paneID}`);
    },
  });

  pi.registerTool({
    name: "pane_close",
    label: "Close Pane",
    description:
      "Close a pane you opened, terminating its process. You cannot close your own pi pane.",
    promptSnippet: "Close one of the Shepherd panes you opened",
    parameters: Type.Object({
      paneID: Type.String({ description: "Pane id from pane_open or pane_list" }),
    }),
    async execute(_toolCallId, params) {
      await request({ type: "closePane", paneID: params.paneID });
      return text(`closed pane ${params.paneID}`);
    },
  });

  // A watch agent must do the watching itself — never breed further
  // watchers. Automation agents get panes + notify but no automation_* tools.
  const isAutomationAgent = process.env.SHEPHERD_AUTOMATION === "1";

  // ---- peer threads --------------------------------------------------------

  pi.registerTool({
    name: "agent_list",
    label: "List Agent Threads",
    description:
      "List every agent thread in Shepherd: id, name, status (working/blocked/idle/done), " +
      "and working directory. Use the ids with agent_send.",
    promptSnippet: "List the other agent threads in Shepherd",
    parameters: Type.Object({}),
    async execute() {
      const reply = await request({ type: "listAgents" });
      const rows = reply.agents ?? [];
      if (rows.length === 0) return text("no agents");
      return text(rows.map((a) =>
        `${a.id}  ${a.name}  [${a.status}]${a.isSelf ? "  (you)" : ""}  ${a.cwd}`
      ).join("\n"));
    },
  });

  pi.registerTool({
    name: "agent_send",
    label: "Message Agent Thread",
    description:
      "Send a message to another agent thread's prompt, exactly as if the user typed it " +
      "there (queued if that agent is mid-turn). The message arrives framed with your " +
      "name. Send information or requests — do not converse: never reply to a mere " +
      "acknowledgment, and treat incoming [from: …] messages as FYI unless they ask for " +
      "action.",
    promptSnippet: "Message another Shepherd agent thread",
    parameters: Type.Object({
      agentID: Type.String({ description: "Target agent id from agent_list" }),
      text: Type.String({ description: "The message to deliver" }),
    }),
    async execute(_toolCallId, params) {
      await request({ type: "sendToAgent", targetAgentID: params.agentID, text: params.text });
      return text(`follow-up dispatch requested for agent ${params.agentID}; acceptance and consumption are not confirmed`);
    },
  });

  pi.registerTool({
    name: "agent_read",
    label: "Read Agent Thread",
    description: "Read finalized visible messages on a live agent's current branch, not streaming text. Thinking, images, hidden entries, and tool arguments are omitted. Returns entry IDs, nextCursor and truncation flags. Defaults to the latest 20 entries; after reads forward. Per-entry text is capped at 4000 characters, total at 48 KiB. A cursor from another branch is an error.",
    parameters: Type.Object({
      agentID: Type.String(),
      after: Type.Optional(Type.String({ description: "Entry ID cursor from this branch, exclusive" })),
      limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 100 })),
    }),
    async execute(_id, params, signal) {
      const reply = await request({ type: "coordinateAgent", targetAgentID: params.agentID,
        request: { operation: "read", after: params.after, limit: params.limit } }, signal);
      return text(reply.result?.text ?? "no messages");
    },
  });

  pi.registerTool({
    name: "agent_steer",
    label: "Steer Agent Thread",
    description: "Request steering dispatch to another live agent via pi.sendUserMessage deliverAs steer. Queues during a turn or starts an idle agent. Reports requested, not accepted or consumed. Cannot target yourself.",
    parameters: Type.Object({ agentID: Type.String(), text: Type.String({ minLength: 1, maxLength: 32768 }) }),
    async execute(_id, params, signal) {
      const reply = await request({ type: "coordinateAgent", targetAgentID: params.agentID,
        request: { operation: "steer", text: params.text } }, signal);
      return text(reply.result?.text ?? "steering dispatch requested");
    },
  });

  pi.registerTool({
    name: "agent_interrupt",
    label: "Interrupt Agent Thread",
    description: "Request best-effort current-turn cancellation on another live agent. Does not confirm it stopped; tools must cooperate. Pi TUI moves queued messages to the editor and does not cancel retries or compaction. Cannot target yourself.",
    parameters: Type.Object({ agentID: Type.String() }),
    async execute(_id, params, signal) {
      const reply = await request({ type: "coordinateAgent", targetAgentID: params.agentID,
        request: { operation: "interrupt" } }, signal);
      return text(reply.result?.text ?? "cancellation requested");
    },
  });

  pi.registerTool({
    name: "agent_wait",
    label: "Wait for Agent Activity",
    description: "Poll another live agent until ctx.isIdle and no pending messages. Only current activity has settled, not proof a sent task succeeded or was consumed. Times out or fails on disconnection/session change. Cancellable; cannot wait for yourself.",
    parameters: Type.Object({ agentID: Type.String(),
      timeoutSeconds: Type.Optional(Type.Integer({ minimum: 1, maximum: 120 })) }),
    async execute(_id, params, signal) {
      if (params.agentID === agentID) throw new Error("cannot wait for yourself");
      const deadline = Date.now() + (params.timeoutSeconds ?? 30) * 1000;
      const initialConnectionLosses = connectionLosses;
      let sessionID;
      let connectionID;
      while (Date.now() < deadline) {
        if (connectionLosses !== initialConnectionLosses) throw new Error("caller disconnected while waiting");
        const reply = await request({ type: "coordinateAgent", targetAgentID: params.agentID,
          request: { operation: "status" } }, signal, Math.min(6_000, deadline - Date.now()));
        if (connectionLosses !== initialConnectionLosses) throw new Error("caller disconnected while waiting");
        if (sessionID && sessionID !== reply.result?.sessionID) throw new Error("target session changed while waiting");
        if (connectionID && connectionID !== reply.result?.connectionID) throw new Error("target connection changed while waiting");
        sessionID = reply.result?.sessionID;
        connectionID = reply.result?.connectionID;
        if (reply.result?.idle === true) return text("current activity settled; this does not confirm any sent task succeeded or was consumed");
        await new Promise<void>((resolve, reject) => {
          const abort = () => { clearTimeout(timer); reject(new Error("wait cancelled")); };
          const timer = setTimeout(() => { signal?.removeEventListener("abort", abort); resolve(); }, Math.min(250, Math.max(0, deadline - Date.now())));
          timer.unref?.();
          if (signal?.aborted) abort();
          else signal?.addEventListener("abort", abort, { once: true });
        });
      }
      throw new Error("wait timed out; current activity has not settled");
    },
  });

  pi.registerTool({
    name: "agent_delete",
    label: "Request Agent Deletion",
    description: "Ask the real user in Shepherd's native confirmation to delete another agent and terminate all its auxiliary processes. No agent-supplied approval is accepted. Cancel or a 120-second confirmation timeout keeps it intact. Keeps worktrees and branches. Cannot delete yourself.",
    parameters: Type.Object({ agentID: Type.String() }),
    async execute(_id, params, signal) {
      const reply = await request({ type: "coordinateAgent", targetAgentID: params.agentID,
        request: { operation: "delete" } }, signal, 125_000);
      return text(reply.result?.text ?? "deletion requested");
    },
  });

  pi.registerTool({
    name: "agent_spawn",
    label: "Spawn Agent Thread",
    description:
      "Start a new top-level agent thread in Shepherd with an opening prompt, visible in " +
      "the sidebar like any user-created agent. Returns the new agent's id — use " +
      "agent_send to follow up, and ask it to agent_send you back when it should report. " +
      "For self-contained work that should not outlive your thread, prefer your own " +
      "subagents instead.",
    promptSnippet: "Spawn a new Shepherd agent thread",
    parameters: Type.Object({
      cwd: Type.String({ description: "Absolute working directory for the new thread" }),
      prompt: Type.String({ description: "Opening prompt — the task, context, and how to report back" }),
    }),
    async execute(_toolCallId, params) {
      const reply = await request({ type: "spawnAgent", cwd: params.cwd, prompt: params.prompt });
      const spawned = reply.agents?.[0];
      if (!spawned) return text("spawned agent thread");
      return text(`spawned agent ${spawned.id} (${spawned.name}) in ${spawned.cwd}`);
    },
  });

  if (!isAutomationAgent) pi.registerTool({
    name: "automation_create",
    label: "Create Automation",
    description:
      "Create a Shepherd automation: a saved watch task run by a dedicated agent. The prompt " +
      "should tell that agent what to poll (exact commands), how often (a single bash loop " +
      "with sleep between checks), the exact success/failure conditions, and to call its " +
      "notify tool then stop when a condition is met. The watch agent does the watching " +
      "itself — its prompt must never instruct it to create further automations. Enabled " +
      "automations restart when Shepherd relaunches.",
    promptSnippet: "Create a Shepherd automation (a saved watch task)",
    parameters: Type.Object({
      name: Type.String({ description: "Short sidebar title, e.g. 'pr-watch #4821'" }),
      prompt: Type.String({ description: "Full instructions for the watch agent" }),
      cwd: Type.String({ description: "Absolute working directory for the watch agent" }),
      enabled: Type.Optional(
        Type.Boolean({ description: "Restart the watch when Shepherd relaunches (default true)" }),
      ),
      start: Type.Optional(
        Type.Boolean({ description: "Start the watch agent immediately (default true)" }),
      ),
    }),
    async execute(_toolCallId, params) {
      await request({
        type: "createAutomation",
        name: params.name,
        prompt: params.prompt,
        cwd: params.cwd,
        enabled: params.enabled !== false,
        start: params.start !== false,
      });
      return text(`created automation: ${params.name}`);
    },
  });

  if (!isAutomationAgent) pi.registerTool({
    name: "automation_list",
    label: "List Automations",
    description:
      "List the user's Shepherd automations: id, name, cwd, enabled, and run state " +
      "(the watch agent's status, or stopped).",
    promptSnippet: "List Shepherd automations",
    parameters: Type.Object({}),
    async execute() {
      const reply = await request({ type: "listAutomations" });
      const rows = reply.automations ?? [];
      if (rows.length === 0) return text("no automations");
      return text(rows.map((a) =>
        `${a.id}  ${a.name}  [${a.agentStatus ?? "stopped"}${a.enabled ? "" : ", disabled"}]  ${a.cwd}`
      ).join("\n"));
    },
  });

  if (!isAutomationAgent) pi.registerTool({
    name: "automation_update",
    label: "Update Automation",
    description:
      "Update a Shepherd automation's name, prompt, cwd, or enabled flag. Omitted fields " +
      "keep their value. A running watch keeps its old prompt until restarted.",
    promptSnippet: "Update a Shepherd automation",
    parameters: Type.Object({
      automationID: Type.String({ description: "Automation id from automation_list" }),
      name: Type.Optional(Type.String()),
      prompt: Type.Optional(Type.String()),
      cwd: Type.Optional(Type.String()),
      enabled: Type.Optional(Type.Boolean()),
    }),
    async execute(_toolCallId, params) {
      await request({
        type: "updateAutomation",
        automationID: params.automationID,
        name: params.name,
        prompt: params.prompt,
        cwd: params.cwd,
        enabled: params.enabled,
      });
      return text(`updated automation ${params.automationID}`);
    },
  });

  if (!isAutomationAgent) pi.registerTool({
    name: "automation_delete",
    label: "Delete Automation",
    description:
      "Delete a Shepherd automation and stop its watch agent if running.",
    promptSnippet: "Delete a Shepherd automation",
    parameters: Type.Object({
      automationID: Type.String({ description: "Automation id from automation_list" }),
    }),
    async execute(_toolCallId, params) {
      await request({ type: "deleteAutomation", automationID: params.automationID });
      return text(`deleted automation ${params.automationID}`);
    },
  });

  if (!isAutomationAgent) pi.registerTool({
    name: "automation_start",
    label: "Start Automation",
    description: "Start a stopped Shepherd automation's watch agent.",
    promptSnippet: "Start a Shepherd automation",
    parameters: Type.Object({
      automationID: Type.String({ description: "Automation id from automation_list" }),
    }),
    async execute(_toolCallId, params) {
      await request({ type: "startAutomation", automationID: params.automationID });
      return text(`started automation ${params.automationID}`);
    },
  });

  if (!isAutomationAgent) pi.registerTool({
    name: "automation_stop",
    label: "Stop Automation",
    description:
      "Stop a running Shepherd automation's watch agent. The automation stays saved.",
    promptSnippet: "Stop a Shepherd automation",
    parameters: Type.Object({
      automationID: Type.String({ description: "Automation id from automation_list" }),
    }),
    async execute(_toolCallId, params) {
      await request({ type: "stopAutomation", automationID: params.automationID });
      return text(`stopped automation ${params.automationID}`);
    },
  });

  pi.registerTool({
    name: "notify",
    label: "Notify User",
    description:
      "Send the user a system notification through Shepherd. Use when something they asked to " +
      "be told about has happened — a condition met, a watched process finished, a result ready.",
    promptSnippet: "Send the user a system notification",
    parameters: Type.Object({
      title: Type.String({ description: "Notification title" }),
      body: Type.Optional(Type.String({ description: "Notification body text" })),
    }),
    async execute(_toolCallId, params) {
      // Fire-and-forget: no reply from Shepherd, like status reports.
      const s = await connect();
      s.write(
        JSON.stringify({ type: "notify", agentID, title: params.title, body: params.body ?? "" }) + "\n",
      );
      return text(`notified: ${params.title}`);
    },
  });

  // Connect eagerly so pushes can reach this agent before it ever uses a
  // pane tool. Failures are fine — request() reconnects on demand.
  for (const event of ["session_start", "session_switch", "session_fork", "session_tree"]) {
    pi.on(event, (_event, ctx) => {
      liveContext = ctx;
      connect().catch(() => {});
    });
  }

  pi.on("session_shutdown", () => {
    liveContext = undefined;
    try {
      socket?.end();
    } catch {
      // Swallow; the process is going away.
    }
    socket = undefined;
  });
}
