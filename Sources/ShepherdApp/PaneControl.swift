import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// Handles pane-control requests from an agent's panes extension.
///
/// Agents drive their own workspace here: open a pane, run something in it,
/// read what it printed, close it. Scope is deliberately narrow — an agent can
/// only touch panes in **its own** layout, and can never close or type into
/// the pane running its own pi process (that is its own terminal, and letting
/// it type there would mean typing into itself).
@MainActor
extension ShepherdViewModel {
    /// Wire the server's pane hook to this view model. Called once at startup.
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
            respond(.panes(paneInfos(in: tab, agent: agent)))

        case .open(_, let axis, let cwd, let relativeTo, let command):
            openPane(
                agent: agent,
                tab: tab,
                axis: axis,
                cwd: cwd,
                relativeTo: relativeTo,
                command: command,
                respond: respond
            )

        case .close(_, let paneID):
            guard let pane = tab.layout.leaf(withID: paneID) else {
                respond(.failed(code: "no_such_pane", message: "pane \(paneID) is not in this agent's layout"))
                return
            }
            guard pane.agentID == nil else {
                respond(.failed(code: "not_closable", message: "an agent cannot close its own pi pane"))
                return
            }
            guard let newLayout = tab.layout.closing(pane: paneID) else {
                respond(.failed(code: "last_pane", message: "a layout always keeps its last pane"))
                return
            }
            if let sessionID = pane.sessionID {
                server.killSession(sessionID)
            }
            sessions.detachPane(paneID)
            setLayout(newLayout, forTab: tab.id)
            if focusedPaneID == paneID {
                focusedPaneID = newLayout.firstLeaf.id
            }
            respond(.ok)

        case .resizeSplit(_, let split, let ratio):
            guard tab.layout.containsSplit(split) else {
                respond(.failed(code: "no_such_split", message: "split is not in this agent's layout"))
                return
            }
            setLayout(
                tab.layout.replacingSplit(split, withRatio: min(0.85, max(0.15, ratio))),
                forTab: tab.id
            )
            respond(.ok)

        case .focus(_, let paneID):
            guard tab.layout.contains(paneID) else {
                respond(.failed(code: "no_such_pane", message: "pane \(paneID) is not in this agent's layout"))
                return
            }
            if activate {
                selectAgent(agent.id)
                focusedPaneID = paneID
            }
            respond(.ok)

        case .sendInput(_, let paneID, let text, let submit):
            guard let pane = tab.layout.leaf(withID: paneID) else {
                respond(.failed(code: "no_such_pane", message: "pane \(paneID) is not in this agent's layout"))
                return
            }
            guard pane.agentID == nil else {
                respond(.failed(code: "not_writable", message: "an agent cannot type into its own pi pane"))
                return
            }
            guard let sessionID = pane.sessionID else {
                respond(.failed(code: "no_session", message: "pane \(paneID) has no running process yet"))
                return
            }
            server.write(sessionID: sessionID, data: Data((submit ? text + "\n" : text).utf8))
            respond(.ok)

        case .read(_, let paneID):
            guard let pane = tab.layout.leaf(withID: paneID) else {
                respond(.failed(code: "no_such_pane", message: "pane \(paneID) is not in this agent's layout"))
                return
            }
            guard let sessionID = pane.sessionID else {
                respond(.content(paneID: paneID, lines: []))
                return
            }
            Task {
                let lines = await self.server.screenText(sessionID: sessionID) ?? []
                respond(.content(paneID: paneID, lines: lines))
            }
        }
    }

    // MARK: Helpers

    private func paneInfos(in tab: Tab, agent: Agent) -> [PaneInfo] {
        tab.layout.leaves.map { leaf in
            PaneInfo(
                id: leaf.id,
                cwd: leaf.cwd,
                isAgentPane: leaf.agentID != nil,
                isFocused: focusedPaneID == leaf.id,
                isAlive: leaf.sessionID != nil
            )
        }
    }

    private func openPane(
        agent: Agent,
        tab: Tab,
        axis: SplitAxis,
        cwd: String?,
        relativeTo: PaneID?,
        command: String?,
        respond: @escaping (PaneOutcome) -> Void
    ) {
        // Split the requested pane, else the agent's own — the layout always
        // has that one, so an agent never has to know a pane id to open one.
        let anchor = relativeTo ?? agent.paneID ?? tab.layout.firstLeaf.id
        guard let anchorLeaf = tab.layout.leaf(withID: anchor) else {
            respond(.failed(code: "no_such_pane", message: "pane \(anchor) is not in this agent's layout"))
            return
        }

        let newPane = LeafPane(cwd: cwd.map { ($0 as NSString).expandingTildeInPath } ?? anchorLeaf.cwd)
        guard let newLayout = tab.layout.splitting(pane: anchor, axis: axis, newPane: newPane) else {
            respond(.failed(code: "split_failed", message: "could not split pane \(anchor)"))
            return
        }

        setLayout(newLayout, forTab: tab.id)

        // The pane view spawns the shell when it renders. Wait for that
        // binding before reporting, so a command runs in a live process
        // rather than being written into a pane that has none yet.
        Task {
            let sessionID = await self.sessions.awaitSession(forPane: newPane.id, timeout: .seconds(5))
            if let sessionID, let command, !command.isEmpty {
                self.server.write(sessionID: sessionID, data: Data((command + "\n").utf8))
            }
            respond(.opened(PaneInfo(
                id: newPane.id,
                cwd: newPane.cwd,
                isAgentPane: false,
                isFocused: self.focusedPaneID == newPane.id,
                isAlive: sessionID != nil
            )))
        }
    }
}

private extension PaneNode {
    func containsSplit(_ target: PaneNode) -> Bool {
        if self == target { return true }
        guard case .split(_, _, let first, let second) = self else { return false }
        return first.containsSplit(target) || second.containsSplit(target)
    }
}
