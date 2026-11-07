import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// Handles terminal-control requests from an agent's panes extension (the `terminal_*` tools).
///
/// Agents drive their own workspace here: open a terminal, run something in it, read what it
/// printed, close it. Scope is deliberately narrow: an agent can only touch terminals in **its
/// own** layout, never its own thread (the pi process it runs in), and a terminal is always a
/// tab of its own, so a request that names where to split (an older client's) opens a new tab.
@MainActor
extension ShepherdViewModel {
    /// Wire the server's terminal hook to this view model. Called once at startup.
    func installPaneControl() {
        server.onPaneRequest = { [weak self] request, respond in
            MainActor.assumeIsolated {
                guard let self else {
                    respond(.failed(code: "unavailable", message: "workspace is gone"))
                    return
                }
                self.handle(request, activate: true, respond: respond)
            }
        }
        server.onRemotePaneRequest = { [weak self] request, respond in
            MainActor.assumeIsolated {
                guard let self else {
                    respond(.failed(code: "unavailable", message: "workspace is gone"))
                    return
                }
                self.handle(request, activate: false, respond: respond)
            }
        }
    }

    /// What a request naming a terminal found: the terminal, or the answer to give.
    private enum TerminalLookup {
        case terminal(LeafPane)
        case refused(PaneOutcome)
    }

    private func handle(
        _ request: PaneRequest,
        activate: Bool,
        respond: @escaping (PaneOutcome) -> Void
    ) {
        guard let agent = state.agents.first(where: { $0.id == request.agentID }),
              let tab = state.tabs.first(where: { $0.id == agent.tabID }) else {
            respond(.failed(code: "no_such_agent", message: "unknown agent \(request.agentID)"))
            return
        }

        switch request {
        case .list:
            respond(.panes(terminalInfos(in: tab, agent: agent)))

        case .open(_, _, let cwd, _, let command):
            // Where an older client asked to split is ignored: a terminal is a tab.
            openTerminal(agent: agent, tab: tab, cwd: cwd, command: command, respond: respond)

        case .close(_, let id):
            switch terminal(id, in: tab, agent: agent, threadCode: "not_closable") {
            case .refused(let outcome):
                respond(outcome)
            case .terminal(let leaf):
                guard let newLayout = tab.layout.closing(pane: id) else {
                    respond(.failed(code: "not_closable", message: "the layout's only terminal cannot be closed"))
                    return
                }
                if let sessionID = leaf.sessionID {
                    server.killSession(sessionID)
                }
                sessions.detachPane(id)
                setLayout(newLayout, forTab: tab.id)
                if focusedPaneID == id {
                    focusedPaneID = newLayout.firstLeaf.id
                }
                respond(.ok)
            }

        case .focus(_, let id):
            switch terminal(id, in: tab, agent: agent, threadCode: "no_such_terminal") {
            case .refused(let outcome):
                respond(outcome)
            case .terminal:
                if activate {
                    selectAgent(agent.id)
                    terminalPanels.update(TerminalPanelKey(host: nil, tab: tab.id)) {
                        $0.shown = true
                        $0.chosenTab = id
                    }
                    focusedPaneID = id
                }
                respond(.ok)
            }

        case .sendInput(_, let id, let text, let submit):
            switch terminal(id, in: tab, agent: agent, threadCode: "not_writable") {
            case .refused(let outcome):
                respond(outcome)
            case .terminal(let leaf):
                guard let sessionID = leaf.sessionID else {
                    respond(.failed(code: "no_session", message: "terminal \(id) has no running process yet"))
                    return
                }
                server.write(sessionID: sessionID, data: Data((submit ? text + "\n" : text).utf8))
                respond(.ok)
            }

        case .read(_, let id):
            switch terminal(id, in: tab, agent: agent, threadCode: "no_such_terminal") {
            case .refused(let outcome):
                respond(outcome)
            case .terminal(let leaf):
                guard let sessionID = leaf.sessionID else {
                    respond(.content(paneID: id, lines: []))
                    return
                }
                Task {
                    let lines = await self.server.screenText(sessionID: sessionID) ?? []
                    respond(.content(paneID: id, lines: lines))
                }
            }
        }
    }

    /// Runs `command` in a new terminal of `agentID`'s layout (the Browser's Start), by the same
    /// rules as an agent's `terminal_open`.
    func openTerminalPane(for agentID: AgentID, cwd: String, command: String, respond: @escaping (PaneOutcome) -> Void) {
        handle(.open(agentID: agentID, axis: .vertical, cwd: cwd, relativeTo: nil, command: command), activate: false, respond: respond)
    }

    // MARK: Helpers

    /// The terminal `id` names in the agent's layout. The thread is not a terminal: asking for
    /// it is refused with `threadCode`, and any id the layout does not hold is `no_such_terminal`.
    private func terminal(_ id: PaneID, in tab: Tab, agent: Agent, threadCode: String) -> TerminalLookup {
        guard let leaf = tab.layout.leaf(withID: id), leaf.isReview != true else {
            return .refused(.failed(code: "no_such_terminal", message: "terminal \(id) is not in this agent's layout"))
        }
        guard leaf.agentID == nil, leaf.id != agent.paneID else {
            return .refused(.failed(code: threadCode, message: "\(id) is the agent's own thread, not a terminal"))
        }
        return .terminal(leaf)
    }

    /// The agent's terminals, oldest first. Its own thread is never among them.
    private func terminalInfos(in tab: Tab, agent: Agent) -> [PaneInfo] {
        TerminalPanel.tabs(in: tab.layout, thread: agent.paneID).map(\.leaf)
            .filter { $0.agentID == nil && $0.id != agent.paneID && $0.isReview != true }
            .map { leaf in
                PaneInfo(
                    id: leaf.id,
                    cwd: leaf.cwd,
                    isAgentPane: false,
                    isFocused: focusedPaneID == leaf.id,
                    isAlive: leaf.sessionID != nil
                )
            }
    }

    /// A new terminal as a tab beside the thread, in `cwd` or the thread's folder (its worktree).
    private func openTerminal(
        agent: Agent,
        tab: Tab,
        cwd: String?,
        command: String?,
        respond: @escaping (PaneOutcome) -> Void
    ) {
        let thread = agent.paneID.flatMap { tab.layout.leaf(withID: $0) } ?? tab.layout.firstLeaf
        let folder = cwd.map { ($0 as NSString).expandingTildeInPath } ?? thread.cwd
        do { try verifyCheckoutAvailable(folder) }
        catch { respond(.failed(code: "checkout_busy", message: String(describing: error))); return }
        let newTerminal = LeafPane(cwd: folder)
        guard let newLayout = tab.layout.splitting(pane: thread.id, axis: .horizontal, newPane: newTerminal) else {
            respond(.failed(code: "open_failed", message: "could not open a terminal beside the thread"))
            return
        }

        setLayout(newLayout, forTab: tab.id)

        // The terminal's view spawns the shell when it renders. Wait for that binding before
        // reporting, so a command runs in a live process rather than being written into a
        // terminal that has none yet.
        Task {
            let sessionID = await self.sessions.awaitSession(forPane: newTerminal.id, timeout: .seconds(5))
            if let sessionID, let command, !command.isEmpty {
                self.server.typeCommand(command, sessionID: sessionID)
            }
            respond(.opened(PaneInfo(
                id: newTerminal.id,
                cwd: newTerminal.cwd,
                isAgentPane: false,
                isFocused: self.focusedPaneID == newTerminal.id,
                isAlive: sessionID != nil
            )))
        }
    }
}
