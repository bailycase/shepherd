import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The terminal panel under the thread (TerminalSplit, TerminalStates boards): show or hide it
/// (⌘J), maximize it (⇧⌘↩), and its tabs. Every change to the panes goes through the layout as
/// before: + splits the thread (a new tab), Split right splits a pane in the tab, closing a tab
/// closes its panes; for a remote agent, through its host's pane requests.
extension ShepherdViewModel {
    /// The layout on screen, as the panel sees it.
    struct TerminalTarget {
        let key: TerminalPanelKey
        let layout: PaneNode
        let thread: PaneID?
        let remote: RemoteAgentRef?
        let focused: PaneID?
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

    /// ⌘J, the Pane menu and the palette (the terminal has no header button). Showing it puts
    /// the keyboard in its terminal; hiding it gives the keyboard back to the thread.
    func toggleTerminalPanel() {
        guard let target = terminalTarget else { NSSound.beep(); return }
        let shown = !terminalPanels.panel(target.key).shown
        terminalPanels.update(target.key) {
            $0.shown = shown
            if !shown { $0.maximized = false }
        }
        if shown, let tab = selectedTerminalTab(target) {
            focusTerminalPane(TerminalPanel.focusedPane(in: tab, focused: target.focused), target: target)
        } else if !shown, let thread = target.thread {
            focusTerminalPane(thread, target: target)
        }
    }

    /// ⇧⌘↩: the panel takes the layout and the thread folds away, or comes back.
    func toggleTerminalMaximized() {
        guard let target = terminalTarget else { NSSound.beep(); return }
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
        focusTerminalPane(TerminalPanel.focusedPane(in: tab, focused: target.focused), target: target)
    }

    /// + : a new pane beside the thread, which the panel shows as a new tab.
    func newTerminalTab(_ target: TerminalTarget? = nil) {
        guard let target = target ?? terminalTarget else { NSSound.beep(); return }
        let anchor = TerminalPanel.newTabAnchor(in: target.layout, thread: target.thread)
        openTerminalPane(target, beside: anchor.pane, axis: anchor.axis)
    }

    /// Split right: a new pane beside the tab's focused pane.
    func splitTerminal(_ target: TerminalTarget? = nil) {
        guard let target = target ?? terminalTarget, let tab = selectedTerminalTab(target) else {
            newTerminalTab(target)
            return
        }
        openTerminalPane(target, beside: TerminalPanel.splitAnchor(in: tab, focused: target.focused), axis: .vertical)
    }

    /// Closes every pane of a tab, as ⌘W closes one (never the thread's, never the last).
    func closeTerminalTab(_ tab: TerminalPanelTab, target: TerminalTarget) {
        let panes = TerminalPanel.panesToClose(tab, thread: target.thread)
        if let remote = target.remote {
            Task {
                for pane in panes {
                    do { try await remoteHosts.closePane(hostID: remote.hostID, agentID: remote.agentID, paneID: pane) }
                    catch { NSSound.beep(); return }
                }
                if let thread = target.thread { remoteFocusedPaneID = thread }
            }
            return
        }
        for pane in panes where !closeLocalPane(pane) { NSSound.beep() }
        if let thread = target.thread, let focused = focusedPaneID, panes.contains(focused) { focusedPaneID = thread }
    }

    private func openTerminalPane(_ target: TerminalTarget, beside anchor: PaneID, axis: SplitAxis) {
        if let remote = target.remote {
            Task {
                do {
                    let pane = try await remoteHosts.openPane(hostID: remote.hostID, agentID: remote.agentID, relativeTo: anchor, axis: axis)
                    remoteFocusedPaneID = pane
                } catch { NSSound.beep() }
            }
            return
        }
        guard let tab = state.tabs.first(where: { $0.id == target.key.tab }), let leaf = tab.layout.leaf(withID: anchor) else { return }
        do { try verifyCheckoutAvailable(leaf.cwd) }
        catch { remoteActionError = String(describing: error); return }
        let pane = LeafPane(cwd: leaf.cwd)
        guard let layout = tab.layout.splitting(pane: anchor, axis: axis, newPane: pane) else { return }
        setLayout(layout, forTab: tab.id)
        focusedPaneID = pane.id
    }

    private func focusTerminalPane(_ pane: PaneID, target: TerminalTarget) {
        if target.remote != nil { remoteFocusedPaneID = pane } else { focusedPaneID = pane }
    }

    /// The panes on screen in a layout, in order: its thread (unless the panel is maximized) and,
    /// while the panel shows, the selected tab's. ⌥⌘←/→ move among these.
    func visiblePanes(layout: PaneNode, key: TerminalPanelKey, thread: PaneID?, focused: PaneID?) -> [PaneID] {
        guard let thread, layout.contains(thread) else { return layout.leaves.map(\.id) }
        terminalPanels.reconcile(key, layout: layout, thread: thread)
        let panel = terminalPanels.panel(key)
        var panes = panel.shown && panel.maximized ? [] : [thread]
        if panel.shown, let tab = terminalPanels.selectedTab(key, layout: layout, thread: thread, focused: focused) {
            panes += tab.panes.map(\.id)
        }
        return panes
    }
}
