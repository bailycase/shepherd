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

    /// A table's text is selectable once the pointer has entered it (`selectable` is what that turns on): the cells take their selection
    /// views then, and the table does not move, resize or draw a pixel differently, at a width where a column wraps and where none does.
    @Test(arguments: [false, true])
    func aTableBecomesSelectableWithoutMovingAPixel(dark: Bool) async throws {
        for width in [700, 430] as [CGFloat] {
            let flip = try await Self.flip(Self.plainTable, width: width, dark: dark)
            #expect(flip.cardBefore == flip.cardAfter && flip.cardBefore.width > 0, "the card keeps its size: \(flip.cardBefore) then \(flip.cardAfter)")
            #expect(flip.selectionBefore == 0 && flip.selectionAfter == flip.cells, "no selection view before the pointer comes, one a cell after")
            #expect(flip.differing == 0, "\(flip.differing) of \(flip.bytes) bytes differ at \(width) pt, \(dark ? "dark" : "light")")
        }
    }

    /// A code span's background on the last line of a wrapped cell is a pixel wider and two taller in text that is not selectable, which is
    /// how SwiftUI draws it: the table's size and everything else it draws are unchanged.
    @Test func aWrappedCodeSpanIsAPixelLargerUntilThePointerEntersItsTable() async throws {
        let flip = try await Self.flip(Self.mixedTable, width: 430, dark: false)
        #expect(flip.cardBefore == flip.cardAfter && flip.cardBefore.width > 0, "the card keeps its size: \(flip.cardBefore) then \(flip.cardAfter)")
        #expect(flip.selectionBefore == 0 && flip.selectionAfter == flip.cells)
        // 218 pixels: the box's right edge and its bottom two rows, under the last line of the one cell that wraps.
        #expect(flip.differing > 0 && flip.differing / 4 < 300, "\(flip.differing / 4) pixels differ")
    }

    /// The card is the same size whether the text is selectable from the first frame or not: the flip above keeps the layout's cached
    /// measurements, so only a table laid out each way from the start can show unselectable text measuring differently.
    @Test(arguments: [false, true])
    func aTableIsTheSameSizeWhetherItsTextIsSelectableFromTheStartOrNot(dark: Bool) async throws {
        for table in [Self.plainTable, Self.mixedTable] {
            let cells = table.columns * (table.rows.count + 1)
            for width in [700, 430] as [CGFloat] {
                let plain = try await Self.opened(table, width: width, dark: dark, selectable: false)
                let selectable = try await Self.opened(table, width: width, dark: dark, selectable: true)
                #expect(plain.selection == 0 && selectable.selection == cells, "selection views: \(plain.selection) then \(selectable.selection) of \(cells)")
                #expect(plain.card == selectable.card && plain.card.width > 0, "the card at \(width) pt: \(plain.card) then \(selectable.card)")
            }
        }
    }

    /// The pointer over a table arms its cells in steps, never all at once, so a table of hundreds of cells takes its selection views over
    /// many turns of the run loop where one stalled it; a cell is built again only for its own step; and the pointer leaving stops the
    /// arming where it was, with every cell armed so far still armed.
    @Test func aTableUnderThePointerTakesItsSelectionViewsInSteps() async throws {
        let table = Self.table(rows: 200, columns: 4)
        let cells = table.columns * (table.rows.count + 1)
        let pointer = Selectability()
        let window = OffscreenWindow(size: CGSize(width: 900, height: 600), dark: false, PointerTableHost(table: table, pointer: pointer))
        defer { window.close() }
        _ = try await Self.settled(window, "the table to stop moving")
        #expect(Self.selectionViews(in: window) == 0, "no selection view until the pointer is over the table")

        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        pointer.on = true
        var seen = 0
        try await eventuallyOnMain("the first cells to take their selection views") {
            ListPerf.settle(window)
            seen = Self.selectionViews(in: window)
            return seen > 0
        }
        pointer.on = false
        var last = -1
        var still = 0
        try await eventuallyOnMain("the arming to stop where it was") {
            ListPerf.settle(window)
            let now = Self.selectionViews(in: window)
            still = now == last ? still + 1 : 0
            last = now
            return still >= 10
        }
        #expect(last >= seen && last < cells, "the pointer leaving stops the arming part of the way: \(seen) of \(cells), then \(last)")

        pointer.on = true
        var partial = 0
        var previous = last
        try await eventuallyOnMain("every cell to take its selection view") {
            ListPerf.settle(window)
            let now = Self.selectionViews(in: window)
            if now > previous && now < cells { partial += 1 }
            previous = now
            return now == cells
        }
        #expect(partial > 0, "the arming resumes in steps, not all at once")
        let built = SHRenderProbe.count("prose.tableCell")
        #expect(built <= 2 * cells, "each cell is built for its own step, not at every step: \(built) for \(cells) cells")
    }

    private struct Flip {
        var cells = 0
        var cardBefore = CGRect.zero
        var cardAfter = CGRect.zero
        var selectionBefore = 0
        var selectionAfter = 0
        var differing = 0
        var bytes = 0
    }

    /// What `window` shows once it has stopped moving and `done` holds, and the table's card.
    private static func settled(_ window: OffscreenWindow, _ what: String, until done: @escaping () -> Bool = { true })
        async throws -> (pixels: [UInt8], card: CGRect) {
        var last: [UInt8] = []
        var still = 0
        try await eventuallyOnMain(what) {
            ListPerf.settle(window)
            let now = Self.pixels(of: window)
            still = now == last && done() ? still + 1 : 0
            last = now
            return still >= 5
        }
        return (last, ListPerf.scrollView(in: window)?.frame ?? .zero)
    }

    /// `table` drawn at `width` before its text is selectable and again once it is, in one window.
    private static func flip(_ table: SHProseTable, width: CGFloat, dark: Bool) async throws -> Flip {
        let selection = Selectability()
        let window = OffscreenWindow(size: CGSize(width: width, height: 420), dark: dark, SelectableTableHost(table: table, selection: selection))
        defer { window.close() }
        var result = Flip(cells: table.columns * (table.rows.count + 1))
        let before = try await settled(window, "the table to stop moving at \(width) pt")
        result.selectionBefore = selectionViews(in: window)
        selection.on = true
        let after = try await settled(window, "every cell to take its selection view at \(width) pt") { selectionViews(in: window) == result.cells }
        result.selectionAfter = selectionViews(in: window)
        result.cardBefore = before.card
        result.cardAfter = after.card
        result.bytes = after.pixels.count
        result.differing = before.pixels.count == after.pixels.count ? zip(before.pixels, after.pixels).filter { $0 != $1 }.count : after.pixels.count
        return result
    }

    /// `table` laid out at `width` in a window of its own with its text selectable from the first frame, or not.
    private static func opened(_ table: SHProseTable, width: CGFloat, dark: Bool, selectable: Bool) async throws -> (card: CGRect, selection: Int) {
        let window = OffscreenWindow(size: CGSize(width: width, height: 420), dark: dark,
                                     SelectableTableHost(table: table, selection: Selectability(on: selectable)))
        defer { window.close() }
        let card = try await settled(window, "the table to stop moving at \(width) pt").card
        return (card, selectionViews(in: window))
    }

    private static func selectionViews(in window: OffscreenWindow) -> Int {
        func count(_ view: NSView) -> Int {
            (String(describing: type(of: view)).contains("TextInteraction") ? 1 : 0) + view.subviews.reduce(0) { $0 + count($1) }
        }
        return count(window.host)
    }

    /// What the window shows, as bytes.
    private static func pixels(of window: OffscreenWindow) -> [UInt8] {
        let view = window.host
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
    }

    /// Every alignment, a header and rows, a column that wraps, and bold words, with no code span.
    private static var plainTable: SHProseTable {
        SHProseTable(
            alignments: [.leading, .center, .trailing, .leading],
            header: ["Area", "Count", "Share", "Notes"].map { SHProseInline.attributed($0) },
            rows: [
                ["Terminals", "6", "19%", "Open, run, read, focus and close a terminal the agent started, each of them by the name it was given"],
                ["Peers", "8", "26%", "List, send, read and steer another agent"],
                ["Notes", "2", "6%", "Notify, and **review**"],
                ["Everything else together", "1,234", "100%", "A longer sentence of plain words that wraps over a couple of lines in its column"],
            ].map { $0.map { SHProseInline.attributed($0) } },
            markdown: "")
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

    /// `rows` rows of short cells in `columns` columns.
    private static func table(rows: Int, columns: Int) -> SHProseTable {
        SHProseTable(
            alignments: Array(repeating: .leading, count: columns),
            header: (0..<columns).map { AttributedString("Column \($0)") },
            rows: (0..<rows).map { row in (0..<columns).map { AttributedString("row \(row) column \($0)") } },
            markdown: "")
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
            SHProseTableView(table: table, selectable: true).equatable()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Whether the table's text is selectable, or the pointer is over the table, from outside: what the pointer entering it makes true.
@MainActor @Observable
private final class Selectability {
    var on: Bool

    init(on: Bool = false) { self.on = on }
}

/// A table with the pointer put over it, or taken away, from outside.
@MainActor
private struct PointerTableHost: View {
    let table: SHProseTable
    let pointer: Selectability

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SHProseTableView(table: table, selectable: false, pointerOver: pointer.on).equatable()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
private struct SelectableTableHost: View {
    let table: SHProseTable
    let selection: Selectability

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SHProseTableView(table: table, selectable: selection.on).equatable()
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
