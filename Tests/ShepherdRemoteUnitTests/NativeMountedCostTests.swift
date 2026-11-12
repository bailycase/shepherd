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

    /// A Swift fence of 300 to 450 bytes, on the 1 KB floor.
    static func swiftFence(_ n: Int) -> String {
        """
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
    }

    /// A reply of `cycles` cycles of a Swift, a Python and a diff fence and a 3x3 table (the shape of the QA model's
    /// 100 KB reply: 82 cycles and the Swift fence of the 83rd, where it stops, 247 fences and 82 tables). Its fences
    /// are 300 to 450 bytes, on the 1 KB floor. `endingMidCycle` adds that fence.
    static func bigReply(cycles: Int, endingMidCycle: Bool = false) -> String {
        var text = ""
        for n in 1...cycles {
            text += swiftFence(n)
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
        if endingMidCycle { text += swiftFence(cycles + 1) }
        return text
    }

    static func prose(cycles: Int, endingMidCycle: Bool = false) -> NativeProse {
        NativeProse(nativeMarkdownParse(bigReply(cycles: cycles, endingMidCycle: endingMidCycle)))
    }

    /// `count` fences of 350 bytes and no other block, the shape of the QA model's `fences:` reply (282 in 100 KB).
    static func fencesReply(count: Int) -> String {
        (1...count).map { _ in "```swift\n\(String(repeating: "x", count: 350))\n```\n\n" }.joined()
    }

    // MARK: Blocks

    @Test func aFenceCostsItsFloorUpToAKilobyteAndThenItsLength() {
        #expect(Cost.block(Self.code(0)) == Cost.fenceFloor)
        #expect(Cost.block(Self.code(1)) == Cost.fenceFloor)
        #expect(Cost.block(Self.code(1024)) == Cost.fenceFloor)
        #expect(Cost.block(Self.code(1025)) == Cost.fenceFloor + Cost.fenceSlope)
        #expect(Cost.block(Self.code(100 * 1024)) == Cost.fenceFloor + 99 * 1024 * Cost.fenceSlope)
        #expect(Cost.block(Self.code(10, language: nil)) == Cost.fenceFloor, "no language is still a fence")
    }

    @Test func aTableCostsItsCellsAtLeastTheFloorEach() {
        let cell = NativeMarkdownBlock.tableCellFloor
        #expect(Cost.block(Self.table(rows: 3, columns: 3)) == 12 * cell * Cost.tableWeight)
        #expect(Cost.block(Self.table(rows: 0, columns: 1)) == cell * Cost.tableWeight, "a header alone is a row of cells")
        let long = NativeMarkdownTable(alignments: [.none], header: ["h"], rows: [[String(repeating: "x", count: 2000)]], source: "")
        #expect(Cost.block(.table(long)) == 2001 * Cost.tableWeight, "cells longer than the floors weigh their bytes")
    }

    @Test func textCostsItsBytes() {
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

    // MARK: Calibration pins (Release QA app; `NativeMountedCost` has the table)

    private static let mib = 1024 * 1024

    @Test func aLongFenceCostsWhatTheCalibrationMeasured() {
        // Fences of 202, 67 and 19 KB (3000, 1000 and 300 lines of Python) added about 19.7, 6 and 2.2 MiB each.
        for (bytes, measured) in [(202_208, 197), (67_000, 60), (19_600, 22)] {
            let cost = Cost.block(Self.code(bytes))
            #expect(abs(cost - measured * Self.mib / 10) <= measured * Self.mib / 10 * 15 / 100, "\(bytes) bytes")
        }
    }

    @Test func rowsCostWhatTheCalibrationMeasured() {
        // 8 and 28 rows of one short reply each held 4.7 and 16.7 MiB.
        for (rows, measured) in [(8, 47), (28, 167)] {
            #expect(abs(rows * Cost.rowBase - measured * Self.mib / 10) <= measured * Self.mib / 10 * 8 / 100, "\(rows) rows")
        }
    }

    @Test func aTurnOfToolCallsCostsWhatTheCalibrationMeasured() {
        // Ten replies of four tool calls of different kinds and a line of closing text, with their prompts: 38 MiB.
        func call(_ name: String, _ id: String, _ args: String) -> NativeThreadMessage {
            Fixture.tool(name, args: args, id: "e-\(id)", callID: id)
        }
        let words = String(repeating: "x", count: 89)
        let messages = [
            call("read", "r", #"{"path":"a.swift"}"#), call("edit", "e", #"{"path":"a.swift"}"#),
            call("bash", "b", #"{"command":"ls"}"#), call("lint", "l", "{}"),
            Fixture.assistant(words),
        ]
        let presentation = nativeTurnPresentation(messages, live: false)
        let bursts = presentation.items.reduce(0) { total, item in
            if case .activity(_, let bursts) = item { total + bursts.count } else { total }
        }
        #expect(bursts == 4, "one line to a kind of call")
        #expect(Cost.presentation(presentation) == 4 * Cost.line + words.utf8.count * Cost.textByte)
        let reply = 10 * (2 * Cost.rowBase + Cost.presentation(presentation))
        #expect(abs(reply - 38 * Self.mib) <= 38 * Self.mib * 15 / 100)
    }

    @Test func anImageCostsItsFloorWhateverItsSource() {
        let floor = NativeMarkdownBlock.imageFloor * Cost.imageWeight
        #expect(Cost.block(.image(alt: "a", source: "b.png")) == floor)
        let data = NativeMarkdownBlock.image(alt: "a", source: "data:image/png;base64," + String(repeating: "x", count: 300_000))
        #expect(Cost.block(data) == floor, "a long source is still one chip or one thumbnail")
    }

    @Test func aClosedDetailsCostsItsSummaryAlone() {
        let small = NativeMarkdownBlock.details(summary: "Log", blocks: [])
        let big = NativeMarkdownBlock.details(summary: "Log", blocks: [Self.code(50_000), Self.table(rows: 30, columns: 5)])
        #expect(Cost.block(small) == Cost.block(big), "its content is not drawn until it is opened")
        #expect(Cost.block(small) == 3 * Cost.textByte + Cost.line, "the summary's words and one line, not the chunking floor")
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
        let reply = Self.prose(cycles: 82, endingMidCycle: true)
        #expect(!reply.isGiant && reply.eagerTail == reply.chunks.count, "a 100 KB reply is laid out whole")
        #expect(reply.eagerCost == reply.cost)
        #expect(reply.lazyEdgeCost == 0, "there are no chunks the lazy stack could build")
        // 247 fences on the floor and 82 tables of 12 cells. Measured on the Release QA app, a thread of four such replies
        // held 998 MiB more once shown: about 249.5 MiB a reply. (The soak's 250 MB was a larger reply, 117 KB and 273 fences.)
        let weight = reply.chunks.reduce(0) { $0 + $1.weight }
        #expect(weight == 247 * 1024 + 82 * 12 * 256, "the fixture is the reply the model was fitted on")
        #expect(abs(reply.cost - Self.measuredBigHundred) <= Self.measuredBigHundred * 3 / 100)
    }

    /// What a mounted 100 KB reply of fences and tables held, in bytes (the calibration: 998 MiB for four).
    static let measuredBigHundred = 998 * 1024 * 1024 / 4

    /// Fences alone pin `fenceWeight` apart from `tableWeight`, which `aReplyBelowTheGate...` pins through the tables.
    @Test func aReplyOfFencesAloneCostsWhatTheCalibrationMeasured() {
        let reply = NativeProse(nativeMarkdownParse(Self.fencesReply(count: 282)))
        #expect(!reply.isGiant && reply.eagerCost == reply.cost)
        #expect(reply.chunks.reduce(0) { $0 + $1.weight } == 282 * 1024, "every fence is on the floor")
        // Four such replies held 532 MiB more once shown.
        let measured = 532 * 1024 * 1024 / 4
        #expect(abs(reply.cost - measured) <= measured * 3 / 100)
    }

    /// The text blocks of the QA model's reply, 10 KB of headings, paragraphs, lists and quotes (`prose:10`).
    static func textReply(cycles: Int) -> String {
        (1...cycles).map { n in
            """
            ## Findings, part \(n)

            I read through the module and the main flow is straightforward, but there are a few places where `Session\(n)` holds state longer than it needs to. The interesting bit is how **ownership** moves between the view model and the store; see [the design notes](https://example.com/design/notes-\(n)) for the background.

            ### What I changed

            - Moved the `refresh\(n)()` call out of the render path
            - Replaced the ad hoc cache with a bounded `LRU\(n)` of 64 entries
            - Made `load(id:)` cancel the previous task before starting a new one
            - Added a regression test for the empty-state case

            ### Steps to verify

            1. Build the project with `swift build`
            2. Run the focused suite: `swift test --filter CacheTests\(n)`
            3. Open the sample project and scroll the list quickly
            4. Confirm the frame time stays under 8 ms

            > The slowest path was never the one we profiled first. Measure, then change one thing at a time. (note \(n))

            The remaining risk is the `retry` path: it still takes a lock on the main actor, which is fine for now but worth a follow-up. Details are in [issue #\(100 + n)](https://example.com/issues/\(100 + n)).


            """
        }.joined()
    }

    @Test func aReplyOfTextBlocksCostsWhatTheCalibrationMeasured() {
        // Four replies of 10 KB of text blocks held 97 MiB, 4.7 of it rows.
        let reply = NativeProse(nativeMarkdownParse(Self.textReply(cycles: 9)))
        #expect(!reply.isGiant && reply.eagerCost == reply.cost)
        let measured = (97 * Self.mib - 47 * Self.mib / 10) / 4
        #expect(abs(reply.cost - measured) <= measured * 20 / 100)
    }

    @Test func aGiantReplyCostsItsEagerTailWhateverItsLength() {
        let small = Self.prose(cycles: 140)
        let large = Self.prose(cycles: 280)
        #expect(small.isGiant && large.isGiant)
        #expect(small.eagerTail == large.eagerTail && small.eagerTail < small.chunks.count)
        let eager = small.chunks.suffix(small.eagerTail).reduce(0) { $0 + $1.cost }
        #expect(small.eagerCost == eager)
        #expect(small.eagerCost < small.cost / 10)
        let chunk = small.chunks.dropLast().map(\.cost).max() ?? 0
        #expect(abs(large.eagerCost - small.eagerCost) <= chunk, "the tail costs the same however long the reply grows, to a chunk (the last is part full)")
        // At the gate a reply stops costing all of its chunks and costs its tail.
        let below = Self.prose(cycles: 82)
        #expect(!below.isGiant && below.eagerCost == below.cost)
        #expect(small.eagerCost < small.cost / 3)
    }

    /// Fences that grow with each one (1,088 bytes, then 64 more), so that chunks of them cost different amounts.
    static func gradedReply(fences: Int) -> String {
        (1...fences).map { "```swift\n\(String(repeating: "x", count: 1024 + 64 * $0))\n```\n\n" }.joined()
    }

    @Test func aGiantRepliesLazyEdgeIsTheChunkBeforeItsEagerTail() {
        let reply = NativeProse(nativeMarkdownParse(Self.gradedReply(fences: 60)))
        #expect(reply.isGiant && reply.eagerTail > 1)
        let costs = reply.chunks.map(\.cost)
        #expect(Set(costs).count == costs.count, "no two chunks cost the same, or the index would not show")
        let edge = reply.chunks.count - reply.eagerTail - 1
        #expect(edge >= 1 && edge + 1 < costs.count)
        #expect(reply.lazyEdgeCost == costs[edge])
        #expect(reply.lazyEdgeCost != costs[edge - 1] && reply.lazyEdgeCost != costs[edge + 1], "not the chunk on either side of it")
        #expect(NativeProse.empty.lazyEdgeCost == 0 && NativeProse.empty.cost == 0 && NativeProse.empty.eagerCost == 0)
    }

    @Test func tenSmallRepliesCostAboutAsMuchAsOneOf100KB() {
        let small = Self.prose(cycles: 8)
        #expect(!small.isGiant && small.eagerCost == small.cost)
        let hundred = Self.prose(cycles: 82)
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
        #expect(Cost.item(.steer(id: "u", text: "use tables", sentAt: nil, images: 0)) == line + 10 * Cost.textByte, "a steer's words cost what a user row's do")
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
        let presentation = NativeTurnPresentation(items: items, changes: nil, toolCalls: 0, endedAt: nil)
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
