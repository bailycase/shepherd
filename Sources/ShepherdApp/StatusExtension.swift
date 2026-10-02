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
        namerExtensionPath: String? = nil,
        needsName: Bool = false,
        isAutomation: Bool = false,
        instructions: (extensionPath: String, directory: String)? = nil,
        suggestFiles: [String] = [],
        design: (extensionPath: String, designID: DesignID, skillDirectory: String)? = nil,
        designReferences: (extensionPath: String, granted: Bool)? = nil,
        mcp: MCPLaunch? = nil,
        browserExtensionPath: String? = nil,
        userHome: String = NSHomeDirectory(),
        model: String?,
        thinking: ThinkingLevel?
    ) throws -> SessionCommand {
        // A design's agent reads its design with its own tools: never references.
        let designReferences = design == nil ? designReferences : nil
        // Nor does it get the browser: that is a thread's own page.
        let browserExtensionPath = design == nil ? browserExtensionPath : nil
        let extensions = [extensionPath, ServiceTierExtension.path(in: home), instructions?.extensionPath, panesExtensionPath, reviewExtensionPath, subagentsExtensionPath,
                          childrenExtensionPath, namerExtensionPath, design?.extensionPath, designReferences?.extensionPath,
                          browserExtensionPath].compactMap { $0 } + (mcp?.extensions ?? [])
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
        // Fast or Standard is the agent's own (the host keeps its file), so every agent gets this.
        env.merge(ServiceTierExtension.environment(for: agentID, in: home)) { _, value in value }
        if let model { env["SHEPHERD_MODEL"] = model }
        return SessionCommand(argv: line.argv, env: env)
    }

    /// Embedded extension source. Extensions/shepherd-status.ts is the canonical
    /// copy; keep this literal byte-identical to it.
    static let extensionSource = #"""
        // Shepherd status extension: reports pi lifecycle status for one agent to the
        // Shepherd extension socket as newline-delimited JSON setAgentStatus messages.
        // Inert unless SHEPHERD_AGENT_ID and SHEPHERD_SOCKET are set; every failure is
        // swallowed so this extension can never break or slow the pi session.
        import * as net from "node:net";
        import type { ExtensionAPI, ExtensionCommandContext, SessionEntry } from "@earendil-works/pi-coding-agent";

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

        """#
}
