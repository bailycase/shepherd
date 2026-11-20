import Testing
@testable import ShepherdApp

/// Checks the menu state (title and enablement) behind the Agent menu's Stop All Working Threads item.
/// It does not check that the menu registers the item.
@Suite("Stop all menu state")
@MainActor
struct StopAllMenuTests {
    @Test func menuStateHasTheCountAndIsDisabledWhenNothingIsWorking() {
        let menu = MenuState()
        #expect(menu.stopAllTitle == "Stop All Working Threads…" && !menu.canStopAll)
        menu.apply(MenuState.Snapshot(workingThreadCount: 3))
        #expect(menu.stopAllTitle == "Stop All Working Threads (3)…" && menu.canStopAll)
        menu.apply(MenuState.Snapshot(workingThreadCount: 0))
        #expect(!menu.canStopAll)
    }
}
