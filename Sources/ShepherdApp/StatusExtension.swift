import Foundation
import ShepherdCore
import ShepherdProtocol

/// Command spec for an app-spawned session.
struct SessionCommand {
    var argv: [String]
    var env: [String: String]
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

    /// Build the argv + env for launching pi for `agent` through a login shell,
    /// with status reporting wired to the app's socket.
    static func command(
        agentID: AgentID,
        /// The pi session to open. Usually the agent's id, but `/new` and
        /// `/resume` move the agent to a different one.
        piSessionID: String,
        socketPath: String,
        extensionPath: String,
        themeExtensionPath: String,
        panesExtensionPath: String,
        reviewExtensionPath: String,
        subagentsExtensionPath: String,
        /// nil when auto-naming is off in Settings.
        namerExtensionPath: String? = nil,
        /// True while the agent's name is provisional: the namer then also
        /// titles from the opening prompt (SHEPHERD_NEEDS_NAME=1).
        needsName: Bool = false,
        /// True for an automation's watch agent: the panes extension then
        /// withholds the automation_* tools so a watcher cannot breed
        /// watchers (SHEPHERD_AUTOMATION=1).
        isAutomation: Bool = false,
        piThemePath: String,
        piThemeName: String,
        model: String?,
        thinking: ThinkingLevel?,
        initialPrompt: String?
    ) -> SessionCommand {
        var cmd = "exec pi"
        // Reopen the session the agent was last in. That starts as the agent's
        // own id (pi creates it on first launch) and follows the user through
        // `/new` and `/resume`, which the status extension reports back.
        cmd += " --session-id \(shellQuoted(piSessionID))"
        cmd += " --theme \(shellQuoted(piThemePath))"
        cmd += " --use-theme \(shellQuoted(piThemeName))"
        if let model {
            cmd += " --model \(shellQuoted(model))"
        }
        if let thinking {
            cmd += " --thinking \(shellQuoted(thinking.rawValue))"
        }
        cmd += " -e \(shellQuoted(extensionPath))"
        cmd += " -e \(shellQuoted(themeExtensionPath))"
        cmd += " -e \(shellQuoted(panesExtensionPath))"
        cmd += " -e \(shellQuoted(reviewExtensionPath))"
        cmd += " -e \(shellQuoted(subagentsExtensionPath))"
        if let namerExtensionPath {
            cmd += " -e \(shellQuoted(namerExtensionPath))"
        }
        if let initialPrompt, !initialPrompt.isEmpty {
            cmd += " \(shellQuoted(initialPrompt))"
        }
        var env = [
            "SHEPHERD_AGENT_ID": agentID.rawValue,
            "SHEPHERD_SOCKET": socketPath,
            "SHEPHERD_EXT_STATUS": extensionPath,
            "SHEPHERD_EXT_THEME": themeExtensionPath,
            "SHEPHERD_EXT_PANES": panesExtensionPath,
            "SHEPHERD_PI_THEME_PATH": piThemePath,
            "SHEPHERD_PI_THEME_NAME": piThemeName,
        ]
        if needsName {
            env["SHEPHERD_NEEDS_NAME"] = "1"
        }
        if isAutomation {
            env["SHEPHERD_AUTOMATION"] = "1"
        }
        if let model {
            env["SHEPHERD_MODEL"] = model
        }
        return SessionCommand(argv: ["/bin/zsh", "-l", "-c", cmd], env: env)
    }

    /// Single-quote wrapping with '"'"' escaping for embedded single quotes.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Embedded extension source. Extensions/shepherd-status.ts is the canonical
    /// copy; keep this literal byte-identical to it.
    static let extensionSource = #"""
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

        """#
}
