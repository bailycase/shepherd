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
/// Calibration: the Release QA app, 2026-11-08, three runs of a fresh app a row. Footprint with the purgeable
/// graphics pool taken off, 5 s after the thread is shown with every row loaded; replies from the QA model. "First" is
/// the first thread shown in the process, "second" a second thread of the same content shown after it.
///
/// | Fixture (rows, content) | First | Second | Estimate |
/// | --- | --- | --- | --- |
/// | 8: four of 100 KB, fences (350 bytes) and tables (12 cells) | 994 MiB, 11,529 NSViews | 398, half the views | 1,003 |
/// | 20: ten of 10 KB, the same | 329, 2,921 | 247, 2,932 | 260 |
/// | 8: four of 100 KB, fences alone (282 each) | 530, 5,669 | 166, half the views | 537 |
/// | 8: four of 30 KB, tables alone (199 each) | 1,296, 15,949 | 1,414, 15,960 | 1,297 |
/// | 8: four of 10 KB, text blocks alone | 97, 541 | 101, 552 | 101 |
/// | 20: ten of 3.8 KB, text, 5 fences and a table | 193, 781 | 93, 792 | 96 |
/// | 4: two of one 202 KB fence | 41, 29 | not read | 42 |
/// | 20: ten of one 19 KB fence | 34, 141 | not read | 34 |
/// | 8: four of one 67 KB fence | 26 (one run 39), 57 | not read | 31 |
/// | 30: fifteen of one 3.2 KB fence | 59, 211 | 26, 222 | 29 |
/// | 8 and 28: one short line of text | 4.7 and 16.7, 33 and 113 | not read | 4.7 and 16.4 |
/// | 20: ten of 4 tool calls; ten of a thought | 38 and 15, 193 and 81 | not read | 34 and 17 |
///
/// The estimate is within 13% of the second thread everywhere, and within 10% of the first except for the 67 KB fence
/// (21% over) and the fixtures that pay what the process does once. Against its second, the first thread holds 82 MiB
/// more for fences in Swift and Python, 33 for Python alone and 100 for the mixed reply, and nothing more for text or
/// tables alone (consistent with the tree-sitter grammars `CodeHighlight` loads and caches; not isolated). That share
/// is inside the fence rate (483 is the first thread's), so the estimate runs 21% under the first of ten 10 KB replies and
/// 50% under the first of the mixed reply and of the 3.2 KB fences, and 5, 3 and 13% over their second.
///
/// The fits: 483 bytes per unit of weight for a fence on its floor (fences alone), 554 for a table (tables alone; fences
/// with tables, by difference, agree within 1%), 100 a byte of a fence above its floor (the 202 KB fence; the 19 and 67
/// KB fences agree within 25%), 2.5 KB a byte of text (text alone; the mixed reply checks it), 0.5 MiB a line (a tool
/// burst holds 0.6, a thought 0.35) and 0.6 MiB a row (8 and 28 rows). Unmeasured: a fence of 1 to 3 KB, the length of a
/// text block apart from its bytes, and a table that is not 12 cells (the 554 mixes a table's own cost with its cells').
///
/// Placeholders: images (448 is the design's) and Mermaid (the app's footprint grew 22 MiB a diagram; its WebContent
/// process was not measured, and 64 MiB is the design's guess at both). Not covered: the lazy part of a giant reply
/// (the one giant fixture, a 202 KB fence, has every chunk in its eager tail). The second thread of 100 KB replies drew
/// half the first's views at 5 s and held steady; the estimate counts what the first drew.
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
    /// A byte of a fence above the floor. Fitted to a 202 KB fence; fences of 19 and 67 KB agree within 25%.
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
