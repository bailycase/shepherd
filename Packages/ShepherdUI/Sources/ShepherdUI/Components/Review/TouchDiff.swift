import SwiftUI

/// The touch diff's columns (MobileDiff, iPadReview, iPadReviewSplit boards): 32pt line-number
/// gutters, a 14pt sign column, then the code. A touch reader has no hover, so a line is tapped
/// to select it (a 3pt running bar and tint), and lines wrap rather than truncate.
public enum NWTouchDiffMetrics {
    public static let numberWidth: CGFloat = 32
    public static let signWidth: CGFloat = 14
    /// The selected line's bar at its leading edge.
    public static let selectionBar: CGFloat = 3
    /// Where a fold's label and an inline comment start with one gutter, and with two.
    public static func annotationLeading(gutters: Int) -> CGFloat {
        CGFloat(gutters) * numberWidth + signWidth
    }
}

/// One line of a touch diff. With two gutters it shows both sides' numbers (iPad unified), with
/// one the number a reader cites (the phone). `wraps` false keeps it to one line (side by side).
/// Equal on its values, so a long diff redraws only the lines whose selection or text changed.
public struct NWTouchDiffLine: View, Equatable {
    let line: NWDiffLineContent
    let gutters: Int
    let wraps: Bool
    let selected: Bool
    let commented: Bool
    let onTap: (() -> Void)?

    public init(_ line: NWDiffLineContent, gutters: Int = 1, wraps: Bool = true, selected: Bool = false, commented: Bool = false,
                onTap: (() -> Void)? = nil) {
        self.line = line
        self.gutters = gutters
        self.wraps = wraps
        self.selected = selected
        self.commented = commented
        self.onTap = onTap
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.line == rhs.line && lhs.gutters == rhs.gutters && lhs.wraps == rhs.wraps && lhs.selected == rhs.selected
            && lhs.commented == rhs.commented && (lhs.onTap == nil) == (rhs.onTap == nil)
    }

    public var body: some View {
        let nw = Color.nw
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if gutters >= 2 {
                NWTouchDiffNumber(value: line.oldNumber)
                NWTouchDiffNumber(value: line.newNumber)
            } else {
                NWTouchDiffNumber(value: line.number)
            }
            Text(line.kind.sign)
                .font(.nw(.mono))
                .foregroundStyle(line.kind == .added ? nw.done : nw.failed)
                .frame(width: NWTouchDiffMetrics.signWidth, alignment: .leading)
            Text(line.text)
                .font(.nw(.mono))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(wraps ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: wraps)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, NW.Space.m)
        }
        .padding(.vertical, NW.Space.xxs)
        .frame(minHeight: NW.Height.rowCompact)
        .background(background(nw))
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(nw.running).frame(width: NWTouchDiffMetrics.selectionBar) }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityText + (commented ? ", commented" : ""))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : onTap == nil ? [] : .isButton)
        .accessibilityHint(onTap == nil ? "" : "Selects the line to comment on it")
    }

    private func background(_ nw: NWPalette) -> Color {
        if selected { return nw.runningTint }
        switch line.kind {
        case .added: return nw.doneTint
        case .removed: return nw.failedTint
        case .context: return .clear
        }
    }
}

/// A line number, right-aligned in its gutter; five digits shrink to fit.
private struct NWTouchDiffNumber: View {
    let value: Int?
    /// The gutter grows with the text size, so large text keeps four digits whole.
    @ScaledMetric(relativeTo: .caption2) private var width = NWTouchDiffMetrics.numberWidth

    var body: some View {
        Text(value.map(String.init) ?? "")
            .font(.nw(.micro, weight: .regular))
            .monospacedDigit()
            .foregroundStyle(.nw.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.trailing, NW.Space.s)
            .frame(width: width, alignment: .trailing)
    }
}

/// A hunk header across the diff: its header in tertiary mono on the running tint (the phone
/// board), or on `bgSunken` beside a docked review.
public struct NWTouchHunkHeader: View {
    let header: String
    let leading: CGFloat
    let tinted: Bool

    public init(_ header: String, leading: CGFloat = NW.Space.l, tinted: Bool = true) {
        self.header = header
        self.leading = leading
        self.tinted = tinted
    }

    public var body: some View {
        Text(header)
            .font(.nw(.micro, weight: .regular))
            .foregroundStyle(.nw.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, leading)
            .padding(.trailing, NW.Space.l)
            .padding(.vertical, NW.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tinted ? Color.nw.runningTint : Color.nw.bgSunken)
            .accessibilityLabel("Hunk \(header)")
    }
}

/// A run of folded lines, as tall as a touch target: "+ 13 more removed lines · 18–32". Tapping
/// it shows them.
public struct NWTouchFoldRow: View {
    let count: Int
    let kind: NWDiffLineKind
    let range: String
    let leading: CGFloat
    let action: () -> Void

    public init(count: Int, kind: NWDiffLineKind, range: String, leading: CGFloat, action: @escaping () -> Void) {
        self.count = count
        self.kind = kind
        self.range = range
        self.leading = leading
        self.action = action
    }

    /// "+ 13 more removed lines · 18–32" (the range is left off when empty).
    public static func label(count: Int, kind: NWDiffLineKind, range: String) -> String {
        let lines = "\(count) more \(kind.word) line\(count == 1 ? "" : "s")"
        return range.isEmpty ? "+ \(lines)" : "+ \(lines) · \(range)"
    }

    public var body: some View {
        let nw = Color.nw
        Button(action: action) {
            HStack(spacing: NW.Space.m) {
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(Self.label(count: count, kind: kind, range: range))
                    .lineLimit(1)
            }
            .font(.nw(.micro, weight: .regular))
            .foregroundStyle(nw.textSecondary)
            .padding(.leading, leading)
            .frame(maxWidth: .infinity, minHeight: NW.Height.touch, alignment: .leading)
            .background(nw.bgSunken)
            .overlay(alignment: .top) { NWHairline() }
            .overlay(alignment: .bottom) { NWHairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the folded lines")
    }
}

/// One row of a diff side by side (iPadReviewSplit board): the old line beside the new one, each
/// with its number and sign on one line, a 1px rule between. An empty side is blank.
public struct NWSplitDiffRow: View, Equatable {
    let old: NWDiffLineContent?
    let new: NWDiffLineContent?
    let selected: NWDiffLineContent.ID?
    let onTap: ((NWDiffLineContent) -> Void)?

    public init(old: NWDiffLineContent?, new: NWDiffLineContent?, selected: NWDiffLineContent.ID? = nil,
                onTap: ((NWDiffLineContent) -> Void)? = nil) {
        self.old = old
        self.new = new
        self.selected = selected
        self.onTap = onTap
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.old == rhs.old && lhs.new == rhs.new && lhs.selected == rhs.selected && (lhs.onTap == nil) == (rhs.onTap == nil)
    }

    public var body: some View {
        HStack(spacing: 0) {
            side(old)
            NWHairline(.vertical)
            side(new)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func side(_ line: NWDiffLineContent?) -> some View {
        if let line {
            NWTouchDiffLine(line, gutters: 1, wraps: false, selected: line.id == selected, onTap: onTap.map { tap in { tap(line) } })
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: NW.Height.rowCompact).accessibilityHidden(true)
        }
    }
}

/// A fold side by side: on its side's half, the other half left sunken and blank.
public struct NWSplitFoldRow: View {
    public enum Side: Sendable { case old, new, both }

    let count: Int
    let kind: NWDiffLineKind
    let range: String
    let side: Side
    let action: () -> Void

    public init(count: Int, kind: NWDiffLineKind, range: String, side: Side, action: @escaping () -> Void) {
        self.count = count
        self.kind = kind
        self.range = range
        self.side = side
        self.action = action
    }

    public var body: some View {
        let fold = NWTouchFoldRow(count: count, kind: kind, range: range, leading: NWTouchDiffMetrics.annotationLeading(gutters: 1), action: action)
        HStack(spacing: 0) {
            if side == .new { blank } else { fold }
            NWHairline(.vertical)
            if side == .old { blank } else if side == .new { fold } else { blank }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var blank: some View {
        Color.nw.bgSunken.frame(maxWidth: .infinity, minHeight: NW.Height.touch).accessibilityHidden(true)
    }
}

#Preview("Touch diff") {
    let line = { (id: Int, kind: NWDiffLineKind, old: Int?, new: Int?, code: String) in
        NWDiffLineContent(id: "l\(id)", key: id, kind: kind, oldNumber: old, newNumber: new, text: AttributedString(code), source: code)
    }
    NWPreviewBoth {
        VStack(spacing: 0) {
            NWTouchHunkHeader("@@ -12,55 +12,21 @@ struct FleetView: View")
            NWTouchDiffLine(line(1, .context, 12, 12, "  let connected = connection.phase == .connected"))
            NWTouchDiffLine(line(2, .removed, 15, nil, "      Section {"))
            NWTouchFoldRow(count: 13, kind: .removed, range: "18–32", leading: NWTouchDiffMetrics.annotationLeading(gutters: 1)) {}
            NWTouchDiffLine(line(3, .added, nil, 16, "        HostCard(connection: connection) { showingSettings = true } // a long line wraps on the phone"),
                            selected: true)
            NWTouchDiffLine(line(4, .added, nil, 17, "          .listRowBackground(tokens.sidebar)"), gutters: 2)
            NWSplitDiffRow(old: line(5, .removed, 16, nil, "if let configuration {"), new: line(6, .added, nil, 16, "HostCard(connection)"))
            NWSplitDiffRow(old: line(7, .removed, 17, nil, "HStack(spacing: 12) {"), new: nil)
            NWSplitFoldRow(count: 13, kind: .removed, range: "18–32", side: .old) {}
        }
        .frame(width: 360)
    }
}
