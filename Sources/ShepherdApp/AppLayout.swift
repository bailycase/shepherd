import SwiftUI
import ShepherdUI

/// Surface dimensions of the Mac app's screens, split by domain into AppLayout+*.swift. The shared scales (space, radius, control heights)
/// are Night Watch's `NW`; these are the app's own layout and change with its screens. Rows
/// marked density-scaled follow Settings ▸ Appearance ▸ Density.
enum AppLayout {
    // Window, sidebar, toolbar, right pane, palette: AppLayout+Navigation.swift.

    // Thread, activity lines, and the composer: AppLayout+Thread.swift

    // Review: diff rows are ShepherdUI NWDiff* metrics; runs fold past `reviewCollapseThreshold`.
    /// "Loading the diff…"'s spinner.
    static let reviewLoadingSpinner: CGFloat = 12

    // Settings and sheets: AppLayout+Settings.swift

    // Component Gallery (Debug builds), laid out like the boards: page margins, three 400pt
    // columns, the gaps between a column's blocks and between items in a row, and bar widths.
    static let galleryGutter: CGFloat = 48
    static let galleryTop: CGFloat = 40
    static let galleryColumnWidth: CGFloat = 400
    static let galleryColumnGap: CGFloat = 40
    static let galleryBlockSpacing: CGFloat = 14
    static let galleryItemSpacing: CGFloat = 10
    static let galleryBarWidth: CGFloat = 240
}
