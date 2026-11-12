import SwiftUI

// Agent prose (SHThread board): the parsed reply's
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
}

/// How a fenced block in prose is drawn: the app picks the renderer (`SHCodeBlock`, or one that highlights it). A type
/// rather than a closure, so the views that draw a block compare equal and are not drawn again when nothing in them changed.
public protocol SHProseCode: View, Equatable {
    /// `writing`: the reply is still writing this fence, so it is open at its end.
    @MainActor init(code: String, language: String?, writing: Bool)
}

/// One top-level block of a reply, or one stretch of a long list, with the id that keeps its view while the reply grows.
public struct SHProsePart: Equatable, Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        /// The ordinal of the top-level block in the reply.
        public var block: Int
        /// The index within a split list; 0 for every other block.
        public var stretch: Int

        public init(block: Int, stretch: Int) {
            self.block = block
            self.stretch = stretch
        }
    }

    public let id: ID
    public let block: SHProseBlock

    public init(id: ID, block: SHProseBlock) {
        self.id = id
        self.block = block
    }
}

/// A run of parts 12pt apart: a chunk of a reply. Each part is its own view, equal to what it was unless its block changed, so
/// a reply that grows at its end draws the block it grew and leaves the rest of the chunk as it was.
public struct SHProseChunk<Code: SHProseCode>: View, Equatable {
    let parts: [SHProsePart]
    /// The fence the reply is still writing: the part that holds it, and its path inside that part, one index per level
    /// down (a quote's or a disclosure's block, a list's item and then its block); `[]` when the part is the fence.
    let writing: (part: SHProsePart.ID, path: [Int])?

    public init(_ parts: [SHProsePart], writing: (part: SHProsePart.ID, path: [Int])? = nil) {
        self.parts = parts
        self.writing = writing
    }

    /// `writingFence`: the open fence is the last one in the chunk, wherever it sits.
    public init(_ parts: [SHProsePart], writingFence: Bool) {
        var writing: (part: SHProsePart.ID, path: [Int])?
        if writingFence, let path = SHProseBlock.lastCodePath(parts.map(\.block)), let index = path.first {
            writing = (parts[index].id, Array(path.dropFirst()))
        }
        self.init(parts, writing: writing)
    }

    nonisolated public static func == (lhs: SHProseChunk, rhs: SHProseChunk) -> Bool {
        lhs.parts == rhs.parts && lhs.writing?.part == rhs.writing?.part && lhs.writing?.path == rhs.writing?.path
    }

    /// Where the open fence is inside `part`, nil when it is in another.
    func writing(in part: SHProsePart) -> [Int]? {
        writing?.part == part.id ? writing?.path : nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            ForEach(parts) { part in
                SHProseBlockView<Code>(block: part.block, writing: writing(in: part)).equatable()
            }
        }
        .shProseLinks()
    }
}

/// Agent prose: body 13.5/1.6 in `textPrimary` at the 640pt measure, blocks 12pt apart.
/// Headings at `.headline`; lists indented 20pt per level to any depth; quotes on a 2pt rule;
/// tables, images, disclosures and footnotes as their own parts; fenced code through `Code` (an
/// `SHCodeBlock` unless the app highlights it). Text follows `shProseSize`.
public struct SHAgentProse<Code: SHProseCode>: View {
    let blocks: [SHProseBlock]
    let maxWidth: CGFloat
    let writingFence: Bool

    public init(_ blocks: [SHProseBlock], maxWidth: CGFloat = SHThreadMetrics.proseMeasure, writingFence: Bool = false) {
        self.blocks = blocks
        self.maxWidth = maxWidth
        self.writingFence = writingFence
    }

    public var body: some View {
        let parts = blocks.enumerated().map { SHProsePart(id: .init(block: $0.offset, stretch: 0), block: $0.element) }
        SHProseChunk<Code>(parts, writingFence: writingFence)
            .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

extension SHAgentProse where Code == SHCodeBlock {
    public init(_ blocks: [SHProseBlock], maxWidth: CGFloat = SHThreadMetrics.proseMeasure, writingFence: Bool = false) {
        self.blocks = blocks
        self.maxWidth = maxWidth
        self.writingFence = writingFence
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
