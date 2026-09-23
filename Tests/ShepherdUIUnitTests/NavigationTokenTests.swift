import Foundation
import Testing
@testable import ShepherdUI

@Suite("Navigation measures")
struct NavigationTokenTests {
    @Test(arguments: [(NWDensity.compact, 22.0), (.standard, 28.0), (.comfortable, 36.0)])
    func rowDensitiesAreTheBoardsHeights(_ density: NWDensity, height: Double) {
        #expect(density.baseRowHeight == CGFloat(height))
    }

    @Test(arguments: [(0.0, "0s"), (59.9, "59s"), (60, "1m"), (3599, "59m"), (3600, "1h"), (86_399, "23h"), (86_400, "1d"), (-5, "0s")])
    func shortDurationsReadInTheirLargestWholeUnit(seconds: Double, text: String) {
        #expect(NWDuration.short(seconds) == text)
    }

    /// The elapsed label ticks each second for a minute, then only when the minute (or hour)
    /// it shows would change.
    @Test(arguments: [(0.0, 1.0), (12.4, 13.0), (59.5, 60.0), (60, 120), (61, 120), (3599, 3600), (3600, 7200), (90_000, 172_800)])
    func theElapsedScheduleTicksWhenTheLabelWouldChange(elapsed: Double, next: Double) {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let now = start.addingTimeInterval(elapsed)
        #expect(NWDuration.nextChange(after: now, since: start) == start.addingTimeInterval(next))
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
