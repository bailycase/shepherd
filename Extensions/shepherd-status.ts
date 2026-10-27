// Shepherd status extension: reports pi lifecycle status for one agent to the
// Shepherd extension socket as newline-delimited JSON setAgentStatus messages.
// Inert unless SHEPHERD_AGENT_ID and SHEPHERD_SOCKET are set. Status reporting
// is best-effort; native codemode failures remain visible as normal tool errors.
import * as net from "node:net";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { createCodemodeExtension, getAgentDir, ProjectTrustStore, SettingsManager, type ExtensionAPI } from "@earendil-works/pi-coding-agent";

type Status = "working" | "blocked" | "idle" | "done";

// Retired synthetic retry command. Old hosts get a visible refusal, never invented input.
export const RETRY_COMMAND = "shepherd-retry";

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

// Shepherd's rarely used tools (the panes, review and browser extensions') are deferred while SHEPHERD_DEFER_TOOLS=1: each is
// registered `deferred` under a `shepherd_*` namespace, and pi sends none of them until the model loads it with tool_search
// (docs/context-budget.md). What keeps them reachable is here, since this extension is in every agent's launch.
const SHEPHERD_NAMESPACE = /^shepherd_/;

export function boundedCodemodeSource(code: string): string {
  const newline = code.indexOf("\n");
  const first = (newline < 0 ? code : code.slice(0, newline)).trimStart();
  const hasOptions = first.startsWith("// @options:");
  const options = hasOptions ? JSON.parse(first.slice("// @options:".length)) : {};
  if (!options || typeof options !== "object" || Array.isArray(options)) throw Error("Codemode options must be an object");
  const timeout = options.timeout_ms ?? 300_000;
  if (!Number.isSafeInteger(timeout) || timeout <= 0) throw Error("Codemode timeout_ms must be a positive integer");
  options.timeout_ms = Math.min(timeout, 300_000);
  const source = hasOptions ? (newline < 0 ? "" : code.slice(newline + 1)) : code;
  return `// @options: ${JSON.stringify(options)}\n${source}`;
}

export default function shepherdStatus(pi: ExtensionAPI) {
  const agentID = process.env.SHEPHERD_AGENT_ID ?? "";
  const socketPath = process.env.SHEPHERD_SOCKET ?? "";
  if (!agentID || !socketPath) return;
  // Read only approved Space resources, never the unapproved branch's extensions or settings.
  pi.on("resources_discover", (_event, ctx) => {
    const owner = process.env.SHEPHERD_RESOURCE_OWNING_SPACE;
    const checkout = process.env.SHEPHERD_RESOURCE_WORKTREE_CWD;
    if (!owner || !checkout || !path.isAbsolute(owner) || !path.isAbsolute(checkout)
        || process.env.SHEPHERD_CHILD === "1" || process.env.SHEPHERD_PROJECT_COORDINATOR === "1") return;
    try {
      const root = fs.realpathSync(owner), here = fs.realpathSync(ctx.cwd), home = fs.realpathSync(os.homedir());
      if (here !== fs.realpathSync(checkout) || here === root || here === home || root === home || root === path.parse(root).root) return;
      const decision = new ProjectTrustStore(getAgentDir()).get(root);
      if (!(decision ?? (SettingsManager.create(root, getAgentDir(), { projectTrusted: false }).getDefaultProjectTrust() === "always"))) return;
      const directories = [".shepherd", ".pi"].map(base => path.join(root, base));
      return { skillPaths: directories.map(base => path.join(base, "skills")),
        promptPaths: directories.map(base => path.join(base, "prompts")) };
    } catch {
      // A missing/revoked Space contributes no resources and never prevents a thread starting.
    }
  });
  const deferTools = process.env.SHEPHERD_DEFER_TOOLS === "1";
  let codemodeEnabled = false;
  // Deferred with the rest (docs/context-budget.md): its definition and pi's script-writing guidelines cost ~875
  // tokens in every request for a tool a minority of turns use; tool_search loads it when a script is the way.
  const CODEMODE = {
    name: "shepherd_codemode",
    description: "codemode, a script that calls several tools at once",
    instructions: "codemode: run a JavaScript script that calls many tools in one step (loops over files, batches of reads or edits).",
  };

  // Use Pi's executor, loadout and discovery unchanged. Its standalone defaults have no
  // deadline and allow calls to other providers, which are not part of Shepherd's tool toggle.
  pi.on("session_start", () => {
    const settings = pi.getSettings().codemode as { enabled?: unknown } | undefined;
    codemodeEnabled = settings?.enabled === true;
    if (!codemodeEnabled) {
      // A hand-edited project may still load the bare built-in. Off wins for this host.
      const active = pi.getActiveTools();
      if (active.includes("codemode")) pi.setActiveTools(active.filter((name) => name !== "codemode"));
      return;
    }
    createCodemodeExtension({ models: false, mode: "on" })({
      ...pi,
      registerTool(tool) {
        pi.registerTool({
          ...tool,
          ...(deferTools ? { exposure: "deferred" as const, namespace: CODEMODE } : {}),
          promptGuidelines: [...(tool.promptGuidelines ?? []), "Shepherd limits each script to 5 minutes and 128 tool calls. Direct classifier and image-model APIs are disabled."],
          async execute(id, input, signal, update, ctx) {
            let calls = 0, remaining = 32 * 1024;
            const outputs = new Map<string, { output: string; outputTruncated: boolean; startedAt: number; timestamp: number }>();
            // The context's tools are non-enumerable getters; spreading it loses them.
            const boundedContext = Object.create(ctx, { executeTool: { async value(...args: Parameters<typeof ctx.executeTool>) {
              if (++calls > 128) throw Error("Shepherd codemode limit reached: 128 tool calls per script");
              const startedAt = Date.now();
              const outcome = await ctx.executeTool(...args);
              // Pi retains call metadata but not output. Save bounded text in display-only details,
              // never model content. Images and other non-text blocks are not copied.
              let output = "", outputTruncated = false;
              let budget = Math.min(8 * 1024, remaining);
              for (const block of outcome.result.content) {
                if (block.type !== "text") { outputTruncated = true; continue; }
                const text = (output ? "\n" : "") + block.text;
                const bytes = Buffer.from(text.slice(0, budget + 1));
                const head = new TextDecoder().decode(bytes.subarray(0, budget), { stream: true });
                output += head;
                const used = Buffer.byteLength(head);
                budget -= used; remaining -= used;
                outputTruncated ||= head.length < text.length;
              }
              outputs.set(outcome.toolCall.id, { output, outputTruncated, startedAt, timestamp: Date.now() });
              return outcome;
            } } });
            const result = await tool.execute(id, { ...input, code: boundedCodemodeSource(input.code) }, signal, update, boundedContext);
            return { ...result, details: { ...result.details,
              calls: result.details.calls.map((call) => ({ ...call, ...outputs.get(call.id) })),
            } };
          },
        });
      },
    });
    // A deferred codemode is activated by tool_search, not here.
    if (!deferTools) pi.setActiveTools([...new Set([...pi.getActiveTools(), "codemode"])]);
  });

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

  const deferredTools = () =>
    pi.getAllTools().filter((tool) => tool.exposure === "deferred" && SHEPHERD_NAMESPACE.test(tool.namespace?.name ?? ""));

  // pi's MCP activates tool_search only for a server on Search, so without this a thread with none could not load a tool. A launch
  // without tool_search at all declares the deferred tools like any other rather than leave them unreachable. And the tools a search
  // loaded stay loaded across a restart: pi 1.0 restores them in some modes and not in the RPC one Shepherd runs (measured), where a
  // thread that opened the browser would lose it at every relaunch. The transcript says what was loaded: the tools that system
  // messages after the first one added (the first is the launch's own set, so a thread from before deferral starts deferred).
  function keepDeferredToolsReachable(ctx?: { sessionManager?: { getBranch?: () => any[] } }) {
    if (!deferTools) return;
    try {
      const deferred = deferredTools();
      if (deferred.length === 0) return;
      let active = pi.getActiveTools();
      if (pi.getAllTools().some((tool) => tool.name === "tool_search")) {
        if (!active.includes("tool_search")) pi.setActiveTools((active = [...active, "tool_search"]));
      } else {
        pi.setActiveTools([...new Set([...active, ...deferred.map((tool) => tool.name)])]);
        return;
      }
      const loaded = new Set<string>();
      let later = false;
      for (const entry of ctx?.sessionManager?.getBranch?.() ?? []) {
        const message = entry?.type === "message" ? entry.message : undefined;
        if (message?.role !== "system") continue;
        if (!later) { later = true; continue; }
        for (const tool of message.toolsRemoved ?? []) loaded.delete(tool?.name);
        for (const tool of message.toolsAdded ?? []) loaded.add(tool?.name);
      }
      const back = deferred.map((tool) => tool.name).filter((name) => loaded.has(name) && !active.includes(name));
      if (back.length > 0) pi.setActiveTools([...active, ...back]);
    } catch {
      // The tools stay deferred; the model can still work without them.
    }
  }

  // One rule line says which of them exist: a deferred tool is in no request, so the model could not otherwise know to look.
  // Without tool_search there is nothing to load them with, and keepDeferredToolsReachable declared them instead.
  function deferredToolsLine(): string | undefined {
    if (!pi.getAllTools().some((tool) => tool.name === "tool_search")) return undefined;
    const families = new Map<string, { names: string[]; description: string }>();
    for (const tool of deferredTools()) {
      const family = families.get(tool.namespace.name) ?? { names: [], description: tool.namespace.description ?? "" };
      family.names.push(tool.name);
      families.set(tool.namespace.name, family);
    }
    if (families.size === 0) return undefined;
    const label = (names: string[]) => {
      const prefix = names[0].split("_")[0];
      return names.length > 1 && names.every((name) => name.startsWith(`${prefix}_`)) ? `${prefix}_*` : names.join(", ");
    };
    const parts = [...families.values()].map((family) => `${label(family.names)} (${family.description})`);
    return `Shepherd tools you load with tool_search when you need them: ${parts.join("; ")}.`;
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

  // Response timing (Shepherd's thread: "Waiting for response", and a reply's Response timing):
  // when each model request left, when its headers came back, and its first stream event, by
  // this process's clock. Only the moment is sent: never the payload, a header or a credential.
  // Dropped while disconnected; the thread then says what it did not measure.
  function sendTiming(seq: number, mark: "sent" | "headers" | "firstEvent" | "message", at = Date.now()) {
    if (!connected || !socket) return;
    try {
      socket.write(JSON.stringify({ type: "responseTiming", agentID, seq, mark, at }) + "\n");
    } catch {
      // Swallow; timing is never worth a failed request.
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

  // Normalize before RPC listeners and persistence see the finalized message. Thinking is
  // not an answer; leave tool calls and other output types (such as images) alone.
  pi.on("message_end", ({ message }) => {
    if (message.role !== "assistant" || !["stop", "length"].includes(message.stopReason)) return;
    if (message.content.some((part) => part.type === "text" ? part.text.trim().length > 0 : part.type !== "thinking")) return;
    return { message: { ...message, stopReason: "error", errorMessage: "The provider returned no answer or tool call. Retry to continue the interrupted turn." } };
  });

  pi.registerCommand(RETRY_COMMAND, {
    description: "Checkpoint recovery requires an updated Shepherd host",
    handler: async (_args, ctx) => {
      try {
        ctx.ui.notify("Use the thread\'s Continue control with a host and engine that support message-free checkpoint recovery. This retired command never resends a user message.", "warning");
      } catch {}
    },
  });

  pi.on("session_start", (_event, ctx) => {
    stopped = false;
    retryDelay = 500;
    pendingWaits.clear();
    connect();
    send("idle");
    offerShortReason();
    keepDeferredToolsReachable(ctx);
    // Fires for startup, /new, /resume, and /reload, so this covers every way
    // the current session can change.
    try {
      sendSession(ctx.sessionManager.getSessionId());
    } catch {
      // Swallow; session tracking must never break the session.
    }
  });

  pi.on("before_agent_start", (event) => {
    offerShortReason();
    if (!deferTools) return;
    try {
      const rules = event?.systemPromptOptions?.promptGuidelines;
      const line = deferredToolsLine();
      if (Array.isArray(rules) && line && !rules.includes(line)) rules.push(line);
    } catch {
      // The line is never worth a failed turn.
    }
  });

  // A search whose best match is a tool of one of these families loads the whole family: the browser's thirteen tools are used
  // together and tool_search loads eight at most, and each load is a change to the request that the provider's prompt cache can
  // notice, so one is better than two. Only the best match counts (the loaded list is in rank order): a search for an MCP tool also
  // loads the weaker matches, such as automation_create for "create an issue", and those do not bring their families.
  if (deferTools) pi.on("tool_result", (event) => {
    if (event.toolName !== "tool_search") return undefined;
    try {
      const loaded: string[] = Array.isArray(event.details?.loaded) ? event.details.loaded : [];
      const all = pi.getAllTools();
      const family = all.find((tool) => tool.name === loaded[0])?.namespace?.name ?? "";
      if (!SHEPHERD_NAMESPACE.test(family)) return undefined;
      const active = new Set(pi.getActiveTools());
      const more = all.filter((tool) => tool.exposure === "deferred" && tool.namespace?.name === family && !active.has(tool.name)).map((tool) => tool.name);
      if (more.length === 0) return undefined;
      pi.setActiveTools([...active, ...more]);
      // The answer says so too, and keeps its first line, "Loaded N tools.", true: Shepherd's thread reads the count from it.
      const first = event.content?.[0];
      if (first?.type !== "text" || typeof first.text !== "string") return undefined;
      const count = /^Loaded (\d+) tools?\./.exec(first.text);
      if (!count) return undefined;
      const total = Number(count[1]) + more.length;
      const text = first.text.replace(count[0], `Loaded ${total} tools.`) + `\nLoaded with them, from the same set: ${more.join(", ")}.`;
      return { content: [{ ...first, text }, ...event.content.slice(1)], details: { ...event.details, loaded: [...loaded, ...more] } };
    } catch {
      return undefined;
    }
  });

  pi.on("tool_call", (event) => {
    if (event.toolName === "codemode" && !codemodeEnabled) return { block: true, reason: "Codemode is disabled for this project." };
    try {
      if (shortTools.has(event.toolName) && event.input && typeof event.input === "object") {
        delete (event.input as Record<string, unknown>).short;
      }
    } catch {}
  });

  // One listener for the first stream event of each request, removed as soon as it fires, so
  // the rest of the stream runs with no handler of ours on it (pi awaits each in stream order).
  let requestSeq = 0;
  let stopWatchingStream: (() => void) | undefined;
  pi.on("before_provider_request", (_event, ctx) => {
    try {
      // An idle prompt-cache refresh is no request the user is waiting on.
      if (ctx?.isIdle?.()) return undefined;
      const seq = ++requestSeq;
      sendTiming(seq, "sent");
      stopWatchingStream?.();
      const stop = pi.on("provider_stream_event", () => {
        stop();
        if (stopWatchingStream === stop) stopWatchingStream = undefined;
        sendTiming(seq, "firstEvent");
      });
      stopWatchingStream = stop;
    } catch {
      // Swallow; the request goes as it was.
    }
    return undefined;
  });

  // The socket and RPC stdout can be read in either order. Link the marks to pi's stable
  // assistant timestamp so late marks cannot be mistaken for the next request or retry.
  pi.on("message_start", (event) => {
    if (event.message.role === "assistant" && requestSeq > 0 && Number.isFinite(event.message.timestamp)) {
      sendTiming(requestSeq, "message", event.message.timestamp);
    }
  });

  pi.on("after_provider_response", () => {
    if (requestSeq > 0 && stopWatchingStream) sendTiming(requestSeq, "headers");
  });

  pi.on("agent_start", () => {
    pendingWaits.clear();
    send("working");
  });

  pi.on("agent_settled", () => {
    stopWatchingStream?.();
    stopWatchingStream = undefined;
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
