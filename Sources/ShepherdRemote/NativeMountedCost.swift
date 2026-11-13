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
/// - text (paragraph, heading, list item, quote, footnote): `textByte` a byte;
/// - a closed disclosure: its summary as text, and a `line` (its content is not drawn until it is opened);
/// - a Mermaid diagram or an agent's page (`html-render`): `mermaid`, mostly in its WebContent process, counted for what it costs the system;
/// - any other line of a row (an activity burst, a thought, a note, an error): `line`; a steer is a `line` and its words
///   as text, like a user row's; a subagent record is a `line` each, though a Project's or worker's thread draws none;
/// - a row: `rowBase` and its items.
///
/// Calibration: the Release QA app, three runs of a fresh app a row. Footprint with the purgeable
/// graphics pool taken off, 5 s after the thread is shown with every row loaded; replies from the QA model. "First" is
/// the first thread shown in the process, "second" a second thread of the same content shown after it.
///
/// | Fixture (rows, content) | First | Second | Estimate |
/// | --- | --- | --- | --- |
/// | 8: four of 100 KB, fences (350 bytes) and tables (12 cells) | 997 MiB, 11,529 NSViews | 397, 4 of 8 rows loaded | 1,003 (501 for 4 rows) |
/// | 20: ten of 10 KB, the same | 328, 2,921 | 247, 2,932 | 260 |
/// | 8: four of 100 KB, fences alone (282 each) | 530, 5,669 | 167, 4 of 8 rows loaded | 537 (268 for 4 rows) |
/// | 8: four of 30 KB, tables alone (199 each) | 1,296, 15,949 | 1,414, 15,960 | 1,297 |
/// | 8: four of 10 KB, text blocks alone | 97, 541 | 101, 552 | 100 |
/// | 20: ten of 3.8 KB, text, 5 fences and a table | 193, 781 | 93, 792 | 96 |
/// | 4: two of one 202 KB fence | 42, 29 | -18 to +6, 2 of 4 rows loaded (noise) | 42 |
/// | 20: ten of one 19 KB fence | 35, 141 | not read | 36 |
/// | 8: four of one 67 KB fence | 26 (one run 39), 57 | not read | 31 |
/// | 30: fifteen of one 3.2 KB fence | 58, 211 | 26, 222 | 30 |
/// | 8 and 28: one short line of text | 4.7 and 17, 33 and 113 | not read | 5.0 and 17.6 |
/// | 20: ten of 4 tool calls; ten of a thought | 38 and 15, 193 and 81 | not read | 36 and 18 |
///
/// The estimate is within 6% of the first thread for the fences and tables, the text, the rows, the tool bursts and the
/// 19 and 202 KB fences, 16% over for the thoughts and 21% over for the 67 KB fence. Against the second thread it is
/// within 17% wherever every row loaded. In every fixture with replies of 100 KB or more (both 100 KB fixtures, the
/// 202 KB fence and the 200 KB replies) the second thread did not load every row: the run waits 90 s and stopped with
/// half of them. Its history stopped at about 1.4-1.5 MB each time, which looks like one history page, so the cause is
/// more likely paging than a slow store; it was not looked into. The "half the views" those threads drew is half the
/// rows. The estimate for those four rows (501 and 268 MiB) is 24 to 28% over the second thread of the fences and tables
/// (393 to 403 MiB, +26% on average) and 57 to 61% over that of the fences alone (166 to 170 MiB, +60% on average; one
/// run read 96, +179%).
///
/// The first thread held more than the second, by 82 MiB for fences in Swift and Python (ten of 10 KB), 33 for Python
/// alone (the 3.2 KB fences) and 100 for the mixed reply, and by nothing for text or tables alone (the second held more).
/// For the 100 KB fixtures it is about 200 MiB per eight rows, if the other four rows of the second thread would have
/// held what its first four did (an extrapolation). The cause is open. A one-time cost of the process (the tree-sitter
/// grammars `CodeHighlight` loads and caches) fits, but the comparison has two confounds, and either could make the gap:
/// - the QA model's plain replies are one text, so the second thread draws fences the first already highlighted, and
///   `CodeHighlightCache` (keyed by the code, 256 entries, more than the 247 fences of a 100 KB reply) may hold them;
/// - the second reading is a difference taken after the first thread was hidden, so it is net of whatever the first gave
///   back then.
/// Whatever the cause, it is inside the fences' rate: 483 is the first thread's, so the estimate runs 21% under the first
/// of ten 10 KB replies and 50% under the first of the mixed reply and of the 3.2 KB fences, and 5, 3 and 17% over
/// their second. The process's one-time cost, if that is it, is not a separate term. A budget that reads this for the
/// threads after the first may be 25 to 60% high for code-heavy replies, and should measure again with distinct content
/// in each thread before it derives its numbers.
///
/// The fits: 483 bytes per unit of weight for a fence on its floor (fences alone), 554 for a table (tables alone; fences
/// with tables, by difference, agree within 1%), 100 a byte of a fence above its floor (the 202 KB fence; the 19 and 67
/// KB fences agree within 25%), 2.5 KB a byte of text (text alone; the mixed reply checks it), 0.5 MiB a line (a tool
/// burst holds 0.6, a thought 0.35) and 0.6 MiB a row (8 and 28 rows). Unmeasured: a fence of 1 to 3 KB, the length of a
/// text block apart from its bytes, and a table that is not 12 cells (the 554 mixes a table's own cost with its cells').
///
/// Placeholders: images (448 is the design's) and Mermaid (the app's footprint grew 22 MiB a diagram; its WebContent
/// process was not measured, and 64 MiB is the design's guess at both).
///
/// The giant path (`eagerCost` of a reply of 128 KB or more, `lazyEdgeCost` of the chunk before its tail) runs low and is
/// not fitted. Four replies of 205 KB on a first thread, three runs each: fences and tables (55 chunks, a tail of 3, 22.7 MiB
/// eager and 9.1 for the edge) held 261 MiB (260 to 262) and 1,174 NSViews against an estimate of 105 (-60%); fences alone
/// (36 chunks, a tail of 3, 15.6 and 7.5) held 214 and 769 against 75 (-65%). The views are the tail's (1,174 is about 10
/// chunks at 117 each, against 103 in the 100 KB replies), so `eagerCost` prices the right chunks and too little for them:
/// the footprint is 156 and 139 MiB over the estimate, close to the same for two fixtures whose estimates differ by 30.
/// A one-time cost of the first thread (above) may be most of it; it was not isolated, since a second thread of such replies
/// loaded 2 of 8 rows in 90 s and its delta (-44, +52 and -42 MiB) is noise. (One run in three fell 70 MiB within a minute
/// of its reading, unexplained.) `lazyEdgeCost`: scrolling 8,000 points up from the
/// end of the thread realized one more chunk of the last reply (+105 NSViews) and added 3 to 5 MiB, against the 9.1 it prices.
///
/// Left out: chunks a lazy stack realizes for a reader scrolled up inside a giant reply, history rows the thread's
/// lazy stack realizes above its eager rows, and that a Mermaid fence still being written is drawn as code
/// (`SHMermaidBlock.renders` wants it finished) though costed as a diagram, and that a page is costed as one where it
/// stays code (iOS, issue bodies, repository files: `SHHTMLBlock` draws it only in a Mac reply).
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
    /// a fence on its floor. Fitted on text blocks alone; the mixed reply, which holds code and tables too, checks it.
    public static let textByte = 2560
    /// A Mermaid diagram: a web view and its process. Mostly out of this process (an estimate).
    public static let mermaid = 64 * 1024 * 1024
    /// One more line in a row: a burst, a thought, a note, an error, a subagent line, a steer's frame. Measured on tool
    /// bursts (0.6 MiB) and thoughts (0.35).
    public static let line = 512 * 1024
    /// What a row costs before its content: its chrome, spacing and footer. Measured, 0.59 MiB a row.
    public static let rowBase = 600 * 1024

    /// What a hidden thread keeps mounted when it lets rows go, at most (`NativeThreadStore.keptRows`): the rows of its last
    /// screen, so that showing it again builds nothing before its first frame. The rows after the last one are kept while they
    /// fit this, the last one alone while it fits `lastRow`.
    public static let lastScreen = 16 * 1024 * 1024
    /// The most a last row alone may cost and still be kept. A reply larger than this (a giant one, 100 KB of fences and tables
    /// costs 250 MiB) is let go with the rest: kept, a hundred hidden threads would hold what the budget exists to bound.
    public static let lastRow = 64 * 1024 * 1024
    /// The most rows of a last screen, whatever they cost.
    public static let lastScreenRows = 4

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
            if ["mermaid", "html-render"].contains(language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) { return mermaid }
            return fenceFloor + max(0, text.utf8.count - NativeMarkdownBlock.codeFloor) * fenceSlope
        case .rule:
            return 0
        case .table:
            return value.proseWeight * tableWeight
        case .image:
            return NativeMarkdownBlock.imageFloor * imageWeight
        case .details(let summary, _):
            return summary.utf8.count * textByte + line
        case .footnotes:
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
        case .steer(_, let text, _, _): line + text.utf8.count * textByte
        case .thinking, .note, .goalRecord, .hook, .error, .retrying, .compaction, .question: line
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
