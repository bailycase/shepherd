import Foundation

/// An estimate, in bytes, of what the views built from a thread's rows hold in memory. It is the Mac's: a reply
/// is laid out whole below `NativeProse.Limits.giantBytes` and a giant one lays out its eager tail
/// (`NativeProse.eagerTail`), while iOS lays out every chunk and does not use this. It is what an agent's hidden
/// layout keeps mounted, which no byte count of the thread's store comes near: a fence holds a text field with
/// its own text system, and a table measures and draws every cell.
///
/// The unit is `NativeMarkdownBlock.proseWeight` (a floor per fence, table cell and image), costed per kind:
/// - a fence: `fenceFloor` up to a kilobyte of code, then `fenceSlope` for each byte above it;
/// - a table: `tableWeight` per unit of weight, 256 to a cell at least;
/// - an image: `imageFloor` units at `imageWeight`, whatever its source (a web or data image is a chip, a file a
///   bounded thumbnail);
/// - text (paragraph, heading, list item, quote, footnote, a closed disclosure's summary): `textByte` a byte;
/// - a Mermaid diagram: `mermaid`, mostly in its WebContent process, counted for what it costs the system;
/// - any other line of a row (an activity burst, a thought, a note, an error, a steer): `line`;
/// - a row: `rowBase` and its items.
///
/// Calibration (Release QA app, 2026-11-08; footprint with the purgeable graphics pool taken off, 5 s after the
/// thread is shown, the first thread shown in a fresh process): 483 bytes per unit of weight for a fence on its floor,
/// 554 for a table, 100 for a byte of a fence above its floor, about 2.5 KB for a byte of text, 0.5 MiB for a line and
/// 0.6 MiB for a row. Images and Mermaid are still the design's guesses.
///
/// Costs are computed with the parse (a chunk's) and in the store's `derive` (a row's), never in a view body.
public enum NativeMountedCost {
    // MARK: Constants

    /// A unit of weight of a fence on its floor. Measured on fences of 350 bytes.
    public static let fenceWeight = 483
    /// A fence of up to 1 KB of code (the weight floor).
    public static let fenceFloor = fenceWeight * NativeMarkdownBlock.codeFloor
    /// A byte of a fence above the floor. Measured on fences of 19, 67 and 202 KB, which agree within 15%.
    public static let fenceSlope = 100
    /// A unit of weight of a table (a cell's floor is 256 units). Measured on tables of 12 cells only.
    public static let tableWeight = 554
    /// A unit of weight of an image, which costs its floor (an estimate).
    public static let imageWeight = 448
    /// A byte of text. Every block is a selectable text view of its own, so a byte of text costs five times a byte of
    /// a fence on its floor. Measured on text blocks alone, and 40% short of a reply that mixes them with code.
    public static let textByte = 2560
    /// A Mermaid diagram: a web view and its process. Mostly out of this process (an estimate).
    public static let mermaid = 64 * 1024 * 1024
    /// One more line in a row: a burst, a thought, a note, an error, a steer, a subagent line. Measured on tool bursts
    /// (0.6 MiB) and thoughts (0.35).
    public static let line = 512 * 1024
    /// What a row costs before its content: its chrome, spacing and footer. Measured, 0.59 MiB a row.
    public static let rowBase = 600 * 1024

    // MARK: Kinds

    /// What the views of `block` hold, once built.
    public static func block(_ value: NativeMarkdownBlock) -> Int {
        switch value {
        case .heading(_, let text), .paragraph(let text):
            return text.utf8.count * textByte
        case .list(_, _, let items):
            return items.reduce(0) { $0 + item($1) }
        case .quote(let inner):
            return inner.reduce(0) { $0 + block($1) }
        case .code(let text, let language):
            if language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid" { return mermaid }
            return fenceFloor + max(0, text.utf8.count - NativeMarkdownBlock.codeFloor) * fenceSlope
        case .rule:
            return 0
        case .table:
            return value.proseWeight * tableWeight
        case .image:
            return NativeMarkdownBlock.imageFloor * imageWeight
        case .details, .footnotes:
            return value.proseWeight * textByte
        }
    }

    static func item(_ item: NativeMarkdownListItem) -> Int {
        item.text.utf8.count * textByte + item.children.reduce(0) { $0 + block($1) }
    }

    /// What one item of a reply holds. A prose item holds what its view lays out (`NativeProse.eagerCost`).
    public static func item(_ item: NativeTurnPresentation.Item) -> Int {
        switch item {
        case .prose(_, _, let prose): prose.eagerCost
        case .activity(_, let bursts): bursts.count * line
        case .subagents(_, let lines): lines.count * line
        case .images(_, let images): images.count * NativeMarkdownBlock.imageFloor * imageWeight
        case .thinking, .note, .goalRecord, .hook, .error, .retrying, .steer, .compaction, .question: line
        }
    }

    /// What the items of a reply hold, without the row around them.
    public static func presentation(_ presentation: NativeTurnPresentation) -> Int {
        presentation.items.reduce(0) { $0 + item($1) }
    }

    /// What a row holds: a reply its items, a user row its words.
    public static func row(_ row: NativeThreadRow) -> Int {
        rowBase + (row.presentation.map(presentation) ?? userWords(row.turn))
    }

    /// A row whose reply costs `presentation` (the store keeps it with the presentation).
    static func row(presentation: Int) -> Int { rowBase + presentation }

    static func userWords(_ turn: NativeTurn) -> Int {
        var bytes = 0
        for message in turn.messages {
            for block in message.blocks where block.kind == .text { bytes += block.text.utf8.count }
        }
        return bytes * textByte
    }
}
