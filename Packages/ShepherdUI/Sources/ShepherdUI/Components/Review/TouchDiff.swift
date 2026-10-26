import SwiftUI

/// The touch diff's columns (MobileDiff, iPadReview, iPadReviewSplit boards): 32pt line-number
/// gutters, a 14pt sign column, then the code. A touch reader has no hover, so a line is tapped
/// to select it (a 3pt running bar and tint), and lines wrap rather than truncate.
public enum SHTouchDiffMetrics {
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
public struct SHTouchDiffLine: View, Equatable {
    let line: SHDiffLineContent
    let gutters: Int
    let wraps: Bool
    let selected: Bool
    let commented: Bool
    let changeBar: Bool
    let onTap: (() -> Void)?

    /// `changeBar` marks an added or removed line with a 3pt bar at its leading edge (the
    /// Changes pane's gutter bar, iPadReview), which the selection's bar replaces.
    public init(_ line: SHDiffLineContent, gutters: Int = 1, wraps: Bool = true, selected: Bool = false, commented: Bool = false,
                changeBar: Bool = false, onTap: (() -> Void)? = nil) {
        self.line = line
        self.gutters = gutters
        self.wraps = wraps
        self.selected = selected
        self.commented = commented
        self.changeBar = changeBar
        self.onTap = onTap
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.line == rhs.line && lhs.gutters == rhs.gutters && lhs.wraps == rhs.wraps && lhs.selected == rhs.selected
            && lhs.commented == rhs.commented && lhs.changeBar == rhs.changeBar && (lhs.onTap == nil) == (rhs.onTap == nil)
    }

    public var body: some View {
        let sh = Color.sh
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if gutters >= 2 {
                SHTouchDiffNumber(value: line.oldNumber)
                SHTouchDiffNumber(value: line.newNumber)
            } else {
                SHTouchDiffNumber(value: line.number)
            }
            Text(line.kind.sign)
                .font(.sh(.mono))
                .foregroundStyle(line.kind == .added ? sh.done : sh.failed)
                .frame(width: SHTouchDiffMetrics.signWidth, alignment: .leading)
            Text(line.text)
                .font(.sh(.code))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(wraps ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: wraps)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, SH.Space.m)
        }
        .padding(.vertical, SH.Space.xxs)
        .frame(minHeight: SH.Height.rowCompact)
        .background(background(sh))
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(sh.running).frame(width: SHTouchDiffMetrics.selectionBar)
            } else if commented {
                Rectangle().fill(sh.lantern).frame(width: SHTouchDiffMetrics.selectionBar)
            } else if changeBar, line.kind != .context {
                Rectangle().fill(line.kind == .added ? sh.done : sh.failed).frame(width: SHTouchDiffMetrics.selectionBar)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityText + (commented ? ", commented" : ""))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : onTap == nil ? [] : .isButton)
        .accessibilityHint(onTap == nil ? "" : "Selects the line to comment on it")
    }

    private func background(_ sh: SHPalette) -> Color {
        if selected { return sh.runningTint }
        // A line with a comment waiting (MobileDiff, iPadReview: lantern bar and tint).
        if commented { return sh.lanternTint }
        switch line.kind {
        case .added: return sh.doneTint
        case .removed: return sh.failedTint
        case .context: return .clear
        }
    }
}

/// A line number, right-aligned in its gutter; five digits shrink to fit.
private struct SHTouchDiffNumber: View {
    let value: Int?
    /// The gutter grows with the text size, so large text keeps four digits whole.
    @ScaledMetric(relativeTo: .caption2) private var width = SHTouchDiffMetrics.numberWidth

    var body: some View {
        Text(value.map(String.init) ?? "")
            .font(.sh(.micro, weight: .regular))
            .monospacedDigit()
            .foregroundStyle(.sh.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.trailing, SH.Space.s)
            .frame(width: width, alignment: .trailing)
    }
}

/// A hunk header across the diff: its header in tertiary mono on the running tint (the phone
/// board), or on `bgSunken` beside a docked review.
public struct SHTouchHunkHeader: View {
    let header: String
    let leading: CGFloat
    let tinted: Bool

    public init(_ header: String, leading: CGFloat = SH.Space.l, tinted: Bool = true) {
        self.header = header
        self.leading = leading
        self.tinted = tinted
    }

    public var body: some View {
        Text(header)
            .font(.sh(.micro, weight: .regular))
            .foregroundStyle(.sh.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, leading)
            .padding(.trailing, SH.Space.l)
            .padding(.vertical, SH.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tinted ? Color.sh.runningTint : Color.sh.bgSunken)
            .accessibilityLabel("Hunk \(header)")
    }
}

/// A run of folded lines, as tall as a touch target: "+ 13 more removed lines · 18–32". Tapping
/// it shows them.
public struct SHTouchFoldRow: View {
    let count: Int
    let kind: SHDiffLineKind
    let range: String
    let leading: CGFloat
    let action: () -> Void

    public init(count: Int, kind: SHDiffLineKind, range: String, leading: CGFloat, action: @escaping () -> Void) {
        self.count = count
        self.kind = kind
        self.range = range
        self.leading = leading
        self.action = action
    }

    /// "+ 13 more removed lines · 18–32" (the range is left off when empty).
    public static func label(count: Int, kind: SHDiffLineKind, range: String) -> String {
        let lines = "\(count) more \(kind.word) line\(count == 1 ? "" : "s")"
        return range.isEmpty ? "+ \(lines)" : "+ \(lines) · \(range)"
    }

    public var body: some View {
        let sh = Color.sh
        Button(action: action) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(Self.label(count: count, kind: kind, range: range))
                    .lineLimit(1)
            }
            .font(.sh(.micro, weight: .regular))
            .foregroundStyle(sh.textSecondary)
            .padding(.leading, leading)
            .frame(maxWidth: .infinity, minHeight: SH.Height.touch, alignment: .leading)
            .background(sh.bgSunken)
            .overlay(alignment: .top) { SHHairline() }
            .overlay(alignment: .bottom) { SHHairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the folded lines")
    }
}

/// One row of a diff side by side (iPadReviewSplit board): the old line beside the new one, each
/// with its number and sign on one line, a 1px rule between. An empty side is blank, or with
/// `hatched` striped so the rows still line up (ChangesStates › Filler).
public struct SHSplitDiffRow: View, Equatable {
    let old: SHDiffLineContent?
    let new: SHDiffLineContent?
    let selected: SHDiffLineContent.ID?
    let hatched: Bool
    let onTap: ((SHDiffLineContent) -> Void)?

    public init(old: SHDiffLineContent?, new: SHDiffLineContent?, selected: SHDiffLineContent.ID? = nil, hatched: Bool = false,
                onTap: ((SHDiffLineContent) -> Void)? = nil) {
        self.old = old
        self.new = new
        self.selected = selected
        self.hatched = hatched
        self.onTap = onTap
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.old == rhs.old && lhs.new == rhs.new && lhs.selected == rhs.selected && lhs.hatched == rhs.hatched
            && (lhs.onTap == nil) == (rhs.onTap == nil)
    }

    public var body: some View {
        HStack(spacing: 0) {
            side(old)
            SHHairline(.vertical)
            side(new)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func side(_ line: SHDiffLineContent?) -> some View {
        if let line {
            SHTouchDiffLine(line, gutters: 1, wraps: false, selected: line.id == selected, changeBar: hatched,
                            onTap: onTap.map { tap in { tap(line) } })
        } else if hatched {
            SHHatchStripes()
                .stroke(Color.sh.lineSubtle, lineWidth: 1)
                .clipped()
                .frame(maxWidth: .infinity, minHeight: SH.Height.rowCompact)
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: SH.Height.rowCompact).accessibilityHidden(true)
        }
    }
}

/// Stripes at 135°, every 6pt: the side of a split row with no line opposite.
struct SHHatchStripes: Shape {
    static let spacing: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += Self.spacing
        }
        return path
    }
}

/// A fold side by side: on its side's half, the other half left sunken and blank.
public struct SHSplitFoldRow: View {
    public enum Side: Sendable { case old, new, both }

    let count: Int
    let kind: SHDiffLineKind
    let range: String
    let side: Side
    let action: () -> Void

    public init(count: Int, kind: SHDiffLineKind, range: String, side: Side, action: @escaping () -> Void) {
        self.count = count
        self.kind = kind
        self.range = range
        self.side = side
        self.action = action
    }

    public var body: some View {
        let fold = SHTouchFoldRow(count: count, kind: kind, range: range, leading: SHTouchDiffMetrics.annotationLeading(gutters: 1), action: action)
        HStack(spacing: 0) {
            if side == .new { blank } else { fold }
            SHHairline(.vertical)
            if side == .old { blank } else if side == .new { fold } else { blank }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var blank: some View {
        Color.sh.bgSunken.frame(maxWidth: .infinity, minHeight: SH.Height.touch).accessibilityHidden(true)
    }
}

#Preview("Touch diff") {
    let line = { (id: Int, kind: SHDiffLineKind, old: Int?, new: Int?, code: String) in
        SHDiffLineContent(id: "l\(id)", key: id, kind: kind, oldNumber: old, newNumber: new, text: AttributedString(code), source: code)
    }
    SHPreviewBoth {
        VStack(spacing: 0) {
            SHTouchHunkHeader("@@ -12,55 +12,21 @@ struct FleetView: View")
            SHTouchDiffLine(line(1, .context, 12, 12, "  let connected = connection.phase == .connected"))
            SHTouchDiffLine(line(2, .removed, 15, nil, "      Section {"))
            SHTouchFoldRow(count: 13, kind: .removed, range: "18–32", leading: SHTouchDiffMetrics.annotationLeading(gutters: 1)) {}
            SHTouchDiffLine(line(3, .added, nil, 16, "        HostCard(connection: connection) { showingSettings = true } // a long line wraps on the phone"),
                            selected: true)
            SHTouchDiffLine(line(4, .added, nil, 17, "          .listRowBackground(tokens.sidebar)"), gutters: 2)
            SHSplitDiffRow(old: line(5, .removed, 16, nil, "if let configuration {"), new: line(6, .added, nil, 16, "HostCard(connection)"))
            SHSplitDiffRow(old: line(7, .removed, 17, nil, "HStack(spacing: 12) {"), new: nil)
            SHSplitFoldRow(count: 13, kind: .removed, range: "18–32", side: .old) {}
        }
        .frame(width: 360)
    }
}
