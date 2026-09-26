import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The terminal panel's own actions (NewTerminalMenu): name a tab and kill what a tab runs. A
/// local agent's go to this Mac's server; a remote agent's to its host
/// (`terminalControlCapability`), which serves them here for its own agents with the same rules.
extension ShepherdViewModel {
    struct TerminalControlError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// A terminal pane of `agentID`'s layout: never its thread, never another agent's.
    private func terminalLeaf(_ paneID: PaneID, of agentID: AgentID) throws -> (tab: Tab, leaf: LeafPane) {
        guard let agent = state.agents.first(where: { $0.id == agentID }),
              let tab = state.tabs.first(where: { $0.id == agent.tabID }),
              let leaf = tab.layout.leaf(withID: paneID) else {
            throw TerminalControlError("That terminal is not in this agent's layout.")
        }
        guard leaf.agentID == nil, leaf.id != agent.paneID else { throw TerminalControlError("That pane is the agent's thread.") }
        return (tab, leaf)
    }

    /// Names a tab (its first pane); a blank name goes back to what it runs.
    func renameTerminalPane(_ paneID: PaneID, of agentID: AgentID, to title: String?) throws {
        let (tab, _) = try terminalLeaf(paneID, of: agentID)
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        setLayout(tab.layout.updatingLeaf(paneID) { $0.title = name?.isEmpty == false ? name : nil }, forTab: tab.id)
    }

    /// Kills the command running in a pane, leaving its shell.
    func killTerminalProcess(_ paneID: PaneID, of agentID: AgentID) async throws {
        let (_, leaf) = try terminalLeaf(paneID, of: agentID)
        guard let session = leaf.sessionID, await server.killForegroundCommand(sessionID: session) else {
            throw TerminalControlError("Nothing is running in that terminal.")
        }
    }

    // MARK: From the panel

    /// Whether the host of `target` takes the panel's own actions: this Mac always does.
    func terminalControlAvailable(_ target: TerminalTarget) -> Bool {
        guard let remote = target.remote else { return true }
        return remoteHosts.connections.first { $0.id == remote.hostID }?.supportsTerminalControl == true
    }

    /// Rename tab: asks for the name (`terminalRenameTarget`).
    func renameTerminalTab(_ tab: TerminalPanelTab, target: TerminalTarget) {
        guard terminalControlAvailable(target) else { NSSound.beep(); return }
        let current = TerminalPanels.title(row: terminalPanels.activity[target.key]?[tab.id], pane: tab.panes.first)
        terminalRenameTarget = TerminalRenameTarget(paneID: tab.id, remote: target.remote, agentID: agentID(of: target),
                                                    name: current)
    }

    func commitTerminalRename(_ rename: TerminalRenameTarget, to title: String) {
        terminalRenameTarget = nil
        if let remote = rename.remote {
            Task {
                do { try await remoteHosts.agentAction(remote, action: .renameTerminal(paneID: rename.paneID, title: title)) }
                catch { remoteActionError = String(describing: error) }
            }
            return
        }
        guard let agentID = rename.agentID else { return }
        do { try renameTerminalPane(rename.paneID, of: agentID, to: title) }
        catch { remoteActionError = String(describing: error) }
    }

    /// Kill process: the command running in the tab's focused pane.
    func killTerminalProcess(in tab: TerminalPanelTab, target: TerminalTarget) {
        let pane = TerminalPanel.focusedPane(in: tab, focused: target.focused)
        if let remote = target.remote {
            Task {
                do { try await remoteHosts.agentAction(remote, action: .killTerminalProcess(paneID: pane)) }
                catch { NSSound.beep() }
            }
            return
        }
        guard let agentID = agentID(of: target) else { return }
        Task {
            do { try await killTerminalProcess(pane, of: agentID) } catch { NSSound.beep() }
        }
    }

    /// Whether the tab's focused pane runs a command Kill process could end.
    func terminalTabIsRunning(_ tab: TerminalPanelTab, target: TerminalTarget) -> Bool {
        let pane = TerminalPanel.focusedPane(in: tab, focused: target.focused)
        return terminalPanels.activity[target.key]?[pane]?.isRunning == true
    }

    /// Where a new tab opens, for the menu: "<space> on <host>" ("payments on build-01").
    func terminalPlace(_ target: TerminalTarget) -> String {
        if let remote = target.remote, let connection = remoteHosts.connections.first(where: { $0.id == remote.hostID }) {
            let agent = connection.state.agents.first { $0.id == remote.agentID }
            let space = agent.flatMap { agent in connection.state.spaces.first { $0.id == agent.spaceID }?.name }
            return "\(space ?? "The thread's folder") on \(connection.config.name)"
        }
        let agent = state.agents.first { $0.tabID == target.key.tab }
        let space = agent.flatMap { agent in state.spaces.first { $0.id == agent.spaceID }?.name }
        return "\(space ?? "The thread's folder") on This Mac"
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
            if let pane = remoteHosts.connections.first(where: { $0.id == ref.hostID })?.state.agents
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

/// A terminal tab being renamed: its first pane, and whose layout it is in.
struct TerminalRenameTarget: Identifiable, Equatable {
    let paneID: PaneID
    let remote: RemoteAgentRef?
    let agentID: AgentID?
    let name: String
    var id: PaneID { paneID }
}
