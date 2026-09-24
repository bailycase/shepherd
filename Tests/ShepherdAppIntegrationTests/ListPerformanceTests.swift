import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Budgets for the long lists (DESIGN.md › Performance), over realistic large fixtures in
/// off-screen windows. The budgets count row bodies (`NWRenderProbe`), which a slower machine
/// doesn't change: a list that builds rows off screen, or redraws every row for a highlight, a
/// selection, or one row's change, fails whatever the hardware. `ListPerformanceReport` prints the
/// timings behind them.
@Suite("List performance", .mainActorExclusive)
@MainActor
struct ListPerformanceTests {
    // MARK: Palette

    private func palette(_ items: [PaletteItem], query: String, highlight: PaletteHighlight = PaletteHighlight()) -> OffscreenWindow {
        OffscreenWindow(size: CGSize(width: 900, height: 700), dark: true,
                        Color.clear.nwCommandPalette(isPresented: .constant(true)) {
                            PaletteCard(items: items, run: { _ in }, close: {}, initialQuery: query, highlight: highlight)
                        })
    }

    @Test func openingThePaletteOverAThousandResultsBuildsOnlyTheRowsOnScreen() throws {
        var window: OffscreenWindow!
        let rows = ListPerf.counting {
            window = palette(ListFixtures.paletteItems(1000), query: "fix")
            ListPerf.settle(window)
        }
        defer { window.close() }
        // At most 14 rows fit; each may be built twice while the card settles.
        #expect(rows["palette.row", default: 0] <= 2 * NWPaletteMetrics.maxVisibleRows, "\(rows)")
    }

    @Test func movingThePaletteHighlightRedrawsOnlyTheRowsItLeavesAndLandsOn() throws {
        let highlight = PaletteHighlight()
        let window = palette(ListFixtures.paletteItems(1000), query: "fix", highlight: highlight)
        defer { window.close() }
        ListPerf.settle(window)

        let rows = ListPerf.counting {
            for index in 1...20 { _ = ListPerf.time(window) { highlight.move(to: index) } }
        }
        // Two rows per move, plus the rows the highlight scrolls into view.
        #expect(rows["palette.row", default: 0] <= 20 * 2 + NWPaletteMetrics.maxVisibleRows, "\(rows)")
    }

    /// Lazy rows still let the card hug a short list, and a long one stops at the cap.
    @Test(arguments: [3, 1000])
    func thePaletteHugsAShortListAndCapsALongOne(count: Int) throws {
        let items = (0..<count).map { PaletteItem(id: "c\($0)", kind: .action("c\($0)"), section: .commands, title: "Command \($0)") }
        let window = palette(items, query: "")
        defer { window.close() }
        ListPerf.settle(window)
        let scroll = try #require(ListPerf.scrollView(in: window))

        let row = NWDensity.standard.rowHeight
        let cap = NWPaletteMetrics.placement(in: CGSize(width: 900, height: 700), rowHeight: row).maxListHeight
        let natural = NWPaletteMetrics.sectionHeight + CGFloat(count) * row
        #expect(abs(scroll.frame.height - min(natural, cap)) < 1, "list \(scroll.frame.height), rows \(natural), cap \(cap)")
    }

    @Test func theHighlightScrollsIntoViewPastTheCap() throws {
        let highlight = PaletteHighlight()
        let window = palette(ListFixtures.paletteItems(1000), query: "fix", highlight: highlight)
        defer { window.close() }
        ListPerf.settle(window)
        let scroll = try #require(ListPerf.scrollView(in: window))

        ListPerf.time(window) { highlight.move(to: 200) }

        let visible = scroll.contentView.bounds
        #expect(visible.minY > CGFloat(150) * NWDensity.standard.rowHeight, "scrolled to \(visible.minY)")
    }
}
