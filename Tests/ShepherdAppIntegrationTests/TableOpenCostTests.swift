import AppKit
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// What opening a thread full of tables builds: cells, layers and selection views, counted per table. A table is 12 cells here, and
/// each is a `Text` under its padding and its place in the table; the fill and the rules around them are the table's, not a layer or two
/// of every cell's own, and the text is not selectable until the pointer enters its table, where the view that makes it so under every
/// cell was the largest part of what the table built and kept: a thousand tables would multiply each.
@Suite("Opening a thread of tables", .mainActorExclusive)
@MainActor
struct TableOpenCostTests {
    private static let cells = 12

    /// What a thread of tables held once it had stopped building.
    private struct Open {
        var layers = 0
        var cellBodies = 0
        var measured = 0
        /// Views that make text selectable (`AppKitTextInteractionView`).
        var selectable = 0
    }

    private static func table(_ n: Int) -> String {
        """
        | Case | Before | After |
        | --- | ---: | ---: |
        | cold start | \(120 + n) ms | \(80 + n) ms |
        | scroll, 10k rows | \(16 + n % 5) ms | 6 ms |
        | memory, steady | \(210 + n) MB | \(150 + n) MB |
        """
    }

    private static func open(tables: Int) async throws -> Open {
        let reply = (0..<tables).map(table).joined(separator: "\n\n")
        let turn = [ThreadFixture.user("u", "Show the numbers"), ThreadFixture.assistant("a", reply)]
        SHRenderProbe.start()
        let thread = FakeThread(ThreadFixture.snapshot(turn), size: CGSize(width: 900, height: 800))
        thread.window.host.sizingOptions = []
        thread.window.host.safeAreaRegions = []
        defer { thread.close() }
        do {
            try await thread.waitUntilReady()
            var last = SHRenderProbe.counts
            var still = 0
            try await eventuallyOnMain("the thread to stop building") {
                ListPerf.settle(thread.window)
                let now = SHRenderProbe.counts
                still = now == last ? still + 1 : 0
                last = now
                return still >= 5
            }
        } catch {
            SHRenderProbe.stop()
            throw error
        }
        let counts = SHRenderProbe.stop()
        func layers(_ layer: CALayer) -> Int { 1 + (layer.sublayers ?? []).reduce(0) { $0 + layers($1) } }
        func selectable(_ view: NSView) -> Int {
            (String(describing: type(of: view)).contains("TextInteraction") ? 1 : 0) + view.subviews.reduce(0) { $0 + selectable($1) }
        }
        return Open(layers: thread.window.host.layer.map(layers) ?? 0, cellBodies: counts["prose.tableCell", default: 0],
                    measured: counts["prose.tableMeasure", default: 0], selectable: selectable(thread.window.host))
    }

    /// Each cell of an open thread is measured once, and each table adds a bounded number of layers: 61 when every cell carried a
    /// frame, a fill and a rule of its own, 53 with the fill and the rules the table's, 29 with its text not yet selectable. A table's body runs three times at open (its
    /// first pass, then the width it is offered, then its card's), and a lazy row built ahead of its layout can run its cells' bodies on
    /// each, so a cell's body is bounded by those three where its measuring, which the layout does, is exact.
    @Test func eachTableOfAnOpenThreadBuildsItsCellsOnceAndAddsFewLayers() async throws {
        let small = try await Self.open(tables: 20)
        let large = try await Self.open(tables: 60)
        for (open, tables) in [(small, 20), (large, 60)] {
            #expect(open.cellBodies >= tables * Self.cells && open.cellBodies <= 3 * tables * Self.cells, "a cell is built at most 3 times: \(open)")
        }
        #expect(large.measured - small.measured == 40 * Self.cells, "and measured once: \(small) then \(large)")
        let layers = Double(large.layers - small.layers) / 40
        #expect(layers <= 34, "layers per table: \(layers), \(small) then \(large)")
    }

    /// A table's text is selectable once the pointer has entered it, so a thread opened and read with the pointer elsewhere builds no
    /// selection view under any cell (there were 12 a table, the largest part of what opening the thread cost).
    @Test func aThreadOfTablesOpensWithNoSelectionViewUnderAnyCell() async throws {
        let small = try await Self.open(tables: 20)
        let large = try await Self.open(tables: 60)
        #expect(large.cellBodies >= 60 * Self.cells, "the cells are built: \(large)")
        #expect(large.selectable == small.selectable, "40 more tables add no selection view: \(small) then \(large)")
    }
}
