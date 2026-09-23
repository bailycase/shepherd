import SwiftUI
import ShepherdUI

/// Surface dimensions of the Mac app's screens, split by domain into AppLayout+*.swift. The shared scales (space, radius, control heights)
/// are Night Watch's `NW`; these are the app's own layout and change with its screens. Rows
/// marked density-scaled follow Settings ▸ Appearance ▸ Density.
enum AppLayout {
    // Window, sidebar, toolbar, right pane, palette: AppLayout+Navigation.swift.

    // Thread, activity lines, and the composer: AppLayout+Thread.swift

    // Review: diff rows are ShepherdUI NWDiff* metrics.
    static let diffCollapseThreshold = 8

    // Settings and sheets: AppLayout+Settings.swift
}
