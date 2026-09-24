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
    // MARK: Sidebar

    private static let sidebarSize = CGSize(width: AppLayout.sidebarDefaultWidth, height: 800)

    /// How many rows fit the window, with a row's height and spacing.
    private static var sidebarRowsOnScreen: Int {
        Int(sidebarSize.height / (NWDensity.standard.rowHeight + AppLayout.sidebarRowSpacing)) + 1
    }

    @Test func openingTheSidebarOverThreeHundredAgentsBuildsOnlyTheRowsOnScreen() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start(with: ListFixtures.fleet(in: app.dir))
        var window: OffscreenWindow!
        let rows = ListPerf.counting {
            window = OffscreenWindow(size: Self.sidebarSize, dark: true, SidebarView(vm: vm))
            ListPerf.settle(window)
        }
        defer { window.close() }
        let built = rows["sidebar.row", default: 0] + rows["sidebar.spaceRow", default: 0]
        #expect(built <= 2 * Self.sidebarRowsOnScreen, "\(rows)")
    }

    /// A status report or a selection costs about the same with 300 agents as with 30: the
    /// sidebar lays out and redraws the rows on screen, never the whole fleet. A ratio on the
    /// same machine, so a slower one doesn't change it.
    @Test func statusReportsAndSelectionCostTheSameForAFleetAsForAFewAgents() async throws {
        func cost(agents: Int, spaces: Int) async throws -> Double {
            let app = try AppHarness()
            defer { app.stop() }
            let vm = try await app.start(with: ListFixtures.fleet(in: app.dir, spaces: spaces, agents: agents))
            let window = OffscreenWindow(size: Self.sidebarSize, dark: true, SidebarView(vm: vm))
            defer { window.close() }
            ListPerf.settle(window)
            var times: [Double] = []
            for round in 0..<3 {
                for index in 0..<8 {
                    var next = vm.state
                    next.agents[index].status = next.agents[index].status == .working ? .done : .working
                    times.append(ListPerf.time(window) { vm.adopt(next) })
                    times.append(ListPerf.time(window) { vm.selectAgent(vm.state.agents[(index + round) % agents].id) })
                }
            }
            // The median: a stray slow frame on a busy machine doesn't decide it.
            return times.sorted()[times.count / 2]
        }
        let few = try await cost(agents: 30, spaces: 4)
        let fleet = try await cost(agents: 300, spaces: 40)
        #expect(fleet < few * 2.5, "\(String(format: "300 agents %.2f ms, 30 agents %.2f ms", fleet, few))")
    }

    // MARK: Review

    private func review(_ files: [DiffFile]) -> OffscreenWindow {
        OffscreenWindow(size: CGSize(width: 600, height: 800), dark: true, ReviewPaneContent(model: ListFixtures.reviewModel(files)))
    }

    @Test func openingAReviewOfThreeHundredFilesBuildsOnlyTheChipsAndLinesInView() throws {
        let files = (0..<300).map { ListFixtures.diffFile("Sources/Module\($0)/File\($0).swift", lines: 12) }
        var window: OffscreenWindow!
        let rows = ListPerf.counting {
            window = review(files)
            ListPerf.settle(window)
        }
        defer { window.close() }
        // A chip is at least its letter, a short name, and padding: about a dozen fit 600pt.
        #expect(rows["review.fileChip", default: 0] <= 24, "\(rows)")
        #expect(rows["diff.line", default: 0] <= 2 * Int(800 / NW.Height.rowCompact), "\(rows)")
    }

    /// Every line can be commented on, but a line builds its `+` only while it is hovered.
    @Test func scrollingALongDiffBuildsNoCommentButtons() throws {
        let window = review([ListFixtures.diffFile("Big.swift", lines: 2000)])
        defer { window.close() }
        let rows = ListPerf.counting {
            ListPerf.settle(window)
            if let scroll = ListPerf.scrollView(in: window) { _ = ListPerf.scroll(window, scroll, step: 400, steps: 40) }
        }
        #expect(rows["diff.line", default: 0] > 100, "the diff scrolled: \(rows)")
        #expect(rows["diff.commentButton", default: 0] == 0, "\(rows)")
    }

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
