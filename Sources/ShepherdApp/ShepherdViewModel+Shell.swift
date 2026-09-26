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

/// The side pane's state, as the toolbar and tests read it.
extension ShepherdViewModel {
    /// The Changes tab is on screen.
    var isReviewPaneShowing: Bool { rightPaneContent == .review }
}
