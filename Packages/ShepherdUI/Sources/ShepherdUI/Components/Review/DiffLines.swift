import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A diff line's kind: unchanged context, an addition, or a removal.
public enum NWDiffLineKind: Sendable, Hashable {
    case context
    case added
    case removed

    /// The sign column: "+", a true minus, or blank.
    public var sign: String {
        switch self {
        case .context: ""
        case .added: "+"
        case .removed: "\u{2212}"
        }
    }

    /// The fold row's word for a run of this kind.
    public var word: String {
        switch self {
        case .context: "unchanged"
        case .added: "added"
        case .removed: "removed"
        }
    }
}

/// The Changes pane's diff columns (ChangesSplit, ChangesUnified): a 3pt gutter bar, 34pt
/// line-number gutters (two in unified, one per side in split), a 16pt sign column in unified,
/// then the code. Comments sit 40pt in, under their line.
public enum NWDiffMetrics {
    public static let barWidth: CGFloat = 3
    public static let numberWidth: CGFloat = 34
    public static let signWidth: CGFloat = 16
    /// Where the unified code column starts.
    public static let codeLeading: CGFloat = barWidth + numberWidth * 2 + signWidth
    /// Where a split side's code starts.
    public static let splitCodeLeading: CGFloat = barWidth + numberWidth
    /// Notices ("Binary file") and comments.
    public static let annotationLeading: CGFloat = 40
    /// Around a line's comment or comment editor.
    public static let annotationInsets = EdgeInsets(top: NW.Space.s, leading: annotationLeading, bottom: NW.Space.m, trailing: NW.Space.l)
    /// The fold row's reveal column.
    public static let foldControlWidth: CGFloat = 37
    /// The gap between the hatching's diagonal lines.
    public static let hatchSpacing: CGFloat = 7
    /// A line; density-scaled.
    @MainActor public static var lineHeight: CGFloat { NW.Height.scaled(21) }
    /// A fold row, a little taller than a line; density-scaled.
    @MainActor public static var foldHeight: CGFloat { NW.Height.scaled(26) }
}

/// One line of a diff, ready to draw: the text arrives already syntax colored (and with its word
/// diff tinted), so nothing is parsed or highlighted while a row renders.
public struct NWDiffLineContent: Identifiable, Equatable, Sendable {
    /// The row's identity in the diff (stable across renders).
    public let id: String
    /// The caller's key for the line (for a comment lookup), unique within its file.
    public let key: Int
    public let kind: NWDiffLineKind
    public let oldNumber: Int?
    public let newNumber: Int?
    /// The code, syntax colored or plain.
    public let text: AttributedString
    /// The plain source line: the help tag and VoiceOver.
    public let source: String

    public init(id: String, key: Int, kind: NWDiffLineKind, oldNumber: Int?, newNumber: Int?, text: AttributedString, source: String) {
        self.id = id
        self.key = key
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
        self.source = source
    }

    /// The number a reader cites: the new side's, or the old side's for a removal.
    public var number: Int? { newNumber ?? oldNumber }

    /// "Removed line 16: if let configuration…", read as one element.
    public var accessibilityText: String {
        let numbered = number.map { " \($0)" } ?? ""
        let lead = switch kind {
        case .context: "Line\(numbered)"
        case .added: "Added line\(numbered)"
        case .removed: "Removed line\(numbered)"
        }
        let code = source.trimmingCharacters(in: .whitespaces)
        return code.isEmpty ? "\(lead), blank" : "\(lead): \(code)"
    }
}

/// One row of the touch diff (the iOS client's review): a hunk header, a line, or a fold.
public enum NWDiffRow: Identifiable, Equatable, Sendable {
    case hunk(id: String, header: String)
    case line(NWDiffLineContent)
    /// Folded lines: how many, their kind, and the numbers they span ("18–32").
    case fold(id: String, count: Int, kind: NWDiffLineKind, range: String)

    public var id: String {
        switch self {
        case .hunk(let id, _), .fold(let id, _, _, _): id
        case .line(let line): line.id
        }
    }
}

/// Unmodified lines folded away (FoldRow): how many, and which way they can open. A fold at the
/// top of a file opens only upward, one at its end only downward.
public struct NWDiffFold: Identifiable, Equatable, Sendable {
    public let id: String
    public let count: Int
    public let revealsUp: Bool
    public let revealsDown: Bool

    public init(id: String, count: Int, revealsUp: Bool = true, revealsDown: Bool = true) {
        self.id = id
        self.count = count
        self.revealsUp = revealsUp
        self.revealsDown = revealsDown
    }

    /// "28 unmodified lines".
    public var label: String { "\(count) unmodified line\(count == 1 ? "" : "s")" }
}

/// What a fold's control asks for: 20 lines at its bottom edge (up), 20 at its top (down), or
/// every line.
public enum NWDiffReveal: Sendable, Equatable {
    case up, down, all
}

/// One row of the Changes pane's diff: a unified line, a split pair (either side may be missing),
/// a fold of unmodified lines, or a notice ("Binary file").
public enum NWChangesRow: Identifiable, Equatable, Sendable {
    case line(NWDiffLineContent)
    case pair(id: String, old: NWDiffLineContent?, new: NWDiffLineContent?)
    case fold(NWDiffFold)
    case notice(id: String, text: String)

    public var id: String {
        switch self {
        case .line(let line): line.id
        case .pair(let id, _, _), .notice(let id, _): id
        case .fold(let fold): fold.id
        }
    }

    /// The lines a row draws, whose comments show under it: the old side first.
    public var lines: [NWDiffLineContent] {
        switch self {
        case .line(let line): [line]
        case .pair(_, let old, let new): [old, new].compactMap { $0 }
        case .fold, .notice: []
        }
    }
}

// MARK: Lines

/// A unified line (ChangesUnified): the 3pt gutter bar on a change, the old and new numbers, the
/// sign, and the syntax-colored code in mono 12, cut at the pane's edge with the full line on
/// hover. Additions sit on `doneTint`, removals on `failedTint`, and a changed word on a second
/// layer of the same tint. With `onComment`, hovering shows a lantern "+", and double-clicking
/// the line also comments.
public struct NWDiffLine: View {
    let line: NWDiffLineContent
    let onComment: (() -> Void)?
    @State private var hovering = false

    public init(_ line: NWDiffLineContent, onComment: (() -> Void)? = nil) {
        self.line = line
        self.onComment = onComment
    }

    /// A line that starts hovered (tests: hovering is seeded, never the pointer).
    init(_ line: NWDiffLineContent, onComment: (() -> Void)?, hovering: Bool) {
        self.line = line
        self.onComment = onComment
        _hovering = State(initialValue: hovering)
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("diff.line")
        let nw = Color.nw
        HStack(spacing: 0) {
            NWDiffGutterBar(kind: line.kind)
            NWDiffNumber(value: line.oldNumber)
            NWDiffNumber(value: line.newNumber)
            Text(line.kind.sign)
                .font(.nw(.code))
                .foregroundStyle(line.kind == .added ? nw.done : nw.failed)
                .frame(width: NWDiffMetrics.signWidth, alignment: .leading)
            NWDiffCode(line: line)
            NWDiffCommentSlot(hovering: hovering, onComment: onComment)
        }
        .frame(height: NWDiffMetrics.lineHeight)
        .background(NWDiffLineBackground.color(line.kind, hovering: hovering && onComment != nil))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .onTapGesture(count: 2) { onComment?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityText)
        .accessibilityActions {
            if let onComment { Button("Comment", action: onComment) }
        }
    }

    static let commentButtonSize: CGFloat = 18
}

/// One side of a split row (ChangesSplit): the gutter bar, the side's number, and the code; a
/// missing side is hatched (Filler) so the rows line up.
public struct NWSplitDiffSide: View {
    public enum Side: Sendable { case old, new }

    let line: NWDiffLineContent?
    let side: Side
    let onComment: (() -> Void)?
    @State private var hovering = false

    public init(_ line: NWDiffLineContent?, side: Side, onComment: (() -> Void)? = nil) {
        self.line = line
        self.side = side
        self.onComment = onComment
    }

    public var body: some View {
        if let line {
            HStack(spacing: 0) {
                NWDiffGutterBar(kind: line.kind)
                NWDiffNumber(value: side == .old ? line.oldNumber : line.newNumber)
                NWDiffCode(line: line)
                NWDiffCommentSlot(hovering: hovering, onComment: onComment)
            }
            .frame(maxWidth: .infinity, minHeight: NWDiffMetrics.lineHeight, maxHeight: NWDiffMetrics.lineHeight)
            .background(NWDiffLineBackground.color(line.kind, hovering: hovering && onComment != nil))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .nwAnimation(.hover, value: hovering)
            .onTapGesture(count: 2) { onComment?() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.accessibilityText)
            .accessibilityActions {
                if let onComment { Button("Comment", action: onComment) }
            }
        } else {
            NWDiffHatch()
                .frame(maxWidth: .infinity, minHeight: NWDiffMetrics.lineHeight, maxHeight: NWDiffMetrics.lineHeight)
                .accessibilityHidden(true)
        }
    }
}

/// A split row: the old side, a 1px rule, the new side, each half the width.
public struct NWSplitDiffLine: View {
    let old: NWDiffLineContent?
    let new: NWDiffLineContent?
    let onComment: ((NWDiffLineContent) -> Void)?

    public init(old: NWDiffLineContent?, new: NWDiffLineContent?, onComment: ((NWDiffLineContent) -> Void)? = nil) {
        self.old = old
        self.new = new
        self.onComment = onComment
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("diff.line")
        HStack(spacing: 0) {
            NWSplitDiffSide(old, side: .old, onComment: old.flatMap { line in onComment.map { comment in { comment(line) } } })
            Color.nw.lineSubtle.frame(width: 1).accessibilityHidden(true)
            NWSplitDiffSide(new, side: .new, onComment: new.flatMap { line in onComment.map { comment in { comment(line) } } })
        }
        .frame(height: NWDiffMetrics.lineHeight)
        .accessibilityElement(children: .contain)
    }
}

/// A changed line's 3pt bar (Gutter bar): `done` for an addition, `failed` for a removal, so a
/// change reads even where its tint is faint.
private struct NWDiffGutterBar: View {
    let kind: NWDiffLineKind

    var body: some View {
        let nw = Color.nw
        (kind == .added ? nw.done : kind == .removed ? nw.failed : Color.clear)
            .frame(width: NWDiffMetrics.barWidth)
    }
}

/// The code, clipped at the edge (never wrapped or ellipsized), its full line on hover.
private struct NWDiffCode: View {
    let line: NWDiffLineContent

    var body: some View {
        Text(line.text)
            .font(.nw(.code))
            .foregroundStyle(Color.nw.textPrimary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            // Takes what the row leaves, however long the line: its width never pushes the row.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .help(line.source)
    }
}

/// The comment "+" slot: always laid out, so hovering moves nothing; the control exists only
/// while the line is hovered, so a long diff doesn't build a hidden one per line.
private struct NWDiffCommentSlot: View {
    let hovering: Bool
    let onComment: (() -> Void)?

    var body: some View {
        if let onComment {
            Color.clear
                .frame(width: NWDiffLine.commentButtonSize + 2 * NW.Space.s, height: NWDiffLine.commentButtonSize)
                .overlay {
                    if hovering {
                        NWDiffCommentButton(action: onComment)
                            .nwTransition(.hover)
                    }
                }
        }
    }
}

enum NWDiffLineBackground {
    @MainActor static func color(_ kind: NWDiffLineKind, hovering: Bool) -> Color {
        let nw = Color.nw
        return switch kind {
        case .added: nw.doneTint
        case .removed: nw.failedTint
        case .context: hovering ? nw.bgHover : .clear
        }
    }
}

/// The filler where one side has no line (Filler, hatched): `lineSubtle` diagonals 7pt apart,
/// so a gap reads as a gap rather than a blank line.
public struct NWDiffHatch: View {
    public init() {}

    public var body: some View {
        let color = Color.nw.lineSubtle
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += NWDiffMetrics.hatchSpacing
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
    }
}

/// A hovered line's lantern `+`. Not a `Button`, which cost twice as much to build: the pointer
/// resting over a scrolling diff hovers a new line every step. The line's own accessibility
/// action comments for VoiceOver.
private struct NWDiffCommentButton: View {
    let action: () -> Void

    var body: some View {
        let _ = NWRenderProbe.tick("diff.commentButton")
        let nw = Color.nw
        Image(systemName: "plus")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(nw.textOnLantern)
            .frame(width: NWDiffLine.commentButtonSize, height: NWDiffLine.commentButtonSize)
            .background(nw.lantern, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityHidden(true)
            .help("Comment on this line")
    }
}

/// A right-aligned line number in its 34pt gutter: mono 10.5, tertiary. Five digits, or four at
/// a large text size, shrink to fit rather than truncate.
private struct NWDiffNumber: View {
    let value: Int?

    var body: some View {
        Text(value.map(String.init) ?? "")
            .font(.nwMono(10.5))
            .monospacedDigit()
            .foregroundStyle(.nw.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.trailing, NW.Space.m)
            .frame(width: NWDiffMetrics.numberWidth, alignment: .trailing)
    }
}

// MARK: Folds

/// Unmodified lines folded between changes (FoldRow): a 26pt `bgSunken` strip between hairlines,
/// the reveal arrows in a 37pt column (up shows the 20 lines at the fold's bottom edge, down the
/// 20 at its top), then "28 unmodified lines", which shows all of them.
public struct NWDiffFoldRow: View {
    let fold: NWDiffFold
    let reveal: (NWDiffReveal) -> Void
    @State private var hovering = false

    public init(_ fold: NWDiffFold, reveal: @escaping (NWDiffReveal) -> Void) {
        self.fold = fold
        self.reveal = reveal
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("diff.fold")
        let nw = Color.nw
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if fold.revealsUp { arrow("chevron.up", .up, label: "Show 20 lines above") }
                if fold.revealsDown { arrow("chevron.down", .down, label: "Show 20 lines below") }
            }
            .frame(width: NWDiffMetrics.foldControlWidth)
            Text(fold.label)
                .font(.nw(.caption))
                .foregroundStyle(hovering ? nw.textSecondary : nw.textTertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture { reveal(.all) }
                .nwAnimation(.hover, value: hovering)
                .help("Show all \(fold.label)")
        }
        .frame(height: NWDiffMetrics.foldHeight)
        .background(nw.bgSunken)
        .overlay(alignment: .top) { NWHairline() }
        .overlay(alignment: .bottom) { NWHairline() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fold.label)
        .accessibilityHint("Shows the unmodified lines")
        .accessibilityAction { reveal(.all) }
        .accessibilityActions {
            if fold.revealsUp { Button("Show 20 lines above") { reveal(.up) } }
            if fold.revealsDown { Button("Show 20 lines below") { reveal(.down) } }
        }
    }

    private func arrow(_ symbol: String, _ direction: NWDiffReveal, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Color.nw.textTertiary)
            .frame(width: NWDiffMetrics.foldControlWidth, height: NWDiffMetrics.foldHeight / (fold.revealsUp && fold.revealsDown ? 2 : 1))
            .contentShape(Rectangle())
            .onTapGesture { reveal(direction) }
            .help(label)
    }
}

// MARK: Diff

/// A file's diff in the Changes pane: lines (unified or split), folds and notices, with an
/// annotation (a comment, or its editor) under any line that has a note. Its body is the rows
/// themselves, so inside a `LazyVStack` they stay lazy and scroll under a pinned file header.
///
/// Each row compares its lines and their notes (never the closures, which act on the same diff),
/// so a comment added, opened, or saved redraws its own row rather than every row on screen.
///
///     Section {
///         NWDiffView(rows, notes: comments, onComment: comment, onReveal: reveal) { line, comment in
///             NWInlineComment(…)
///         }
///     } header: { NWFileHeader(…) }
public struct NWDiffView<Note: Equatable, Annotation: View>: View {
    let rows: [NWChangesRow]
    let notes: [Int: Note]
    let onComment: ((NWDiffLineContent) -> Void)?
    let onReveal: (String, NWDiffReveal) -> Void
    let annotation: (NWDiffLineContent, Note) -> Annotation

    /// `notes` are keyed by a line's `key`; a line with one shows `annotation` under its row,
    /// inset by `NWDiffMetrics.annotationInsets`. `onReveal` gets a fold's id and the direction.
    public init(_ rows: [NWChangesRow], notes: [Int: Note], onComment: ((NWDiffLineContent) -> Void)? = nil,
                onReveal: @escaping (String, NWDiffReveal) -> Void,
                @ViewBuilder annotation: @escaping (NWDiffLineContent, Note) -> Annotation) {
        self.rows = rows
        self.notes = notes
        self.onComment = onComment
        self.onReveal = onReveal
        self.annotation = annotation
    }

    public var body: some View {
        ForEach(rows) { row in
            NWDiffRowView(row: row, notes: notes.isEmpty ? [] : row.lines.compactMap { line in notes[line.key].map { NoteSlot(line: line, note: $0) } },
                          onComment: onComment, onReveal: onReveal, annotation: annotation)
                .equatable()
        }
    }
}

/// A diff without notes.
public enum NWDiffNoNote: Equatable, Sendable {}

extension NWDiffView where Note == NWDiffNoNote, Annotation == EmptyView {
    /// A diff without annotations.
    public init(_ rows: [NWChangesRow], onComment: ((NWDiffLineContent) -> Void)? = nil,
                onReveal: @escaping (String, NWDiffReveal) -> Void) {
        self.init(rows, notes: [:], onComment: onComment, onReveal: onReveal) { _, _ in EmptyView() }
    }
}

struct NoteSlot<Note: Equatable>: Equatable {
    let line: NWDiffLineContent
    let note: Note
}

/// One row, always a single view (a lazy stack's fast path). Opaque on the pane's background, so
/// the rows sliding into place as a fold or a comment opens or closes cover what is fading
/// under them instead of showing through it. Equal while its row and notes are.
private struct NWDiffRowView<Note: Equatable, Annotation: View>: View, Equatable {
    let row: NWChangesRow
    let notes: [NoteSlot<Note>]
    let onComment: ((NWDiffLineContent) -> Void)?
    let onReveal: (String, NWDiffReveal) -> Void
    let annotation: (NWDiffLineContent, Note) -> Annotation

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.notes == rhs.notes && (lhs.onComment == nil) == (rhs.onComment == nil)
    }

    var body: some View {
        let _ = NWRenderProbe.tick("diff.row")
        VStack(alignment: .leading, spacing: 0) {
            switch row {
            case .line(let line):
                NWDiffLine(line, onComment: onComment.map { comment in { comment(line) } })
            case .pair(_, let old, let new):
                NWSplitDiffLine(old: old, new: new, onComment: onComment)
            case .fold(let fold):
                NWDiffFoldRow(fold) { onReveal(fold.id, $0) }
            case .notice(_, let text):
                Text(text)
                    .font(.nw(.caption))
                    .foregroundStyle(Color.nw.textTertiary)
                    .padding(.vertical, NW.Space.m)
                    .padding(.leading, NWDiffMetrics.annotationLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(notes, id: \.line.id) { slot in
                annotation(slot.line, slot.note)
                    .padding(NWDiffMetrics.annotationInsets)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { NWHairline() }
                    .overlay(alignment: .bottom) { NWHairline() }
            }
        }
        .background(Color.nw.bgWindow)
    }
}
