import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The terminal panel's own actions (NewTerminalMenu): name a tab and kill what a tab runs. A
/// local agent's go to the background host; a remote agent's to its host
/// (`terminalControlCapability`), which serves them here for its own agents with the same rules.
extension ShepherdViewModel {
    struct TerminalControlError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: From the panel

    /// Whether the host of `target` takes the panel's own actions: this Mac always does.
    func terminalControlAvailable(_ target: TerminalTarget) -> Bool {
        guard let remote = target.remote else { return true }
        return remoteHosts.allConnections.first { $0.id == remote.hostID }?.supportsTerminalControl == true
    }

    /// Rename tab: asks for the name (`terminalRenameTarget`).
    func renameTerminalTab(_ tab: TerminalPanelTab, target: TerminalTarget) {
        guard terminalControlAvailable(target) else { NSSound.beep(); return }
        let current = TerminalPanels.title(row: terminalPanels.activity[target.key]?[tab.id], pane: tab.leaf)
        terminalRenameTarget = TerminalRenameTarget(paneID: tab.id, remote: target.remote, agentID: agentID(of: target),
                                                    name: current)
    }

    func commitTerminalRename(_ rename: TerminalRenameTarget, to title: String) {
        terminalRenameTarget = nil
        if let remote = rename.remote ?? rename.agentID.flatMap(localRef) {
            Task {
                do { try await remoteHosts.agentAction(remote, action: .renameTerminal(paneID: rename.paneID, title: title)) }
                catch { fail("Couldn’t rename the terminal", error) }
            }
        }
    }

    /// Kill process: the command running in the tab's terminal.
    func killTerminalProcess(in tab: TerminalPanelTab, target: TerminalTarget) {
        if let remote = target.remote ?? agentID(of: target).flatMap(localRef) {
            Task {
                do { try await remoteHosts.agentAction(remote, action: .killTerminalProcess(paneID: tab.id)) }
                catch { NSSound.beep() }
            }
        }
    }

    /// Whether the tab's terminal runs a command Kill process could end.
    func terminalTabIsRunning(_ tab: TerminalPanelTab, target: TerminalTarget) -> Bool {
        terminalPanels.activity[target.key]?[tab.id]?.isRunning == true
    }

    /// Where a new tab opens, for the menu: "<space> on <host>" ("payments on build-01").
    func terminalPlace(_ target: TerminalTarget) -> String {
        if let remote = target.remote, let connection = remoteHosts.allConnections.first(where: { $0.id == remote.hostID }) {
            let agent = connection.state.agents.first { $0.id == remote.agentID }
            let space = agent.flatMap { agent in connection.state.spaces.first { $0.id == agent.spaceID }?.name }
            return "\(space ?? "The thread's folder") on \(connection.config.name)"
        }
        let agent = state.agents.first { $0.tabID == target.key.tab }
        let space = agent.flatMap { agent in state.spaces.first { $0.id == agent.spaceID }?.name }
        return "\(space ?? "The thread's folder") on This Mac"
    }

    /// The new-tab row's title: only a worktree thread's terminal opens "in the worktree".
    func newTerminalTitle(_ target: TerminalTarget) -> String {
        let agent = if let remote = target.remote {
            remoteHosts.allConnections.first { $0.id == remote.hostID }?.state.agents.first { $0.id == remote.agentID }
        } else {
            state.agents.first { $0.tabID == target.key.tab }
        }
        return Self.newTerminalTitle(worktree: agent?.worktreeBranch != nil)
    }

    nonisolated static func newTerminalTitle(worktree: Bool) -> String {
        worktree ? "New terminal in the worktree" : "New terminal"
    }

    /// Add to message (TerminalPane): the selection goes into the thread's composer as a code
    /// block after what is typed there, and the thread takes the keyboard.
    func addTerminalSelection(_ text: String, to owner: SidePaneOwner) {
        let store: NativeThreadStore
        switch owner {
        case .local(let agentID):
            store = threadStores.store(for: agentID)
            if let pane = state.agents.first(where: { $0.id == agentID })?.paneID { focusedPaneID = pane }
        case .remote(let ref):
            store = remoteThreadStores.store(for: ref)
            if let pane = remoteHosts.allConnections.first(where: { $0.id == ref.hostID })?.state.agents
                .first(where: { $0.id == ref.agentID })?.paneID { remoteFocusedPaneID = pane }
        }
        store.draft = Self.draft(store.draft, adding: text)
    }

    /// The draft with `selection` fenced after it, a blank line apart.
    static func draft(_ draft: String, adding selection: String) -> String {
        let body = selection.trimmingCharacters(in: .newlines)
        guard !body.isEmpty else { return draft }
        let lead = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : draft.hasSuffix("\n\n") ? draft
            : draft.hasSuffix("\n") ? draft + "\n" : draft + "\n\n"
        return lead + "```\n" + body + "\n```\n"
    }

    private func agentID(of target: TerminalTarget) -> AgentID? {
        if let remote = target.remote { return remote.agentID }
        return state.agents.first { $0.tabID == target.key.tab }?.id
    }
}

/// A terminal tab being renamed: its terminal, and whose layout it is in.
struct TerminalRenameTarget: Identifiable, Equatable {
    let paneID: PaneID
    let remote: RemoteAgentRef?
    let agentID: AgentID?
    let name: String
    var id: PaneID { paneID }
}
