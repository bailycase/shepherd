import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// An agent's terminal tools (`terminal_*`) are served by the background host
/// (`SessionServer.serveThreads`); the app only asks it to open one.
@MainActor
extension ShepherdViewModel {
    /// Runs `command` in a new terminal of `agentID`'s layout (the Browser's Start), by the same
    /// rules as an agent's `terminal_open`.
    func openTerminalPane(for agentID: AgentID, cwd: String, command: String, respond: @escaping (PaneOutcome) -> Void) {
        guard let ref = localRef(agentID) else {
            return respond(.failed(code: "unavailable", message: BackgroundHostClient.HostStarting().description))
        }
        // The background host opens it and runs the command, by the same rules.
        Task {
            do {
                try await remoteHosts.agentAction(ref, action: .openTerminal(cwd: cwd, command: command))
                // Its callers (the Browser's Start) read only that it opened.
                respond(.opened(PaneInfo(id: PaneID(), cwd: cwd, isAgentPane: false, isFocused: false, isAlive: true)))
            } catch { respond(.failed(code: "open_failed", message: ActionError.describe(error))) }
        }
    }
}
