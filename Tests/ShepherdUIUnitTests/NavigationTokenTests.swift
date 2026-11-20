import Foundation
import Testing
@testable import ShepherdUI

@Suite("Navigation measures")
struct NavigationTokenTests {
    @Test(arguments: [(SHDensity.compact, 22.0), (.standard, 28.0), (.comfortable, 36.0)])
    func rowDensitiesAreTheBoardsHeights(_ density: SHDensity, height: Double) {
        #expect(density.baseRowHeight == CGFloat(height))
    }

    @Test func thePaletteSitsEighteenPercentDownAtItsDesignedWidth() {
        let placement = SHPaletteMetrics.placement(in: CGSize(width: 1440, height: 900), rowHeight: 28)
        #expect(placement.top == 162)
        #expect(placement.width == 620)
        #expect(placement.maxListHeight == CGFloat(28 * 14))
    }

    /// In a short window the list gives way so the card never runs off the bottom; in a narrow
    /// one the card keeps a margin on each side.
    @Test func thePaletteIsCappedByTheWindow() {
        let short = SHPaletteMetrics.placement(in: CGSize(width: 720, height: 600), rowHeight: 28)
        let cardBottom = short.top + SHPaletteMetrics.searchHeight + 2 * SHPaletteMetrics.padding + short.maxListHeight
        #expect(cardBottom <= 600 - SHPaletteMetrics.margin)
        #expect(short.width == 620)

        let narrow = SHPaletteMetrics.placement(in: CGSize(width: 500, height: 600), rowHeight: 28)
        #expect(narrow.width == 500 - 2 * SHPaletteMetrics.margin)
    }

    @Test func aTinyWindowStillLeavesRoomForOneRow() {
        let tiny = SHPaletteMetrics.placement(in: CGSize(width: 100, height: 80), rowHeight: 28)
        #expect(tiny.maxListHeight == 28)
        #expect(tiny.width >= 0)
    }
}
