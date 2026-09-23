import SwiftUI
import ShepherdUI
import ShepherdRemote

/// Agent prose: the turn's parsed Markdown drawn by `NWAgentProse`, with fenced code
/// highlighted. Blocks are parsed once per turn (`NativeTurnPresentation`); inline runs are
/// styled once per text.
struct Prose: View, Equatable {
    let blocks: [NativeMarkdownBlock]
    var maxWidth: CGFloat = AppLayout.proseMaxWidth

    init(blocks: [NativeMarkdownBlock], maxWidth: CGFloat = AppLayout.proseMaxWidth) {
        self.blocks = blocks
        self.maxWidth = maxWidth
    }

    init(text: String, maxWidth: CGFloat = AppLayout.proseMaxWidth) {
        self.init(blocks: nativeMarkdownBlocks(text), maxWidth: maxWidth)
    }

    var body: some View {
        NWAgentProse(Self.proseBlocks(blocks), maxWidth: maxWidth) { code, language in
            HighlightedCodeBlock(code: code, language: language)
        }
    }

    static func proseBlocks(_ blocks: [NativeMarkdownBlock]) -> [NWProseBlock] {
        blocks.map { block in
            switch block {
            case .heading(let level, let text): .heading(level: level, text: inline(text))
            case .paragraph(let text): .paragraph(inline(text))
            case .quote(let text): .quote(inline(text))
            case .code(let text, let language): .code(text, language: language)
            case .rule: .rule
            case .list(let ordered, let start, let items):
                .list(ordered: ordered, start: start,
                      items: items.map { NWProseListItem(text: inline($0.text), children: proseBlocks($0.children)) })
            }
        }
    }

    private struct InlineKey: Hashable {
        var text: String
        var scale: CGFloat
    }

    private static var inlineCache: [InlineKey: AttributedString] = [:]

    /// Inline Markdown: code runs in mono 12, links in running blue. A per-run border cannot be
    /// expressed inside `Text`, so a code span is filled with the board's border color
    /// (`lineSubtle`) instead of `bgSunken` plus a line. Cached per text and text scale.
    static func inline(_ text: String) -> AttributedString {
        let key = InlineKey(text: text, scale: ThemeStore.shared.textScale)
        if let cached = inlineCache[key] { return cached }
        var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = Font.nwMono(12)
            attributed[run.range].backgroundColor = Color.nw.lineSubtle
        }
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = Color.nw.running
        }
        if inlineCache.count > 2048 { inlineCache.removeAll(keepingCapacity: true) }
        inlineCache[key] = attributed
        return attributed
    }
}

/// A fenced block, plain on its first frame and syntax colored once tree-sitter has run in the
/// block's task. Results are cached, so a block that scrolls back in is colored at once.
struct HighlightedCodeBlock: View {
    let code: String
    let language: String?
    @State private var highlighted: AttributedString?

    private var key: CodeHighlightCache.Key { CodeHighlightCache.Key(code: trimmed, language: language) }
    private var trimmed: String { code.trimmingCharacters(in: .newlines) }

    var body: some View {
        NWCodeBlock(trimmed, language: language, highlighted: highlighted ?? CodeHighlightCache.cached(key))
            .task(id: key) {
                guard CodeHighlightCache.cached(key) == nil else { return }
                // Let the plain block land first; highlighting a long block is not free.
                await Task.yield()
                guard !Task.isCancelled else { return }
                highlighted = CodeHighlightCache.highlight(key)
            }
    }
}

@MainActor
enum CodeHighlightCache {
    struct Key: Hashable {
        var code: String
        var language: String?
    }

    private static var values: [Key: AttributedString] = [:]

    static func cached(_ key: Key) -> AttributedString? { values[key] }

    /// nil when the language has no grammar (the block stays plain).
    static func highlight(_ key: Key) -> AttributedString? {
        if let value = values[key] { return value }
        guard let path = CodeHighlight.path(forFenceLanguage: key.language) else { return nil }
        let lines = key.code.components(separatedBy: "\n")
        let colored = CodeHighlight.highlightLines(lines, path: path, style: .theme)
        guard colored.count == lines.count else { return nil }
        var joined = AttributedString()
        for (index, line) in colored.enumerated() {
            if index > 0 { joined += AttributedString("\n") }
            joined += line
        }
        if values.count > 256 { values.removeAll(keepingCapacity: true) }
        values[key] = joined
        return joined
    }
}
