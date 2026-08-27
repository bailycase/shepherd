import Foundation
import AppKit
import ShepherdCore
import ShepherdProtocol

/// Clicking a subagent row shows Shepherd's inspector dashboard
/// (shepherd-inspect.mjs) as its own focused workspace — a dedicated
/// inspector layout per agent, not a split carved out of the agent's panes.
/// The dashboard mirrors the run's lifecycle artifacts; its prompt steers
/// (plain text) or stops (`:stop`) through the run's control inbox. Closing
/// it never touches the run, and selecting the agent flips back to the
/// agent's terminal untouched.
@MainActor
extension ShepherdViewModel {
    func openChildInspector(agentID: AgentID, child: ChildRun) {
        guard let asyncDir = child.asyncDir,
              let agent = state.agents.first(where: { $0.id == agentID }),
              let runner = try? InspectExtension.installedPath() else {
            selectAgent(agentID)
            NSSound.beep()
            return
        }
        // Select the agent first (sidebar highlight, space switch), then lift
        // the workspace to the inspector layout.
        selectAgent(agentID)
        inspectingAgentID = agentID

        // Re-clicking the child already on screen is pure navigation — the
        // viewer keeps running, nothing is re-sent.
        if inspectedChild[agentID] == child.id,
           state.tabs.contains(where: { $0.inspectorFor == agentID }) {
            return
        }

        let command = Self.inspectorCommand(
            runner: runner,
            asyncDir: asyncDir,
            runID: child.runID,
            childIndex: child.childIndex
        )

        if let tab = state.tabs.first(where: { $0.inspectorFor == agentID }) {
            // Retarget the live pane. The running viewer holds stdin in raw
            // mode, so anything written while it is still dying gets eaten
            // by it instead of reaching the shell — that was the "dropped in
            // a bare shell" race. Interrupt, give the process a beat to
            // exit and the shell to reclaim the tty, then send the command.
            let paneID = tab.layout.firstLeaf.id
            focusedPaneID = paneID
            inspectedChild[agentID] = child.id
            Task {
                guard let sessionID = await sessions.awaitSession(forPane: paneID, timeout: .seconds(2)) else {
                    return
                }
                server.write(sessionID: sessionID, data: Data("\u{03}".utf8))
                try? await Task.sleep(for: .milliseconds(350))
                server.write(sessionID: sessionID, data: Data((command + "\n").utf8))
            }
            return
        }

        // First inspection for this agent: create its inspector layout. The
        // pane spawns a login shell on render; the command follows once the
        // session is live.
        let pane = LeafPane(cwd: TerminalSessionStore.resolvedCwd(agentCwd(agent)))
        let order = (state.tabs.filter { $0.spaceID == agent.spaceID }.map(\.order).max() ?? -1) + 1
        let tab = Tab(
            spaceID: agent.spaceID,
            order: order,
            layout: .leaf(pane),
            inspectorFor: agentID
        )
        state.tabs.append(tab)
        sessions.stateDidChange(state)
        enqueuePersistence("inspector tab") { try await $0.addTab(tab) }
        focusedPaneID = pane.id
        inspectedChild[agentID] = child.id

        Task {
            guard let sessionID = await sessions.awaitSession(forPane: pane.id, timeout: .seconds(5)) else {
                return
            }
            server.write(sessionID: sessionID, data: Data((command + "\n").utf8))
        }
    }

    private func agentCwd(_ agent: Agent) -> String {
        state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd
            ?? state.spaces.first { $0.id == agent.spaceID }?.path
            ?? NSHomeDirectory()
    }

    /// No `exec`: the shell must survive the viewer so a later child click
    /// can ^C back to the prompt and launch the next dashboard in place.
    /// Quoting keeps temp paths with spaces intact.
    static func inspectorCommand(runner: String, asyncDir: String, runID: String, childIndex: Int?) -> String {
        func quoted(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
        var command = "node \(quoted(runner)) --async-dir \(quoted(asyncDir)) --run-id \(quoted(runID))"
        if let childIndex {
            command += " --index \(childIndex)"
        }
        return command
    }
}
