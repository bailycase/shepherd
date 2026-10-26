import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A diff line's kind: unchanged context, an addition, or a removal.
public enum SHDiffLineKind: Sendable, Hashable {
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
public enum SHDiffMetrics {
    public static let barWidth: CGFloat = 3
    public static let numberWidth: CGFloat = 34
    public static let commentButtonSize: CGFloat = 18
    public static let commentSlotWidth: CGFloat = commentButtonSize + 2 * SH.Space.s
    public static let signWidth: CGFloat = 16
    /// Where the unified code column starts.
    public static let codeLeading: CGFloat = barWidth + numberWidth * 2 + signWidth
    /// Where a split side's code starts.
    public static let splitCodeLeading: CGFloat = barWidth + numberWidth
    /// Notices ("Binary file") and comments.
    public static let annotationLeading: CGFloat = 40
    /// Around a line's comment or comment editor.
    public static let annotationInsets = EdgeInsets(top: SH.Space.s, leading: annotationLeading, bottom: SH.Space.m, trailing: SH.Space.l)
    /// The fold row's reveal column.
    public static let foldControlWidth: CGFloat = 37
    /// The gap between the hatching's diagonal lines.
    public static let hatchSpacing: CGFloat = 7
    /// A line; density-scaled.
    @MainActor public static var lineHeight: CGFloat { SH.Height.scaled(21) }
    /// A fold row, a little taller than a line; density-scaled.
    @MainActor public static var foldHeight: CGFloat { SH.Height.scaled(26) }
}

/// One line of a diff, ready to draw: the text arrives already syntax colored (and with its word
/// diff tinted), so nothing is parsed or highlighted while a row renders.
public struct SHDiffLineContent: Identifiable, Equatable, Sendable {
    /// The row's identity in the diff (stable across renders).
    public let id: String
    /// The caller's key for the line (for a comment lookup), unique within its file.
    public let key: Int
    public let kind: SHDiffLineKind
    public let oldNumber: Int?
    public let newNumber: Int?
    /// The code, syntax colored or plain.
    public let text: AttributedString
    /// The plain source line: the help tag and VoiceOver.
    public let source: String

    public init(id: String, key: Int, kind: SHDiffLineKind, oldNumber: Int?, newNumber: Int?, text: AttributedString, source: String) {
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
public enum SHDiffRow: Identifiable, Equatable, Sendable {
    case hunk(id: String, header: String)
    case line(SHDiffLineContent)
    /// Folded lines: how many, their kind, and the numbers they span ("18–32").
    case fold(id: String, count: Int, kind: SHDiffLineKind, range: String)

    public var id: String {
        switch self {
        case .hunk(let id, _), .fold(let id, _, _, _): id
        case .line(let line): line.id
        }
    }
}

/// Unmodified lines folded away (FoldRow): how many, and which way they can open. A fold at the
/// top of a file opens only upward, one at its end only downward.
public struct SHDiffFold: Identifiable, Equatable, Sendable {
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
public enum SHDiffReveal: Sendable, Equatable {
    case up, down, all
}

/// One row of the Changes pane's diff: a unified line, a split pair (either side may be missing),
/// a fold of unmodified lines, or a notice ("Binary file").
public enum SHChangesRow: Identifiable, Equatable, Sendable {
    case line(SHDiffLineContent)
    case pair(id: String, old: SHDiffLineContent?, new: SHDiffLineContent?)
    case fold(SHDiffFold)
    case notice(id: String, text: String)

    public var id: String {
        switch self {
        case .line(let line): line.id
        case .pair(let id, _, _), .notice(let id, _): id
        case .fold(let fold): fold.id
        }
    }

    /// The lines a row draws, whose comments show under it: the old side first.
    public var lines: [SHDiffLineContent] {
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
public struct SHDiffLine: View {
    let line: SHDiffLineContent
    let onComment: (() -> Void)?
    @State private var hovering = false

    public init(_ line: SHDiffLineContent, onComment: (() -> Void)? = nil) {
        self.line = line
        self.onComment = onComment
    }

    /// A line that starts hovered (tests: hovering is seeded, never the pointer).
    init(_ line: SHDiffLineContent, onComment: (() -> Void)?, hovering: Bool) {
        self.line = line
        self.onComment = onComment
        _hovering = State(initialValue: hovering)
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("diff.line")
        SHDiffLineDrawing(line: line, side: nil, reservesComment: onComment != nil)
        .overlay(alignment: .trailing) { SHDiffCommentSlot(hovering: hovering, onComment: onComment) }
        .help(line.source)
        .frame(height: SHDiffMetrics.lineHeight)
        .background(SHDiffLineBackground.color(line.kind, hovering: hovering && onComment != nil))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .onTapGesture(count: 2) { onComment?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityText)
        .accessibilityActions {
            if let onComment { Button("Comment", action: onComment) }
        }
    }

    static let commentButtonSize = SHDiffMetrics.commentButtonSize
}

/// One side of a split row (ChangesSplit): the gutter bar, the side's number, and the code; a
/// missing side is hatched (Filler) so the rows line up.
public struct SHSplitDiffSide: View {
    public enum Side: Sendable { case old, new }

    let line: SHDiffLineContent?
    let side: Side
    let onComment: (() -> Void)?
    @State private var hovering = false

    public init(_ line: SHDiffLineContent?, side: Side, onComment: (() -> Void)? = nil) {
        self.line = line
        self.side = side
        self.onComment = onComment
    }

    public var body: some View {
        if let line {
            SHDiffLineDrawing(line: line, side: side, reservesComment: onComment != nil)
            .overlay(alignment: .trailing) { SHDiffCommentSlot(hovering: hovering, onComment: onComment) }
            .help(line.source)
            .frame(maxWidth: .infinity, minHeight: SHDiffMetrics.lineHeight, maxHeight: SHDiffMetrics.lineHeight)
            .background(SHDiffLineBackground.color(line.kind, hovering: hovering && onComment != nil))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
            .onTapGesture(count: 2) { onComment?() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.accessibilityText)
            .accessibilityActions {
                if let onComment { Button("Comment", action: onComment) }
            }
        } else {
            SHDiffHatch()
                .frame(maxWidth: .infinity, minHeight: SHDiffMetrics.lineHeight, maxHeight: SHDiffMetrics.lineHeight)
                .accessibilityHidden(true)
        }
    }
}

/// A split row: the old side, a 1px rule, the new side, each half the width.
public struct SHSplitDiffLine: View {
    let old: SHDiffLineContent?
    let new: SHDiffLineContent?
    let onComment: ((SHDiffLineContent) -> Void)?

    public init(old: SHDiffLineContent?, new: SHDiffLineContent?, onComment: ((SHDiffLineContent) -> Void)? = nil) {
        self.old = old
        self.new = new
        self.onComment = onComment
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("diff.line")
        HStack(spacing: 0) {
            SHSplitDiffSide(old, side: .old, onComment: old.flatMap { line in onComment.map { comment in { comment(line) } } })
            Color.sh.lineSubtle.frame(width: 1).accessibilityHidden(true)
            SHSplitDiffSide(new, side: .new, onComment: new.flatMap { line in onComment.map { comment in { comment(line) } } })
        }
        .frame(height: SHDiffMetrics.lineHeight)
        .accessibilityElement(children: .contain)
    }
}

/// The fixed-height line is one drawing rather than several independently measured Text
/// views. Interaction and accessibility remain on its containing row.
private struct SHDiffLineDrawing: View {
    let line: SHDiffLineContent
    let side: SHSplitDiffSide.Side?
    let reservesComment: Bool
    @Environment(\.splitDiffScroll) private var horizontalScroll

    var body: some View {
        let sh = Color.sh
        let offset = side.map { $0 == .old ? horizontalScroll?.oldOffset ?? 0 : horizontalScroll?.newOffset ?? 0 } ?? 0
        Canvas { context, size in
            let bar = SHDiffMetrics.barWidth
            let number = SHDiffMetrics.numberWidth
            let numbers = side.map { [$0 == .old ? line.oldNumber : line.newNumber] } ?? [line.oldNumber, line.newNumber]
            let signX = bar + number * CGFloat(numbers.count)
            let codeX = signX + (side == nil ? SHDiffMetrics.signWidth : 0)
            if line.kind != .context {
                context.fill(Path(CGRect(x: 0, y: 0, width: bar, height: size.height)), with: .color(line.kind == .added ? sh.done : sh.failed))
            }
            for (index, value) in numbers.enumerated() {
                if let value {
                    let text = context.resolve(Text(String(value)).font(.shMono(10.5)).foregroundStyle(sh.textTertiary))
                    let width = text.measure(in: CGSize(width: .infinity, height: size.height)).width
                    let scale = max(0.6, min(1, (number - SH.Space.m) / max(1, width)))
                    var gutter = context
                    gutter.translateBy(x: bar + number * CGFloat(index + 1) - SH.Space.m, y: size.height / 2)
                    gutter.scaleBy(x: scale, y: scale)
                    gutter.draw(text, at: .zero, anchor: .trailing)
                }
            }
            if side == nil {
                context.draw(Text(line.kind.sign).font(.sh(.code)).foregroundStyle(line.kind == .added ? sh.done : sh.failed),
                             at: CGPoint(x: signX, y: size.height / 2), anchor: .leading)
            }
            let slot = reservesComment ? SHDiffMetrics.commentSlotWidth : 0
            context.clip(to: Path(CGRect(x: codeX, y: 0, width: max(0, size.width - codeX - slot), height: size.height)))
            context.draw(Text(line.text).font(.sh(.code)).foregroundStyle(sh.textPrimary),
                         at: CGPoint(x: codeX - offset, y: size.height / 2), anchor: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .clipped()
    }
}

/// The comment "+" slot: always laid out, so hovering moves nothing; the control exists only
/// while the line is hovered, so a long diff doesn't build a hidden one per line.
private struct SHDiffCommentSlot: View {
    let hovering: Bool
    let onComment: (() -> Void)?

    var body: some View {
        if let onComment {
            Color.clear
                .frame(width: SHDiffLine.commentButtonSize + 2 * SH.Space.s, height: SHDiffLine.commentButtonSize)
                .overlay {
                    if hovering {
                        SHDiffCommentButton(action: onComment)
                            .shTransition(.hover)
                    }
                }
        }
    }
}

enum SHDiffLineBackground {
    @MainActor static func color(_ kind: SHDiffLineKind, hovering: Bool) -> Color {
        let sh = Color.sh
        return switch kind {
        case .added: sh.doneTint
        case .removed: sh.failedTint
        case .context: hovering ? sh.bgHover : .clear
        }
    }
}

/// The filler where one side has no line (Filler, hatched): `lineSubtle` diagonals 7pt apart,
/// so a gap reads as a gap rather than a blank line.
public struct SHDiffHatch: View {
    public init() {}

    public var body: some View {
        let color = Color.sh.lineSubtle
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += SHDiffMetrics.hatchSpacing
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
    }
}

/// A hovered line's lantern `+`. Not a `Button`, which cost twice as much to build: the pointer
/// resting over a scrolling diff hovers a new line every step. The line's own accessibility
/// action comments for VoiceOver.
private struct SHDiffCommentButton: View {
    let action: () -> Void

    var body: some View {
        let _ = SHRenderProbe.tick("diff.commentButton")
        let sh = Color.sh
        Image(systemName: "plus")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(sh.textOnLantern)
            .frame(width: SHDiffLine.commentButtonSize, height: SHDiffLine.commentButtonSize)
            .background(sh.lantern, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityHidden(true)
            .help("Comment on this line")
    }
}

// MARK: Folds

/// Unmodified lines folded between changes (FoldRow): a 26pt `bgSunken` strip between hairlines,
/// the reveal arrows in a 37pt column (up shows the 20 lines at the fold's bottom edge, down the
/// 20 at its top), then "28 unmodified lines", which shows all of them.
public struct SHDiffFoldRow: View {
    let fold: SHDiffFold
    let reveal: (SHDiffReveal) -> Void
    @State private var hovering = false

    public init(_ fold: SHDiffFold, reveal: @escaping (SHDiffReveal) -> Void) {
        self.fold = fold
        self.reveal = reveal
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("diff.fold")
        let sh = Color.sh
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if fold.revealsUp { arrow("chevron.up", .up, label: "Show 20 lines above") }
                if fold.revealsDown { arrow("chevron.down", .down, label: "Show 20 lines below") }
            }
            .frame(width: SHDiffMetrics.foldControlWidth)
            Text(fold.label)
                .font(.sh(.caption))
                .foregroundStyle(hovering ? sh.textSecondary : sh.textTertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture { reveal(.all) }
                .shAnimation(.hover, value: hovering)
                .help("Show all \(fold.label)")
        }
        .frame(height: SHDiffMetrics.foldHeight)
        .background(sh.bgSunken)
        .overlay(alignment: .top) { SHHairline() }
        .overlay(alignment: .bottom) { SHHairline() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fold.label)
        .accessibilityHint("Shows the unmodified lines")
        .accessibilityAction { reveal(.all) }
        .accessibilityActions {
            if fold.revealsUp { Button("Show 20 lines above") { reveal(.up) } }
            if fold.revealsDown { Button("Show 20 lines below") { reveal(.down) } }
        }
    }

    private func arrow(_ symbol: String, _ direction: SHDiffReveal, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Color.sh.textTertiary)
            .frame(width: SHDiffMetrics.foldControlWidth, height: SHDiffMetrics.foldHeight / (fold.revealsUp && fold.revealsDown ? 2 : 1))
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
///         SHDiffView(rows, notes: comments, onComment: comment, onReveal: reveal) { line, comment in
///             SHInlineComment(…)
///         }
///     } header: { SHFileHeader(…) }
public struct SHDiffView<Note: Equatable, Annotation: View>: View {
    let rows: [SHChangesRow]
    let notes: [Int: Note]
    let onComment: ((SHDiffLineContent) -> Void)?
    let onReveal: (String, SHDiffReveal) -> Void
    let annotation: (SHDiffLineContent, Note) -> Annotation

    /// `notes` are keyed by a line's `key`; a line with one shows `annotation` under its row,
    /// inset by `SHDiffMetrics.annotationInsets`. `onReveal` gets a fold's id and the direction.
    public init(_ rows: [SHChangesRow], notes: [Int: Note], onComment: ((SHDiffLineContent) -> Void)? = nil,
                onReveal: @escaping (String, SHDiffReveal) -> Void,
                @ViewBuilder annotation: @escaping (SHDiffLineContent, Note) -> Annotation) {
        self.rows = rows
        self.notes = notes
        self.onComment = onComment
        self.onReveal = onReveal
        self.annotation = annotation
    }

    public var body: some View {
        ForEach(rows) { row in
            SHDiffRowView(row: row, notes: notes.isEmpty ? [] : row.lines.compactMap { line in notes[line.key].map { NoteSlot(line: line, note: $0) } },
                          onComment: onComment, onReveal: onReveal, annotation: annotation)
                .equatable()
        }
    }
}

/// A diff without notes.
public enum SHDiffNoNote: Equatable, Sendable {}

extension SHDiffView where Note == SHDiffNoNote, Annotation == EmptyView {
    /// A diff without annotations.
    public init(_ rows: [SHChangesRow], onComment: ((SHDiffLineContent) -> Void)? = nil,
                onReveal: @escaping (String, SHDiffReveal) -> Void) {
        self.init(rows, notes: [:], onComment: onComment, onReveal: onReveal) { _, _ in EmptyView() }
    }
}

struct NoteSlot<Note: Equatable>: Equatable {
    let line: SHDiffLineContent
    let note: Note
}

/// One row, always a single view (a lazy stack's fast path). Opaque on the pane's background, so
/// the rows sliding into place as a fold or a comment opens or closes cover what is fading
/// under them instead of showing through it. Equal while its row and notes are.
private struct SHDiffRowView<Note: Equatable, Annotation: View>: View, Equatable {
    let row: SHChangesRow
    let notes: [NoteSlot<Note>]
    let onComment: ((SHDiffLineContent) -> Void)?
    let onReveal: (String, SHDiffReveal) -> Void
    let annotation: (SHDiffLineContent, Note) -> Annotation

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.notes == rhs.notes && (lhs.onComment == nil) == (rhs.onComment == nil)
    }

    var body: some View {
        let _ = SHRenderProbe.tick("diff.row")
        VStack(alignment: .leading, spacing: 0) {
            switch row {
            case .line(let line):
                SHDiffLine(line, onComment: onComment.map { comment in { comment(line) } })
            case .pair(_, let old, let new):
                SHSplitDiffLine(old: old, new: new, onComment: onComment)
            case .fold(let fold):
                SHDiffFoldRow(fold) { onReveal(fold.id, $0) }
            case .notice(_, let text):
                Text(text)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textTertiary)
                    .padding(.vertical, SH.Space.m)
                    .padding(.leading, SHDiffMetrics.annotationLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(notes, id: \.line.id) { slot in
                annotation(slot.line, slot.note)
                    .padding(SHDiffMetrics.annotationInsets)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { SHHairline() }
                    .overlay(alignment: .bottom) { SHHairline() }
            }
        }
        .background(Color.sh.bgWindow)
    }
}
