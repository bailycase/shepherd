import Foundation
import SwiftUI
import Testing
@testable import ShepherdUI

/// The Browser while the agent is using it (PaneStates › BrowserPane · the agent is using it).
@Suite("Browser agent components")
struct BrowserAgentComponentTests {
    @Test func theBoardsMeasures() {
        #expect(SHBrowserAgentMetrics.ringWidth == 2)
        #expect(SHBrowserAgentMetrics.pointerWidth == 18)
        #expect(SHBrowserAgentMetrics.cardInset == 12, "12pt from the pane's sides, under the toolbar")
        #expect(SHBrowserAgentMetrics.cardGlyph == 12)
        #expect(SHBrowserAgentMetrics.cardLeading == 12 && SHBrowserAgentMetrics.cardOther == 8, "padding 8, 12 on the leading side")
    }

    @Test func theArrowsTipIsWhereTheGlyphIsPlaced() {
        let path = SHAgentPointerShape().path(in: CGRect(x: 0, y: 0, width: 18, height: 20))
        let bounds = path.boundingRect
        #expect(bounds.minX == 2 && bounds.minY == 2 && bounds.maxX == 15 && bounds.maxY == 17)
        #expect(SHBrowserAgentMetrics.pointerTip == CGPoint(x: 2, y: 2))
        let scaled = SHAgentPointerShape().path(in: CGRect(x: 0, y: 0, width: 36, height: 40)).boundingRect
        #expect(scaled.minX == 4 && scaled.maxY == 34, "it scales with its box")
    }

    @Test func browserActivityHasItsOwnKind() {
        #expect(SHActivityLine.Kind.browser != .other)
    }
}
