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
                  let connection = remoteHosts.allConnections.first(where: { $0.id == remote.hostID }),
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
        guard let target = terminalTarget, !panelTabs(target).isEmpty else { NSSound.beep(); return }
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

    /// The panel's tabs: the layout's terminals, then any app output tabs.
    func panelTabs(_ target: TerminalTarget) -> [TerminalPanelTab] {
        terminalPanels.tabs(target.key, layout: target.layout, thread: target.thread)
    }

    /// ⇧⌘] and ⇧⌘[: the next or previous tab, wrapping, while the panel shows more than one.
    func selectAdjacentTerminal(_ delta: Int) {
        guard let target = terminalTarget, terminalPanels.panel(target.key).shown,
              let tab = TerminalPanel.adjacent(to: selectedTerminalTab(target), in: panelTabs(target), delta: delta) else { return }
        selectTerminalTab(tab, target: target)
    }

    /// ⌘D, + and the New Terminal menu rows: a new terminal in the thread's folder (its
    /// worktree). Its tab opens at once, selected and Starting, with the keyboard on no shell;
    /// the host makes the terminal, and the tab becomes it (`TerminalTabOverlay`). A remote
    /// agent's is made by its host; a failure takes the tab back and gives back what it took.
    func newTerminalTab(_ target: TerminalTarget? = nil) {
        guard let target = target ?? terminalTarget, let ref = terminalRef(target) else { NSSound.beep(); return }
        let anchor = TerminalPanel.newTabAnchor(in: target.layout, thread: target.thread)
        let key = target.key
        let placeholder = beginOpenTerminal(target)
        Task { [weak self] in
            do {
                let real = try await self?.requestOpenTerminal(ref, beside: anchor.pane, axis: anchor.axis)
                if let real { self?.finishOpenTerminal(placeholder, real: real, key: key, ref: ref) }
            } catch {
                self?.failOpenTerminal(placeholder, key: key, error: error)
            }
        }
    }

    /// Closes a tab's terminal, as ⌘W does (never the thread's). The tab goes at once and the
    /// keyboard returns to the thread; if the host refuses, the tab comes back.
    func closeTerminalTab(_ tab: TerminalPanelTab, target: TerminalTarget) {
        if terminalPanels.appKey(tab.id) != nil {
            let terminals = TerminalPanel.tabs(in: target.layout, thread: target.thread, overlay: terminalPanels.overlay(target.key)).count
            terminalPanels.closeApp(tab.id, in: target.key, terminals: terminals)
            return
        }
        if terminalPanels.isStarting(tab.id, in: target.key) {
            abandonStartingTerminal(tab.id, key: target.key)
            return
        }
        guard tab.id != target.thread, let ref = terminalRef(target) else { NSSound.beep(); return }
        closeTerminalPane(tab.id, key: target.key, ref: ref, thread: target.thread, layout: target.layout)
    }

    // MARK: Opening ahead of the host

    /// What the panel asks of a host, which a test replaces to hold a reply back or refuse it.
    struct TerminalRequests {
        var open: @MainActor (RemoteAgentRef, PaneID, SplitAxis) async throws -> PaneID
        var close: @MainActor (RemoteAgentRef, PaneID) async throws -> Void
    }

    /// Where a target's requests go: the agent's host, which for a local agent is the background host.
    func terminalRef(_ target: TerminalTarget) -> RemoteAgentRef? {
        if let remote = target.remote { return remote }
        return state.agents.first { $0.tabID == target.key.tab }.flatMap { localRef($0.id) }
    }

    /// The pushed layout of a panel, and its thread.
    func terminalLayout(_ key: TerminalPanelKey) -> (layout: PaneNode, thread: PaneID?)? {
        if let host = key.host {
            guard let connection = remoteHosts.allConnections.first(where: { $0.id == host }),
                  let tab = connection.state.tabs.first(where: { $0.id == key.tab }) else { return nil }
            return (tab.layout, connection.state.agents.first { $0.tabID == tab.id }?.paneID)
        }
        guard let tab = state.tabs.first(where: { $0.id == key.tab }) else { return nil }
        return (tab.layout, state.agents.first { $0.tabID == tab.id }?.paneID)
    }

    private func terminalFocus(_ key: TerminalPanelKey) -> PaneID? {
        key.host == nil ? focusedPaneID : remoteFocusedPaneID
    }

    private func setTerminalFocus(_ pane: PaneID?, _ key: TerminalPanelKey) {
        if key.host == nil { focusedPaneID = pane } else { remoteFocusedPaneID = pane }
    }

    /// Brings a panel up to date with its layout and what is in flight for it.
    func reconcileTerminalPanel(_ key: TerminalPanelKey) {
        guard let found = terminalLayout(key) else { return }
        terminalPanels.reconcile(key, layout: found.layout, thread: found.thread)
    }

    /// Every panel with a tab in flight, brought up to date with the layout the host just pushed.
    func reconcileOpenTerminals() {
        for key in terminalPanels.overlays.keys { reconcileTerminalPanel(key) }
    }

    func requestOpenTerminal(_ ref: RemoteAgentRef, beside anchor: PaneID, axis: SplitAxis) async throws -> PaneID {
        if let terminalRequests { return try await terminalRequests.open(ref, anchor, axis) }
        return try await remoteHosts.openPane(hostID: ref.hostID, agentID: ref.agentID, relativeTo: anchor, axis: axis)
    }

    func requestCloseTerminal(_ ref: RemoteAgentRef, pane: PaneID) async throws {
        if let terminalRequests { return try await terminalRequests.close(ref, pane) }
        try await remoteHosts.closePane(hostID: ref.hostID, agentID: ref.agentID, paneID: pane)
    }

    /// The tab opens: selected, the panel shown, the keyboard on the placeholder (no pane, so no
    /// shell takes what is typed). Returns the placeholder.
    private func beginOpenTerminal(_ target: TerminalTarget) -> PaneID {
        let key = target.key
        let raw = TerminalPanel.tabs(in: target.layout, thread: target.thread).map(\.id)
        let cwd = target.thread.flatMap { target.layout.leaf(withID: $0)?.cwd } ?? target.layout.firstLeaf.cwd
        let before = (chosen: terminalPanels.panel(key).chosenTab, focus: terminalFocus(key))
        let placeholder = terminalPanels.updateOverlay(key) {
            $0.beginOpen(layout: raw, cwd: cwd, previousChosen: before.chosen, previousFocus: before.focus)
        }
        terminalPanels.update(key) {
            $0.shown = true
            $0.chosenTab = placeholder
        }
        setTerminalFocus(placeholder, key)
        terminalPanels.reconcile(key, layout: target.layout, thread: target.thread)
        return placeholder
    }

    /// The host made `real`. The tab becomes it once the layout holds it, and only then does the
    /// keyboard move: someone who went elsewhere meanwhile is left there.
    private func finishOpenTerminal(_ placeholder: PaneID, real: PaneID, key: TerminalPanelKey, ref: RemoteAgentRef) {
        switch terminalPanels.updateOverlay(key, { $0.opened(placeholder, real: real) }) {
        case .close(let pane):
            // Closed while it started: the pane the host made goes too.
            sendCloseTerminal(pane, key: key, ref: ref)
        case .adopted, .unknown:
            break
        }
        reconcileTerminalPanel(key)
    }

    /// The host refused: the tab goes, and the selection and keyboard go back to what they were
    /// if they were still on it.
    private func failOpenTerminal(_ placeholder: PaneID, key: TerminalPanelKey, error: Error) {
        guard let pending = terminalPanels.updateOverlay(key, { $0.openFailed(placeholder) }) else { return }
        terminalPanels.update(key) { if $0.chosenTab == placeholder { $0.chosenTab = pending.previousChosen } }
        if terminalFocus(key) == placeholder { setTerminalFocus(pending.previousFocus, key) }
        reconcileTerminalPanel(key)
        if key.host == nil { fail("Couldn’t open a terminal", error) } else { NSSound.beep() }
    }

    // MARK: Closing ahead of the host

    /// A tab that is still Starting is closed: it goes at once, and the terminal the host makes
    /// for it is closed when its reply comes.
    func abandonStartingTerminal(_ placeholder: PaneID, key: TerminalPanelKey) {
        let outcome = terminalPanels.updateOverlay(key) { $0.abandon(placeholder) }
        let home = terminalLayout(key).map { $0.thread ?? $0.layout.firstLeaf.id }
        terminalPanels.update(key) { if $0.chosenTab == placeholder { $0.chosenTab = nil } }
        if terminalFocus(key) == placeholder { setTerminalFocus(home, key) }
        if case .close(let pane) = outcome, let ref = terminalRef(forPanel: key) {
            sendCloseTerminal(pane, key: key, ref: ref)
        }
        reconcileTerminalPanel(key)
    }

    private func terminalRef(forPanel key: TerminalPanelKey) -> RemoteAgentRef? {
        if let host = key.host {
            return remoteHosts.allConnections.first { $0.id == host }?.state.agents.first { $0.tabID == key.tab }
                .map { RemoteAgentRef(hostID: host, agentID: $0.id) }
        }
        return state.agents.first { $0.tabID == key.tab }.flatMap { localRef($0.id) }
    }

    /// Closes a terminal pane: the tab leaves at once and the keyboard goes to the thread if it
    /// was on the tab. The host's refusal brings the tab back, without moving the keyboard again.
    func closeTerminalPane(_ pane: PaneID, key: TerminalPanelKey, ref: RemoteAgentRef, thread: PaneID?, layout: PaneNode) {
        let selected = terminalPanels.selectedTab(key, layout: layout, thread: thread, focused: terminalFocus(key))?.id
        guard terminalPanels.updateOverlay(key, { $0.beginClose(pane) }) else { return }
        let home = thread.flatMap { layout.contains($0) ? $0 : nil } ?? layout.closing(pane: pane)?.firstLeaf.id ?? layout.firstLeaf.id
        terminalPanels.update(key) { if $0.chosenTab == pane { $0.chosenTab = nil } }
        if terminalFocus(key) == pane || selected == pane { setTerminalFocus(home, key) }
        terminalPanels.closeRestoresPanel[key] = terminalPanels.panel(key).shown
        terminalPanels.reconcile(key, layout: layout, thread: thread)
        sendCloseTerminal(pane, key: key, ref: ref)
    }

    private func sendCloseTerminal(_ pane: PaneID, key: TerminalPanelKey, ref: RemoteAgentRef) {
        Task { [weak self] in
            do {
                try await self?.requestCloseTerminal(ref, pane: pane)
                self?.terminalPanels.updateOverlay(key) { $0.closeConfirmed(pane) }
                self?.terminalPanels.closeRestoresPanel[key] = nil
            } catch {
                self?.failCloseTerminal(pane, key: key, error: error)
            }
            self?.reconcileTerminalPanel(key)
        }
    }

    /// The host kept the terminal: its tab is back where it was. Nothing is selected or focused
    /// by this, since the person has moved on; a panel that closed for it opens again.
    private func failCloseTerminal(_ pane: PaneID, key: TerminalPanelKey, error: Error) {
        terminalPanels.updateOverlay(key) { $0.closeFailed(pane) }
        reconcileTerminalPanel(key)
        if terminalPanels.closeRestoresPanel.removeValue(forKey: key) == true, !terminalPanels.panel(key).shown,
           let found = terminalLayout(key), !terminalPanels.tabs(key, layout: found.layout, thread: found.thread).isEmpty {
            terminalPanels.update(key) { $0.shown = true }
        }
        if key.host == nil { fail("Couldn’t close the terminal", error) } else { NSSound.beep() }
    }

    private func focusTerminal(_ pane: PaneID, target: TerminalTarget) {
        // An app's output is a view, not a terminal: the keyboard stays where it is.
        guard terminalPanels.appKey(pane) == nil else { return }
        if target.remote != nil { remoteFocusedPaneID = pane } else { focusedPaneID = pane }
    }
}
