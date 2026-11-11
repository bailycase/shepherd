import Foundation

// MARK: Prose chunks

/// A reply's parsed blocks, grouped into chunks with stable identity, so a parse that lands leaves
/// unchanged chunks as they were, and a view of a giant reply builds only the chunks in view plus
/// its tail (`eagerTail`).
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
        /// Bytes of text from which a reply is giant (`isGiant`): 128 KB, a few dozen screens. Below it a view
        /// lays every chunk out, as it did before chunks. The weights are no gauge of this: a fence and a
        /// table cell weigh a floor, so a 25 KB reply of code and tables weighs 140 KB and makes nine chunks.
        public static let giantBytes = 128 * 1024
        /// Weight the chunks before the last must reach to be laid out for real beside it (`eagerTail`).
        public static let eagerWeight = 32 * 1024
    }

    public let chunks: [NativeProseChunk]
    /// The text ends inside a fence still open: the block a streaming reply is writing.
    public let endsInOpenFence: Bool
    /// Top-level blocks, whatever stretches the lists were cut into.
    public let blockCount: Int
    /// The bytes of text the blocks draw, with no floors (`NativeMarkdownBlock.proseBytes`).
    public let textBytes: Int

    public static let empty = NativeProse([], endsInOpenFence: false)

    public var isEmpty: Bool { chunks.isEmpty }

    /// Long enough that a view builds only the chunks in view (`Limits.giantBytes`): what a nested lazy
    /// stack's height estimates cost a reader (a scroll up through it moves the text under them) is
    /// paid only by a reply whose every chunk built at once would cost more.
    public var isGiant: Bool { textBytes >= Limits.giantBytes }

    /// How many chunks at the end a view lays out for real. All of them for a reply that is not giant.
    /// For a giant one, the last chunk and the closed chunks before it until they weigh `Limits.eagerWeight`,
    /// so the end of the reply, where a stream grows and the thread follows it, is never an estimate even
    /// when the chunks are short (a run of wide tables is a few hundred points a chunk). The last chunk
    /// does not count: it grows, and a count that followed it would hand a chunk to the lazy stack
    /// each time it filled.
    public var eagerTail: Int {
        guard isGiant else { return chunks.count }
        var count = 1, weight = 0
        for chunk in chunks.dropLast().reversed() {
            guard weight < Limits.eagerWeight else { break }
            weight += chunk.weight
            count += 1
        }
        return count
    }

    /// What the views of every chunk hold (`NativeMountedCost`).
    public var cost: Int { chunks.reduce(0) { $0 + $1.cost } }

    /// What the views of a reply hold once built: the chunks the Mac's view lays out for real (`eagerTail`), all of
    /// them for a reply that is not giant. iOS lays out every chunk, so this undercounts a giant reply there.
    public var eagerCost: Int { chunks.suffix(eagerTail).reduce(0) { $0 + $1.cost } }

    /// The chunk just before the eager tail, which the Mac's lazy stack builds first when the reader scrolls up from
    /// the end. Nothing for a reply that is not giant.
    public var lazyEdgeCost: Int {
        let index = chunks.count - eagerTail - 1
        return chunks.indices.contains(index) ? chunks[index].cost : 0
    }

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
        var chunks: [NativeProseChunk] = []
        var current: [NativeProsePart] = []
        var weight = 0
        func close() {
            guard !current.isEmpty else { return }
            chunks.append(Self.chunk(current, weight: weight, at: chunks.count, reusing: previous))
            current = []
            weight = 0
        }
        for part in Self.parts(of: blocks[...], from: 0) {
            if Self.closes(count: current.count, weight: weight, before: part) { close() }
            current.append(part)
            weight += part.weight
        }
        close()
        self.init(chunks: chunks, endsInOpenFence: endsInOpenFence, blockCount: blocks.count,
                  textBytes: blocks.reduce(0) { $0 + $1.proseBytes })
    }

    init(chunks: [NativeProseChunk], endsInOpenFence: Bool, blockCount: Int, textBytes: Int) {
        self.chunks = chunks
        self.endsInOpenFence = endsInOpenFence
        self.blockCount = blockCount
        self.textBytes = textBytes
    }

    public init(_ parsed: (blocks: [NativeMarkdownBlock], endsInOpenFence: Bool), reusing previous: NativeProse? = nil) {
        self.init(parsed.blocks, endsInOpenFence: parsed.endsInOpenFence, reusing: previous)
    }

    /// Whether the chunk of `count` parts and `weight` so far is full before `part` joins it.
    static func closes(count: Int, weight: Int, before part: NativeProsePart) -> Bool {
        count > 0 && (count >= Limits.parts || weight >= Limits.weight || part.continuation)
    }

    /// The chunk at `index` of the prose it replaces, when it is the same, else a new one.
    static func chunk(_ parts: [NativeProsePart], weight: Int, at index: Int, reusing previous: NativeProse?) -> NativeProseChunk {
        if let old = previous?.chunks[safe: index], old.id == parts[0].id, old.parts == parts { return old }
        return NativeProseChunk(id: parts[0].id, parts: parts, weight: weight)
    }

    /// The parts of `blocks`, the first of which is top-level block number `ordinal`.
    static func parts(of blocks: ArraySlice<NativeMarkdownBlock>, from ordinal: Int) -> [NativeProsePart] {
        var parts: [NativeProsePart] = []
        parts.reserveCapacity(blocks.count)
        for (offset, block) in blocks.enumerated() {
            let ordinal = ordinal + offset
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

// MARK: Growing replies

/// A reply's prose that can grow: its markdown state (`NativeMarkdownState`) and the chunks of its frozen blocks. The
/// frozen blocks are final, so a chunk the greedy rule has closed over them is final too: it is built once and kept,
/// and only the open chunk and the tail's are made again. `prose` always equals `NativeProse` of the full parse.
public struct NativeProseState: Sendable {
    public private(set) var markdown: NativeMarkdownState
    /// Chunks of frozen parts that a part after them has closed.
    private(set) var closed: [NativeProseChunk] = []
    /// Frozen parts not in a closed chunk yet, and their weight.
    private var pending: [NativeProsePart] = []
    private var pendingWeight = 0
    /// The frozen blocks already made into parts, and their text.
    private var partedBlocks = 0
    private var partedBytes = 0
    public private(set) var prose: NativeProse = .empty

    /// `previous` is the prose this one replaces; chunks equal to its own keep its storage.
    public init(_ text: String, streaming: Bool, reusing previous: NativeProse? = nil) {
        markdown = NativeMarkdownState(text, streaming: streaming)
        rebuild(reusing: previous)
    }

    /// What `markdown.tail(of:)` says.
    public func tail(of newText: String) -> (bytes: Int, lines: Int)? { markdown.tail(of: newText) }

    /// False, and nothing changed, when `newText` does not keep the guard.
    public mutating func advance(to newText: String, streaming: Bool) -> Bool {
        guard markdown.advance(to: newText, streaming: streaming) else { return false }
        rebuild(reusing: prose)
        return true
    }

    private mutating func rebuild(reusing previous: NativeProse?) {
        let blocks = markdown.blocks
        let frozen = markdown.frozenCount
        if frozen > partedBlocks {
            let fresh = blocks[partedBlocks..<frozen]
            for part in NativeProse.parts(of: fresh, from: partedBlocks) {
                if NativeProse.closes(count: pending.count, weight: pendingWeight, before: part) {
                    closed.append(NativeProse.chunk(pending, weight: pendingWeight, at: closed.count, reusing: previous))
                    pending.removeAll(keepingCapacity: true)
                    pendingWeight = 0
                }
                pending.append(part)
                pendingWeight += part.weight
            }
            partedBytes += fresh.reduce(0) { $0 + $1.proseBytes }
            partedBlocks = frozen
        }
        // The same greedy rule goes on over the tail, from the frozen parts still open.
        let tail = blocks[frozen...]
        var open: [NativeProseChunk] = []
        var current = pending
        var weight = pendingWeight
        for part in NativeProse.parts(of: tail, from: frozen) {
            if NativeProse.closes(count: current.count, weight: weight, before: part) {
                open.append(NativeProse.chunk(current, weight: weight, at: closed.count + open.count, reusing: previous))
                current = []
                weight = 0
            }
            current.append(part)
            weight += part.weight
        }
        if !current.isEmpty { open.append(NativeProse.chunk(current, weight: weight, at: closed.count + open.count, reusing: previous)) }
        prose = NativeProse(chunks: closed + open, endsInOpenFence: markdown.endsInOpenFence, blockCount: blocks.count,
                            textBytes: partedBytes + tail.reduce(0) { $0 + $1.proseBytes })
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
        /// What the views of its blocks hold (`NativeMountedCost`), worked out once, in the parse.
        let cost: Int

        init(parts: [NativeProsePart], weight: Int) {
            self.parts = parts
            self.blocks = parts.map(\.block)
            self.weight = weight
            self.cost = self.blocks.reduce(0) { $0 + NativeMountedCost.block($1) }
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
    /// What the views of its blocks hold (`NativeMountedCost`).
    public var cost: Int { storage.cost }
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
    var proseWeight: Int { proseSize(floored: true) }

    /// The UTF-8 bytes of the text a block draws, with no floors.
    var proseBytes: Int { proseSize(floored: false) }

    fileprivate func proseSize(floored: Bool) -> Int {
        func atLeast(_ floor: Int, _ bytes: Int) -> Int { floored ? max(floor, bytes) : bytes }
        switch self {
        case .heading(_, let text), .paragraph(let text): return text.utf8.count
        case .list(_, _, let items): return items.reduce(0) { $0 + $1.proseSize(floored: floored) }
        case .quote(let inner): return inner.reduce(0) { $0 + $1.proseSize(floored: floored) }
        case .code(let text, _): return atLeast(Self.codeFloor, text.utf8.count)
        case .rule: return 0
        case .table(let table):
            let cells = table.header.count + table.rows.reduce(0) { $0 + $1.count }
            let bytes = table.header.reduce(0) { $0 + $1.utf8.count } + table.rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.utf8.count } }
            return floored ? max(Self.tableCellFloor * cells, bytes) : bytes
        case .image(let alt, let source): return atLeast(Self.imageFloor, alt.utf8.count + source.utf8.count)
        case .details(let summary, _): return summary.utf8.count + (floored ? Self.detailsFloor : 0)
        case .footnotes(let notes): return notes.reduce(0) { $0 + $1.text.utf8.count }
        }
    }

    static let codeFloor = 1024
    static let tableCellFloor = 256
    static let imageFloor = 1024
    static let detailsFloor = 256
}

extension NativeMarkdownListItem {
    var proseWeight: Int { proseSize(floored: true) }

    fileprivate func proseSize(floored: Bool) -> Int {
        text.utf8.count + children.reduce(0) { $0 + $1.proseSize(floored: floored) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
