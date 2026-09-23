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
            attributed[run.range].font = Font.nw(.code)
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

/// A fenced block, plain on its first frame and syntax colored once tree-sitter has run off the
/// main actor in the block's task. Results are cached, so a block that scrolls back in is
/// colored at once. A streaming block keeps its last colors while the longer text is colored.
struct HighlightedCodeBlock: View {
    let code: String
    let language: String?
    /// The last colors this block rendered, with the code they color: the block keeps its
    /// identity while a reply streams into it.
    @State private var rendered: CodeHighlightCache.Rendered?

    private var key: CodeHighlightCache.Key { CodeHighlightCache.Key(fence: code, language: language) }

    var body: some View {
        let key = key
        NWCodeBlock(key.code, language: language,
                    highlighted: CodeHighlightCache.colors(for: key, last: rendered, cached: CodeHighlightCache.cached(key)))
            .task(id: key) {
                guard CodeHighlightCache.cached(key) == nil, CodeHighlight.path(forFenceLanguage: key.language) != nil else { return }
                let style = CodeHighlight.Style.theme
                let value = await Task.detached(priority: .userInitiated) { CodeHighlightCache.render(key, style: style) }.value
                guard !Task.isCancelled, let value else { return }
                CodeHighlightCache.store(value, for: key)
                rendered = CodeHighlightCache.Rendered(key: key, value: value)
            }
    }
}

/// Colored fenced blocks by code and language: rendered anywhere, cached on the main actor.
enum CodeHighlightCache {
    struct Key: Hashable, Sendable {
        var code: String
        var language: String?

        init(code: String, language: String?) {
            self.code = code
            self.language = language
        }

        /// A fence's code as the block draws it: without its leading and trailing newlines.
        init(fence code: String, language: String?) {
            self.init(code: code.trimmingCharacters(in: .newlines), language: language)
        }
    }

    /// A block's colors and the code they color.
    struct Rendered {
        var key: Key
        var value: AttributedString
    }

    /// The colors to draw `key` with: its own once rendered or cached. While a block that grew
    /// (a streaming reply) is colored again, its last colors with the new text plain after
    /// them; colors for other code are never drawn. nil draws the block plain.
    static func colors(for key: Key, last: Rendered?, cached: AttributedString?) -> AttributedString? {
        if let last, last.key == key { return last.value }
        if let cached { return cached }
        guard let last, last.key.language == key.language, key.code.hasPrefix(last.key.code) else { return nil }
        return last.value + AttributedString(String(key.code.dropFirst(last.key.code.count)))
    }

    @MainActor private static var values: [Key: AttributedString] = [:]

    @MainActor static func cached(_ key: Key) -> AttributedString? { values[key] }

    @MainActor static func store(_ value: AttributedString, for key: Key) {
        if values.count > 256 { values.removeAll(keepingCapacity: true) }
        values[key] = value
    }

    /// The block's colors, nil when the language has no grammar (the block stays plain).
    /// Parses with tree-sitter, so callers run it off the main actor.
    static func render(_ key: Key, style: CodeHighlight.Style) -> AttributedString? {
        guard let path = CodeHighlight.path(forFenceLanguage: key.language) else { return nil }
        let lines = key.code.components(separatedBy: "\n")
        let colored = CodeHighlight.highlightLines(lines, path: path, style: style)
        guard colored.count == lines.count else { return nil }
        var joined = AttributedString()
        for (index, line) in colored.enumerated() {
            if index > 0 { joined += AttributedString("\n") }
            joined += line
        }
        return joined
    }
}
