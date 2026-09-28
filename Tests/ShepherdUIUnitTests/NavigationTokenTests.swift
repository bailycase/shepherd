import Foundation
import Testing
@testable import ShepherdUI

@Suite("Navigation measures")
struct NavigationTokenTests {
    @Test(arguments: [(NWDensity.compact, 22.0), (.standard, 28.0), (.comfortable, 36.0)])
    func rowDensitiesAreTheBoardsHeights(_ density: NWDensity, height: Double) {
        #expect(density.baseRowHeight == CGFloat(height))
    }

    @Test func thePaletteSitsEighteenPercentDownAtItsDesignedWidth() {
        let placement = NWPaletteMetrics.placement(in: CGSize(width: 1440, height: 900), rowHeight: 28)
        #expect(placement.top == 162)
        #expect(placement.width == 620)
        #expect(placement.maxListHeight == CGFloat(28 * 14))
    }

    /// In a short window the list gives way so the card never runs off the bottom; in a narrow
    /// one the card keeps a margin on each side.
    @Test func thePaletteIsCappedByTheWindow() {
        let short = NWPaletteMetrics.placement(in: CGSize(width: 720, height: 600), rowHeight: 28)
        let cardBottom = short.top + NWPaletteMetrics.searchHeight + 2 * NWPaletteMetrics.padding + short.maxListHeight
        #expect(cardBottom <= 600 - NWPaletteMetrics.margin)
        #expect(short.width == 620)

        let narrow = NWPaletteMetrics.placement(in: CGSize(width: 500, height: 600), rowHeight: 28)
        #expect(narrow.width == 500 - 2 * NWPaletteMetrics.margin)
    }

    @Test func aTinyWindowStillLeavesRoomForOneRow() {
        let tiny = NWPaletteMetrics.placement(in: CGSize(width: 100, height: 80), rowHeight: 28)
        #expect(tiny.maxListHeight == 28)
        #expect(tiny.width >= 0)
    }
}
