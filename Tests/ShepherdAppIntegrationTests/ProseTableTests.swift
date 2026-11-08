import AppKit
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdUI

/// A finished table measures its cells once. Resizing the thread changes the width it is offered,
/// which re-measures its rows (their heights), never its columns (`prose.tableMeasure`).
@Suite("Prose table", .mainActorExclusive)
@MainActor
struct ProseTableTests {
    @Test func aFinishedTableIsNotMeasuredAgainWhenTheThreadResizes() async throws {
        let table = Self.table(rows: 20)
        let cells = table.columns * (table.rows.count + 1)

        // Counting from before the window opens: the first build is the only one that measures.
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        let window = OffscreenWindow(size: CGSize(width: 560, height: 900), dark: false, TableHost(table: table))
        defer { window.close() }
        var widths = [try await Self.settledCard(window, near: 560)]
        let built = SHRenderProbe.count("prose.tableMeasure")
        #expect(built == cells, "the first build measures each cell once: \(SHRenderProbe.counts)")

        for width in [607, 653, 700, 653, 607, 560] as [CGFloat] {
            window.window.setContentSize(CGSize(width: width, height: 900))
            widths.append(try await Self.settledCard(window, near: width))
        }
        let resized = SHRenderProbe.count("prose.tableMeasure")
        #expect(resized == cells, "a width change measures rows, not cells: \(SHRenderProbe.counts)")
        #expect(widths.max()! - widths.min()! > 100, "the columns really changed width: \(widths)")
        #expect(widths.first == widths.last, "the same width lays out the same: \(widths)")
    }

    /// The table's card once it fits the window (the offer, less what rounding down gives up).
    private static func settledCard(_ window: OffscreenWindow, near offer: CGFloat) async throws -> CGFloat {
        var last: CGFloat = 0
        var stable = 0
        try await eventuallyOnMain("the table to fit \(offer) pt") {
            ListPerf.settle(window)
            let width = ListPerf.scrollView(in: window)?.frame.width ?? 0
            stable = width == last && abs(width - offer) <= 3 ? stable + 1 : 0
            last = width
            return stable >= 5
        }
        return last
    }

    /// Cells whose natural width passes the column cap, so every column shrinks with the window.
    private static func table(rows: Int) -> SHProseTable {
        func cell(_ row: Int, _ column: Int) -> AttributedString {
            AttributedString("row \(row) column \(column) " + String(repeating: "alpha beta gamma delta ", count: 6))
        }
        return SHProseTable(
            alignments: [.leading, .leading, .leading],
            header: ["Name", "Notes", "Owner"].map { AttributedString($0) },
            rows: (0..<rows).map { row in (0..<3).map { cell(row, $0) } },
            markdown: "")
    }
}

@MainActor
private struct TableHost: View {
    let table: SHProseTable

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SHProseTableView(table: table).equatable()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
