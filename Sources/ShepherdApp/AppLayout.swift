import SwiftUI
import ShepherdUI

/// Surface dimensions of the Mac app's screens: window, sidebar, header, thread, tool rows,
/// right pane, review, palette, settings. The shared scales (space, radius, control heights)
/// are Night Watch's `NW`; these are the app's own layout and change with its screens. Rows
/// marked density-scaled follow Settings ▸ Appearance ▸ Density.
enum AppLayout {
    // Window, sidebar, toolbar, right pane, palette: AppLayout+Navigation.swift.

    // Thread, activity lines, and the composer: AppLayout+Thread.swift

    // Review
    static let fileStripHeight: CGFloat = 34
    static let fileHeaderHeight: CGFloat = 36
    static let diffLineHeight: CGFloat = 21
    static let diffNumberWidth: CGFloat = 36
    static let diffSignWidth: CGFloat = 14
    static let diffCollapsedRunHeight: CGFloat = 24
    static let diffCollapseThreshold = 8

    // Settings
    static let settingsNavWidth: CGFloat = 232
    static let settingsContentWidth: CGFloat = 720
    static let settingsTop: CGFloat = 44
    /// Density-scaled.
    @MainActor static var settingsRowMinHeight: CGFloat { NW.Height.scaled(52) }
}
