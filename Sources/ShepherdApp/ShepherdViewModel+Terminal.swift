import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The terminal panel under the thread (TerminalSplit, TerminalStates boards): show or hide it
/// (⌘J), maximize it (⇧⌘↩), and its tabs, one terminal each. Every change goes through the layout:
/// a new terminal is a leaf beside the thread, closing a tab closes its terminal; for a remote
/// agent, through its host's requests. ⌘J with no terminal opens one, so the panel is never empty.
extension ShepherdViewModel {
    /// The layout on screen, as the panel sees it.
    struct TerminalTarget {
        let key: TerminalPanelKey
        let layout: PaneNode
        let thread: PaneID?
        let remote: RemoteAgentRef?
        let focused: PaneID?

        /// The terminals in the layout, one tab each.
        var tabs: [TerminalPanelTab] { TerminalPanel.tabs(in: layout, thread: thread) }
    }

    /// The layout on screen, its panel brought up to date with it first (the views do the same as
    /// they draw; an action may come before a draw).
    var terminalTarget: TerminalTarget? {
        guard let target = unreconciledTerminalTarget else { return nil }
        terminalPanels.reconcile(target.key, layout: target.layout, thread: target.thread)
        return target
    }

    var unreconciledTerminalTarget: TerminalTarget? {
        if let remote = selectedRemoteAgent {
            guard remoteInspectingAgent != remote,
                  let connection = remoteHosts.connections.first(where: { $0.id == remote.hostID }),
                  let agent = connection.state.agents.first(where: { $0.id == remote.agentID }),
                  let tab = connection.state.tabs.first(where: { $0.id == agent.tabID }) else { return nil }
            return TerminalTarget(key: TerminalPanelKey(host: remote.hostID, tab: tab.id), layout: tab.layout,
                                  thread: agent.paneID, remote: remote, focused: remoteFocusedPaneID)
        }
        // A design's screen is its canvas and chat: it has no terminal panel.
        guard let tab = activeTab, let agent = selectedAgent, agent.tabID == tab.id, design(drawnBy: agent) == nil else { return nil }
        return TerminalTarget(key: TerminalPanelKey(host: nil, tab: tab.id), layout: tab.layout, thread: agent.paneID,
                              remote: nil, focused: focusedPaneID)
    }

    var isTerminalPanelShowing: Bool {
        unreconciledTerminalTarget.map { terminalPanels.panel($0.key).shown } ?? false
    }

    /// ⌘J, the Terminal menu and the palette (the terminal has no header button). Showing it puts
    /// the keyboard in its terminal, and with no terminal yet opens one; hiding it gives the
    /// keyboard back to the thread.
    func toggleTerminalPanel() {
        guard let target = terminalTarget else { NSSound.beep(); return }
        if terminalPanels.panel(target.key).shown {
            terminalPanels.update(target.key) {
                $0.shown = false
                $0.maximized = false
            }
            if let thread = target.thread { focusTerminal(thread, target: target) }
            return
        }
        guard let tab = selectedTerminalTab(target) else {
            newTerminalTab(target)
            return
        }
        terminalPanels.update(target.key) { $0.shown = true }
        focusTerminal(tab.id, target: target)
    }

    /// ⇧⌘↩: the panel takes the layout and the thread folds away, or comes back. With no
    /// terminal there is nothing to maximize.
    func toggleTerminalMaximized() {
        guard let target = terminalTarget, !target.tabs.isEmpty else { NSSound.beep(); return }
        terminalPanels.update(target.key) {
            $0.maximized = !$0.maximized || !$0.shown
            $0.shown = true
        }
    }

    func selectedTerminalTab(_ target: TerminalTarget) -> TerminalPanelTab? {
        terminalPanels.selectedTab(target.key, layout: target.layout, thread: target.thread, focused: target.focused)
    }

    func selectTerminalTab(_ tab: TerminalPanelTab, target: TerminalTarget) {
        terminalPanels.choose(tab, in: target.key)
        focusTerminal(tab.id, target: target)
    }

    /// ⇧⌘] and ⇧⌘[: the next or previous tab, wrapping, while the panel shows more than one.
    func selectAdjacentTerminal(_ delta: Int) {
        guard let target = terminalTarget, terminalPanels.panel(target.key).shown,
              let tab = TerminalPanel.adjacent(to: selectedTerminalTab(target), in: target.tabs, delta: delta) else { return }
        selectTerminalTab(tab, target: target)
    }

    /// ⌘D, + and the New Terminal menu rows: a new terminal in the thread's folder (its
    /// worktree), which the panel shows as a new tab and which takes the keyboard. A remote
    /// agent's is made by its host; a failure beeps and shows nothing.
    func newTerminalTab(_ target: TerminalTarget? = nil) {
        guard let target = target ?? terminalTarget else { NSSound.beep(); return }
        let anchor = TerminalPanel.newTabAnchor(in: target.layout, thread: target.thread)
        openTerminal(target, beside: anchor.pane, axis: anchor.axis)
    }

    /// Closes a tab's terminal, as ⌘W does (never the thread's).
    func closeTerminalTab(_ tab: TerminalPanelTab, target: TerminalTarget) {
        guard tab.id != target.thread else { NSSound.beep(); return }
        if let remote = target.remote {
            Task {
                do {
                    try await remoteHosts.closePane(hostID: remote.hostID, agentID: remote.agentID, paneID: tab.id)
                    if let thread = target.thread { remoteFocusedPaneID = thread }
                } catch { NSSound.beep() }
            }
            return
        }
        // The keyboard goes back to the thread, the layout's first leaf (`closeLocalPane`).
        if !closeLocalPane(tab.id) { NSSound.beep() }
    }

    /// The host is asked to open the terminal beside `anchor`: a current host opens a tab and
    /// ignores where, an older one splits the anchor (the thread) to make one.
    private func openTerminal(_ target: TerminalTarget, beside anchor: PaneID, axis: SplitAxis) {
        if let remote = target.remote {
            Task {
                do {
                    let pane = try await remoteHosts.openPane(hostID: remote.hostID, agentID: remote.agentID, relativeTo: anchor, axis: axis)
                    remoteFocusedPaneID = pane
                } catch { NSSound.beep() }
            }
            return
        }
        guard let tab = state.tabs.first(where: { $0.id == target.key.tab }), let leaf = tab.layout.leaf(withID: anchor) else {
            NSSound.beep()
            return
        }
        do { try verifyCheckoutAvailable(leaf.cwd) }
        catch { remoteActionError = String(describing: error); return }
        let terminal = LeafPane(cwd: leaf.cwd)
        guard let layout = tab.layout.splitting(pane: anchor, axis: axis, newPane: terminal) else { NSSound.beep(); return }
        setLayout(layout, forTab: tab.id)
        focusedPaneID = terminal.id
        terminalPanels.reconcile(target.key, layout: layout, thread: target.thread)
    }

    private func focusTerminal(_ pane: PaneID, target: TerminalTarget) {
        if target.remote != nil { remoteFocusedPaneID = pane } else { focusedPaneID = pane }
    }
}
