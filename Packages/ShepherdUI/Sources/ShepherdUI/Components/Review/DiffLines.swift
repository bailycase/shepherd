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

/// The diff's fixed columns (Review board): two 36pt line-number gutters, a 16pt sign column,
/// then the code. Fold rows and inline comments start 6pt into the code column.
public enum NWDiffMetrics {
    public static let numberWidth: CGFloat = 36
    public static let signWidth: CGFloat = 16
    /// Where the code column starts.
    public static let codeLeading: CGFloat = numberWidth * 2 + signWidth
    /// Fold labels and inline comments.
    public static let annotationLeading: CGFloat = codeLeading + NW.Space.s
    /// Around a line's inline comment or comment editor.
    public static let annotationInsets = EdgeInsets(top: NW.Space.s, leading: annotationLeading, bottom: NW.Space.m, trailing: NW.Space.l)
    /// A fold row, a little taller than a line; density-scaled.
    @MainActor public static var foldHeight: CGFloat { NW.Height.scaled(24) }
}

/// One line of a diff, ready to draw: the text arrives already syntax colored, so nothing is
/// parsed or highlighted while a row renders.
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

/// One row of `NWDiffView`: a hunk header, a line, or a fold of hidden lines.
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

/// One diff line (Review board): 22pt (density-scaled), old and new numbers in 36pt gutters,
/// the sign, and the syntax-colored code in mono 11.5, tail-truncated with the full line on
/// hover. Additions sit on `doneTint`, removals on `failedTint`. With `onComment`, hovering
/// shows a lantern "+", and double-clicking the line also comments.
public struct NWDiffLine: View {
    let line: NWDiffLineContent
    let onComment: (() -> Void)?
    @State private var hovering = false

    public init(_ line: NWDiffLineContent, onComment: (() -> Void)? = nil) {
        self.line = line
        self.onComment = onComment
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("diff.line")
        let nw = Color.nw
        HStack(spacing: 0) {
            NWDiffNumber(value: line.oldNumber)
            NWDiffNumber(value: line.newNumber)
            Text(line.kind.sign)
                .font(.nw(.mono))
                .foregroundStyle(line.kind == .added ? nw.done : nw.failed)
                .frame(width: NWDiffMetrics.signWidth)
            Text(line.text)
                .font(.nw(.mono))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(line.source)
            if let onComment {
                // The slot is always laid out, so hovering moves nothing; the button exists only
                // while the line is hovered, so a long diff doesn't build a hidden one per line.
                Color.clear
                    .frame(width: NWDiffLine.commentButtonSize + 2 * NW.Space.s, height: NWDiffLine.commentButtonSize)
                    .overlay {
                        if hovering {
                            Button(action: onComment) {
                                let _ = NWRenderProbe.tick("diff.commentButton")
                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(nw.textOnLantern)
                                    .frame(width: NWDiffLine.commentButtonSize, height: NWDiffLine.commentButtonSize)
                                    .background(nw.lantern, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHidden(true)
                            .help("Comment on this line")
                            .nwTransition(.hover)
                        }
                    }
            }
        }
        .frame(minHeight: NW.Height.rowCompact)
        .background(background(nw))
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

    private func background(_ nw: NWPalette) -> Color {
        switch line.kind {
        case .added: nw.doneTint
        case .removed: nw.failedTint
        case .context: hovering && onComment != nil ? nw.bgHover : .clear
        }
    }
}

/// A right-aligned line number in its 36pt gutter: micro size, regular weight, tertiary. Five
/// digits, or four at a large text size, shrink to fit rather than truncate.
private struct NWDiffNumber: View {
    let value: Int?

    var body: some View {
        Text(value.map(String.init) ?? "")
            .font(.nw(.micro, weight: .regular))
            .monospacedDigit()
            .foregroundStyle(.nw.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.trailing, NW.Space.s)
            .frame(width: NWDiffMetrics.numberWidth, alignment: .trailing)
    }
}

/// A hunk header ("@@ -12,55 +12,10 @@ struct FleetView: View {"): a 22pt `bgSunken` row with the
/// header in tertiary mono, aligned to the code column.
public struct NWHunkHeader: View {
    let header: String

    public init(_ header: String) { self.header = header }

    public var body: some View {
        let _ = NWRenderProbe.tick("diff.hunk")
        Text(header)
            .font(.nw(.mono))
            .foregroundStyle(.nw.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, NWDiffMetrics.codeLeading)
            .padding(.trailing, NW.Space.l)
            .frame(maxWidth: .infinity, minHeight: NW.Height.rowCompact, alignment: .leading)
            .background(Color.nw.bgSunken)
            .help(header)
            .accessibilityLabel("Hunk \(header)")
    }
}

/// Lines folded out of a long run (Review board): a 24pt `bgSunken` strip between 1px rules,
/// "+ 13 more removed lines · 18–32" in micro mono, aligned 6pt into the code column. Clicking it
/// shows the lines; with `expandFile`, ⌥-click (or the VoiceOver action) shows the whole file.
public struct NWFoldRow: View {
    let count: Int
    let kind: NWDiffLineKind
    let range: String
    let action: () -> Void
    let expandFile: (() -> Void)?

    public init(count: Int, kind: NWDiffLineKind, range: String, action: @escaping () -> Void, expandFile: (() -> Void)? = nil) {
        self.count = count
        self.kind = kind
        self.range = range
        self.action = action
        self.expandFile = expandFile
    }

    /// "+ 13 more removed lines · 18–32" (the range is left off when empty).
    public static func label(count: Int, kind: NWDiffLineKind, range: String) -> String {
        let lines = "\(count) more \(kind.word) line\(count == 1 ? "" : "s")"
        return range.isEmpty ? "+ \(lines)" : "+ \(lines) · \(range)"
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("diff.fold")
        Button {
            #if os(macOS)
            if let expandFile, NSEvent.modifierFlags.contains(.option) { return expandFile() }
            #endif
            action()
        } label: {
            Text(Self.label(count: count, kind: kind, range: range))
                .lineLimit(1)
        }
        .buttonStyle(NWFoldRowStyle())
        .help(expandFile == nil ? "Show these lines" : "Show these lines (⌥-click shows the whole file)")
        .accessibilityHint("Shows the folded lines")
        .accessibilityActions {
            if let expandFile { Button("Show the whole file", action: expandFile) }
        }
    }
}

private struct NWFoldRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NWFoldRowBody(configuration: configuration)
    }
}

private struct NWFoldRowBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        let nw = Color.nw
        configuration.label
            .font(.nw(.micro, weight: .regular))
            .foregroundStyle(hovering || configuration.isPressed ? nw.textSecondary : nw.textTertiary)
            .padding(.leading, NWDiffMetrics.annotationLeading)
            .frame(maxWidth: .infinity, minHeight: NWDiffMetrics.foldHeight, alignment: .leading)
            .background(nw.bgSunken)
            .overlay(alignment: .top) { NWHairline() }
            .overlay(alignment: .bottom) { NWHairline() }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .nwAnimation(.hover, value: hovering)
            .nwFocusRing(radius: 0)
    }
}

/// A file's diff (Review board): hunk headers, lines, and folds, with an annotation (an inline
/// comment, or its editor) under any line. Its body is the rows themselves, so inside a
/// `LazyVStack` they stay lazy and can scroll under a pinned `NWFileHeader`.
///
///     Section {
///         NWDiffView(rows, onComment: comment, onExpand: expand) { line in
///             if let note = notes[line.key] { NWInlineComment(…) }
///         }
///     } header: { NWFileHeader(…) }
public struct NWDiffView<Annotation: View>: View {
    let rows: [NWDiffRow]
    let onComment: ((NWDiffLineContent) -> Void)?
    let onExpand: (String) -> Void
    let onExpandFile: (() -> Void)?
    let annotation: (NWDiffLineContent) -> Annotation

    /// `onExpand` gets a fold's id; `onExpandFile` (⌥-click on a fold) opens every fold. The
    /// annotation is inset under its line (`NWDiffMetrics.annotationInsets`).
    public init(_ rows: [NWDiffRow], onComment: ((NWDiffLineContent) -> Void)? = nil, onExpand: @escaping (String) -> Void,
                onExpandFile: (() -> Void)? = nil, @ViewBuilder annotation: @escaping (NWDiffLineContent) -> Annotation) {
        self.rows = rows
        self.onComment = onComment
        self.onExpand = onExpand
        self.onExpandFile = onExpandFile
        self.annotation = annotation
    }

    public var body: some View {
        ForEach(rows) { row in
            NWDiffRowView(row: row, onComment: onComment, onExpand: onExpand, onExpandFile: onExpandFile, annotation: annotation)
        }
    }
}

extension NWDiffView where Annotation == EmptyView {
    /// A diff without annotations.
    public init(_ rows: [NWDiffRow], onComment: ((NWDiffLineContent) -> Void)? = nil, onExpand: @escaping (String) -> Void,
                onExpandFile: (() -> Void)? = nil) {
        self.init(rows, onComment: onComment, onExpand: onExpand, onExpandFile: onExpandFile) { _ in EmptyView() }
    }
}

/// One row, always a single view (a lazy stack's fast path). Opaque on the pane's background, so
/// the rows sliding into place as a fold or a comment opens or closes cover what is fading
/// under them instead of showing through it.
private struct NWDiffRowView<Annotation: View>: View {
    let row: NWDiffRow
    let onComment: ((NWDiffLineContent) -> Void)?
    let onExpand: (String) -> Void
    let onExpandFile: (() -> Void)?
    let annotation: (NWDiffLineContent) -> Annotation

    var body: some View {
        let _ = NWRenderProbe.tick("diff.row")
        VStack(alignment: .leading, spacing: 0) {
            switch row {
            case .hunk(_, let header):
                NWHunkHeader(header)
            case .line(let line):
                NWDiffLine(line, onComment: onComment.map { comment in { comment(line) } })
                annotation(line).padding(NWDiffMetrics.annotationInsets)
            case .fold(let id, let count, let kind, let range):
                NWFoldRow(count: count, kind: kind, range: range, action: { onExpand(id) }, expandFile: onExpandFile)
            }
        }
        .background(Color.nw.bgWindow)
    }
}
