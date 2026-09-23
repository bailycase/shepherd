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
        (1207.0, 100.0, .docked, 480.0, 726.0),
        // At the threshold the 480 minimum wins over "at most half", and the thread keeps 400.
        (881.0, nil, .docked, 480.0, 400.0),
        (960.0, 700.0, .docked, 480.0, 479.0),
        // Narrower, the pane overlays the thread instead of squeezing it.
        (880.0, nil, .overlay, 600.0, 880.0),
        (720.0, 480.0, .overlay, 480.0, 720.0),
        (300.0, nil, .overlay, 300.0, 300.0),
        (0.0, nil, .overlay, 0.0, 0.0),
    ])
    func theRightPaneDocksWhileTheThreadKeepsFourHundredPoints(column: Double, preferred: Double?, mode: ShellLayout.PaneMode,
                                                                width: Double, content: Double) {
        let pane = ShellLayout.rightPane(containerWidth: column, preferredWidth: preferred.map { CGFloat($0) })
        #expect(pane == ShellLayout.Pane(mode: mode, width: width, contentWidth: content))
    }

    @Test(arguments: Array(stride(from: 0.0, through: 2400, by: 37)))
    func thePaneNeverProducesANegativeOrOversizedWidth(column: Double) {
        for preferred in [nil, 0, 200, 600, 5000] as [Double?] {
            let pane = ShellLayout.rightPane(containerWidth: column, preferredWidth: preferred.map { CGFloat($0) })
            #expect(pane.width >= 0 && pane.contentWidth >= 0)
            #expect(pane.width <= max(column, 0))
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
