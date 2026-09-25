import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#endif

/// A table in agent prose: a card with the thread's radius and a hairline `lineSubtle` border, a
/// header row on `bgSunken` in `ui` semibold `textSecondary`, cells in the prose size with
/// 8×12 padding, and hairline rows. Columns take their content's width up to
/// `tableColumnMax` and wrap past it; a table narrower than the column hugs its content, and
/// one that cannot fit without squeezing a column under `tableColumnMin` scrolls sideways inside
/// its card, never widening the thread. Copy (on hover on the Mac, always on iOS) copies it as
/// Markdown.
struct NWProseTableView: View, Equatable {
    let table: NWProseTable
    @Environment(\.nwProseSize) private var size
    @State private var hovering = false
    @State private var copied = false
    @State private var copies = 0
    @FocusState private var copyFocused: Bool

    nonisolated static func == (lhs: NWProseTableView, rhs: NWProseTableView) -> Bool { lhs.table == rhs.table }

    var body: some View {
        let _ = NWRenderProbe.tick("prose.table")
        let nw = Color.nw
        // Drawn directly when its columns fit, and in a scroll view only when they do not.
        ViewThatFits(in: .horizontal) {
            grid(fitting: true)
            ScrollView(.horizontal) { grid(fitting: false) }
        }
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
        .overlay(alignment: .topTrailing) { copyButton }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table, \(table.rows.count) \(table.rows.count == 1 ? "row" : "rows")")
    }

    private func grid(fitting: Bool) -> some View {
        let columns = table.columns
        let rows = table.rows.count
        return NWTableLayout(columns: columns, fitting: fitting, table: table, size: size) {
            ForEach(0..<(columns * (rows + 1)), id: \.self) { index in
                let row = index / columns - 1
                let column = index % columns
                NWTableCell(text: row < 0 ? table.header[column] : table.rows[row][column],
                            header: row < 0, alignment: table.alignments[column], last: row == rows - 1,
                            copyInset: NWPlatform.showsHoverDetails && column == columns - 1)
            }
        }
    }

    private var copyButton: some View {
        Button {
            NWPasteboard.copy(table.markdown)
            copied = true
            copies += 1
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            NWCopyGlyph(copied: copied, copies: copies)
        }
        .buttonStyle(.nwIcon(size: NWThreadMetrics.codeCopyButton))
        .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .focused($copyFocused)
        // Centered on the header's first line.
        .padding(.top, ((NWTableCell.verticalPadding * 2 + NWTextStyle.ui.size * NWTextStyle.ui.lineHeight
                         - NWThreadMetrics.codeCopyButton) / 2).rounded())
        .padding(.trailing, NW.Space.xs)
        .opacity(NWPlatform.showsHoverDetails || hovering || copyFocused || copied ? 1 : 0)
        .nwAnimation(.hover, value: hovering || copyFocused || copied)
        .help("Copy as Markdown")
        .accessibilityLabel(copied ? "Copied" : "Copy table as Markdown")
    }
}

/// One cell: its text wraps at the column's width, and it fills its row so the header's fill
/// and the row's hairline span the whole row.
struct NWTableCell: View {
    static let verticalPadding = NW.Space.m
    static let horizontalPadding = NW.Space.l * 2

    let text: AttributedString
    let header: Bool
    let alignment: NWProseTable.Alignment
    /// The last row: the card's border closes it, so it draws no hairline.
    let last: Bool
    /// Where Copy always shows (iOS), the last column leaves room for it, so it never covers
    /// the header and the column's alignment holds. On the Mac it shows on hover, over the
    /// header's end.
    let copyInset: Bool
    @Environment(\.nwProseSize) private var size

    var body: some View {
        let _ = NWRenderProbe.tick("prose.tableCell")
        let nw = Color.nw
        Text(text)
            .font(header ? .nw(.ui, weight: .semibold) : .nw(.body, size: size))
            .lineSpacing(header ? NWTextStyle.ui.lineSpacing(size) : NWTextStyle.headline.lineSpacing(size))
            .foregroundStyle(header ? nw.textSecondary : nw.textPrimary)
            .multilineTextAlignment(alignment.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Self.verticalPadding)
            .padding(.leading, NW.Space.l)
            .padding(.trailing, NW.Space.l + (copyInset ? NWThreadMetrics.codeCopyButton : 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.frame)
            .background(header ? nw.bgSunken : .clear)
            .overlay(alignment: .bottom) { if !last { NWHairline() } }
            .accessibilityAddTraits(header ? .isHeader : [])
    }
}

extension NWProseTable.Alignment {
    var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frame: Alignment {
        switch self {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }
}

/// Lays cells out row by row. A column's natural width is its widest cell, capped at
/// `tableColumnMax`. `fitting` fits the table into the width it is offered: it hugs narrower
/// content, lets capped columns grow into spare room, and shrinks columns toward
/// `tableColumnMin` when it must (its ideal width is the sum of those minimums, so
/// `ViewThatFits` picks it only when that fits). Otherwise columns keep their natural widths
/// (inside a scroll view). Every row is as tall as its tallest cell.
struct NWTableLayout: Layout {
    let columns: Int
    let fitting: Bool
    /// The cells' text, to find each column's widest word.
    let table: NWProseTable
    let size: NWProseSize

    struct Cache {
        /// Each column's widest cell, unwrapped.
        var ideal: [CGFloat]
        /// Each column's widest word, padded: it never shrinks under it, so a wrapped cell
        /// breaks between words, never inside an identifier.
        var words: [CGFloat]
        /// Row heights for the last widths laid out.
        var measured: (widths: [CGFloat], heights: [CGFloat])?
    }

    func makeCache(subviews: Subviews) -> Cache {
        var ideal = Array(repeating: CGFloat.zero, count: columns)
        for (index, subview) in subviews.enumerated() {
            ideal[index % columns] = max(ideal[index % columns], subview.sizeThatFits(.unspecified).width.rounded(.up))
        }
        // SwiftUI lays out on the main thread.
        let words = MainActor.assumeIsolated { [table, size, columns] in
            (0..<columns).map { column in
                var widest = NWTableWords.widest(table.header[column], header: true, size: size)
                for row in table.rows { widest = max(widest, NWTableWords.widest(row[column], header: false, size: size)) }
                let inset = NWPlatform.showsHoverDetails && column == columns - 1 ? NWThreadMetrics.codeCopyButton : 0
                return (widest + NWTableCell.horizontalPadding + inset).rounded(.up) + 1
            }
        }
        return Cache(ideal: ideal, words: words)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let widths = widths(for: proposal.width, cache: cache)
        let heights = heights(for: widths, subviews: subviews, cache: &cache)
        return CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let widths = widths(for: proposal.width, cache: cache)
        let heights = heights(for: widths, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { return }
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: widths[column], height: height))
                x += widths[column]
            }
            y += height
        }
    }

    /// Column widths in `available` points (nil: unconstrained).
    func widths(for available: CGFloat?, cache: Cache) -> [CGFloat] {
        Self.widths(for: available, ideal: cache.ideal, words: cache.words, fitting: fitting,
                    minimum: NWThreadMetrics.tableColumnMin, maximum: NWThreadMetrics.tableColumnMax)
    }

    /// `words` raises a column's minimum to its widest word (never past `maximum`).
    static func widths(for available: CGFloat?, ideal: [CGFloat], words: [CGFloat]? = nil, fitting: Bool,
                       minimum: CGFloat, maximum: CGFloat) -> [CGFloat] {
        let natural = ideal.map { min($0, maximum) }
        let floor = ideal.indices.map { min(ideal[$0], max(minimum, min(words?[$0] ?? 0, maximum))) }
        guard fitting else { return natural }
        guard let available, available.isFinite else { return floor }
        let naturalSum = natural.reduce(0, +)
        if naturalSum <= available {
            // Room to spare: wrapped columns grow toward their content, and the table hugs it.
            let wants = zip(ideal, natural).map { $0 - $1 }
            let wanted = wants.reduce(0, +)
            guard wanted > 0 else { return natural }
            let extra = min(available - naturalSum, wanted)
            return zip(natural, wants).map { ($0 + extra * $1 / wanted).rounded(.down) }
        }
        let floorSum = floor.reduce(0, +)
        guard floorSum < available else { return floor }
        // Too wide: every column gives up its share of the overflow, down to its minimum.
        let gives = zip(natural, floor).map { $0 - $1 }
        let given = gives.reduce(0, +)
        return zip(floor, gives).map { ($0 + (available - floorSum) * $1 / given).rounded(.down) }
    }

    private func heights(for widths: [CGFloat], subviews: Subviews, cache: inout Cache) -> [CGFloat] {
        if let measured = cache.measured, measured.widths == widths { return measured.heights }
        let rows = columns == 0 ? 0 : subviews.count / columns
        var heights = Array(repeating: CGFloat.zero, count: rows)
        for (index, subview) in subviews.enumerated() where index / columns < rows {
            let height = subview.sizeThatFits(ProposedViewSize(width: widths[index % columns], height: nil)).height
            heights[index / columns] = max(heights[index / columns], height.rounded(.up))
        }
        cache.measured = (widths, heights)
        return heights
    }
}

/// The widest word of a cell's text (a stretch a line never breaks inside), measured with
/// CoreText in the faces the cell draws: Geist for text (semibold in the header, bold where
/// strong), Geist Mono for code spans, at the current text scale. Cached per text.
@MainActor
enum NWTableWords {
    private struct Key: Hashable {
        var text: AttributedString
        var header: Bool
        var size: NWProseSize
        var scale: CGFloat
    }

    private static var cache: [Key: CGFloat] = [:]

    static func widest(_ text: AttributedString, header: Bool, size: NWProseSize) -> CGFloat {
        let key = Key(text: text, header: header, size: size, scale: ThemeStore.shared.textScale)
        if let cached = cache[key] { return cached }
        var widest: CGFloat = 0
        var word: CGFloat = 0
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            let font = font(code: intent.contains(.code), strong: header || intent.contains(.stronglyEmphasized),
                            style: header ? .ui : .body, size: size)
            var token = ""
            for character in text[run.range].characters {
                if character.isWhitespace {
                    word += measure(token, font)
                    token = ""
                    widest = max(widest, word)
                    word = 0
                } else {
                    token.append(character)
                }
            }
            // A word may run on into the next run ("`notify`,").
            word += measure(token, font)
        }
        widest = max(widest, word)
        if cache.count > 4096 { cache.removeAll(keepingCapacity: true) }
        cache[key] = widest
        return widest
    }

    private static func font(code: Bool, strong: Bool, style: NWTextStyle, size: NWProseSize) -> CTFont {
        let points = code ? NWTextStyle.code.size : style.size - (style == .body ? size.step : 0)
        var scaled = points * ThemeStore.shared.textScale
        #if os(iOS)
        scaled = UIFontMetrics(forTextStyle: code ? .callout : style == .ui ? .callout : .body).scaledValue(for: scaled)
        #endif
        let name = NWFonts.postScriptName(mono: code, weight: code ? .regular : strong ? (style == .ui ? .semibold : .bold) : .regular)
        return CTFontCreateWithName(name as CFString, scaled, nil)
    }

    private static func measure(_ token: String, _ font: CTFont) -> CGFloat {
        guard !token.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: token, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
