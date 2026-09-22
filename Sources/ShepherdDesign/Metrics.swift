import SwiftUI

/// Sizes from the design handoff (§3 layout, §5 tool rows, §9 review pane, §10 subagents, §12
/// palette and settings). Row heights scale with the density setting; everything else is fixed.
public enum Metrics {
    @MainActor private static var density: CGFloat { ThemeStore.shared.density }

    // Spacing (2pt base): inside a row 8–12, between rows 2, between turns 28, panels 12–16.
    public static let space2: CGFloat = 2
    public static let space4: CGFloat = 4
    public static let space6: CGFloat = 6
    public static let space8: CGFloat = 8
    public static let space10: CGFloat = 10
    public static let space12: CGFloat = 12
    public static let space16: CGFloat = 16
    public static let space20: CGFloat = 20
    public static let space24: CGFloat = 24
    public static let space28: CGFloat = 28
    public static let space32: CGFloat = 32

    // Window
    public static let windowMinWidth: CGFloat = 1040
    public static let windowMinHeight: CGFloat = 640
    public static let windowDefaultWidth: CGFloat = 1440
    public static let windowDefaultHeight: CGFloat = 900
    public static let mainColumnMinWidth: CGFloat = 720
    public static let trafficLightHeight: CGFloat = 38

    // Sidebar
    public static let sidebarDefaultWidth: CGFloat = 256
    /// While a right pane (review or inspector) is open.
    public static let sidebarCompactWidth: CGFloat = 184
    public static let sidebarPadding: CGFloat = 8
    @MainActor public static var sidebarRowHeight: CGFloat { (32 * density).rounded() }
    @MainActor public static var sidebarRowHeightCompact: CGFloat { (26 * density).rounded() }
    public static let sidebarIndent: CGFloat = 22
    public static let sidebarIndentCompact: CGFloat = 16
    public static let statusDot: CGFloat = 7
    public static let statusDotCompact: CGFloat = 6

    // Header
    public static let headerHeight: CGFloat = 52
    public static let headerPadding: CGFloat = 20

    // Thread
    public static let threadMaxWidth: CGFloat = 760
    /// Agent prose stays ~85 characters even though the column is wider.
    public static let proseMaxWidth: CGFloat = 680
    public static let userMaxWidth: CGFloat = 600
    public static let gutter: CGFloat = 32
    /// Gutter when the window is too narrow for the column plus the full gutter.
    public static let gutterCompact: CGFloat = 16
    public static let threadTop: CGFloat = 28
    public static let turnSpacing: CGFloat = 28
    public static let blockSpacing: CGFloat = 10
    /// Auto-scroll follows the tail only within this distance of the bottom.
    public static let followThreshold: CGFloat = 80
    public static let workingRowHeight: CGFloat = 28

    // Tool rows
    public static let toolRowHeight: CGFloat = 36
    /// Inside the subagent inspector the transcript is one step smaller.
    public static let toolRowHeightSmall: CGFloat = 34
    public static let toolNameWidth: CGFloat = 40
    public static let toolOutputIndent: CGFloat = 62
    public static let toolOutputMaxLines = 12
    public static let statusGlyph: CGFloat = 14

    // Controls
    public static let buttonSmall: CGFloat = 28
    public static let buttonMedium: CGFloat = 30
    public static let buttonLarge: CGFloat = 32
    public static let chipHeight: CGFloat = 32
    public static let attachmentChipHeight: CGFloat = 28
    public static let segmentHeight: CGFloat = 26
    public static let segmentHeightSmall: CGFloat = 22
    public static let switchWidth: CGFloat = 38
    public static let switchHeight: CGFloat = 22
    public static let fieldHeight: CGFloat = 30

    // Composer and its menus
    public static let composerMaxRows = 8
    public static let menuRowHeight: CGFloat = 36
    public static let menuMaxRows = 8
    public static let modelPickerWidth: CGFloat = 380
    public static let modelRowHeight: CGFloat = 40

    // Right pane (review and subagent inspector share the slot)
    public static let paneDefaultWidth: CGFloat = 600
    public static let paneMinWidth: CGFloat = 480
    public static let paneMaxFraction: CGFloat = 0.5
    public static let fileStripHeight: CGFloat = 34
    public static let fileHeaderHeight: CGFloat = 36
    public static let diffLineHeight: CGFloat = 21
    public static let diffNumberWidth: CGFloat = 36
    public static let diffSignWidth: CGFloat = 14
    public static let diffCollapsedRunHeight: CGFloat = 24
    public static let diffCollapseThreshold = 8

    // Subagents
    public static let subagentHeaderHeight: CGFloat = 40
    public static let ledgerHeaderHeight: CGFloat = 36
    public static let ledgerRowHeight: CGFloat = 44
    public static let ledgerNameWidth: CGFloat = 72
    public static let runCell: CGFloat = 8
    public static let progressHeight: CGFloat = 4

    // Palette and settings
    public static let paletteWidth: CGFloat = 640
    public static let paletteTop: CGFloat = 120
    public static let paletteSearchHeight: CGFloat = 56
    public static let paletteRowHeight: CGFloat = 38
    public static let settingsNavWidth: CGFloat = 232
    public static let settingsContentWidth: CGFloat = 720
    public static let settingsTop: CGFloat = 44
    @MainActor public static var settingsRowMinHeight: CGFloat { (52 * density).rounded() }
}

public enum Radius {
    /// Inline code, keycaps.
    public static let xs: CGFloat = 4
    /// Rows.
    public static let sm: CGFloat = 6
    /// Small and medium buttons.
    public static let button: CGFloat = 7
    /// Large buttons, menus' rows, inline cards.
    public static let md: CGFloat = 8
    /// Groups (tool groups, settings cards).
    public static let lg: CGFloat = 10
    /// Composer, menus, bubbles.
    public static let xl: CGFloat = 12
    /// The command palette.
    public static let xxl: CGFloat = 14
    /// The user bubble's trailing-bottom corner.
    public static let bubbleTail: CGFloat = 4
    public static let pill: CGFloat = 999
}
