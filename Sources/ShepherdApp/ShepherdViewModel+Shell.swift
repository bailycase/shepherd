import Foundation

/// The window shell: the sidebar's docked, hidden, and overlaid states (`ShellLayout`).
extension ShepherdViewModel {
    /// Whether the sidebar is on screen, docked or overlaid.
    var isSidebarVisible: Bool { sidebarAutoHidden ? sidebarOverlayShown : !sidebarHidden }

    /// ⇧⌘S, the toolbar's sidebar button, the palette. In a window too narrow to dock the
    /// sidebar it overlays instead, and the docked preference is left alone.
    func toggleSidebar() {
        if sidebarAutoHidden { sidebarOverlayShown.toggle() } else { sidebarHidden.toggle() }
    }

    /// The window crossed the sidebar's fit point. An overlay never survives into a docked
    /// layout.
    func setSidebarAutoHidden(_ autoHidden: Bool) {
        guard autoHidden != sidebarAutoHidden else { return }
        sidebarAutoHidden = autoHidden
        if sidebarOverlayShown { sidebarOverlayShown = false }
    }

    /// The overlaid sidebar closes once it has done its job (a selection) or loses focus.
    func dismissSidebarOverlay() {
        if sidebarOverlayShown { sidebarOverlayShown = false }
    }
}

/// The toolbar's pane toggles: each lights up while its own pane is showing.
extension ShepherdViewModel {
    var isReviewPaneShowing: Bool { rightPaneContent == .review }

    var isInspectorShowing: Bool {
        if case .inspector = rightPaneContent { return true }
        return false
    }

    /// Review toggle: closes the review when it is showing; otherwise shows it (closing an
    /// inspector that covers it, or opening a review).
    func toggleReviewPane() {
        if isInspectorShowing {
            closeInspector()
            if rightPaneContent == .review { return }
        }
        openUserReview()
    }

    /// Subagents toggle: closes the inspector, or inspects the thread's current subagent (⌘I).
    func toggleSubagentPane() {
        if isInspectorShowing { closeInspector() } else { sendThreadCommand(.inspectSubagent) }
    }

    private func closeInspector() {
        if let remote = selectedRemoteAgent { subagentInspector.remoteRuns.removeValue(forKey: remote) }
        else if let id = selectedAgentID { subagentInspector.runByAgent.removeValue(forKey: id) }
    }
}
