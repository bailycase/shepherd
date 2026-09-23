import SwiftUI
import ShepherdUI

/// The window, sidebar, toolbar, right pane, and palette (Navigation board). Row heights come
/// from `NWDensity` (Settings ▸ Appearance ▸ Sidebar rows) through the environment.
extension AppLayout {
    // Window
    static let windowMinWidth: CGFloat = 720
    static let windowMinHeight: CGFloat = 600
    static let windowDefaultWidth: CGFloat = 1440
    static let windowDefaultHeight: CGFloat = 900
    /// The main column never narrows below this beside a docked sidebar; a narrower window
    /// hides the sidebar and shows it as an overlay on demand.
    static let mainColumnMinWidth: CGFloat = 720
    /// The title-bar strip the window controls sit in, for surfaces without a toolbar.
    static let trafficLightHeight: CGFloat = 38
    /// How far a toolbar that runs under the window controls starts from the leading edge.
    static let trafficLightInset: CGFloat = 70

    // Sidebar
    static let sidebarDefaultWidth: CGFloat = 232
    static let sidebarMinWidth: CGFloat = 190
    static let sidebarMaxWidth: CGFloat = 340
    static let sidebarPadding: CGFloat = NWSidebarMetrics.treeInset
    static let sidebarIndent: CGFloat = NWSidebarMetrics.indentStep
    /// An overlaid sidebar leaves this much of the window uncovered.
    static let sidebarOverlayMargin: CGFloat = 48

    // Toolbar
    static let headerHeight: CGFloat = NWToolbarMetrics.height
    static let headerPadding: CGFloat = NWToolbarMetrics.leadingPadding

    // Right pane (review and subagent inspector share the slot)
    static let paneDefaultWidth: CGFloat = 600
    static let paneMinWidth: CGFloat = 480
    static let paneMaxFraction: CGFloat = 0.5
    /// The thread keeps at least this beside a docked pane; narrower, the pane overlays it.
    static let threadMinWidth: CGFloat = 400
    /// Dragging a split's divider leaves each side at least this long (when the split allows).
    static let splitPaneMinSpan: CGFloat = 160

    // Palette
    static let paletteWidth: CGFloat = NWPaletteMetrics.width
    static let paletteSearchHeight: CGFloat = NWPaletteMetrics.searchHeight
    /// Standard-density palette rows; the palette itself follows the density setting.
    @MainActor static var paletteRowHeight: CGFloat { NWDensity.standard.rowHeight }
}

/// The window's adaptive rules (resizability review): when the sidebar docks or overlays and
/// how wide it is, and whether the right pane docks beside the thread or overlays it. Pure.
enum ShellLayout {
    enum SidebarMode: Equatable {
        case docked, overlay, hidden
    }

    struct Sidebar: Equatable {
        let mode: SidebarMode
        let width: CGFloat
        /// The window is too narrow to dock the sidebar; ⇧⌘S shows it as an overlay.
        let autoHidden: Bool
    }

    /// The sidebar for a window `windowWidth` wide. It docks while the main column keeps its
    /// minimum beside at least the sidebar's minimum width (narrowing to fit), else it hides
    /// and ⇧⌘S overlays it.
    static func sidebar(windowWidth: CGFloat, preferredWidth: CGFloat, userHidden: Bool, overlayShown: Bool) -> Sidebar {
        let preferred = min(max(preferredWidth, AppLayout.sidebarMinWidth), AppLayout.sidebarMaxWidth)
        let room = windowWidth - 1 - AppLayout.mainColumnMinWidth
        if room >= AppLayout.sidebarMinWidth {
            return Sidebar(mode: userHidden ? .hidden : .docked, width: min(preferred, room), autoHidden: false)
        }
        let width = max(0, min(preferred, windowWidth - AppLayout.sidebarOverlayMargin))
        return Sidebar(mode: overlayShown ? .overlay : .hidden, width: width, autoHidden: true)
    }

    /// The narrowest window that docks the sidebar at `width`.
    static func sidebarFitWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, AppLayout.sidebarMinWidth), AppLayout.sidebarMaxWidth) + 1 + AppLayout.mainColumnMinWidth
    }

    enum PaneMode: Equatable {
        case docked, overlay
    }

    struct Pane: Equatable {
        let mode: PaneMode
        let width: CGFloat
        /// What is left for the thread: beside a docked pane, or all of it under an overlay.
        let contentWidth: CGFloat
    }

    /// Narrower than this, the pane overlays the thread instead of squeezing it.
    static let paneDockThreshold = AppLayout.threadMinWidth + 1 + AppLayout.paneMinWidth

    /// The right pane in a main column `containerWidth` wide. Docked, it is 600 by default, at
    /// least 480, at most half the column (480 wins), and the thread keeps 400; below that the
    /// pane overlays the thread and, with its 1pt edge, never exceeds the column. Nothing is
    /// ever negative.
    static func rightPane(containerWidth: CGFloat, preferredWidth: CGFloat?) -> Pane {
        let total = max(0, containerWidth)
        let preferred = max(preferredWidth.flatMap { $0 > 0 ? $0 : nil } ?? AppLayout.paneDefaultWidth, AppLayout.paneMinWidth)
        if total >= paneDockThreshold {
            let widest = max(AppLayout.paneMinWidth, min(total * AppLayout.paneMaxFraction, total - 1 - AppLayout.threadMinWidth))
            let width = min(preferred, widest)
            return Pane(mode: .docked, width: width, contentWidth: total - 1 - width)
        }
        return Pane(mode: .overlay, width: min(preferred, max(0, total - 1)), contentWidth: total)
    }

    /// The divider ratio for a drag at `position` along a split `span` long (its 1pt divider
    /// included): 15–85%, and each side keeps `splitPaneMinSpan` (a split too short for both
    /// stays centred).
    static func splitRatio(position: CGFloat, span: CGFloat) -> Double {
        let span = max(1, span)
        let floor = min(0.5, AppLayout.splitPaneMinSpan / max(1, span - 1))
        return min(min(0.85, 1 - floor), max(max(0.15, floor), position / span))
    }
}
