import Foundation
import SwiftUI
import Testing
@testable import ShepherdUI

/// The Browser while the agent is using it (PaneStates › BrowserPane · the agent is using it).
@Suite("Browser agent components")
struct BrowserAgentComponentTests {
    @Test func theBoardsMeasures() {
        #expect(NWBrowserAgentMetrics.ringWidth == 2)
        #expect(NWBrowserAgentMetrics.pointerWidth == 18)
        #expect(NWBrowserAgentMetrics.cardInset == 12, "12pt from the pane's sides, under the toolbar")
        #expect(NWBrowserAgentMetrics.cardGlyph == 12)
        #expect(NWBrowserAgentMetrics.tabTipWidth == 300)
        #expect(NWBrowserAgentMetrics.cardLeading == 12 && NWBrowserAgentMetrics.cardOther == 8, "padding 8, 12 on the leading side")
    }

    @Test(arguments: [(0.0, "0s"), (10.4, "10s"), (59.9, "59s"), (60.0, "1m"), (125.0, "2m"), (3599.0, "59m"), (3600.0, "1h"), (7300.0, "2h"), (-4.0, "0s")])
    func theTipsAgeReadsInTheLargestWholeUnit(seconds: Double, expected: String) {
        #expect(NWPaneTabTip.age(seconds: seconds) == expected)
    }

    @Test func theArrowsTipIsWhereTheGlyphIsPlaced() {
        let path = NWAgentPointerShape().path(in: CGRect(x: 0, y: 0, width: 18, height: 20))
        let bounds = path.boundingRect
        #expect(bounds.minX == 2 && bounds.minY == 2 && bounds.maxX == 15 && bounds.maxY == 17)
        #expect(NWBrowserAgentMetrics.pointerTip == CGPoint(x: 2, y: 2))
        let scaled = NWAgentPointerShape().path(in: CGRect(x: 0, y: 0, width: 36, height: 40)).boundingRect
        #expect(scaled.minX == 4 && scaled.maxY == 34, "it scales with its box")
    }

    @Test func aTabCarriesItsTipOnlyWhenGivenOne() {
        let tip = NWSidePaneTabTip(text: "localhost:5173/checkout", openedAt: Date(timeIntervalSince1970: 1))
        #expect(NWSidePaneTab(id: "browser", title: "Browser", systemImage: "globe", news: true, tip: tip).tip == tip)
        #expect(NWSidePaneTab(id: "changes", title: "Changes", systemImage: "x").tip == nil)
        #expect(NWActivityLine.Kind.browser != .other)
    }
}
