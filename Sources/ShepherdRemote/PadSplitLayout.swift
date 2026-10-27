import CoreGraphics

/// The iPad split view's shape (iPadThread, iPadPortrait boards): side by side, or the sidebar
/// sliding over the thread; and where the thread's side pane goes (DuoOpenSidePane, DuoBookSidePane).
public enum PadSplitLayout {
    /// Whether the sidebar slides over the thread: a window taller than it is wide (portrait, or a
    /// narrow Split View or Stage Manager window). `window` is the window's whole size, measured
    /// with the keyboard ignored: the keyboard shortens what content has left, and taking that
    /// for the window's shape turned a portrait iPad into a landscape one the moment the composer
    /// took focus, which restyled the split view and dropped the focus again.
    public static func sidebarOverlays(window: CGSize) -> Bool {
        window.width < window.height
    }

    // MARK: Side pane (the Mac's `ShellLayout.rightPane`)

    /// The thread keeps at least this beside a docked pane.
    public static let threadMinWidth: CGFloat = 400
    /// The pane is never narrower than this, nor wider than `paneMaxFraction` of its column, nor
    /// wider than `paneDefaultWidth`.
    public static let paneMinWidth: CGFloat = 380
    public static let paneDefaultWidth: CGFloat = 600
    public static let paneMaxFraction: CGFloat = 0.5
    /// The hairline between the thread and the pane.
    public static let dividerWidth: CGFloat = 1
    /// The narrowest column that docks the pane beside the thread.
    public static let paneDockThreshold = threadMinWidth + dividerWidth + paneMinWidth

    /// Where the side pane goes in a column `column` wide.
    public enum PaneDock: Equatable, Sendable {
        /// Beside the thread, `width` wide; the thread takes the rest.
        case beside(width: CGFloat)
        /// The column is too narrow for both: the pane takes it, the thread behind it.
        case alone
    }

    /// The pane in a detail column `column` wide: docked while the thread keeps 400 and the pane
    /// 380, at most half the column and 600; narrower, it takes the column.
    public static func pane(column: CGFloat) -> PaneDock {
        guard column >= paneDockThreshold else { return .alone }
        let widest = min(column * paneMaxFraction, column - dividerWidth - threadMinWidth)
        return .beside(width: min(paneDefaultWidth, max(paneMinWidth, widest)))
    }

    /// Whether a docked sidebar `sidebar` wide still fits beside the thread and its open pane in
    /// a window `window` wide. It doesn't on iPhone Duo's inner display (951pt beside a 300pt
    /// sidebar), so opening the pane hides the sidebar, which comes back over the thread on
    /// demand, as in a narrow Mac window. A wide iPad keeps both.
    public static func sidebarFitsBesidePane(window: CGFloat, sidebar: CGFloat) -> Bool {
        window - sidebar - dividerWidth >= paneDockThreshold
    }

    // MARK: Across the hinge

    /// Unfolding (compact to regular) with a thread's screens pushed over it: the screens on top
    /// that are side-pane tabs (Changes, a diff, Terminal, Subagents, a run, Files, Browser) leave
    /// the stack and the pane opens beside the thread on the topmost one's tab. `tabs` is the
    /// pushed stack, each screen's tab or nil for one that isn't a tab. Nil when the top screen
    /// isn't a tab, so the stack stays as it is.
    public static func unfold(_ tabs: [PadSidePaneTab?]) -> (keep: Int, tab: PadSidePaneTab)? {
        guard let top = tabs.last ?? nil else { return nil }
        let keep = tabs.lastIndex { $0 == nil }.map { $0 + 1 } ?? 0
        return (keep, top)
    }
}

/// The side pane's tabs (DuoSidePaneTabs board; the Mac's `SidePaneTab`): Changes, Files,
/// Terminal, Subagents and Browser always, Artifacts once the thread has made one.
public enum PadSidePaneTab: String, CaseIterable, Codable, Hashable, Sendable {
    case changes, files, terminal, subagents, browser, artifacts

    public var title: String {
        switch self {
        case .changes: "Changes"
        case .files: "Files"
        case .terminal: "Terminal"
        case .subagents: "Subagents"
        case .browser: "Browser"
        case .artifacts: "Artifacts"
        }
    }

    /// The tabs a thread's pane shows, in order.
    public static func shown(artifacts: Bool) -> [PadSidePaneTab] {
        artifacts ? allCases : allCases.filter { $0 != .artifacts }
    }
}
