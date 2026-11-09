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
/// thread is shown, one app start per run). Measured, all of it below the giant gate: four replies of 100 KB of
/// fences and tables (247 fences of 350 bytes and 82 tables of 12 cells each): 998, 999 and 996 MiB, 11,529 more
/// NSViews; four replies of 100 KB of fences alone (282 fences each): 532 MiB, 5,669 NSViews. That is 483 bytes per
/// unit of weight for a fence on its floor, and (from the difference) 554 for a table cell. What the design guessed
/// from the soak (448 for both) was 7 and 19 percent low. Both fits are in-sample.
///
/// Placeholders, never measured: the rate of a fence above its floor (the floor's own, so a 100 KB fence costs about
/// 49 MB), the table rate apart from its cells (the 554 mixes a table's own cost with its cells'), text, images,
/// lines, rows and Mermaid, and everything above the gate (`NativeProse.eagerCost` and `lazyEdgeCost` of a giant reply).
///
/// Left out: chunks a lazy stack realizes for a reader scrolled up inside a giant reply, history rows the thread's
/// lazy stack realizes above its eager rows, and that a Mermaid fence still being written is drawn as code
/// (`SHMermaidBlock.renders` wants it finished) though costed as a diagram.
///
/// Costs are computed with the parse (a chunk's) and in the store's `derive` (a row's), never in a view body.
public enum NativeMountedCost {
    // MARK: Constants

    /// A unit of weight of a fence on its floor. Measured on fences of 350 bytes.
    public static let fenceWeight = 483
    /// A fence of up to 1 KB of code (the weight floor).
    public static let fenceFloor = fenceWeight * NativeMarkdownBlock.codeFloor
    /// A byte of a fence above the floor. A placeholder, the floor's own rate, until a run of one long fence sets it.
    public static let fenceSlope = fenceWeight
    /// A unit of weight of a table (a cell's floor is 256 units). Measured by difference, tables of 12 cells only.
    public static let tableWeight = 554
    /// A unit of weight of an image, which costs its floor (an estimate).
    public static let imageWeight = 448
    /// A byte of text: a quarter of a fence's, text being one view per block and a fence a text system (an estimate).
    public static let textByte = fenceWeight / 4
    /// A Mermaid diagram: a web view and its process. Mostly out of this process (an estimate).
    public static let mermaid = 64 * 1024 * 1024
    /// One more line in a row: a burst, a thought, a note, an error, a steer, a subagent line (an estimate).
    public static let line = 128 * 1024
    /// What a row costs before its content: its chrome, spacing and footer (an estimate).
    public static let rowBase = 256 * 1024

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
