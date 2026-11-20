import Testing
@testable import ShepherdApp

/// The Agent menu's Stop All Working Threads item reads its title and enablement from `MenuState`.
@Suite("Stop all menu item")
@MainActor
struct StopAllMenuTests {
    @Test func theItemShowsTheCountAndIsDisabledWhenNothingIsWorking() {
        let menu = MenuState()
        #expect(menu.stopAllTitle == "Stop All Working Threads…" && !menu.canStopAll)
        menu.apply(MenuState.Snapshot(workingThreadCount: 3))
        #expect(menu.stopAllTitle == "Stop All Working Threads (3)…" && menu.canStopAll)
        menu.apply(MenuState.Snapshot(workingThreadCount: 0))
        #expect(!menu.canStopAll)
    }
}
