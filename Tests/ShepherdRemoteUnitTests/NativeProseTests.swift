import Testing
@testable import ShepherdRemote

@Suite("Prose chunks")
struct NativeProseTests {
    typealias Item = NativeMarkdownListItem
    typealias ID = NativeProsePart.ID

    static func paragraphs(_ count: Int, from first: Int = 0) -> [NativeMarkdownBlock] {
        (first..<first + count).map { .paragraph("Paragraph \($0).") }
    }

    static func list(_ count: Int, start: Int = 1, ordered: Bool = true, bytes: Int = 8) -> NativeMarkdownBlock {
        .list(ordered: ordered, start: start, items: (0..<count).map { Item(text: String(repeating: "x", count: bytes) + "\($0)") })
    }

    static func starts(_ chunk: NativeProseChunk) -> [Int] {
        chunk.parts.compactMap { if case .list(_, let start, _) = $0.block { start } else { nil } }
    }

    @Test func tenBlocksMakeOneChunk() {
        let blocks = Self.paragraphs(10)
        let prose = NativeProse(blocks, endsInOpenFence: true)
        #expect(prose.chunks.count == 1)
        #expect(prose.chunks[0].id == ID(block: 0, stretch: 0))
        #expect(prose.chunks[0].parts.count == 10)
        #expect(prose.blockCount == 10 && !prose.isEmpty && prose.endsInOpenFence)
        #expect(prose.blocks == blocks)
    }

    @Test func noBlocksMakeNoChunks() {
        #expect(NativeProse.empty.isEmpty && NativeProse.empty.chunks.isEmpty && NativeProse.empty.blockCount == 0)
        #expect(NativeProse([]).blocks.isEmpty)
    }

    @Test func aHundredSmallParagraphsCloseAChunkAtThirtyTwoParts() {
        let prose = NativeProse(Self.paragraphs(100))
        #expect(prose.chunks.map(\.id) == [ID(block: 0, stretch: 0), ID(block: 32, stretch: 0), ID(block: 64, stretch: 0), ID(block: 96, stretch: 0)])
        #expect(prose.chunks.map(\.parts.count) == [32, 32, 32, 4])
        #expect(prose.chunks.allSatisfy { !$0.continuesList })
    }

    @Test func threeKilobyteFencesCloseChunksByWeight() {
        let fence = NativeMarkdownBlock.code(String(repeating: "x", count: 3 * 1024), language: "swift")
        let prose = NativeProse(Array(repeating: fence, count: 20))
        // Six fences weigh 18 KB: the chunk closes before the seventh joins.
        #expect(prose.chunks.map(\.id.block) == [0, 6, 12, 18])
        #expect(prose.chunks.map(\.parts.count) == [6, 6, 6, 2])
        #expect(prose.chunks.dropLast().allSatisfy { $0.weight >= NativeProse.Limits.weight })
        #expect(prose.chunks.dropLast().allSatisfy { $0.weight - ($0.parts.last?.weight ?? 0) < NativeProse.Limits.weight })
    }

    @Test func anOrderedListKeepsItsNumberingAcrossStretchesThatStartTheirOwnChunks() {
        let blocks: [NativeMarkdownBlock] = [.paragraph("Steps:"), Self.list(70, start: 3), .paragraph("Done.")]
        let prose = NativeProse(blocks)
        #expect(prose.chunks.map(\.id) == [ID(block: 0, stretch: 0), ID(block: 1, stretch: 1), ID(block: 1, stretch: 2)])
        #expect(prose.chunks.map(\.continuesList) == [false, true, true])
        #expect(prose.chunks.flatMap(Self.starts) == [3, 35, 67])
        #expect(prose.chunks.flatMap(\.parts).filter { $0.id.block == 1 }.map(\.continuation) == [false, true, true])
        // The paragraph after the list joins the last stretch's chunk.
        #expect(prose.chunks[2].parts.map(\.id) == [ID(block: 1, stretch: 2), ID(block: 2, stretch: 0)])
        #expect(prose.blockCount == 3)
        #expect(prose.blocks == blocks)
    }

    @Test func aListOfHeavyItemsSplitsByWeight() {
        let list = Self.list(10, bytes: 4 * 1024 - 1)
        let prose = NativeProse([list])
        // Four items of 4 KB reach the limit.
        #expect(prose.chunks.flatMap(Self.starts) == [1, 5, 9])
        #expect(prose.chunks.map(\.continuesList) == [false, true, true])
        #expect(prose.blocks == [list])
    }

    @Test func aStretchHoldsAtLeastOneItemWhateverItWeighs() {
        let heavy = NativeMarkdownBlock.list(ordered: false, start: 1, items: [
            Item(text: String(repeating: "x", count: 40 * 1024)), Item(text: "short"), Item(text: String(repeating: "y", count: 40 * 1024)),
        ])
        let prose = NativeProse([heavy])
        let counts = prose.chunks.flatMap(\.parts).map { part -> Int in
            if case .list(_, _, let items) = part.block { items.count } else { 0 }
        }
        // The first item fills a stretch alone; the short one rides with the next heavy one.
        #expect(counts == [1, 2])
        #expect(prose.blocks == [heavy])
    }

    @Test func aTrulyShortListIsOnePartAndAThirtyTwoItemListToo() {
        let one = NativeProse([Self.list(32)])
        #expect(one.chunks.count == 1 && one.chunks[0].parts.count == 1 && !one.chunks[0].parts[0].continuation)
        let two = NativeProse([Self.list(33)])
        #expect(two.chunks.map(\.continuesList) == [false, true])
        #expect(two.chunks.flatMap(Self.starts) == [1, 33])
    }

    @Test func nestedListsCountTheirChildrenInTheWeight() {
        let item = Item(text: "parent", children: [.code(String(repeating: "x", count: 5 * 1024), language: nil)])
        #expect(NativeMarkdownBlock.list(ordered: false, start: 1, items: [item]).proseWeight == "parent".utf8.count + 5 * 1024)
        #expect(NativeMarkdownBlock.quote([.paragraph("abc"), .paragraph("de")]).proseWeight == 5)
    }

    /// Texts the parser's own tests use, and the shapes agents write: every block comes back as parsed.
    static let fixtures: [String] = [
        MarkdownBlockTests.toolsReply,
        "# Plan\nIntro line\ncontinues here.\n\n- first **bold**\n- second\n  - nested `code`\n  - nested two\n- third\n\n1. one\n2. two\n\n> quoted\n> more\n\n---\n\n```swift\nlet a = 1\n```",
        "- [x] Parse tables\n- [ ] Render diagrams\n  - nested under it\n    - and deeper",
        "3) c\n4) d\n\nafter",
        "```\npartial",
        "", "* * *", ">bare quote", "+ plus", "#hashtag and -dash", "###### six\n\n## Closed ##",
        "~~~python\nprint(1)\n~~~\n\ntext",
        "1. Parser\n   - Blocks\n     - Tables\n   - Inline runs\n2. Renderers",
        "| a | b |\n|---|--:|\n| 1 | 2 |\n| 3 | 4 |\n\nAfter the table.",
        "- Tools:\n  | Area | Count |\n  |---|--:|\n  | Panes | 6 |\n  | Agents | 8 |\n",
        "<details><summary>Log</summary>\n\n- 41 passed\n\n</details>\n\n![Alt](shot.png)\n\nA note.[^1]\n\n[^1]: The footnote.",
        "Line one\r\nLine two\r\n\r\n- a\r\n- b\r\n",
        "> - quoted list\n> - two\n>\n> ```sh\n> ls\n> ```",
        (0..<70).map { "\($0 + 3). item \($0)" }.joined(separator: "\n"),
        (0..<100).map { "Paragraph \($0)." }.joined(separator: "\n\n"),
        (0..<40).map { "- item \($0)\n  - child \($0)\n    ```\n    code \($0)\n    ```" }.joined(separator: "\n"),
        (0..<12).map { "## Section \($0)\n\n" + (0..<6).map { "- point \($0)" }.joined(separator: "\n") + "\n\n```swift\n" + String(repeating: "let value = 1\n", count: 400) + "```" }
            .joined(separator: "\n\n"),
    ]

    @Test(arguments: fixtures, [false, true])
    func chunkingKeepsEveryBlockAsParsed(text: String, streaming: Bool) {
        let parsed = nativeMarkdownParse(text, streaming: streaming)
        let prose = NativeProse(parsed)
        #expect(prose.blocks == parsed.blocks)
        #expect(prose.endsInOpenFence == parsed.endsInOpenFence)
        #expect(prose.blockCount == parsed.blocks.count)
        #expect(prose.chunks.flatMap(\.parts).map(\.block).count >= parsed.blocks.count)
        #expect(prose.chunks.allSatisfy { !$0.parts.isEmpty && $0.id == $0.parts[0].id })
        #expect(prose.chunks.map(\.id) == prose.chunks.map(\.id).sorted { ($0.block, $0.stretch) < ($1.block, $1.stretch) })
    }

    @Test func appendingBlocksKeepsEveryClosedChunksIdAndParts() {
        var blocks = Self.paragraphs(10)
        blocks += [Self.list(70), .code(String(repeating: "x", count: 3 * 1024), language: nil)]
        var previous = NativeProse(blocks)
        for extra in 0..<120 {
            blocks.append(extra.isMultiple(of: 7) ? .code(String(repeating: "y", count: 2 * 1024), language: "swift") : .paragraph("More \(extra)."))
            let next = NativeProse(blocks)
            for (old, new) in zip(previous.chunks.dropLast(), next.chunks) {
                #expect(old.id == new.id && old.parts == new.parts, "chunk \(old.id) changed when block \(blocks.count) was appended")
            }
            #expect(next.chunks.count >= previous.chunks.count)
            previous = next
        }
        #expect(previous.chunks.count > 5)
    }

    @Test func aGrowingLastBlockChangesOnlyTheLastChunk() {
        var blocks = Self.paragraphs(40)
        let before = NativeProse(blocks)
        blocks[39] = .paragraph("Paragraph 39, grown by a streamed word.")
        let after = NativeProse(blocks)
        #expect(after.chunks.count == before.chunks.count)
        #expect(after.chunks[0] == before.chunks[0])
        #expect(after.chunks[1] != before.chunks[1])
    }

    @Test func reusingKeepsTheStorageOfUnchangedChunksAndReplacesChangedOnes() {
        var blocks = Self.paragraphs(100)
        let first = NativeProse(blocks)
        // Built apart: equal, but not the same storage.
        let apart = NativeProse(blocks)
        #expect(!first.chunks[0].sharesStorage(with: apart.chunks[0]))
        #expect(first == apart)

        blocks[99] = .paragraph("Paragraph 99, grown.")
        let reused = NativeProse(blocks, reusing: first)
        for index in 0..<3 { #expect(reused.chunks[index].sharesStorage(with: first.chunks[index]), "chunk \(index)") }
        #expect(!reused.chunks[3].sharesStorage(with: first.chunks[3]))
        #expect(reused.chunks[3].parts.last?.block == .paragraph("Paragraph 99, grown."))
        #expect(reused.blocks == blocks)

        // An edit in the first chunk replaces it; the chunks after it keep what they were.
        blocks[0] = .paragraph("Edited.")
        let edited = NativeProse(blocks, reusing: reused)
        #expect(!edited.chunks[0].sharesStorage(with: reused.chunks[0]))
        for index in 1..<4 { #expect(edited.chunks[index].sharesStorage(with: reused.chunks[index]), "chunk \(index)") }
    }

    @Test func aChunkEqualsItselfAtOnceAndAnotherByItsParts() {
        let a = NativeProse(Self.paragraphs(40)).chunks[0]
        let b = NativeProse(Self.paragraphs(40)).chunks[0]
        #expect(a == a && a.sharesStorage(with: a))
        #expect(a == b && !a.sharesStorage(with: b))
        #expect(a != NativeProse(Self.paragraphs(40, from: 1)).chunks[0])
    }

    @Test func weightsApplyTheirFloors() {
        #expect(NativeMarkdownBlock.paragraph("abc").proseWeight == 3)
        #expect(NativeMarkdownBlock.paragraph("é").proseWeight == 2, "UTF-8 bytes")
        #expect(NativeMarkdownBlock.heading(level: 2, text: "Title").proseWeight == 5)
        #expect(NativeMarkdownBlock.rule.proseWeight == 0)
        #expect(NativeMarkdownBlock.code("x", language: nil).proseWeight == 1024)
        #expect(NativeMarkdownBlock.code(String(repeating: "x", count: 3000), language: nil).proseWeight == 3000)
        let table = NativeMarkdownTable(alignments: [.none, .none], header: ["a", "b"], rows: [["1", "2"], ["3", "4"]], source: "")
        #expect(NativeMarkdownBlock.table(table).proseWeight == 6 * 256, "six cells, the header included")
        let big = NativeMarkdownTable(alignments: [.none], header: ["h"], rows: [[String(repeating: "x", count: 1000)]], source: "")
        #expect(NativeMarkdownBlock.table(big).proseWeight == 1001)
        #expect(NativeMarkdownBlock.image(alt: "a", source: "b.png").proseWeight == 1024)
        let details = NativeMarkdownBlock.details(summary: "Log", blocks: [.paragraph(String(repeating: "x", count: 10_000))])
        #expect(details.proseWeight == 3 + 256, "collapsed content is not drawn")
        #expect(NativeMarkdownBlock.footnotes([NativeMarkdownFootnote(number: 1, text: "note")]).proseWeight == 4)
    }
    @Test func textBytesCountTheTextAloneWhateverTheFloors() {
        let table = NativeMarkdownTable(alignments: [.none, .none], header: ["a", "b"], rows: [["1", "2"], ["3", "4"]], source: "| a | b |")
        let blocks: [NativeMarkdownBlock] = [
            .paragraph("abc"), .code("xy", language: nil), .table(table), .image(alt: "a", source: "b.png"),
            .details(summary: "Log", blocks: [.paragraph(String(repeating: "x", count: 10_000))]),
            Self.list(2, bytes: 4), .quote([.paragraph("q")]),
        ]
        let prose = NativeProse(blocks)
        #expect(prose.textBytes == 3 + 2 + 6 + 6 + 3 + 2 * 5 + 1)
        #expect(prose.chunks.reduce(0) { $0 + $1.weight } > 3 * 1024, "the weights keep their floors")
        #expect(NativeProse.empty.textBytes == 0)
    }

    /// 40 code fences of 100 bytes make three chunks and weigh 40 KB with their floors, and hold 4 KB of text.
    @Test func aReplyIsGiantByItsTextNotByItsWeight() {
        let fences = NativeProse(Array(repeating: .code(String(repeating: "x", count: 100), language: "swift"), count: 40))
        #expect(fences.chunks.count == 3 && fences.textBytes == 4000)
        #expect(!fences.isGiant && fences.eagerTail == 3, "the floors make chunks, not a reason to estimate any")

        func paragraphs(bytes: Int) -> NativeProse { NativeProse(Array(repeating: .paragraph(String(repeating: "x", count: 1024)), count: bytes / 1024)) }
        let just = paragraphs(bytes: NativeProse.Limits.giantBytes - 1024)
        #expect(!just.isGiant && just.eagerTail == just.chunks.count)
        let giant = paragraphs(bytes: NativeProse.Limits.giantBytes)
        #expect(giant.isGiant && giant.eagerTail < giant.chunks.count)
    }

    @Test func aGiantRepliesTailIsItsLastChunkAndTheClosedChunksBeforeItUntilTheyWeighEnough() {
        // Two 8 KB paragraphs make a chunk (16 KB closes it): 25 of them are 13 chunks.
        let paragraph = NativeMarkdownBlock.paragraph(String(repeating: "x", count: 8 * 1024))
        var blocks = Array(repeating: paragraph, count: 25)
        let long = NativeProse(blocks)
        #expect(long.isGiant && long.chunks.count == 13)
        // The last chunk, then closed ones until they weigh the limit: two of 16 KB.
        #expect(long.eagerTail == 3)

        // The count holds as the last chunk grows and as a new one opens: the chunk that moves into
        // the lazy stack is the one that fell off the end, never one that a growing last chunk takes.
        for _ in 0..<6 {
            blocks.append(paragraph)
            #expect(NativeProse(blocks).eagerTail == 3)
        }

        // Short chunks (wide tables are a few hundred points each) are laid out for the same weight.
        let cell = String(repeating: "c", count: 40)
        let wide = NativeMarkdownTable(alignments: Array(repeating: .none, count: 8), header: Array(repeating: cell, count: 8),
                                       rows: Array(repeating: Array(repeating: cell, count: 8), count: 2), source: "")
        let tables = NativeProse(Array(repeating: .table(wide), count: 400))
        #expect(tables.isGiant && tables.chunks.dropLast().allSatisfy { $0.parts.count == 3 })
        #expect(tables.eagerTail == 3)
    }
}
