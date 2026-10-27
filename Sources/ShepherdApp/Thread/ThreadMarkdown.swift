import SwiftUI
import AppKit
import ShepherdUI
import ShepherdRemote
import ShepherdSessions

/// A local file link in prose opens in the editor chosen in Settings ▸ Advanced; its menu offers the others.
extension SHProseFileLinks {
    @MainActor static let app = SHProseFileLinks(
        editorName: { url in EditorOpener.application(for: url, editor: AppSettings.shared.editor).map(EditorOpener.name(of:)) ?? "Editor" },
        editors: {
            EditorOpener.installedEditors().compactMap { app in
                Bundle(url: app)?.bundleIdentifier.map { SHFileEditor(id: $0, name: EditorOpener.name(of: app)) }
            }
        },
        open: { url, editor in ShepherdViewModel.openInEditor(url, editor: editor ?? AppSettings.shared.editor) },
        reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
}

/// Agent prose: the turn's parsed Markdown drawn by `SHAgentProse`, with fenced code
/// highlighted. Blocks are parsed once per turn (`NativeTurnPresentation`); inline runs are
/// styled once per text (`SHProseInline`).
struct Prose: View, Equatable {
    let blocks: [NativeMarkdownBlock]
    var maxWidth: CGFloat = AppLayout.proseMaxWidth
    /// A streaming reply is writing the last fenced block (still open): it is colored as it
    /// grows (`CodeHighlightThrottle`), and in full once it is finished.
    var writingFence = false

    init(blocks: [NativeMarkdownBlock], maxWidth: CGFloat = AppLayout.proseMaxWidth, writingFence: Bool = false) {
        self.blocks = blocks
        self.maxWidth = maxWidth
        self.writingFence = writingFence
    }

    init(text: String, maxWidth: CGFloat = AppLayout.proseMaxWidth) {
        self.init(blocks: nativeMarkdownBlocks(text), maxWidth: maxWidth)
    }

    var body: some View {
        let writing = writingFence ? Self.lastCode(blocks) : nil
        SHAgentProse(Self.proseBlocks(blocks), maxWidth: maxWidth, writingFence: writingFence) { code, language in
            HighlightedCodeBlock(code: code, language: language, writing: code == writing)
        }
    }

    /// The last fenced block's code, in document order: an open fence runs to the end.
    static func lastCode(_ blocks: [NativeMarkdownBlock]) -> String? {
        for block in blocks.reversed() {
            switch block {
            case .code(let text, _): return text
            case .list(_, _, let items):
                if let code = items.reversed().lazy.compactMap({ lastCode($0.children) }).first { return code }
            case .quote(let inner), .details(_, let inner):
                if let code = lastCode(inner) { return code }
            default: break
            }
        }
        return nil
    }

    /// The parsed blocks for `SHAgentProse`, their inline runs styled once per text
    /// (`SHProseInline`).
    static func proseBlocks(_ blocks: [NativeMarkdownBlock]) -> [SHProseBlock] {
        blocks.map { block in
            switch block {
            case .heading(let level, let text): .heading(level: level, text: SHProseInline.attributed(text))
            case .paragraph(let text): .paragraph(SHProseInline.attributed(text))
            case .quote(let inner): .quote(proseBlocks(inner))
            case .code(let text, let language): .code(text, language: language)
            case .rule: .rule
            case .list(let ordered, let start, let items):
                .list(ordered: ordered, start: start, items: items.map {
                    SHProseListItem(text: SHProseInline.attributed($0.text), task: $0.task.map { $0 == .done ? .done : .open },
                                    children: proseBlocks($0.children))
                })
            case .table(let table): .table(proseTable(table))
            case .image(let alt, let source): .image(SHProseImage(alt: alt, source: source))
            case .details(let summary, let inner): .details(summary: SHProseInline.attributed(summary), blocks: proseBlocks(inner))
            case .footnotes(let notes):
                .footnotes(notes.map { SHProseFootnote(number: $0.number, text: SHProseInline.attributed($0.text)) })
            }
        }
    }

    static func proseTable(_ table: NativeMarkdownTable) -> SHProseTable {
        SHProseTable(
            alignments: table.alignments.map {
                switch $0 {
                case .none, .leading: .leading
                case .center: .center
                case .trailing: .trailing
                }
            },
            header: table.header.map(SHProseInline.attributed),
            rows: table.rows.map { $0.map(SHProseInline.attributed) },
            markdown: table.source)
    }
}

/// A turn's thinking (`SHThinking`): live, or finished with its Markdown, parsed once per
/// change (`NativeTurnPresentation`), styled here only when this row's own inputs change, so a
/// reply streaming under it leaves it alone. One view for both, so "Thinking…" settles into
/// "Thought for Ns" in place.
struct ThinkingRow: View, Equatable {
    let seconds: Double?
    let blocks: [NativeMarkdownBlock]
    let live: Bool
    /// Live thinking: when the host saw it start (ms), for its clock; nil draws none.
    var since: Double? = nil
    let isExpanded: Bool
    let toggle: () -> Void

    static func == (lhs: ThinkingRow, rhs: ThinkingRow) -> Bool {
        lhs.seconds == rhs.seconds && lhs.live == rhs.live && lhs.since == rhs.since && lhs.isExpanded == rhs.isExpanded
            && lhs.blocks == rhs.blocks
    }

    var body: some View {
        let expanded = Binding(get: { isExpanded }, set: { if $0 != isExpanded { toggle() } })
        // Live: the shared summary so far opens under "Thinking… · 30s" (ResponseVisibility › B);
        // with none, the live line and its clock.
        live
            ? SHThinking.live(since: since.map { Date(timeIntervalSince1970: $0 / 1000) }, blocks: Prose.proseBlocks(blocks),
                              isExpanded: expanded)
            : SHThinking(nativeThoughtText(seconds), blocks: Prose.proseBlocks(blocks), isExpanded: expanded,
                         spokenTitle: nativeThoughtSpokenText(seconds))
    }
}

/// A fenced block, plain on its first frame and syntax colored once tree-sitter has run off the
/// main actor in the block's task. Results are cached, so a block that scrolls back in is
/// colored at once. A block a reply is still writing (`writing`) is colored again at most every
/// 250 ms and only up to its last complete line (`CodeHighlightThrottle`): between renders it
/// keeps its last colors with the new text plain after them, and a render a newer chunk
/// supersedes is dropped. A finished block is colored once, in full.
struct HighlightedCodeBlock: View {
    let code: String
    let language: String?
    var writing = false
    /// The last colors this block rendered, with the code they color: the block keeps its
    /// identity while a reply streams into it.
    @State private var rendered: CodeHighlightCache.Rendered?
    /// When the block was last colored, while it is being written. A reference: noting it
    /// never redraws the block.
    @State private var lastRender = CodeHighlightThrottle.Last()

    private var key: CodeHighlightCache.Key { CodeHighlightCache.Key(fence: code, language: language) }

    private struct TaskKey: Equatable {
        let key: CodeHighlightCache.Key
        let writing: Bool
    }

    var body: some View {
        let key = key
        SHCodeBlock(key.code, language: language,
                    highlighted: CodeHighlightCache.colors(for: key, last: rendered, cached: CodeHighlightCache.cached(key)))
            .task(id: TaskKey(key: key, writing: writing)) {
                guard CodeHighlightCache.cached(key) == nil, CodeHighlight.path(forFenceLanguage: key.language) != nil else { return }
                var decision = CodeHighlightThrottle.decide(code: key.code, writing: writing, last: lastRender.value, now: .now)
                if case .wait(let delay) = decision {
                    // A newer chunk cancels this and decides again, with less of the wait left.
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    decision = CodeHighlightThrottle.decide(code: key.code, writing: writing, last: lastRender.value, now: .now)
                }
                guard case .render(let lines) = decision else { return }
                let target = lines.map { key.prefix(lines: $0) } ?? key
                if let cached = CodeHighlightCache.cached(target) {
                    rendered = CodeHighlightCache.Rendered(key: target, value: cached)
                    return
                }
                if let lines { lastRender.value = CodeHighlightThrottle.Render(at: .now, lines: lines) }
                // A newer chunk leaves this render running (the lines it colors are still the
                // block's first lines); only a newer render supersedes it, and it is dropped.
                lastRender.inFlight?.cancel()
                SHRenderProbe.tick("highlight.render")
                let style = CodeHighlight.Style.theme
                let work = Task.detached(priority: .userInitiated) { CodeHighlightCache.render(target, style: style) }
                lastRender.inFlight = work
                let value = await work.value
                guard lastRender.inFlight == work, let value else { return }
                lastRender.inFlight = nil
                CodeHighlightCache.store(value, for: target)
                rendered = CodeHighlightCache.Rendered(key: target, value: value)
            }
    }
}

/// When a fenced block a reply is still writing is colored again. A pure function of the last
/// render (its time and how many lines it colored) and the code now, so it is tested with
/// injected values.
enum CodeHighlightThrottle {
    static let interval: Duration = .milliseconds(250)

    struct Render: Equatable {
        let at: ContinuousClock.Instant
        let lines: Int
    }

    /// The block's last render, kept by reference, and the render still running.
    @MainActor final class Last {
        var value: Render?
        var inFlight: Task<AttributedString?, Never>?
    }

    enum Decision: Equatable {
        /// Color it now: its first `lines` lines, or all of it when nil.
        case render(lines: Int?)
        /// A line has been completed since, but the last render was too recent.
        case wait(Duration)
        /// Nothing to color yet: the text grew within its last line.
        case keep
    }

    static func decide(code: String, writing: Bool, last: Render?, now: ContinuousClock.Instant) -> Decision {
        // A finished block is colored once, in full.
        guard writing else { return .render(lines: nil) }
        // The last line is still being written: only the lines before it are complete.
        let complete = code.utf8.count { $0 == UInt8(ascii: "\n") }
        guard complete > (last?.lines ?? 0) else { return .keep }
        guard let last else { return .render(lines: complete) }
        let since = now - last.at
        return since >= interval ? .render(lines: complete) : .wait(interval - since)
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

        /// The same code's first `lines` lines.
        func prefix(lines: Int) -> Key {
            var seen = 0
            for index in code.utf8.indices where code.utf8[index] == UInt8(ascii: "\n") {
                seen += 1
                if seen == lines { return Key(code: String(code[..<index]), language: language) }
            }
            return self
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

    private final class Entry {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    /// Each throttled render of a growing fence is a new key: evict the oldest, never everything.
    @MainActor private static let values: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 256
        return cache
    }()

    @MainActor private static func name(_ key: Key) -> NSString { "\(key.language ?? "")\n\(key.code)" as NSString }

    @MainActor static func cached(_ key: Key) -> AttributedString? { values.object(forKey: name(key))?.value }

    @MainActor static func store(_ value: AttributedString, for key: Key) {
        values.setObject(Entry(value), forKey: name(key))
    }

    /// The block's colors, nil when the language has no grammar (the block stays plain) or the
    /// render was cancelled (a newer chunk superseded it). Parses with tree-sitter, so callers
    /// run it off the main actor.
    static func render(_ key: Key, style: CodeHighlight.Style,
                       isCancelled: @Sendable () -> Bool = { Task.isCancelled }) -> AttributedString? {
        guard let path = CodeHighlight.path(forFenceLanguage: key.language), !isCancelled() else { return nil }
        let lines = key.code.components(separatedBy: "\n")
        let colored = CodeHighlight.highlightLines(lines, path: path, style: style, isCancelled: isCancelled)
        guard colored.count == lines.count, !isCancelled() else { return nil }
        var joined = AttributedString()
        for (index, line) in colored.enumerated() {
            if isCancelled() { return nil }
            if index > 0 { joined += AttributedString("\n") }
            joined += line
        }
        return joined
    }
}
