// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd panes extension: lets an agent drive its own workspace — open panes
// beside itself, run commands in them, read what they printed, and close them.
// The agent's own pi pane is off limits (it cannot close or type into itself).
// Inert unless Shepherd's env is present.
import * as net from "node:net";
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
  let buffer = "";
  let nextID = 1;
  const pending = new Map<number, (reply: Reply) => void>();

  function connect(): Promise<net.Socket> {
    if (socket && !socket.destroyed) return Promise.resolve(socket);
    return new Promise((resolve, reject) => {
      const s = net.createConnection(socketPath);
      s.setEncoding("utf8");
      s.on("connect", () => {
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
              if (reply.type === "message" && typeof reply.text === "string") {
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
                  pending.delete(reply.id);
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
        socket = undefined;
        reject(error);
      });
      s.on("close", () => {
        socket = undefined;
        // Fail everything still waiting rather than hanging the agent.
        for (const [id, resolver] of pending) {
          pending.delete(id);
          resolver({ type: "error", id, code: "disconnected", message: "Shepherd closed the connection" });
        }
      });
      s.unref();
    });
  }

  // Throws on failure: pi marks a tool errored only when execute throws.
  async function request(payload: Record<string, unknown>): Promise<Reply> {
    const s = await connect();
    const id = nextID++;
    const reply = await new Promise<Reply>((resolve) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        resolve({ type: "error", id, code: "timeout", message: "Shepherd did not reply in time" });
      }, REQUEST_TIMEOUT_MS);
      timer.unref?.();

      pending.set(id, (received) => {
        clearTimeout(timer);
        resolve(received);
      });
      s.write(JSON.stringify({ ...payload, id, agentID }) + "\n");
    });

    if (reply.type === "error") {
      throw new Error(
        `${reply.message ?? "pane request failed"}${reply.code ? ` (${reply.code})` : ""}`,
      );
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
      return text(`sent to agent ${params.agentID}`);
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
  pi.on("session_start", () => {
    connect().catch(() => {});
  });

  pi.on("session_shutdown", () => {
    try {
      socket?.end();
    } catch {
      // Swallow; the process is going away.
    }
    socket = undefined;
  });
}
