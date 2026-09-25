import SwiftUI

// Agent prose (NWThread board, DESIGN.md › Thread › Rich content in prose): the parsed reply's
// blocks with their inline runs already styled (`NWProseInline`). Value inputs only: the app
// parses once per change and maps its blocks here.

/// One Markdown block of agent prose, with its inline runs already styled.
public enum NWProseBlock: Equatable, Sendable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list(ordered: Bool, start: Int, items: [NWProseListItem])
    case quote([NWProseBlock])
    case code(String, language: String?)
    case rule
    case table(NWProseTable)
    case image(NWProseImage)
    /// A `<details>` disclosure, collapsed until opened.
    case details(summary: AttributedString, blocks: [NWProseBlock])
    /// The message's notes, after its last block.
    case footnotes([NWProseFootnote])
}

public struct NWProseListItem: Equatable, Sendable {
    public var text: AttributedString
    /// A task item's box, drawn read-only.
    public var task: NWProseTask?
    /// Blocks under the item: paragraphs, lists nested to any depth, code, tables.
    public var children: [NWProseBlock]

    public init(text: AttributedString, task: NWProseTask? = nil, children: [NWProseBlock] = []) {
        self.text = text
        self.task = task
        self.children = children
    }
}

public enum NWProseTask: Equatable, Sendable {
    case open, done
}

/// A pipe table: every row as long as the header.
public struct NWProseTable: Equatable, Sendable {
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
/// (`nwProseFileRoot`); anything else, and every remote URL, is a chip that is never fetched.
public struct NWProseImage: Equatable, Sendable {
    public var alt: String
    public var source: String

    public init(alt: String, source: String) {
        self.alt = alt
        self.source = source
    }
}

public struct NWProseFootnote: Equatable, Sendable {
    public var number: Int
    public var text: AttributedString

    public init(number: Int, text: AttributedString) {
        self.number = number
        self.text = text
    }
}

extension EnvironmentValues {
    /// The folder local image paths in prose resolve against (the agent's working directory),
    /// nil where the agent's files are not on this device (a remote host's agent, the iOS
    /// client): its images show as chips.
    @Entry public var nwProseFileRoot: URL? = nil
}

/// Agent prose: body 13.5/1.6 in `textPrimary` at the 640pt measure, blocks 12pt apart.
/// Headings at `.headline`; lists indented 20pt per level to any depth; quotes on a 2pt rule;
/// tables, images, disclosures and footnotes as their own parts; fenced code through `code` (an
/// `NWCodeBlock` unless the app highlights it). Text follows `nwProseSize`.
public struct NWAgentProse<Code: View>: View {
    let blocks: [NWProseBlock]
    let maxWidth: CGFloat
    let code: (String, String?) -> Code

    public init(_ blocks: [NWProseBlock], maxWidth: CGFloat = NWThreadMetrics.proseMeasure,
                @ViewBuilder code: @escaping (String, String?) -> Code) {
        self.blocks = blocks
        self.maxWidth = maxWidth
        self.code = code
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWProseBlocks(blocks: blocks, code: code)
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

extension NWAgentProse where Code == NWCodeBlock {
    public init(_ blocks: [NWProseBlock], maxWidth: CGFloat = NWThreadMetrics.proseMeasure) {
        self.init(blocks, maxWidth: maxWidth) { NWCodeBlock($0, language: $1) }
    }
}

/// Blocks at one level: the reply's own, or those inside a list item, a quote or a disclosure.
struct NWProseBlocks<Code: View>: View {
    let blocks: [NWProseBlock]
    var nested = false
    /// How deep in lists these blocks sit: each level draws its own bullet.
    var depth = 0
    /// Inside a quote: italic `textSecondary`.
    var quoted = false
    let code: (String, String?) -> Code
    @Environment(\.nwProseSize) private var size

    var body: some View {
        let nw = Color.nw
        let tone = quoted ? nw.textSecondary : nw.textPrimary
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case .heading(_, let text):
                Text(text).font(.nw(.headline, size: size)).lineSpacing(NWTextStyle.headline.lineSpacing(size))
                    .foregroundStyle(tone).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, nested ? 0 : NW.Space.xs)
                    .accessibilityAddTraits(.isHeader)
            case .paragraph(let text):
                Text(text).nwText(.body, size: size).italic(quoted).foregroundStyle(tone).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .quote(let inner):
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    NWProseBlocks(blocks: inner, nested: true, depth: depth, quoted: true, code: code)
                }
                .padding(.leading, NW.Space.l)
                .overlay(alignment: .leading) { nw.lineStrong.frame(width: NWThreadMetrics.ruleWidth) }
            case .code(let text, let language):
                code(text, language)
            case .rule:
                NWHairline().padding(.vertical, NW.Space.xs)
            case .list(let ordered, let start, let items):
                list(ordered: ordered, start: start, items: items, tone: tone)
            case .table(let table):
                NWProseTableView(table: table).equatable()
            case .image(let image):
                NWProseImageView(image: image)
            case .details(let summary, let inner):
                NWProseDetails(summary: summary, blocks: inner, depth: depth, code: code)
            case .footnotes(let notes):
                NWProseFootnotes(notes: notes)
            }
        }
    }

    private func list(ordered: Bool, start: Int, items: [NWProseListItem], tone: Color) -> some View {
        VStack(alignment: .leading, spacing: NW.Space.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    // The marker ends 6pt before the item, as a list's outside marker does.
                    marker(ordered: ordered, number: start + index, task: item.task)
                        .frame(width: NWThreadMetrics.listIndent - NW.Space.s, alignment: .trailing)
                        .padding(.trailing, NW.Space.s)
                    VStack(alignment: .leading, spacing: NW.Space.xs) {
                        if !item.text.characters.isEmpty || item.children.isEmpty {
                            Text(item.text).nwText(.body, size: size).italic(quoted).foregroundStyle(tone).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        NWProseBlocks(blocks: item.children, nested: true, depth: depth + 1, quoted: quoted, code: code)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(item.task.map { $0 == .done ? "Done" : "Not done" } ?? "")
            }
        }
    }

    /// "1.", a bullet for this depth (•, ◦, ▪), or a task's box.
    @ViewBuilder private func marker(ordered: Bool, number: Int, task: NWProseTask?) -> some View {
        let nw = Color.nw
        if let task {
            Image(systemName: task == .done ? "checkmark.square.fill" : "square")
                .font(.nw(.body, size: size))
                .foregroundStyle(task == .done ? nw.textSecondary : nw.textTertiary)
                .accessibilityHidden(true)
        } else {
            Text(ordered ? "\(number)." : NWProseBlocks.bullet(depth: depth))
                .font(.nw(.body, size: size)).foregroundStyle(nw.textPrimary).monospacedDigit()
                .fixedSize()
                .accessibilityHidden(!ordered)
        }
    }

    /// Bullets alternate by depth, as nested lists read in print.
    static func bullet(depth: Int) -> String {
        // The square asks for its text form: iOS would draw it as a large emoji square.
        ["•", "◦", "▪\u{FE0E}"][depth % 3]
    }
}
