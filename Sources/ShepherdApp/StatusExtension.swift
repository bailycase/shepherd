import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// Command spec for an app-spawned session.
struct SessionCommand {
    var argv: [String]
    var env: [String: String]
}

/// What an agent's pi is launched with for MCP (Settings ▸ Pi ▸ Bundled extensions ▸ MCP servers;
/// docs/mcp.md): pi's own MCP and tool search switched on over the home's `-builtin:` switches, the
/// secrets the servers' entries refer to in its environment, and, while Settings ▸ MCP servers ▸
/// Also use a repo's .mcp.json is on, the extension that registers the repo's servers.
struct MCPLaunch: Equatable {
    /// `-e` arguments: pi's built-ins by name, then the repo extension's file.
    var extensions: [String]
    var environment: [String: String]

    static let builtIns = ["builtin:mcp", "builtin:tool-search"]

    /// What an agent launches with under these settings: nil while Settings ▸ Pi ▸ MCP servers
    /// is off. `install` writes the repo extension and returns its path.
    @MainActor
    static func forAgents(settings: AppSettings, store: MCPStore,
                          install: () throws -> String = MCPProjectExtension.installedPath) rethrows -> MCPLaunch? {
        guard settings.piMCPExtension else { return nil }
        var extensions = builtIns
        var environment = store.launchEnvironment()
        if settings.mcpProjectConfig {
            extensions.append(try install())
            environment["SHEPHERD_EXT_MCP_PROJECT"] = "1"
        }
        return MCPLaunch(extensions: extensions, environment: environment)
    }
}

/// The per-agent pi status extension: bundled TypeScript source installed to
/// Application Support and passed to pi via `-e`, reporting agent lifecycle
/// status to the app's extension socket.
enum StatusExtension {
    /// Write the extension source to Application Support (idempotent) and
    /// return its filesystem path.
    static func installedPath() throws -> String {
        let dir = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("shepherd-status.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }

    /// argv + env for an agent: Shepherd's pi (`pi --mode rpc` through the launcher in its pi
    /// home) in `cwd`, from a login shell (so the user's PATH reaches pi's tools), reopening the
    /// pi session the agent was last in, with status reporting wired to the app's socket
    /// (`PiLaunch.agent` builds the line). The opening prompt is not passed positionally; RPC
    /// mode ignores positional messages, so the app sends it as the first `prompt` command
    /// instead. Throws when the agent's session folder would resolve outside the home.
    static func command(
        home: PiHome,
        cwd: String,
        agentID: AgentID,
        piSessionID: String,
        socketPath: String,
        extensionPath: String,
        panesExtensionPath: String?,
        reviewExtensionPath: String?,
        subagentsExtensionPath: String?,
        childrenExtensionPath: String? = nil,
        childEnvironment: [String: String] = [:],
        goalCrossProviderEvaluation: Bool = false,
        goalsEnabled: Bool = false,
        namerExtensionPath: String? = nil,
        needsName: Bool = false,
        isAutomation: Bool = false,
        instructions: (extensionPath: String, directory: String)? = nil,
        suggestFiles: [String] = [],
        design: (extensionPath: String, designID: DesignID, skillDirectory: String)? = nil,
        designReferences: (extensionPath: String, granted: Bool)? = nil,
        mcp: MCPLaunch? = nil,
        browserExtensionPath: String? = nil,
        contextExtensionPath: String? = nil,
        deferTools: Bool = false,
        userHome: String = NSHomeDirectory(),
        model: String?,
        thinking: ThinkingLevel?
    ) throws -> SessionCommand {
        // A design's agent reads its design with its own tools: never references.
        let designReferences = design == nil ? designReferences : nil
        // Nor does it get the browser: that is a thread's own page.
        let browserExtensionPath = design == nil ? browserExtensionPath : nil
        // Nor are its tools deferred: it works from all of them (docs/context-budget.md, Deferred tools).
        let deferTools = deferTools && design == nil
        // Deferred tools are loaded with pi's tool_search. With MCP on the launch already has it; without, it is the one built-in to add.
        let toolSearch = deferTools && mcp == nil ? ["builtin:tool-search"] : []
        // Child result delivery must run before the goal's final-settlement evaluator.
        let extensions = [extensionPath, ServiceTierExtension.path(in: home), instructions?.extensionPath, panesExtensionPath, reviewExtensionPath, subagentsExtensionPath,
                          childrenExtensionPath, GoalExtension.path(in: home), namerExtensionPath, design?.extensionPath, designReferences?.extensionPath,
                          browserExtensionPath].compactMap { $0 } + (mcp?.extensions ?? toolSearch) + [contextExtensionPath].compactMap { $0 }
        let line = try PiLaunch.agent(home: home, cwd: cwd, sessionID: piSessionID, model: model, thinking: thinking?.rawValue,
                                      extensions: extensions, untrustedProject: PiLaunch.isHomeFolder(cwd, userHome: userHome))
        var env = [
            "SHEPHERD_AGENT_ID": agentID.rawValue,
            "SHEPHERD_SOCKET": socketPath,
            "SHEPHERD_EXT_STATUS": extensionPath,
        ]
        if let instructions { env["SHEPHERD_INSTRUCTIONS_DIR"] = instructions.directory }
        // Settings ▸ Experiments ▸ Suggested instructions, while on for this agent: the files its
        // suggest_instruction may draft a line for.
        if instructions != nil, !suggestFiles.isEmpty { env["SHEPHERD_SUGGEST_FILES"] = suggestFiles.joined(separator: ",") }
        if let panesExtensionPath { env["SHEPHERD_EXT_PANES"] = panesExtensionPath }
        // Settings ▸ Pi ▸ Browser tools: the tools on the thread's own page (docs/browser.md).
        if let browserExtensionPath { env["SHEPHERD_EXT_BROWSER"] = browserExtensionPath }
        if let childrenExtensionPath {
            env["SHEPHERD_NATIVE_CHILDREN"] = "1"
            env["SHEPHERD_EXT_CHILDREN"] = childrenExtensionPath
            env.merge(childEnvironment) { _, value in value }
        }
        if namerExtensionPath != nil && needsName { env["SHEPHERD_NEEDS_NAME"] = "1" }
        if isAutomation { env["SHEPHERD_AUTOMATION"] = "1" }
        // A design's agent: its design tools, and the skill they hand pi.
        if let design {
            env["SHEPHERD_DESIGN_ID"] = design.designID.rawValue
            env["SHEPHERD_DESIGN_SKILL_DIR"] = design.skillDirectory
        }
        // A thread's design references: design_get registers itself once it holds one.
        if let designReferences { env["SHEPHERD_DESIGN_REFS"] = designReferences.granted ? "granted" : "on" }
        // Settings ▸ MCP servers: the Keychain values pi's MCP expands into its servers' env and headers.
        if let mcp { env.merge(mcp.environment) { _, value in value } }
        // Settings ▸ Agents ▸ Trim old tool output: what the model is sent, never the thread (docs/context-budget.md).
        if let contextExtensionPath { env["SHEPHERD_EXT_CONTEXT"] = contextExtensionPath }
        // Settings ▸ Agents ▸ Defer rarely used tools: the browser, other-thread, automation and review tools are loaded by a search.
        if deferTools { env["SHEPHERD_DEFER_TOOLS"] = "1" }
        // Fast or Standard is the agent's own (the host keeps its file), so every agent gets this.
        env.merge(ServiceTierExtension.environment(for: agentID, in: home)) { _, value in value }
        // Keep the controller loaded so the experiment can change without restarting pi.
        env[GoalExtension.environmentKey] = "1"
        env["SHEPHERD_GOALS_ENABLED"] = goalsEnabled ? "1" : "0"
        // Always override an inherited opt-in; absence would leak the app's launch environment.
        env["SHEPHERD_GOAL_MODELS"] = goalCrossProviderEvaluation
            ? "anthropic/claude-haiku-4-5,openai/gpt-5.1-codex-mini,google/gemini-2.5-flash" : ""
        if let model { env["SHEPHERD_MODEL"] = model }
        return SessionCommand(argv: line.argv, env: env)
    }

    /// Embedded extension source. Extensions/shepherd-status.ts is the canonical
    /// copy; keep this literal byte-identical to it.
    static let extensionSource = #"""
        // Shepherd status extension: reports pi lifecycle status for one agent to the
        // Shepherd extension socket as newline-delimited JSON setAgentStatus messages.
        // Inert unless SHEPHERD_AGENT_ID and SHEPHERD_SOCKET are set. Status reporting
        // is best-effort; native codemode failures remain visible as normal tool errors.
        import * as net from "node:net";
        import { createCodemodeExtension, type ExtensionAPI, type ExtensionCommandContext, type SessionEntry } from "@earendil-works/pi-coding-agent";

        type Status = "working" | "blocked" | "idle" | "done";

        // Shepherd's Retry runs `/shepherd-retry <ms>`: the user message pi stamped at that
        // millisecond goes again in place of the turn it opened (see retryTurn).
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
          const deferTools = process.env.SHEPHERD_DEFER_TOOLS === "1";
          let codemodeEnabled = false;

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
            pi.setActiveTools([...new Set([...pi.getActiveTools(), "codemode"])]);
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

          // Retry: pi's session is a tree, so the leaf moves back to the message's parent (no summary)
          // and the message goes again as it was, text and images. The failed turn stays in the file
          // but leaves the active branch, so the model sees the message once. Idle only, and only a
          // user message on the active branch.
          async function retryTurn(args: string, ctx: ExtensionCommandContext) {
            const notify = (text: string) => ctx.ui.notify(text, "warning");
            if (!ctx.isIdle() || ctx.hasPendingMessages()) return notify("Retry once the agent has stopped.");
            const at = Number(args.trim());
            let target: Extract<SessionEntry, { type: "message" }> | undefined;
            if (args.trim() !== "" && Number.isFinite(at)) {
              for (const entry of ctx.sessionManager.getBranch()) {
                if (entry.type !== "message" || entry.message.role !== "user") continue;
                if (Math.trunc(Number(entry.message.timestamp)) === at) target = entry;
              }
            }
            if (!target || target.message.role !== "user") return notify("That message is no longer in this conversation.");
            const { content } = target.message;
            const resend = typeof content === "string"
              ? content
              : content.filter((part) => part.type === "text" || part.type === "image");
            const { cancelled } = await ctx.navigateTree(target.id, { summarize: false });
            if (cancelled) return;
            pi.sendUserMessage(resend);
          }

          pi.registerCommand(RETRY_COMMAND, {
            description: "Retry the latest turn (Shepherd's Retry)",
            handler: async (args, ctx) => {
              try {
                await retryTurn(args, ctx);
              } catch (error) {
                try {
                  ctx.ui.notify(`Couldn't retry: ${error instanceof Error ? error.message : String(error)}`, "warning");
                } catch {}
              }
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

        """#
}
