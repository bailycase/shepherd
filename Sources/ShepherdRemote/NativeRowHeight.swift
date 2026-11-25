import Foundation

/// A deliberately low estimate, in points, of how tall a thread row is on the Mac.
///
/// While its window is being live-resized, `ThreadView` lays out only enough rows at the end
/// of a thread for real to cover the window, by this estimate. It cannot know a row's true
/// height before SwiftUI lays it out, so the estimate stays below it: text is packed at the
/// widest prose measure, line heights sit under the default text scale's, and expanded
/// disclosures are left out. Images and rendered diagrams count as nothing, because their
/// drawn height is not known from their source. Where the estimate is wrong in the other
/// direction, the cover it is summed against carries slack (`AppLayout.eagerCoverFactor`).
public enum NativeRowHeight {
    /// One line of body text, under its height at the default text scale.
    static let textLine = 20
    /// One line of code, under its height at the default text scale.
    static let codeLine = 17
    /// Character widths packed into one line at the widest prose measure: a scalar from the
    /// wide ranges (CJK, emoji) counts as two.
    static let widthsPerTextLine = 100
    /// One table row, under a drawn cell's height.
    static let tableRow = 28
    /// Any other single line in a row.
    static let line = 20
    /// The gap before a block of prose, under the stacks' spacing.
    static let blockGap = 10
    /// The room a row itself takes in the column besides its content: its spacing and chrome.
    static let rowBase = 36

    public static func row(_ row: NativeThreadRow) -> Int {
        rowBase + (row.presentation.map(presentation) ?? userWords(row.turn))
    }

    static func row(presentation height: Int) -> Int { rowBase + height }

    public static func presentation(_ presentation: NativeTurnPresentation) -> Int {
        presentation.items.reduce(0) { $0 + item($1) }
    }

    static func item(_ item: NativeTurnPresentation.Item) -> Int {
        switch item {
        case .prose(_, let text, let prose): item.awaitsParse ? textHeight(text) : prose.height
        case .activity(_, let bursts): bursts.count * line
        case .subagents(_, let lines): lines.count * line
        case .note(_, let text), .goalRecord(_, let text): textHeight(text)
        case .steer(_, let text, _, _, _): textHeight(text)
        case .thinking, .hook, .error, .retrying, .compaction, .question: line
        case .images: 0
        }
    }

    static func block(_ value: NativeMarkdownBlock) -> Int {
        let height: Int
        switch value {
        case .heading(_, let text), .paragraph(let text):
            height = textHeight(text)
        case .list(_, _, let items):
            height = items.reduce(0) { $0 + listItem($1) }
        case .quote(let inner):
            height = inner.reduce(0) { $0 + block($1) }
        case .code(let text, let language):
            height = codeHeight(text, language: language)
        case .rule, .image:
            return 0
        case .table(let table):
            height = (table.rows.count + (table.header.isEmpty ? 0 : 1)) * tableRow
        case .details(let summary, _):
            height = textHeight(summary)
        case .footnotes(let notes):
            height = notes.reduce(0) { $0 + textHeight($1.text) }
        }
        return height == 0 ? 0 : blockGap + height
    }

    private static func listItem(_ item: NativeMarkdownListItem) -> Int {
        textHeight(item.text) + item.children.reduce(0) { $0 + block($1) }
    }

    private static func userWords(_ turn: NativeTurn) -> Int {
        turn.messages.reduce(0) { total, message in
            total + message.blocks.reduce(0) { $0 + ($1.kind == .text ? textHeight($1.text) : 0) }
        }
    }

    /// Text as whole lines: a line for every hard break, and for every `widthsPerTextLine`
    /// character widths between them.
    static func textHeight(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var lines = 0, segment = 0
        func closeSegment() {
            lines += max(1, (segment + widthsPerTextLine - 1) / widthsPerTextLine)
            segment = 0
        }
        for scalar in text.unicodeScalars {
            if scalar == "\n" { closeSegment() } else { segment += scalar.value < 0x1100 ? 1 : 2 }
        }
        closeSegment()
        return lines * textLine
    }

    private static func codeHeight(_ text: String, language: String?) -> Int {
        // A rendered diagram or page can be shorter than its source; its height is not in the text.
        if let language {
            let name = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if name == "mermaid" || name == "html-render" { return 0 }
        }
        guard !text.isEmpty else { return 0 }
        return (text.utf8.count { $0 == 0x0A } + 1) * codeLine
    }
}
