import SwiftUI
import ShepherdUI

/// The window, its dividers and workspace, the sidebar, toolbar, right pane, and palette
/// (Navigation board). Row heights come from `SHDensity` (Settings ▸ Appearance ▸ Sidebar rows)
/// through the environment.
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
    /// The close button's centre from the window's top leading corner (`.lights` in the boards): on the 44pt row
    /// the sidebar's top bar and the toolbar share, 22pt in from the window's leading edge to its edge.
    static let windowControlsCenter = CGPoint(x: 28, y: SHSidebarMetrics.panelInset + SHSidebarMetrics.topBarHeight / 2)
    /// How far a toolbar that runs under the window controls starts from the leading edge.
    static let trafficLightInset: CGFloat = 70

    // Dividers
    /// The layout's dividers: pane splits and the edges of the docked sidebar and right pane.
    /// 1pt rather than a hairline, because the window's arithmetic counts them.
    static let dividerWidth: CGFloat = 1
    /// A divider's drag target, centred on it.
    static let resizeHandleWidth: CGFloat = 9
    /// VoiceOver's adjustment step for the sidebar's width and the right pane's.
    static let sidebarAdjustStep: CGFloat = 16
    static let paneAdjustStep: CGFloat = 40

    // Sidebar
    static let sidebarDefaultWidth: CGFloat = 248
    static let sidebarMinWidth: CGFloat = 190
    static let sidebarMaxWidth: CGFloat = 340
    static let sidebarPadding: CGFloat = SHSidebarMetrics.listInset
    /// The docked sidebar panel's inset from the window's leading edge: what the window gives it
    /// beyond its width.
    static let sidebarGutter: CGFloat = SHSidebarMetrics.panelInset
    static let sidebarRowSpacing: CGFloat = SHSidebarMetrics.rowSpacing
    /// An overlaid sidebar leaves this much of the window uncovered.
    static let sidebarOverlayMargin: CGFloat = 48

    // Destination pages (NavNewThread, NavAutomations, NavHosts); the header is `SHPageMetrics`'.
    /// New thread: the column's gaps and padding, the heading (Geist 26 semibold, tracked −2%),
    /// the 720pt composer and the Continue card's row under it.
    static let newThreadGap: CGFloat = 24
    static let newThreadSidePadding: CGFloat = 40
    /// The boards' `.hero` sits 120pt above the middle.
    static let newThreadBottomPadding: CGFloat = 120
    /// New design's heading (SF Pro 26 semibold, tracked −2%).
    static let newThreadHeadingSize: CGFloat = 26
    static let newThreadHeadingTracking: CGFloat = -0.52
    /// New thread's words (the boards' hero `.ta`): a size up from the thread's.
    static let newThreadFieldSize: CGFloat = 15
    /// The boards' suggestion rows (`.sg`) under the composer.
    static let newThreadSuggestionHeight: CGFloat = 34
    static let newThreadComposerWidth: CGFloat = 720
    /// The suggestions sit 14pt under the composer.
    static let newThreadCardsTop: CGFloat = 14

    // Workspace
    /// How far a terminal pane's placeholder ("starting session…") sits from its corner.
    static let panePlaceholderPadding: CGFloat = 10

    // Toolbar
    static let headerHeight: CGFloat = SHToolbarMetrics.height
    /// The thread toolbar's distance from the window's top (the boards' 8pt window padding), so its row is the docked
    /// sidebar's top bar's and the window controls' (`windowControlsCenter`).
    static let toolbarTop: CGFloat = SHSidebarMetrics.panelInset
    static let headerPadding: CGFloat = SHToolbarMetrics.leadingPadding

    // Side pane (its tabs, or the subagent inspector over them; PaneStates)
    /// The boards' pane (`.pane.w`) is 720 wide.
    static let paneDefaultWidth: CGFloat = 720
    /// The thread's pane is a card (GXSidePane): 8pt from the thread before it and from the window's top, bottom and trailing edges.
    static let paneCardEdge: CGFloat = SHSidePaneMetrics.cardGap + SHSidePaneMetrics.cardInset
    /// Under 480 the tab strip drops its labels (`SHSidePaneMetrics.labelsMinWidth`).
    static let paneMinWidth: CGFloat = 380
    static let paneMaxFraction: CGFloat = 0.5
    /// The Browser (PaneStates › viewport): a chosen width's frame sits this far from the pane's
    /// top, on `bgSunken` (PaneStates' 280pt-wide framed device: `padding: 14px 0 0 0`).
    static let browserFrameMargin: CGFloat = 14
    /// A picked element's popover sits this far from the element and the page's edges.
    static let browserPopoverGap: CGFloat = 12
    /// The viewport menu hangs this far under the toolbar, its trailing edge under the Viewport
    /// button (Open in your browser and the toolbar's padding to its right).
    static let browserMenuDrop: CGFloat = 4
    static let browserMenuTrailing: CGFloat = 38
    /// The Changes tab's bar under the pane's tabs: scope and totals, Local | PR (Review board).
    static let changesBarHeight: CGFloat = 40
    static let changesBarLeadingPadding: CGFloat = 14
    /// The Changes tab's file rows sit 12pt in from the pane's sides (the boards' `.pbody`).
    static let changesFileRowsInset: CGFloat = SH.Space.l
    /// The thread keeps at least this beside a docked pane; narrower, the pane overlays it.
    static let threadMinWidth: CGFloat = 400

    // Palette
    static let paletteWidth: CGFloat = SHPaletteMetrics.width
    static let paletteSearchHeight: CGFloat = SHPaletteMetrics.searchHeight
    /// Standard-density palette rows; the palette itself follows the density setting.
    @MainActor static var paletteRowHeight: CGFloat { SHDensity.standard.rowHeight }
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
        let room = windowWidth - AppLayout.sidebarGutter - AppLayout.mainColumnMinWidth
        if room >= AppLayout.sidebarMinWidth {
            return Sidebar(mode: userHidden ? .hidden : .docked, width: min(preferred, room), autoHidden: false)
        }
        let width = max(0, min(preferred, windowWidth - AppLayout.sidebarOverlayMargin))
        return Sidebar(mode: overlayShown ? .overlay : .hidden, width: width, autoHidden: true)
    }

    /// The narrowest window that docks the sidebar at `width`.
    static func sidebarFitWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, AppLayout.sidebarMinWidth), AppLayout.sidebarMaxWidth) + AppLayout.sidebarGutter + AppLayout.mainColumnMinWidth
    }

    /// A window width as the shell's layout tells it apart: at and past the narrowest window that
    /// docks the widest sidebar, `sidebar` answers the same for every width, so the shell
    /// watches this rather than the width itself.
    static func layoutWidth(_ windowWidth: CGFloat) -> CGFloat {
        min(windowWidth, sidebarFitWidth(AppLayout.sidebarMaxWidth))
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
    static let paneDockThreshold = AppLayout.threadMinWidth + AppLayout.dividerWidth + AppLayout.paneMinWidth

    /// The side pane in a main column `containerWidth` wide. Docked, it is 600 by default, at
    /// least 380, at most half the column (380 wins), and the thread keeps 400; below that the
    /// pane overlays the thread and, with its 1pt edge, never exceeds the column. Nothing is
    /// ever negative.
    static func rightPane(containerWidth: CGFloat, preferredWidth: CGFloat?,
                          defaultWidth: CGFloat = AppLayout.paneDefaultWidth, edge: CGFloat = AppLayout.dividerWidth) -> Pane {
        let total = max(0, containerWidth)
        let preferred = max(preferredWidth.flatMap { $0 > 0 ? $0 : nil } ?? defaultWidth, AppLayout.paneMinWidth)
        if total >= paneDockThreshold + edge - AppLayout.dividerWidth {
            let widest = max(AppLayout.paneMinWidth, min(total * AppLayout.paneMaxFraction, total - edge - AppLayout.threadMinWidth))
            let width = min(preferred, widest)
            return Pane(mode: .docked, width: width, contentWidth: total - edge - width)
        }
        return Pane(mode: .overlay, width: min(preferred, max(0, total - edge)), contentWidth: total)
    }

    /// The widest the side pane may be beside a column this wide: half of it where it docks
    /// (PaneStates: double-click the divider for half the window), never taking the thread's 400.
    static func widestRightPane(containerWidth: CGFloat, edge: CGFloat = AppLayout.dividerWidth) -> CGFloat {
        rightPane(containerWidth: containerWidth, preferredWidth: .greatestFiniteMagnitude, edge: edge).width
    }
}
