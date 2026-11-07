import Foundation

// MARK: Prose chunks

/// A reply's parsed blocks, grouped into chunks with stable identity, so a view builds only the
/// chunks in view plus the last one, and a parse that lands leaves unchanged chunks as they were.
///
/// A chunk holds at most `Limits.parts` parts and about `Limits.weight` bytes. A part is one
/// top-level block; a long list is cut into stretches (parts of its own that keep its numbering),
/// so one list never makes one chunk huge. Chunking is greedy and a pure function of the part
/// sequence: appending blocks never changes a chunk that a later part closed.
public struct NativeProse: Equatable, Sendable {
    public enum Limits {
        /// Parts in one chunk.
        public static let parts = 32
        /// Bytes of text in one chunk, weighed by `NativeMarkdownBlock.proseWeight`.
        public static let weight = 16 * 1024
        /// Items in one stretch of a list.
        public static let listItems = 32
    }

    public let chunks: [NativeProseChunk]
    /// The text ends inside a fence still open: the block a streaming reply is writing.
    public let endsInOpenFence: Bool
    /// Top-level blocks, whatever stretches the lists were cut into.
    public let blockCount: Int

    public static let empty = NativeProse([], endsInOpenFence: false)

    public var isEmpty: Bool { chunks.isEmpty }

    /// The blocks as parsed: parts in order, the stretches of one list rejoined into it.
    public var blocks: [NativeMarkdownBlock] {
        var blocks: [NativeMarkdownBlock] = []
        blocks.reserveCapacity(blockCount)
        var list: (ordered: Bool, start: Int, items: [NativeMarkdownListItem])?
        func flush() {
            guard let open = list else { return }
            blocks.append(.list(ordered: open.ordered, start: open.start, items: open.items))
            list = nil
        }
        for part in chunks.lazy.flatMap(\.parts) {
            if part.continuation, list != nil, case .list(_, _, let more) = part.block {
                list?.items.append(contentsOf: more)
                continue
            }
            flush()
            if case .list(let ordered, let start, let items) = part.block {
                list = (ordered, start, items)
            } else {
                blocks.append(part.block)
            }
        }
        flush()
        return blocks
    }

    /// `previous` is the prose this one replaces: a chunk equal to the one at its index keeps
    /// that chunk's storage, so comparing the two stays cheap.
    public init(_ blocks: [NativeMarkdownBlock], endsInOpenFence: Bool = false, reusing previous: NativeProse? = nil) {
        let parts = Self.parts(of: blocks)
        var chunks: [NativeProseChunk] = []
        var current: [NativeProsePart] = []
        var weight = 0
        func close() {
            guard let first = current.first else { return }
            let chunk = NativeProseChunk(id: first.id, parts: current, weight: weight)
            if let old = previous?.chunks[safe: chunks.count], old.id == chunk.id, old.parts == chunk.parts {
                chunks.append(old)
            } else {
                chunks.append(chunk)
            }
            current = []
            weight = 0
        }
        for part in parts {
            if !current.isEmpty, current.count >= Limits.parts || weight >= Limits.weight || part.continuation { close() }
            current.append(part)
            weight += part.weight
        }
        close()
        self.chunks = chunks
        self.endsInOpenFence = endsInOpenFence
        self.blockCount = blocks.count
    }

    public init(_ parsed: (blocks: [NativeMarkdownBlock], endsInOpenFence: Bool), reusing previous: NativeProse? = nil) {
        self.init(parsed.blocks, endsInOpenFence: parsed.endsInOpenFence, reusing: previous)
    }

    private static func parts(of blocks: [NativeMarkdownBlock]) -> [NativeProsePart] {
        var parts: [NativeProsePart] = []
        parts.reserveCapacity(blocks.count)
        for (ordinal, block) in blocks.enumerated() {
            guard case .list(let ordered, let start, let items) = block, items.count > 1 else {
                parts.append(NativeProsePart(id: .init(block: ordinal, stretch: 0), block: block, weight: block.proseWeight))
                continue
            }
            var first = 0
            var weight = 0
            var stretch = 0
            for (index, item) in items.enumerated() {
                weight += item.proseWeight
                let last = index == items.count - 1
                guard last || index - first + 1 >= Limits.listItems || weight >= Limits.weight else { continue }
                let slice = first == 0 && last ? block : .list(ordered: ordered, start: start + first, items: Array(items[first...index]))
                parts.append(NativeProsePart(id: .init(block: ordinal, stretch: stretch), block: slice, weight: weight))
                first = index + 1
                weight = 0
                stretch += 1
            }
        }
        return parts
    }
}

/// One top-level block of a reply, or one stretch of a long list.
public struct NativeProsePart: Equatable, Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        /// The ordinal of the top-level block in the item.
        public var block: Int
        /// The index within a split list; 0 for every other block.
        public var stretch: Int

        public init(block: Int, stretch: Int) {
            self.block = block
            self.stretch = stretch
        }
    }

    public let id: ID
    public let block: NativeMarkdownBlock
    /// What the block costs to draw, in bytes (`NativeMarkdownBlock.proseWeight`).
    public let weight: Int
    /// A later stretch of a list: its numbering and marker column carry on from the stretch before.
    public var continuation: Bool { id.stretch > 0 }
}

/// A run of parts a lazy stack builds as one view.
public struct NativeProseChunk: Equatable, Identifiable, Sendable {
    /// Shared between a chunk and the chunk that replaced it when nothing in it changed.
    final class Storage: Sendable {
        let parts: [NativeProsePart]
        let blocks: [NativeMarkdownBlock]
        let weight: Int

        init(parts: [NativeProsePart], weight: Int) {
            self.parts = parts
            self.blocks = parts.map(\.block)
            self.weight = weight
        }
    }

    /// Its first part's id.
    public let id: NativeProsePart.ID
    let storage: Storage

    init(id: NativeProsePart.ID, parts: [NativeProsePart], weight: Int) {
        self.id = id
        self.storage = Storage(parts: parts, weight: weight)
    }

    public var parts: [NativeProsePart] { storage.parts }
    public var blocks: [NativeMarkdownBlock] { storage.blocks }
    public var weight: Int { storage.weight }
    /// The first part carries on a list the chunk before it ended in.
    public var continuesList: Bool { storage.parts.first?.continuation ?? false }

    /// Always correct, and O(1) when the two share their storage.
    public static func == (lhs: NativeProseChunk, rhs: NativeProseChunk) -> Bool {
        lhs.id == rhs.id && (lhs.storage === rhs.storage || lhs.storage.parts == rhs.storage.parts)
    }

    func sharesStorage(with other: NativeProseChunk) -> Bool { storage === other.storage }
}

// MARK: Weights

extension NativeMarkdownBlock {
    /// What a block costs to build and keep, in UTF-8 bytes. A fence, a table cell and an image
    /// weigh at least a floor (a view and a renderer cost more than their text), and a closed
    /// `<details>` weighs its summary alone: its content is not drawn.
    var proseWeight: Int {
        switch self {
        case .heading(_, let text), .paragraph(let text): text.utf8.count
        case .list(_, _, let items): items.reduce(0) { $0 + $1.proseWeight }
        case .quote(let inner): inner.reduce(0) { $0 + $1.proseWeight }
        case .code(let text, _): max(Self.codeFloor, text.utf8.count)
        case .rule: 0
        case .table(let table):
            max(Self.tableCellFloor * (table.header.count + table.rows.reduce(0) { $0 + $1.count }),
                table.header.reduce(0) { $0 + $1.utf8.count } + table.rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.utf8.count } })
        case .image(let alt, let source): max(Self.imageFloor, alt.utf8.count + source.utf8.count)
        case .details(let summary, _): summary.utf8.count + Self.detailsFloor
        case .footnotes(let notes): notes.reduce(0) { $0 + $1.text.utf8.count }
        }
    }

    static let codeFloor = 1024
    static let tableCellFloor = 256
    static let imageFloor = 1024
    static let detailsFloor = 256
}

extension NativeMarkdownListItem {
    var proseWeight: Int { text.utf8.count + children.reduce(0) { $0 + $1.proseWeight } }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
