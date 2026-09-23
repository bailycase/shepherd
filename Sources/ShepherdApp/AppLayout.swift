import SwiftUI
import ShepherdUI

/// Surface dimensions of the Mac app's screens: window, sidebar, header, thread, tool rows,
/// right pane, review, palette, settings. The shared scales (space, radius, control heights)
/// are Night Watch's `NW`; these are the app's own layout and change with its screens. Rows
/// marked density-scaled follow Settings ▸ Appearance ▸ Density.
enum AppLayout {
    // Window
    static let windowMinWidth: CGFloat = 1040
    static let windowMinHeight: CGFloat = 640
    static let windowDefaultWidth: CGFloat = 1440
    static let windowDefaultHeight: CGFloat = 900
    static let mainColumnMinWidth: CGFloat = 720
    static let trafficLightHeight: CGFloat = 38

    // Sidebar
    static let sidebarDefaultWidth: CGFloat = 256
    static let sidebarPadding: CGFloat = 8
    /// Denser than the design's 28pt row: a real fleet needs the rows. Density-scaled.
    @MainActor static var sidebarRowHeight: CGFloat { NW.Height.scaled(26) }
    static let sidebarIndent: CGFloat = 16

    // Header
    static let headerHeight: CGFloat = 52
    static let headerPadding: CGFloat = 20

    // Thread, activity lines, and the composer: AppLayout+Thread.swift

    // Right pane (review and subagent inspector share the slot)
    static let paneDefaultWidth: CGFloat = 600
    static let paneMinWidth: CGFloat = 480
    static let paneMaxFraction: CGFloat = 0.5
    static let fileStripHeight: CGFloat = 34
    static let fileHeaderHeight: CGFloat = 36
    static let diffLineHeight: CGFloat = 21
    static let diffNumberWidth: CGFloat = 36
    static let diffSignWidth: CGFloat = 14
    static let diffCollapsedRunHeight: CGFloat = 24
    static let diffCollapseThreshold = 8

    // Subagents
    static let subagentHeaderHeight: CGFloat = 40
    static let ledgerHeaderHeight: CGFloat = 36
    static let ledgerRowHeight: CGFloat = 44
    static let ledgerNameWidth: CGFloat = 72
    static let runCell: CGFloat = 8

    // Palette and settings
    static let paletteWidth: CGFloat = 640
    static let paletteTop: CGFloat = 120
    static let paletteSearchHeight: CGFloat = 56
    static let paletteRowHeight: CGFloat = 38
    static let settingsNavWidth: CGFloat = 232
    static let settingsContentWidth: CGFloat = 720
    static let settingsTop: CGFloat = 44
    /// Density-scaled.
    @MainActor static var settingsRowMinHeight: CGFloat { NW.Height.scaled(52) }
}
