import ShepherdUI
import Testing
@testable import ShepherdApp

/// The side pane's strip and its header button (PaneStates): only the tabs Shepherd has, their
/// counts and pi's dots, labels dropping under 480pt, and the button's dot while the strip is out
/// of sight.
@Suite("Side pane")
struct SidePaneTests {
    @Test func theStripShowsOnlyTheTabsShepherdHas() {
        #expect(SidePaneTab.allCases == [.changes], "Browser, Artifacts and Files are not built, so they have no tab")
        #expect(SidePaneTabs.items(news: [], changedFiles: nil).map(\.title) == ["Changes"])
    }

    @Test(arguments: [(nil, false), (0, false), (4, true)] as [(Int?, Bool)])
    func changesCountsItsFilesAndCarriesPisDot(changedFiles: Int?, news: Bool) {
        let tab = SidePaneTabs.items(news: news ? [.changes] : [], changedFiles: changedFiles)[0]
        #expect(tab.count == changedFiles)
        #expect(tab.news == news)
        #expect(tab.shortcut == "⌃1")
        #expect(tab.systemImage == "plus.forwardslash.minus")
    }

    @Test(arguments: [(600, true), (480, true), (479, false), (380, false)] as [(Double, Bool)])
    func underFourHundredEightyPointsTheLabelsDrop(width: Double, labels: Bool) {
        #expect(NWSidePaneMetrics.showsLabels(width: width) == labels)
    }

    @Test(arguments: [
        // open, inspecting, news → lit, dot
        (false, false, false, false, nil),
        (false, false, true, false, "pi opened a review in Changes"),
        (true, false, false, true, nil),
        // The strip is on screen: its tab says it, not the button.
        (true, false, true, true, nil),
        // An inspected run covers the strip.
        (true, true, true, true, "pi opened a review in Changes"),
        (false, true, false, true, nil),
    ] as [(Bool, Bool, Bool, Bool, String?)])
    func theHeaderButtonLightsWhileThePaneShowsAndTakesTheDotWhileTheStripIsHidden(
        open: Bool, inspecting: Bool, news: Bool, lit: Bool, dot: String?
    ) {
        let button = SidePaneTab.button(open: open, inspecting: inspecting, news: news ? [.changes] : [])
        #expect(button.isOn == lit)
        #expect(button.news == dot)
    }
}
