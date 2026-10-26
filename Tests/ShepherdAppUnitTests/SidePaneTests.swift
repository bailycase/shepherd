import ShepherdUI
import Testing
@testable import ShepherdApp

/// The side pane's strip and its header button (PaneStates): only the tabs Shepherd has, their
/// counts and pi's dots, labels dropping under 480pt, and the button's dot while the strip is out
/// of sight.
@Suite("Side pane")
struct SidePaneTests {
    @Test func theStripShowsOnlyTheTabsShepherdHas() {
        #expect(SidePaneTab.allCases == [.changes, .browser, .artifacts, .subagents, .files])
        #expect(SidePaneTabs.items(news: [], changedFiles: nil).map(\.title) == ["Changes", "Browser", "Files"],
                "Artifacts and Subagents wait for a first file and a first run; Files is always shown")
        #expect(SidePaneTabs.items(news: [], changedFiles: nil, browser: false).map(\.title) == ["Changes", "Files"],
                "a remote thread on a host with no tunnels (an older one) has no Browser, as before")
        #expect(SidePaneTabs.items(news: [], changedFiles: 2, artifacts: 3, subagents: (1, .running)).map(\.title)
                == ["Changes", "Browser", "Files", "Artifacts", "Subagents"])
        #expect(SidePaneTab.tabs(browser: true) == [.changes, .browser, .files, .artifacts, .subagents])
        #expect(SidePaneTab.tabs(browser: false) == [.changes, .files, .artifacts, .subagents])
    }

    @Test func artifactsIsThePageGlyphOnControlThreeAndCountsItsFiles() throws {
        let tab = try #require(SidePaneTabs.items(news: [], changedFiles: nil, artifacts: 3).first { $0.id == "artifacts" })
        #expect(tab.title == "Artifacts" && tab.count == 3 && tab.shortcut == "⌃3" && tab.systemImage == NWGlyph.artifact.symbolName)
        #expect(SidePaneTabs.items(news: [], changedFiles: nil, artifacts: nil).allSatisfy { $0.id != "artifacts" }, "no file, no tab")
    }

    @Test func theDigitsFollowTheBoardAndAHostWithoutTunnelsKeepsThem() {
        #expect(SidePaneTab.allCases.map(\.digit) == [1, 2, 3, 4, 5])
        #expect(SidePaneTab.allCases.map(\.shortcutDisplay) == ["⌃1", "⌃2", "⌃3", "⌃4", "⌃5"])
        #expect(SidePaneTab.artifacts.digit == 3, "PaneStates: Artifacts is ⌃3; Subagents is ⌃4; Files is ⌃5")
        #expect(SidePaneTab.files.digit == 5)
    }

    @Test func theBrowserIsGlobeOnControlTwoAndCarriesPisDot() throws {
        let tab = try #require(SidePaneTabs.items(news: [.browser], changedFiles: 3).first { $0.id == "browser" })
        #expect(tab.systemImage == "globe" && tab.shortcut == "⌃2")
        #expect(tab.news && tab.count == nil)
        #expect(SidePaneTab.button(open: false, inspecting: false, news: [.browser]).news == "Agent opened a page in Browser")
        #expect(SidePaneTab.button(open: false, inspecting: false, news: [.browser, .changes]).news == "Agent opened a review in Changes",
                "the first tab's news leads")
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
        (false, false, true, false, "Agent opened a review in Changes"),
        (true, false, false, true, nil),
        // The strip is on screen: its tab says it, not the button.
        (true, false, true, true, nil),
        // An inspected run covers the strip.
        (true, true, true, true, "Agent opened a review in Changes"),
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
