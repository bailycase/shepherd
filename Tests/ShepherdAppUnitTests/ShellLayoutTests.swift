import Foundation
import Observation
import ShepherdCore
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The window's adaptive rules: the sidebar docks while the main column keeps its minimum, and
/// the right pane docks while the thread keeps 400pt.
@Suite("Shell layout")
@MainActor
struct ShellLayoutTests {
    @Test(arguments: [
        // window, preferred, user hidden, overlay requested → mode, width, auto-hidden
        (1440.0, 232.0, false, false, ShellLayout.SidebarMode.docked, 232.0, false),
        (1440.0, 232.0, true, false, .hidden, 232.0, false),
        (1440.0, 232.0, true, true, .hidden, 232.0, false),
        // Narrowing to fit: the main column keeps 720 (+1 for the edge).
        (1000.0, 340.0, false, false, .docked, 279.0, false),
        (911.0, 232.0, false, false, .docked, 190.0, false),
        // Below the fit point the sidebar hides, and ⇧⌘S overlays it.
        (910.0, 232.0, false, false, .hidden, 232.0, true),
        (720.0, 232.0, false, false, .hidden, 232.0, true),
        (720.0, 232.0, false, true, .overlay, 232.0, true),
        (720.0, 232.0, true, true, .overlay, 232.0, true),
    ])
    func theSidebarDocksOnlyWhileTheMainColumnKeepsItsMinimum(window: Double, preferred: Double, userHidden: Bool, overlay: Bool,
                                                              mode: ShellLayout.SidebarMode, width: Double, autoHidden: Bool) {
        let sidebar = ShellLayout.sidebar(windowWidth: window, preferredWidth: preferred, userHidden: userHidden, overlayShown: overlay)
        #expect(sidebar == ShellLayout.Sidebar(mode: mode, width: width, autoHidden: autoHidden))
    }

    /// The shell watches `layoutWidth` instead of the window's width, so past the widest
    /// window that still narrows the sidebar a resize reruns nothing: every sidebar answer must
    /// be the same for the clamped width as for the real one.
    @Test(arguments: [720.0, 910.0, 911.0, 1000.0, 1060.0, 1061.0, 1062.0, 1440.0, 2560.0] as [CGFloat])
    func theClampedWidthLaysOutTheShellAsTheWindowWidthDoes(window: CGFloat) {
        let clamped = ShellLayout.layoutWidth(window)
        #expect(clamped == min(window, AppLayout.sidebarMaxWidth + AppLayout.dividerWidth + AppLayout.mainColumnMinWidth))
        for preferred in [90.0, 190.0, 232.0, 340.0, 900.0] {
            for (userHidden, overlay) in [(false, false), (true, false), (false, true), (true, true)] {
                #expect(ShellLayout.sidebar(windowWidth: clamped, preferredWidth: preferred, userHidden: userHidden, overlayShown: overlay)
                    == ShellLayout.sidebar(windowWidth: window, preferredWidth: preferred, userHidden: userHidden, overlayShown: overlay))
            }
            // A drag on the sidebar's edge is capped by the room the window leaves the same way.
            let room = { (width: CGFloat) in AppSettings.clampSidebarWidth(min(preferred, Double(width - AppLayout.dividerWidth - AppLayout.mainColumnMinWidth))) }
            #expect(room(clamped) == room(window))
        }
    }

    @Test func aPreferredWidthOutsideTheDragRangeIsClamped() {
        #expect(ShellLayout.sidebar(windowWidth: 1600, preferredWidth: 90, userHidden: false, overlayShown: false).width == AppLayout.sidebarMinWidth)
        #expect(ShellLayout.sidebar(windowWidth: 1600, preferredWidth: 900, userHidden: false, overlayShown: false).width == AppLayout.sidebarMaxWidth)
    }

    @Test func theDefaultSidebarIsTheBoards232Points() {
        #expect(AppSettings.defaultSidebarWidth == 232)
        #expect(AppSettings.sidebarWidthRange == 190...340)
    }

    @Test func anOverlaidSidebarLeavesSomeOfTheWindowUncovered() {
        let sidebar = ShellLayout.sidebar(windowWidth: 300, preferredWidth: 340, userHidden: false, overlayShown: true)
        #expect(sidebar.width == 300 - AppLayout.sidebarOverlayMargin)
    }

    @Test(arguments: [
        // column, preferred → mode, pane width, thread width
        (1207.0, nil as Double?, ShellLayout.PaneMode.docked, 600.0, 606.0),
        (1207.0, 900.0, .docked, 603.5, 602.5),
        (1207.0, 100.0, .docked, 380.0, 826.0),
        (881.0, nil, .docked, 440.5, 439.5),
        // At the threshold the 380 minimum wins over "at most half", and the thread keeps 400.
        (781.0, nil, .docked, 380.0, 400.0),
        (960.0, 700.0, .docked, 480.0, 479.0),
        // Narrower, the pane overlays the thread instead of squeezing it.
        (780.0, nil, .overlay, 600.0, 780.0),
        (720.0, 480.0, .overlay, 480.0, 720.0),
        // The overlaid pane and its 1pt edge fit the column exactly.
        (300.0, nil, .overlay, 299.0, 300.0),
        (0.0, nil, .overlay, 0.0, 0.0),
    ])
    func theSidePaneDocksWhileTheThreadKeepsFourHundredPoints(column: Double, preferred: Double?, mode: ShellLayout.PaneMode,
                                                                width: Double, content: Double) {
        let pane = ShellLayout.rightPane(containerWidth: column, preferredWidth: preferred.map { CGFloat($0) })
        #expect(pane == ShellLayout.Pane(mode: mode, width: width, contentWidth: content))
    }

    /// Double-clicking the divider: half the column where the thread keeps its 400 beside it.
    @Test(arguments: [(1440.0, 720.0), (1000.0, 500.0), (781.0, 380.0), (700.0, 699.0)])
    func theWidestPaneIsHalfTheColumn(column: Double, width: Double) {
        #expect(ShellLayout.widestRightPane(containerWidth: column) == CGFloat(width))
    }

    @Test(arguments: [
        // position, span → ratio
        (500.0, 1001.0, 500.0 / 1001),
        // Each side keeps 160pt of the 1000 beside the divider…
        (20.0, 1001.0, 0.16), (990.0, 1001.0, 0.84),
        // …and never less than 15% or more than 85% in a long split.
        (10.0, 2001.0, 0.15), (1990.0, 2001.0, 0.85),
        // Too short for two 160pt sides: the divider stays centred.
        (40.0, 301.0, 0.5), (0.0, 0.0, 0.5),
    ])
    func aDividerDragLeavesEachSideItsMinimum(position: Double, span: Double, ratio: Double) {
        #expect(abs(ShellLayout.splitRatio(position: position, span: span) - ratio) < 0.000_1)
    }

    @Test(arguments: Array(stride(from: 0.0, through: 2400, by: 37)))
    func thePaneNeverProducesANegativeOrOversizedWidth(column: Double) {
        for preferred in [nil, 0, 200, 600, 5000] as [Double?] {
            let pane = ShellLayout.rightPane(containerWidth: column, preferredWidth: preferred.map { CGFloat($0) })
            #expect(pane.width >= 0 && pane.contentWidth >= 0)
            #expect(pane.width + 1 <= max(column, 1), "the pane and its edge stay inside the column")
            if pane.mode == .docked {
                #expect(pane.contentWidth >= AppLayout.threadMinWidth)
                #expect(pane.width + 1 + pane.contentWidth == CGFloat(column))
                #expect(pane.width <= max(AppLayout.paneMinWidth, column * AppLayout.paneMaxFraction))
            }
        }
    }
}

/// Observation's change callback is `@Sendable`; the flag it sets is read back on the same actor.
private final class ChangeFlag: @unchecked Sendable {
    var fired = false
}

@Suite("Menu state")
@MainActor
struct MenuStateTests {
    /// Menus rebuild only when what they show changes: an identical snapshot notifies nobody.
    @Test func applyingAnIdenticalSnapshotNotifiesNoMenu() {
        let menu = MenuState()
        var snapshot = MenuState.Snapshot()
        snapshot.agents = [MenuState.Item(id: "a", title: "Fix login")]
        menu.apply(snapshot)

        let notified = ChangeFlag()
        withObservationTracking {
            _ = menu.agents
            _ = menu.hasVisibleThread
        } onChange: { notified.fired = true }
        menu.apply(snapshot)
        #expect(!notified.fired)

        snapshot.hasVisibleThread = true
        menu.apply(snapshot)
        #expect(notified.fired)
        #expect(menu.hasVisibleThread)
    }

    @Test func aChangeReachesOnlyTheMenusThatReadIt() {
        let menu = MenuState()
        let notified = ChangeFlag()
        withObservationTracking { _ = menu.spaces } onChange: { notified.fired = true }
        var snapshot = MenuState.Snapshot()
        snapshot.sidebarVisible = false
        menu.apply(snapshot)
        #expect(!notified.fired)
        #expect(!menu.sidebarVisible)
    }
}
