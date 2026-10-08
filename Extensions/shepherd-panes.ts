// @ts-nocheck -- loaded by pi/jiti; this project intentionally has no Node TS workspace.
// Shepherd's terminal and agent tools: lets an agent drive its own workspace — open terminals
// under its thread, run commands in them, read what they printed, and close them — and reach
// other agent threads and automations. The agent's own thread is not a terminal: it is never
// listed, and nothing here can type into it or close it. Wire fields keep their older names
// (panes, paneID). Inert unless Shepherd's env is present.
import * as net from "node:net";
import { randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const REQUEST_TIMEOUT_MS = 15_000;
// A call that touches another thread may wait for the user's approval (up to 120 s on the host).
const APPROVAL_TIMEOUT_MS = 130_000;

interface Reply {
  type: string;
  id: number;
  code?: string;
  message?: string;
  panes?: TerminalInfo[];
  pane?: TerminalInfo;
  paneID?: string;
  lines?: string[];
  automations?: AutomationInfo[];
  agents?: AgentPeerInfo[];
  text?: string;
  delivery?: "task" | "report";
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

interface TerminalInfo {
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
                      result = { text: "current-turn cancellation requested, not confirmed stopped; tools must cooperate. A pending retry or compaction is cancelled too; queued messages stay queued." };
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
                try {
                  if (reply.delivery === "report") {
                    // Pi defers this safely past in-flight tool results, without another turn.
                    pi.sendMessage({ customType: "shepherd-peer-report", content: reply.text, display: false },
                      { triggerTurn: false });
                  } else if (reply.delivery === undefined || reply.delivery === "task") {
                    pi.sendUserMessage(reply.text, { deliverAs: "followUp" });
                  }
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

  function describe(terminal: TerminalInfo): string {
    const tags = [
      terminal.isFocused ? "focused" : undefined,
      terminal.isAlive ? undefined : "no process",
    ].filter(Boolean);
    return `${terminal.id}  ${terminal.cwd}${tags.length > 0 ? `  [${tags.join(", ")}]` : ""}`;
  }

  // ---- terminal tools ------------------------------------------------------
  // A terminal is a tab under the agent's thread, named by an opaque terminal id. The thread
  // itself is never one: it is left out of the list, and Shepherd refuses it everywhere else.

  pi.registerTool({
    name: "terminal_list",
    label: "List Terminals",
    description:
      "List the terminals under your Shepherd thread: each terminal's id, working directory, and " +
      "whether it is focused or has a running process.",
    promptSnippet: "List the terminals under your Shepherd thread",
    parameters: Type.Object({}),
    async execute() {
      const reply = await request({ type: "listPanes" });
      const terminals = (reply.panes ?? []).filter((terminal) => !terminal.isAgentPane);
      return text(terminals.length === 0 ? "no terminals" : terminals.map(describe).join("\n"));
    },
  });

  pi.registerTool({
    name: "terminal_open",
    label: "Open Terminal",
    description:
      "Open a new terminal under your Shepherd thread, as a tab of its own, without changing the " +
      "user's focus, and optionally run a command in it. Returns the new terminal's id for " +
      "terminal_run, terminal_read, terminal_focus, and terminal_close.",
    promptSnippet: "Open a terminal under you and optionally run a command in it",
    promptGuidelines: [
      "Use terminal_open for long-running processes the user should see — dev servers, log tails, " +
      "test watchers — and use bash for one-off commands whose output you just need to read.",
    ],
    parameters: Type.Object({
      command: Type.Optional(
        Type.String({ description: "Shell command to run in the new terminal once it starts" }),
      ),
      cwd: Type.Optional(
        Type.String({ description: "Working directory; defaults to your thread's directory" }),
      ),
    }),
    async execute(_toolCallId, params) {
      const reply = await request({
        type: "openPane",
        cwd: params.cwd,
        command: params.command,
      });
      const terminal = reply.pane;
      if (!terminal) return text("terminal opened");
      return text(
        `opened terminal ${terminal.id} in ${terminal.cwd}` +
        (params.command ? `\nrunning: ${params.command}` : "") +
        (terminal.isAlive ? "" : "\nwarning: the terminal has no running process yet"),
      );
    },
  });

  pi.registerTool({
    name: "terminal_run",
    label: "Run in Terminal",
    description:
      "Type text into one of your terminals. By default it is submitted as a command (newline " +
      "appended); pass submit:false to type without running, e.g. to answer a prompt.",
    promptSnippet: "Type a command into one of your Shepherd terminals",
    parameters: Type.Object({
      terminalID: Type.String({ description: "Terminal id from terminal_open or terminal_list" }),
      text: Type.String({ description: "Text to type into the terminal" }),
      submit: Type.Optional(
        Type.Boolean({ description: "Append a newline so the text runs (default true)" }),
      ),
    }),
    async execute(_toolCallId, params) {
      await request({
        type: "sendPaneInput",
        paneID: params.terminalID,
        text: params.text,
        submit: params.submit !== false,
      });
      return text(`sent to terminal ${params.terminalID}`);
    },
  });

  pi.registerTool({
    name: "terminal_read",
    label: "Read Terminal",
    description:
      "Read what is currently on a terminal's screen, as plain text lines. This is the visible " +
      "screen rather than full scrollback, so read soon after running something.",
    promptSnippet: "Read the current screen of one of your Shepherd terminals",
    parameters: Type.Object({
      terminalID: Type.String({ description: "Terminal id from terminal_open or terminal_list" }),
    }),
    async execute(_toolCallId, params) {
      const reply = await request({ type: "readPane", paneID: params.terminalID });
      const lines = reply.lines ?? [];
      return text(lines.length === 0 ? "(terminal is empty)" : lines.join("\n"));
    },
  });

  pi.registerTool({
    name: "terminal_focus",
    label: "Focus Terminal",
    description:
      "Show a terminal in the Shepherd window and move the user's keyboard there.",
    promptSnippet: "Focus one of your Shepherd terminals for the user",
    promptGuidelines: [
      "Use terminal_focus sparingly: it moves the user's keyboard focus away from what they were doing.",
    ],
    parameters: Type.Object({
      terminalID: Type.String({ description: "Terminal id from terminal_open or terminal_list" }),
    }),
    async execute(_toolCallId, params) {
      await request({ type: "focusPane", paneID: params.terminalID });
      return text(`focused terminal ${params.terminalID}`);
    },
  });

  pi.registerTool({
    name: "terminal_close",
    label: "Close Terminal",
    description:
      "Close one of your terminals, terminating its process. Closing the last one hides the " +
      "terminal area.",
    promptSnippet: "Close one of the Shepherd terminals you opened",
    parameters: Type.Object({
      terminalID: Type.String({ description: "Terminal id from terminal_open or terminal_list" }),
    }),
    async execute(_toolCallId, params) {
      await request({ type: "closePane", paneID: params.terminalID });
      return text(`closed terminal ${params.terminalID}`);
    },
  });

  // A watch agent must do the watching itself — never breed further
  // watchers. Automation agents get the terminal tools + notify but no automation_* tools.
  const isAutomationAgent = process.env.SHEPHERD_AUTOMATION === "1";

  // Deferred tools (docs/context-budget.md): with SHEPHERD_DEFER_TOOLS=1 pi leaves a deferred tool out of every request until
  // the model loads it with tool_search, and the status extension keeps tool_search reachable and says in the prompt that
  // these exist. A deferred tool has no promptSnippet: that line would only repeat the search result, and loading the tool
  // would send the whole tool list again. A watch agent's agent_send stays direct: it is how the run reports.
  const DEFER = process.env.SHEPHERD_DEFER_TOOLS === "1";
  const deferPeers = DEFER && !isAutomationAgent;
  // The description is the clause of the one prompt line that says these tools exist; the instructions are words tool_search matches.
  const PEERS = {
    name: "shepherd_agents",
    description: "other agent threads, only when the user explicitly asks you to",
    instructions:
      "Other agent threads in Shepherd: list the threads, send a message to, steer, interrupt, read, wait for, " +
      "start or delete another thread.",
  };
  const AUTOMATIONS = {
    name: "shepherd_automations",
    description: "Shepherd automations, the saved watch tasks",
    instructions:
      "Shepherd automations: saved watch tasks that monitor something and notify the user. " +
      "Create, list, update, delete, start or stop an automation.",
  };
  const later = (on: boolean, namespace: { name: string; description: string; instructions: string }) =>
    on ? { exposure: "deferred" as const, namespace } : {};
  const line = (on: boolean, snippet: string) => (on ? undefined : snippet);

  // Project history is not sidebar registration. These requests go through the live app.
  const PROJECTS = {
    name: "shepherd_projects",
    description: "register existing local project directories and refresh Shepherd's project UI",
    instructions: "Use project_register, project_add_child or project_refresh when the user requests project registration, child folder creation, or refresh. Never edit projects.json or state.json to register a project.",
  };
  if (!isAutomationAgent) pi.registerTool({
    name: "project_register",
    label: "Register Project",
    description: "Register an existing local directory in Shepherd's live sidebar with a display name, when requested by the user. Does not create files, start threads, select a project, or grant project trust. Absolute paths and ~/ paths are accepted. Duplicate canonical paths return the existing registration unchanged. Returns JSON {space, created}; space contains the canonical id, name and path. A successful reply follows live UI adoption. Requires a Shepherd build with project tools.",
    ...later(DEFER, PROJECTS),
    promptSnippet: line(DEFER, "Register an existing project directory in Shepherd's live sidebar"),
    parameters: Type.Object({
      path: Type.String({ description: "Existing readable directory on this Mac, absolute or ~/" }),
      name: Type.String({ description: "Display name, 1–256 characters, no control characters" }),
    }),
    async execute(_id, args) {
      const reply = await request({ type: "registerProject", path: args.path, name: args.name });
      return text(JSON.stringify({ space: reply.space, created: reply.created }));
    },
  });
  if (!isAutomationAgent) pi.registerTool({
    name: "project_add_child",
    label: "Add Child Project",
    description: "When requested by the user, create an empty direct child folder or register an existing descendant of a local parent project. Set create:true only to create a new folder, false for an existing folder. Canonical paths must stay inside parentPath. Never overwrites a folder or link, initializes Git, or starts a thread. Returns JSON {space, created}; created means a new registration. Creation errors leave existing files untouched. If registration fails after creation, the folder remains; retry with create:false. Requires a Shepherd build with child project tools.",
    ...later(DEFER, PROJECTS),
    promptSnippet: line(DEFER, "Create or register a child project folder inside a parent project"),
    parameters: Type.Object({
      parentPath: Type.String({ description: "Existing parent project directory, absolute or ~/" }),
      path: Type.String({ description: "Child directory, absolute or ~/; creation must be directly inside parentPath" }),
      name: Type.String({ description: "Display name, 1–256 characters, no control characters" }),
      create: Type.Boolean({ description: "true: create a new empty folder; false: register an existing folder" }),
    }),
    async execute(_id, args) {
      const reply = await request({ type: "addChildProject", parentPath: args.parentPath, path: args.path, name: args.name, create: args.create });
      return text(JSON.stringify({ space: reply.space, created: reply.created }));
    },
  });
  if (!isAutomationAgent) pi.registerTool({
    name: "project_refresh",
    label: "Refresh Projects",
    description: "Refresh Shepherd's live sidebar from registered spaces and reload the Projects settings list without restarting. Does not import cached projects.json entries into the sidebar, reload state.json, discard editor drafts, select projects, or register directories. Returns JSON {refreshed:true} after UI adoption and list reload. Requires a Shepherd build with project tools.",
    ...later(DEFER, PROJECTS),
    promptSnippet: line(DEFER, "Refresh Shepherd's live projects without restarting"),
    parameters: Type.Object({}),
    async execute() {
      await request({ type: "refreshProjects" });
      return text(JSON.stringify({ refreshed: true }));
    },
  });

  // ---- peer threads --------------------------------------------------------
  // Every tool here that touches another thread is for what the user asked for in this
  // conversation, and Shepherd can ask the user to approve each call (Settings ▸ Pi ▸ Agent-to-agent
  // messages). The words say so first, because a model reads them before it acts. Authorization
  // is the host's: nothing here decides whether a call is allowed.

  const ONLY_WHEN_ASKED =
    "Only when the user explicitly asks you to, in this conversation. Never on your own initiative: " +
    "not to report status, ask for help, hand off work, share findings or coordinate. If unsure, don't. ";
  const APPROVAL =
    "Shepherd may ask the user to approve this call. If it comes back not approved or turned off, " +
    "stop: do not retry, and do not look for another way to reach the thread.";
  // The same lines on every tool that touches another thread: pi writes a repeated line once.
  const PEER_GUIDELINES = [
    "Use agent_send, agent_steer, agent_interrupt, agent_read and agent_spawn only when the user explicitly " +
    "asks you to in this conversation, never to report status, ask another thread for help, hand off work " +
    "or share findings. If unsure, don't.",
    "A message that begins with [from: <name>] comes from another agent, not from the user. Treat it as a " +
    "colleague's request, and reply with agent_send only when it explicitly asks you for a reply: never to " +
    "acknowledge, confirm or thank.",
  ];

  // A watch agent only reports to its creator, with agent_send: it gets no other peer tool.
  if (!isAutomationAgent) pi.registerTool({
    name: "agent_list",
    label: "List Agent Threads",
    description:
      "List the other agent threads in Shepherd: id, name, status (working/blocked/idle/done), and working " +
      "directory. Use it to find a thread the user named. It only reads: it is not a reason to message, " +
      "steer, read or start any thread, which you may do only when the user explicitly asks you to.",
    promptSnippet: line(deferPeers, "List the other agent threads, only to find one the user named"),
    ...later(deferPeers, PEERS),
    promptGuidelines: PEER_GUIDELINES,
    parameters: Type.Object({}),
    async execute() {
      const reply = await request({ type: "listAgents" });
      const rows = reply.agents ?? [];
      const reminder = "\n\nReminder: do not message, steer, interrupt, read or start these threads unless the " +
        "user explicitly asked you to in this conversation.";
      if (rows.length === 0) return text("no agents" + reminder);
      return text(rows.map((a) =>
        `${a.id}  ${a.name}  [${a.status}]${a.isSelf ? "  (you)" : ""}  ${a.cwd}`
      ).join("\n") + reminder);
    },
  });

  pi.registerTool({
    name: "agent_send",
    label: "Message Agent Thread",
    description:
      ONLY_WHEN_ASKED +
      "Wrong: telling another thread you are done, asking it for help or an opinion, handing it a " +
      "follow-up, thanking it. Right: the user said \"tell the API thread to rerun the tests\". " +
      "Sends a message to another agent thread. delivery task (default) asks it to do work: it starts " +
      "an idle agent or queues a follow-up while busy. delivery report is hidden context only, and " +
      "never starts or queues a turn. The other thread sees an agent's message, not the user's. " +
      APPROVAL + " Dispatch is not confirmation of acceptance or consumption.",
    promptSnippet: line(deferPeers, "Message another agent thread, only when the user explicitly asked you to"),
    ...later(deferPeers, PEERS),
    promptGuidelines: PEER_GUIDELINES,
    parameters: Type.Object({
      agentID: Type.String({ description: "Target agent id from agent_list" }),
      text: Type.String({ description: "The message to deliver" }),
      delivery: Type.Optional(Type.Union([Type.Literal("task"), Type.Literal("report")],
        { description: "task (default): start/queue work; report: context only, no new turn" })),
    }),
    async execute(_toolCallId, params, signal) {
      const delivery = params.delivery ?? "task";
      await request({ type: "sendToAgent", targetAgentID: params.agentID, text: params.text, delivery },
        signal, APPROVAL_TIMEOUT_MS);
      return text(`${delivery} dispatch requested for agent ${params.agentID}; acceptance and consumption are not confirmed`);
    },
  });

  if (!isAutomationAgent) pi.registerTool({
    name: "agent_read",
    label: "Read Agent Thread",
    description:
      ONLY_WHEN_ASKED +
      "Wrong: looking at another thread to see what it is doing or to find context. Right: the user said " +
      "\"see what the review thread concluded\". Reads finalized visible messages on a live agent's current " +
      "branch, not streaming text. Thinking, images, hidden entries, and tool arguments are omitted. Returns " +
      "entry IDs, nextCursor and truncation flags. Defaults to the latest 20 entries; after reads forward. " +
      "Per-entry text is capped at 4000 characters, total at 48 KiB. A cursor from another branch is an " +
      "error. " + APPROVAL,
    promptGuidelines: PEER_GUIDELINES,
    ...later(deferPeers, PEERS),
    parameters: Type.Object({
      agentID: Type.String(),
      after: Type.Optional(Type.String({ description: "Entry ID cursor from this branch, exclusive" })),
      limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 100 })),
    }),
    async execute(_id, params, signal) {
      const reply = await request({ type: "coordinateAgent", targetAgentID: params.agentID,
        request: { operation: "read", after: params.after, limit: params.limit } }, signal, APPROVAL_TIMEOUT_MS);
      return text(reply.result?.text ?? "no messages");
    },
  });

  if (!isAutomationAgent) pi.registerTool({
    name: "agent_steer",
    label: "Steer Agent Thread",
    description:
      ONLY_WHEN_ASKED +
      "Wrong: redirecting another thread because you think it is off track. Right: the user said \"tell " +
      "the worker thread to stop using the old API now\". Steers another live agent: the message lands at " +
      "its next step, or starts an idle one. Reports requested, not accepted or consumed. Cannot target " +
      "yourself. " + APPROVAL,
    promptGuidelines: PEER_GUIDELINES,
    ...later(deferPeers, PEERS),
    parameters: Type.Object({ agentID: Type.String(), text: Type.String({ minLength: 1, maxLength: 32768 }) }),
    async execute(_id, params, signal) {
      const reply = await request({ type: "coordinateAgent", targetAgentID: params.agentID,
        request: { operation: "steer", text: params.text } }, signal, APPROVAL_TIMEOUT_MS);
      return text(reply.result?.text ?? "steering dispatch requested");
    },
  });

  if (!isAutomationAgent) pi.registerTool({
    name: "agent_interrupt",
    label: "Interrupt Agent Thread",
    description:
      ONLY_WHEN_ASKED +
      "Wrong: stopping another thread because it seems stuck or slow. Right: the user said \"stop the " +
      "migration thread\". Best-effort cancellation of another live agent's current turn. Does not confirm " +
      "it stopped; tools must cooperate. Also cancels a pending retry or compaction; messages already " +
      "queued stay queued. Cannot target yourself. " + APPROVAL,
    promptGuidelines: PEER_GUIDELINES,
    ...later(deferPeers, PEERS),
    parameters: Type.Object({ agentID: Type.String() }),
    async execute(_id, params, signal) {
      const reply = await request({ type: "coordinateAgent", targetAgentID: params.agentID,
        request: { operation: "interrupt" } }, signal, APPROVAL_TIMEOUT_MS);
      return text(reply.result?.text ?? "cancellation requested");
    },
  });

  if (!isAutomationAgent) pi.registerTool({
    name: "agent_wait",
    label: "Wait for Agent Activity",
    description:
      "Only after the user asked you to message or steer another thread, to see whether it has finished; " +
      "never to keep watch over threads on your own. Polls another live agent until ctx.isIdle and no pending " +
      "messages. Only current activity has settled, not proof a sent task succeeded or was consumed. Times " +
      "out or fails on disconnection/session change. Cancellable; cannot wait for yourself.",
    ...later(deferPeers, PEERS),
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

  if (!isAutomationAgent) pi.registerTool({
    name: "agent_delete",
    label: "Request Agent Deletion",
    description:
      "Only when the user explicitly asks you to delete another agent. Never on your own initiative, " +
      "never to tidy up. Asks the real user in Shepherd's native confirmation to delete another agent and " +
      "terminate all its auxiliary processes. No agent-supplied approval is accepted. Cancel or a 120-second " +
      "confirmation timeout keeps it intact. Keeps worktrees and branches. Cannot delete yourself.",
    ...later(deferPeers, PEERS),
    parameters: Type.Object({ agentID: Type.String() }),
    async execute(_id, params, signal) {
      const reply = await request({ type: "coordinateAgent", targetAgentID: params.agentID,
        request: { operation: "delete" } }, signal, 125_000);
      return text(reply.result?.text ?? "deletion requested");
    },
  });

  if (!isAutomationAgent) pi.registerTool({
    name: "agent_spawn",
    label: "Spawn Agent Thread",
    description:
      "Only when the user explicitly asks you to start a new agent thread. Never on your own initiative, " +
      "and never to offload, parallelize or delegate work: for that, use your own subagents. Wrong: " +
      "starting a thread to run tests or look into a side question. Right: the user said \"open a thread " +
      "in ~/src/api and have it fix the build\". Starts a new top-level agent thread in Shepherd with an " +
      "opening prompt, visible in the sidebar like any user-created agent. Returns the new agent's id. " +
      APPROVAL,
    promptSnippet: line(deferPeers, "Start a new agent thread, only when the user explicitly asked you to"),
    ...later(deferPeers, PEERS),
    promptGuidelines: PEER_GUIDELINES,
    parameters: Type.Object({
      cwd: Type.String({ description: "Absolute working directory for the new thread" }),
      prompt: Type.String({ description: "Opening prompt: the task and the context it needs. Don't tell it to message you back unless the user asked for that." }),
    }),
    async execute(_toolCallId, params, signal) {
      const reply = await request({ type: "spawnAgent", cwd: params.cwd, prompt: params.prompt },
        signal, APPROVAL_TIMEOUT_MS);
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
      "automations restart when Shepherd relaunches. Set replyToCreator only when the user asked to hear " +
      "the result back in this thread: the watch agent then sends it to your thread with agent_send " +
      "(delivery report), which works only while the user allows agent messages from automations; " +
      "otherwise it just notifies.",
    promptSnippet: line(DEFER, "Create a Shepherd automation (a saved watch task)"),
    ...later(DEFER, AUTOMATIONS),
    parameters: Type.Object({
      name: Type.String({ description: "Short sidebar title, e.g. 'pr-watch #4821'" }),
      prompt: Type.String({ description: "Full instructions for the watch agent" }),
      replyToCreator: Type.Optional(Type.Boolean({ description: "Only when the user asked to hear the result in this thread: asks the watch agent to report completion or failure back to it (default false). Adds instructions, not a guaranteed delivery hook." })),
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
        prompt: params.replyToCreator
          ? `${params.prompt}\n\nCompletion report: Before stopping, on success, failure, or a blocked watch, call agent_send with agentID ${JSON.stringify(agentID)}, delivery "report", and a concise result including relevant links. This is the creator thread, not an agent to find by name. Also call notify. If the creator no longer exists or delivery fails, include that in the notification and stop; do not retry indefinitely or send to another thread. This requests dispatch, not confirmation that the creator read it.`
          : params.prompt,
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
    promptSnippet: line(DEFER, "List Shepherd automations"),
    ...later(DEFER, AUTOMATIONS),
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
    promptSnippet: line(DEFER, "Update a Shepherd automation"),
    ...later(DEFER, AUTOMATIONS),
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
    promptSnippet: line(DEFER, "Delete a Shepherd automation"),
    ...later(DEFER, AUTOMATIONS),
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
    description:
      "Start a Shepherd automation's run. A finished run is replaced by the new one; a run still working or waiting on the user is refused.",
    promptSnippet: line(DEFER, "Start a Shepherd automation"),
    ...later(DEFER, AUTOMATIONS),
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
    promptSnippet: line(DEFER, "Stop a Shepherd automation"),
    ...later(DEFER, AUTOMATIONS),
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

  // What to do with a message from another agent holds for every thread, loaded agent_* tools or not: they bring the
  // rule with them (pi writes a repeated rule once), and until they load this does.
  if (deferPeers) {
    pi.on("before_agent_start", (event) => {
      try {
        const rules = event?.systemPromptOptions?.promptGuidelines;
        if (Array.isArray(rules) && !rules.includes(PEER_GUIDELINES[1])) rules.push(PEER_GUIDELINES[1]);
      } catch {
        // The rule is never worth a failed turn.
      }
    });
  }

  // Connect eagerly so pushes can reach this agent before it ever uses a
  // Shepherd tool. Failures are fine — request() reconnects on demand.
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
