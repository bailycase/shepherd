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
    /// RPC agents inspect native children in the side panel inside their own workspace; the
    /// inspector-tab flow below stays for terminal agents.
    func openChildInspector(agentID: AgentID, child: ChildRun) {
        if state.agents.first(where: { $0.id == agentID })?.runtime == .rpc {
            selectAgent(agentID)
            subagentInspector.runByAgent[agentID] = child.runID
            return
        }
        openChildInspectorTab(agentID: agentID, child: child)
    }

    /// Toggle the side panel for a run (card click, ⌘I, × on the panel).
    func toggleSubagentInspector(agentID: AgentID, runID: String) {
        subagentInspector.toggle(agentID: agentID, runID: runID)
    }

    /// "Fork as new agent": copy the finished child's transcript into its cwd's pi session
    /// directory under a fresh id and start an RPC agent on it in the parent's space. The new
    /// agent is named "<role> (fork)" provisionally so the namer can retitle it. Throws with a
    /// user-facing message when the transcript is missing or the copy fails; nothing is created then.
    @discardableResult
    func forkSubagent(agentID: AgentID, run: ChildRun) async throws -> AgentID {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else {
            throw PiSessionFile.ForkFailure(message: "The parent agent is no longer listed.")
        }
        guard let file = run.sessionFile else {
            throw PiSessionFile.ForkFailure(message: "The subagent's session file is not known.")
        }
        let cwd = run.cwd ?? agentCwd(agent)
        let sessionID = try PiSessionFile.fork(sessionFile: file, cwd: cwd)
        var config = NewAgentConfig(spaceID: agent.spaceID, workingDirectory: cwd, model: run.model ?? agent.model,
                                    thinking: run.thinking.flatMap(ThinkingLevel.init(rawValue:)) ?? agent.thinkingLevel ?? .medium,
                                    initialPrompt: nil, runtime: .rpc)
        config.initialName = "\(run.role ?? run.label) (fork)"
        config.piSessionID = sessionID
        return try await startAgent(config)
    }

    private func openChildInspectorTab(agentID: AgentID, child: ChildRun) {
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
            childIndex: child.childIndex,
            themePath: try? ShepherdPiTheme.installedPath(for: themeManager.current)
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
    static func inspectorCommand(runner: String, asyncDir: String, runID: String, childIndex: Int?, themePath: String? = nil) -> String {
        func quoted(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
        var command = "node \(quoted(runner)) --async-dir \(quoted(asyncDir)) --run-id \(quoted(runID))"
        if let childIndex {
            command += " --index \(childIndex)"
        }
        if let themePath {
            command += " --theme-path \(quoted(themePath))"
        }
        return command
    }
}
