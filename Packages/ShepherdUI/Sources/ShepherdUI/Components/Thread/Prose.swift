import SwiftUI

// Agent prose (SHThread board, docs/design/thread.md › Thread › Rich content in prose): the parsed reply's
// blocks with their inline runs already styled (`SHProseInline`). Value inputs only: the app
// parses once per change and maps its blocks here.

/// One Markdown block of agent prose, with its inline runs already styled.
public enum SHProseBlock: Equatable, Sendable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list(ordered: Bool, start: Int, items: [SHProseListItem])
    case quote([SHProseBlock])
    case code(String, language: String?)
    case rule
    case table(SHProseTable)
    case image(SHProseImage)
    /// A `<details>` disclosure, collapsed until opened.
    case details(summary: AttributedString, blocks: [SHProseBlock])
    /// The message's notes, after its last block.
    case footnotes([SHProseFootnote])
}

public struct SHProseListItem: Equatable, Sendable {
    public var text: AttributedString
    /// A task item's box, drawn read-only.
    public var task: SHProseTask?
    /// Blocks under the item: paragraphs, lists nested to any depth, code, tables.
    public var children: [SHProseBlock]

    public init(text: AttributedString, task: SHProseTask? = nil, children: [SHProseBlock] = []) {
        self.text = text
        self.task = task
        self.children = children
    }
}

public enum SHProseTask: Equatable, Sendable {
    case open, done
}

/// A pipe table: every row as long as the header.
public struct SHProseTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable {
        case leading, center, trailing
    }

    public var alignments: [Alignment]
    public var header: [AttributedString]
    public var rows: [[AttributedString]]
    /// The table as Markdown, for Copy.
    public var markdown: String

    public init(alignments: [Alignment], header: [AttributedString], rows: [[AttributedString]], markdown: String) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
        self.markdown = markdown
    }

    public var columns: Int { header.count }
}

/// `![alt](source)`: a local file draws as a thumbnail when this device can read it
/// (`shProseFileRoot`); anything else, and every remote URL, is a chip that is never fetched.
public struct SHProseImage: Equatable, Sendable {
    public var alt: String
    public var source: String

    public init(alt: String, source: String) {
        self.alt = alt
        self.source = source
    }
}

public struct SHProseFootnote: Equatable, Sendable {
    public var number: Int
    public var text: AttributedString

    public init(number: Int, text: AttributedString) {
        self.number = number
        self.text = text
    }
}

extension EnvironmentValues {
    /// The folder local image and file-link paths in prose resolve against (the agent's working directory),
    /// nil where the agent's files are not on this device (a remote host's agent, the iOS
    /// client): its images show as chips.
    @Entry public var shProseFileRoot: URL? = nil
    @Entry var shWritingFence: [Int]? = nil
}

/// Agent prose: body 13.5/1.6 in `textPrimary` at the 640pt measure, blocks 12pt apart.
/// Headings at `.headline`; lists indented 20pt per level to any depth; quotes on a 2pt rule;
/// tables, images, disclosures and footnotes as their own parts; fenced code through `code` (an
/// `SHCodeBlock` unless the app highlights it). Text follows `shProseSize`.
public struct SHAgentProse<Code: View>: View {
    let blocks: [SHProseBlock]
    let maxWidth: CGFloat
    let code: (String, String?) -> Code
    let writingFence: Bool

    public init(_ blocks: [SHProseBlock], maxWidth: CGFloat = SHThreadMetrics.proseMeasure,
                writingFence: Bool = false, @ViewBuilder code: @escaping (String, String?) -> Code) {
        self.blocks = blocks
        self.maxWidth = maxWidth
        self.code = code
        self.writingFence = writingFence
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHProseBlocks(blocks: blocks, code: code)
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .environment(\.shWritingFence, writingFence ? SHProseBlock.lastCodePath(blocks) : nil)
    }
}

extension SHAgentProse where Code == SHCodeBlock {
    public init(_ blocks: [SHProseBlock], maxWidth: CGFloat = SHThreadMetrics.proseMeasure, writingFence: Bool = false) {
        self.init(blocks, maxWidth: maxWidth, writingFence: writingFence) { SHCodeBlock($0, language: $1) }
    }
}

/// How prose reads: a reply's body, a quote inside it, or the model's thinking.
enum SHProseVoice: Equatable {
    /// Body in `textPrimary`.
    case reply
    /// Body italic in `textSecondary`.
    case quoted
    /// Italic 12.5 at 1.55 in `textSecondary` (expanded `SHThinking`); headings semibold.
    case thinking
}

/// Blocks at one level: the reply's own, or those inside a list item, a quote or a disclosure.
struct SHProseBlocks<Code: View>: View {
    let blocks: [SHProseBlock]
    var path: [Int] = []
    var nested = false
    /// How deep in lists these blocks sit: each level draws its own bullet.
    var depth = 0
    var voice = SHProseVoice.reply
    let code: (String, String?) -> Code
    @Environment(\.shWritingFence) private var writingFence
    @Environment(\.shProseSize) private var size
    @Environment(\.shProseHalfLeading) private var halfLeading
    @Environment(\.shProseTaskLinks) private var taskLinks
    @Environment(\.shProseFileRoot) private var fileRoot
    @Environment(\.shProseFileLinks) private var fileLinks
    @Environment(\.openURL) private var openURL

    var body: some View {
        let sh = Color.sh
        let tone = voice == .reply ? sh.textPrimary : sh.textSecondary
        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
            let blockPath = path + [index]
            switch block {
            case .heading(_, let text):
                heading(text).foregroundStyle(tone).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, nested || voice == .thinking ? 0 : SH.Space.xs)
                    .accessibilityAddTraits(.isHeader)
            case .paragraph(let text):
                words(text).foregroundStyle(tone).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    // CSS puts half of a line's leading above and below it; `.lineSpacing` only adds it between lines, so a paragraph
                    // of n lines is n line heights tall here only with it (the ProjectLead boards' `line-height: 1.6`).
                    .padding(.vertical, halfLeading && voice == .reply ? Self.halfLeadingPad : 0)
            case .quote(let inner):
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    SHProseBlocks(blocks: inner, path: blockPath, nested: true, depth: depth, voice: voice == .thinking ? .thinking : .quoted, code: code)
                }
                .padding(.leading, SH.Space.l)
                .overlay(alignment: .leading) { sh.lineStrong.frame(width: SHThreadMetrics.ruleWidth) }
            case .code(let text, let language):
                if SHMermaidBlock.renders(language: language, writing: blockPath == writingFence) {
                    SHMermaidBlock(text)
                } else {
                    code(text, language)
                }
            case .rule:
                SHHairline().padding(.vertical, SH.Space.xs)
            case .list(let ordered, let start, let items):
                list(ordered: ordered, start: start, items: items, tone: tone, path: blockPath)
            case .table(let table):
                SHProseTableView(table: table).equatable()
            case .image(let image):
                SHProseImageView(image: image)
            case .details(let summary, let inner):
                SHProseDetails(summary: summary, blocks: inner, path: blockPath, depth: depth, voice: voice, code: code)
            case .footnotes(let notes):
                SHProseFootnotes(notes: notes)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let destination = SHProseLink.destination(url, root: fileRoot) else { return .discarded }
            openURL(destination)
            return .handled
        })
    }

    private func list(ordered: Bool, start: Int, items: [SHProseListItem], tone: Color, path: [Int]) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    // The marker ends 6pt before the item, as a list's outside marker does.
                    marker(ordered: ordered, number: start + index, task: item.task)
                        .frame(width: SHThreadMetrics.listIndent - SH.Space.s, alignment: .trailing)
                        .padding(.trailing, SH.Space.s)
                    VStack(alignment: .leading, spacing: SH.Space.xs) {
                        if !item.text.characters.isEmpty || item.children.isEmpty {
                            words(item.text).foregroundStyle(tone).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SHProseBlocks(blocks: item.children, path: path + [index], nested: true, depth: depth + 1, voice: voice, code: code)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(item.task.map { $0 == .done ? "Done" : "Not done" } ?? "")
            }
        }
    }

    /// "1.", a bullet for this depth (•, ◦, ▪), or a task's box.
    @ViewBuilder private func marker(ordered: Bool, number: Int, task: SHProseTask?) -> some View {
        let sh = Color.sh
        if let task {
            Image(systemName: task == .done ? "checkmark.square.fill" : "square")
                .font(font)
                .foregroundStyle(task == .done ? sh.textSecondary : sh.textTertiary)
                .accessibilityHidden(true)
        } else {
            Text(ordered ? "\(number)." : SHProseBlocks.bullet(depth: depth))
                .font(font).foregroundStyle(voice == .thinking ? sh.textSecondary : sh.textPrimary).monospacedDigit()
                .fixedSize()
                .accessibilityHidden(!ordered)
        }
    }

    /// CSS's half-leading for the boards' `line-height: 1.6` at the body size (`SHLeadMetrics.proseLineHeight`).
    @MainActor private static var halfLeadingPad: CGFloat { SHLineSpacing.halfLeading(size: SHTextStyle.body.size, lineHeight: SHLeadMetrics.proseLineHeight) }

    private var font: Font { voice == .thinking ? SHThinking.font : .sh(.body, size: size) }

    /// A paragraph's or a list item's text in this voice.
    @ViewBuilder private func words(_ text: AttributedString) -> some View {
        switch voice {
        case .reply, .quoted:
            if voice == .reply, halfLeading, SHPlainParagraph.isPlain(text) {
                SHPlainParagraph(text: String(text.characters), size: size, lineSpacing: SHTextStyle.body.lineSpacing(size))
            } else if voice == .reply, let taskLinks, SHProseTaskLinks.hasReference(text) {
                SHTaskChipText.text(text, links: taskLinks, size: size).shText(.body, size: size)
                    .textRenderer(SHTaskChipRenderer(halfLeading: Self.halfLeadingPad))
                    .modifier(SHTaskChipPressTargets(halfLeading: Self.halfLeadingPad))
            } else {
                // Outside a Project conversation a task reference is only words: nothing opens it, the system included.
                let shown = SHProseTaskLinks.hasReference(text) ? SHProseTaskLinks.inert(text) : text
                SHProseFileLinks.prose(shown, root: fileRoot, actions: fileLinks).shText(.body, size: size).italic(voice == .quoted)
                    .modifier(SHFileLinkTargets(actions: SHProseFileLinks.targets(shown, root: fileRoot, actions: fileLinks)))
            }
        case .thinking: Text(text).font(SHThinking.font).italic().lineSpacing(SHThinking.lineSpacing)
        }
    }

    @ViewBuilder private func heading(_ text: AttributedString) -> some View {
        switch voice {
        case .reply, .quoted:
            SHProseFileLinks.prose(text, root: fileRoot, actions: fileLinks).font(.sh(.headline, size: size)).lineSpacing(SHTextStyle.headline.lineSpacing(size))
                .modifier(SHFileLinkTargets(actions: SHProseFileLinks.targets(text, root: fileRoot, actions: fileLinks)))
        case .thinking: Text(text).font(SHThinking.headingFont).italic().lineSpacing(SHThinking.lineSpacing)
        }
    }

    /// Bullets alternate by depth, as nested lists read in print.
    static func bullet(depth: Int) -> String {
        // The square asks for its text form: iOS would draw it as a large emoji square.
        ["•", "◦", "▪\u{FE0E}"][depth % 3]
    }
}

extension EnvironmentValues {
    /// A paragraph's leading is split above and below each line, as CSS does (the Project conversation and its worker threads).
    @Entry public var shProseHalfLeading = false
}

// The open fence runs to the end, including inside quotes, lists and disclosures.
extension SHProseBlock {
    static func lastCodePath(_ blocks: [SHProseBlock]) -> [Int]? {
        for (index, block) in blocks.enumerated().reversed() {
            switch block {
            case .code: return [index]
            case .quote(let inner), .details(_, let inner):
                if let path = lastCodePath(inner) { return [index] + path }
            case .list(_, _, let items):
                for (itemIndex, item) in items.enumerated().reversed() {
                    if let path = lastCodePath(item.children) { return [index, itemIndex] + path }
                }
            default: break
            }
        }
        return nil
    }
}
