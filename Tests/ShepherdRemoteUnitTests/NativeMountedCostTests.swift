import Testing
import ShepherdProtocol
@testable import ShepherdRemote

@Suite("Mounted cost")
struct NativeMountedCostTests {
    typealias Cost = NativeMountedCost
    typealias Item = NativeMarkdownListItem

    static func code(_ bytes: Int, language: String? = "swift") -> NativeMarkdownBlock {
        .code(String(repeating: "x", count: bytes), language: language)
    }

    static func table(rows: Int, columns: Int, cell: String = "c") -> NativeMarkdownBlock {
        .table(NativeMarkdownTable(alignments: Array(repeating: .none, count: columns), header: Array(repeating: cell, count: columns),
                                   rows: Array(repeating: Array(repeating: cell, count: columns), count: rows), source: ""))
    }

    /// A reply of `cycles` cycles of a Swift, a Python and a diff fence and a 3x3 table, the shape of a
    /// 100 KB reply of the QA model (92 cycles, 117 KB). Its fences are 300 to 450 bytes, on the 1 KB floor.
    static func bigReply(cycles: Int) -> String {
        var text = ""
        for n in 1...cycles {
            text += """
            ```swift
            @MainActor @Observable
            final class Store\(n) {
                private(set) var items: [Item] = []
                private var task: Task<Void, Never>?

                func reload() {
                    task?.cancel()
                    task = Task { [weak self] in
                        guard let fresh = try? await Loader.fetch(page: \(n)) else { return }
                        self?.items = fresh.sorted { $0.updatedAt > $1.updatedAt }
                    }
                }
            }
            ```


            """
            text += """
            ```python
            def summarize_\(n)(rows, limit=\(n * 10)):
                \"\"\"Group rows by key and keep the newest ones.\"\"\"
                groups = {}
                for row in rows:
                    groups.setdefault(row['key'], []).append(row)
                return {k: sorted(v, key=lambda r: r['ts'])[-limit:] for k, v in groups.items()}
            ```


            """
            text += """
            ```diff
            --- a/Sources/App/Cache\(n).swift
            +++ b/Sources/App/Cache\(n).swift
            @@ -\(10 + n),7 +\(10 + n),9 @@ final class Cache\(n) {
                 private var storage: [Key: Value] = [:]
            -    func value(for key: Key) -> Value? { storage[key] }
            +    private let limit = 64
            +    func value(for key: Key) -> Value? {
            +        defer { trim() }
            +        return storage[key]
            +    }
                 func insert(_ value: Value, for key: Key) { storage[key] = value }
            ```


            """
            text += """
            | Case | Before | After |
            | --- | ---: | ---: |
            | cold start | \(120 + n) ms | \(80 + n) ms |
            | scroll, 10k rows | \(16 + n % 5) ms | 6 ms |
            | memory, steady | \(210 + n) MB | \(150 + n) MB |


            """
        }
        return text
    }

    static func prose(cycles: Int) -> NativeProse { NativeProse(nativeMarkdownParse(bigReply(cycles: cycles))) }

    // MARK: Blocks

    @Test func aFenceCostsItsFloorUpToAKilobyteAndThenItsLength() {
        #expect(Cost.block(Self.code(0)) == Cost.fenceFloor)
        #expect(Cost.block(Self.code(1)) == Cost.fenceFloor)
        #expect(Cost.block(Self.code(1024)) == Cost.fenceFloor)
        #expect(Cost.block(Self.code(1025)) == Cost.fenceFloor + Cost.fenceByte)
        #expect(Cost.block(Self.code(100 * 1024)) == Cost.fenceFloor + 99 * 1024 * Cost.fenceByte)
        #expect(Cost.block(Self.code(10, language: nil)) == Cost.fenceFloor, "no language is still a fence")
    }

    @Test func aTableCostsItsCellsAtLeastTheFloorEach() {
        let cell = NativeMarkdownBlock.tableCellFloor
        #expect(Cost.block(Self.table(rows: 3, columns: 3)) == 12 * cell * Cost.tableWeight)
        #expect(Cost.block(Self.table(rows: 0, columns: 1)) == cell * Cost.tableWeight, "a header alone is a row of cells")
        let long = NativeMarkdownTable(alignments: [.none], header: ["h"], rows: [[String(repeating: "x", count: 2000)]], source: "")
        #expect(Cost.block(.table(long)) == 2001 * Cost.tableWeight, "cells longer than the floors weigh their bytes")
    }

    @Test func textCostsAQuarterOfAFencesRatePerByte() {
        #expect(Cost.textByte * 4 == Cost.fenceByte)
        #expect(Cost.block(.paragraph(String(repeating: "x", count: 1000))) == 1000 * Cost.textByte)
        #expect(Cost.block(.heading(level: 2, text: "Plan")) == 4 * Cost.textByte)
        #expect(Cost.block(.paragraph("é")) == 2 * Cost.textByte, "UTF-8 bytes")
        #expect(Cost.block(.footnotes([NativeMarkdownFootnote(number: 1, text: "note"), NativeMarkdownFootnote(number: 2, text: "more")])) == 8 * Cost.textByte)
        #expect(Cost.block(.paragraph("")) == 0 && Cost.block(.rule) == 0)
    }

    @Test func aMermaidFenceCostsItsWebViewWhateverItsLengthAndAnotherLanguageDoesNot() {
        let diagram = "graph TD\n  A --> B"
        #expect(Cost.block(.code(diagram, language: "mermaid")) == Cost.mermaid)
        #expect(Cost.block(.code(String(repeating: "x", count: 20_000), language: " Mermaid ")) == Cost.mermaid, "the view trims and ignores case")
        #expect(Cost.block(.code(diagram, language: "plantuml")) == Cost.fenceFloor, "drawn as source, not as a diagram")
    }

    @Test func anImageCostsItsFloorAndItsLengthAbove() {
        #expect(Cost.block(.image(alt: "a", source: "b.png")) == NativeMarkdownBlock.imageFloor * Cost.imageWeight)
        let long = NativeMarkdownBlock.image(alt: "a", source: String(repeating: "x", count: 5000))
        #expect(Cost.block(long) == 5001 * Cost.imageWeight)
    }

    @Test func aClosedDetailsCostsItsSummaryAlone() {
        let small = NativeMarkdownBlock.details(summary: "Log", blocks: [])
        let big = NativeMarkdownBlock.details(summary: "Log", blocks: [Self.code(50_000), Self.table(rows: 30, columns: 5)])
        #expect(Cost.block(small) == Cost.block(big), "its content is not drawn until it is opened")
        #expect(Cost.block(small) == (3 + Int(NativeMarkdownBlock.detailsFloor)) * Cost.textByte)
    }

    @Test func nestedListsAndQuotesCostTheirChildren() {
        let inner = NativeMarkdownBlock.list(ordered: false, start: 1, items: [Item(text: "deep", children: [Self.code(10)])])
        let list = NativeMarkdownBlock.list(ordered: true, start: 1, items: [
            Item(text: "one", children: [.paragraph("more"), inner]), Item(text: "two"),
        ])
        let expected = (3 + 4 + 4) * Cost.textByte + Cost.fenceFloor + 3 * Cost.textByte
        #expect(Cost.block(list) == expected)
        #expect(Cost.block(.quote([list, Self.code(5000)])) == expected + Cost.block(Self.code(5000)))
        #expect(Cost.block(.quote([.quote([.paragraph("xy")])])) == 2 * Cost.textByte)
    }

    // MARK: Chunks and replies

    @Test func aChunkCostsWhatItsBlocksDoAndKeepsItWhenItsStorageIsReused() {
        let blocks: [NativeMarkdownBlock] = [.paragraph("intro"), Self.code(300), Self.table(rows: 3, columns: 3), Self.code(5000)]
        let prose = NativeProse(blocks)
        #expect(prose.chunks.count == 1)
        #expect(prose.chunks[0].cost == blocks.reduce(0) { $0 + Cost.block($1) })
        #expect(prose.cost == prose.chunks[0].cost)

        let reused = NativeProse(blocks, reusing: prose)
        #expect(reused.chunks[0].sharesStorage(with: prose.chunks[0]))
        #expect(reused.chunks[0].cost == prose.chunks[0].cost)
        let grown = NativeProse(blocks + [.paragraph("growing")], reusing: prose)
        #expect(!grown.chunks[0].sharesStorage(with: prose.chunks[0]))
        #expect(grown.chunks[0].cost == prose.chunks[0].cost + 7 * Cost.textByte)
    }

    @Test func aListSplitIntoStretchesCostsTheSameAsTheWholeList() {
        let list = NativeMarkdownBlock.list(ordered: true, start: 1, items: (0..<100).map { Item(text: "item \($0)", children: [Self.code(20)]) })
        let prose = NativeProse([list])
        #expect(prose.chunks.count > 1)
        #expect(prose.cost == Cost.block(list))
    }

    @Test func aReplyBelowTheGateCostsAllItsChunksAndEagerlyToo() {
        let reply = Self.prose(cycles: 92)
        #expect(!reply.isGiant && reply.eagerTail == reply.chunks.count, "a 100 KB reply is laid out whole")
        #expect(reply.eagerCost == reply.cost)
        #expect(reply.lazyEdgeCost == 0, "there are no chunks the lazy stack could build")
        // 273 fences on the floor and 91 tables of 12 cells: about 559,104 units of weight. Measured, a mounted reply of
        // this shape held about 250 MB (Release: the soak, then the calibration run).
        let weight = reply.chunks.reduce(0) { $0 + $1.weight }
        #expect(abs(weight - 559_104) <= 559_104 / 20, "the fixture is the reply the model was fitted on")
        #expect(abs(reply.cost - Self.measuredBigHundred) <= Self.measuredBigHundred * 3 / 100)
    }

    /// What a mounted 100 KB reply of fences and tables held, in bytes.
    static let measuredBigHundred = 250_000_000

    @Test func aGiantReplyCostsItsEagerTailWhateverItsLength() {
        let small = Self.prose(cycles: 368)
        let large = Self.prose(cycles: 736)
        #expect(small.isGiant && large.isGiant)
        #expect(small.eagerTail == large.eagerTail && small.eagerTail < small.chunks.count)
        let eager = small.chunks.suffix(small.eagerTail).reduce(0) { $0 + $1.cost }
        #expect(small.eagerCost == eager)
        #expect(small.eagerCost < small.cost / 10)
        let chunk = small.chunks.dropLast().map(\.cost).max() ?? 0
        #expect(abs(large.eagerCost - small.eagerCost) <= chunk, "the tail costs the same however long the reply grows, to a chunk (the last is part full)")
        // At the gate a reply stops costing all of its chunks and costs its tail.
        let below = Self.prose(cycles: 92), above = Self.prose(cycles: 140)
        #expect(!below.isGiant && below.eagerCost == below.cost)
        #expect(above.isGiant && above.eagerCost < above.cost / 3)
    }

    @Test func aGiantRepliesLazyEdgeIsTheChunkBeforeItsEagerTail() {
        let reply = Self.prose(cycles: 368)
        let edge = reply.chunks[reply.chunks.count - reply.eagerTail - 1]
        #expect(reply.lazyEdgeCost == edge.cost && edge.cost > 0)
        #expect(NativeProse.empty.lazyEdgeCost == 0 && NativeProse.empty.cost == 0 && NativeProse.empty.eagerCost == 0)
    }

    @Test func tenSmallRepliesCostAboutAsMuchAsOneOf100KB() {
        let small = Self.prose(cycles: 9)
        #expect(!small.isGiant && small.eagerCost == small.cost)
        let hundred = Self.prose(cycles: 92)
        let ten = 10 * small.cost
        #expect(abs(ten - hundred.cost) <= hundred.cost / 10, "cost follows the text, not how it is chunked")
    }

    // MARK: Items and rows

    @Test func everyLineLikeItemCostsALineAndAnItemOfSeveralCostsThemAll() {
        let line = Cost.line
        #expect(Cost.item(.note(id: "n", text: "a note")) == line)
        #expect(Cost.item(.goalRecord(id: "g", text: "Goal met")) == line)
        #expect(Cost.item(.thinking(id: "t", text: "hm", blocks: [.paragraph("hm")], seconds: 2, live: false, since: nil)) == line)
        #expect(Cost.item(.subagents(id: "s", lines: [.init(title: "a", meta: ""), .init(title: "b", meta: "")])) == 2 * line)
        #expect(Cost.item(.images(id: "i", images: [])) == 0)
    }

    @Test func aProseItemCostsWhatItsViewLaysOut() {
        let reply = Self.prose(cycles: 140)
        #expect(Cost.item(.prose(id: "p", text: "", prose: reply)) == reply.eagerCost)
        let short = NativeProse([.paragraph("short")])
        #expect(Cost.item(.prose(id: "p", text: "short", prose: short)) == 5 * Cost.textByte)
    }

    @Test func aReplyRowCostsItsBaseAndItsItemsAndAUserRowItsWords() {
        let items: [NativeTurnPresentation.Item] = [
            .prose(id: "p", text: "", prose: NativeProse([Self.code(100)])), .note(id: "n", text: "note"),
        ]
        let presentation = NativeTurnPresentation(items: items, changes: nil, toolCalls: 0, copyText: "", endedAt: nil)
        let turn = NativeTurn(id: "a", isUser: false, messages: [])
        let reply = NativeThreadRow(turn: turn, presentation: presentation, live: false, promptText: nil, startedAt: nil)
        #expect(Cost.row(reply) == Cost.rowBase + Cost.fenceFloor + Cost.line)
        #expect(Cost.presentation(presentation) == Cost.fenceFloor + Cost.line)

        let message = NativeThreadMessage(entryID: "u", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "hello there")])
        let user = NativeThreadRow(turn: NativeTurn(id: "u", isUser: true, messages: [message]), presentation: nil, live: false, promptText: nil, startedAt: nil)
        #expect(Cost.row(user) == Cost.rowBase + 11 * Cost.textByte)
        let empty = NativeThreadRow(turn: NativeTurn(id: "u2", isUser: true, messages: []), presentation: nil, live: false, promptText: nil, startedAt: nil)
        #expect(Cost.row(empty) == Cost.rowBase)
    }
}
