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

    /// The header's fill and the rows' hairlines are the table's, laid under the cells, where they were each cell's own: the table draws
    /// every pixel it drew with a frame, a fill and a rule on each cell (`LegacyTable`), in every alignment, in a column that wraps.
    @Test(arguments: [false, true])
    func aTableDrawsWhatItDrewWhenEachCellDrewItsOwnFillAndRule(dark: Bool) async throws {
        let table = Self.mixedTable
        for width in [700, 430] as [CGFloat] {
            let new = OffscreenWindow(size: CGSize(width: width, height: 420), dark: dark, TableHost(table: table))
            let old = OffscreenWindow(size: CGSize(width: width, height: 420), dark: dark, LegacyTableHost(table: table))
            defer { new.close(); old.close() }
            var drawn: [[UInt8]] = []
            for window in [new, old] {
                var last: [UInt8] = []
                var still = 0
                try await eventuallyOnMain("the table to stop moving at \(width) pt") {
                    ListPerf.settle(window)
                    let now = Self.pixels(of: window)
                    still = now == last ? still + 1 : 0
                    last = now
                    return still >= 5
                }
                drawn.append(last)
            }
            #expect(drawn[0].count == drawn[1].count && drawn[0].count > 0, "both draw at one size")
            let differing = zip(drawn[0], drawn[1]).filter { $0 != $1 }.count
            #expect(differing == 0, "\(differing) of \(drawn[0].count) bytes differ at \(width) pt, \(dark ? "dark" : "light")")
        }
    }

    /// What the window shows, as bytes.
    private static func pixels(of window: OffscreenWindow) -> [UInt8] {
        let view = window.host
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
    }

    /// Every alignment, a header and rows, a column that wraps, and inline code in it, as the thread styles them.
    private static var mixedTable: SHProseTable {
        SHProseTable(
            alignments: [.leading, .center, .trailing, .leading],
            header: ["Area", "Count", "Share", "Tools"].map { SHProseInline.attributed($0) },
            rows: [
                ["Terminals", "6", "19%", "`terminal_list`, `terminal_open`, `terminal_run`, `terminal_read`, `terminal_focus`, `terminal_close`"],
                ["Peers", "8", "26%", "`agent_list`, `agent_send`, `agent_read`, `agent_steer`"],
                ["Notes", "2", "6%", "`notify`, **review**"],
                ["Everything else together", "1,234", "100%", "A longer sentence of plain words that wraps over a couple of lines in its column"],
            ].map { $0.map { SHProseInline.attributed($0) } },
            markdown: "")
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

@MainActor
private struct LegacyTableHost: View {
    let table: SHProseTable

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LegacyTable(table: table)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The table as it was drawn while every cell carried its own frame, fill and rule: `SHProseTableView` with the cells of that time,
/// laid out by `SHTableLayout` as a layout of cells alone. Its copy button, hidden on the Mac, is left out.
@MainActor
private struct LegacyTable: View {
    let table: SHProseTable
    @Environment(\.shProseSize) private var size
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var availableWidth: CGFloat?
    @State private var contentWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                grid.onGeometryChange(for: CGFloat.self) { $0.size.width.rounded(.up) } action: { contentWidth = $0 }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: contentWidth)
            .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
            .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
            Spacer(minLength: 0)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded(.down) } action: { availableWidth = $0 }
    }

    private var grid: some View {
        let columns = table.columns
        let rows = table.rows.count
        return SHTableLayout(columns: columns, fitting: true, table: table, size: size, dynamicType: dynamicType,
                             viewportWidth: availableWidth) {
            ForEach(0..<(columns * (rows + 1)), id: \.self) { index in
                let row = index / columns - 1
                let column = index % columns
                LegacyCell(text: row < 0 ? table.header[column] : table.rows[row][column], header: row < 0,
                           alignment: table.alignments[column], last: row == rows - 1, copyInset: false)
            }
        }
    }
}

@MainActor
private struct LegacyCell: View {
    let text: AttributedString
    let header: Bool
    let alignment: SHProseTable.Alignment
    let last: Bool
    let copyInset: Bool
    @Environment(\.shProseSize) private var size

    private var frame: Alignment {
        switch alignment {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }

    var body: some View {
        let sh = Color.sh
        Text(text)
            .font(header ? .sh(.ui, weight: .semibold) : .sh(.body, size: size))
            .lineSpacing(header ? SHTextStyle.ui.lineSpacing(size) : SHTextStyle.headline.lineSpacing(size))
            .foregroundStyle(header ? sh.textSecondary : sh.textPrimary)
            .multilineTextAlignment(alignment.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, SHTableCell.verticalPadding)
            .padding(.leading, SH.Space.l)
            .padding(.trailing, SH.Space.l + (copyInset ? SHThreadMetrics.codeCopyButton : 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frame)
            .background(header ? sh.bgSunken : .clear)
            .overlay(alignment: .bottom) { if !last { SHHairline() } }
            .accessibilityAddTraits(header ? .isHeader : [])
    }
}
