import Testing
@testable import ShepherdRemote

@Suite("Markdown blocks")
struct MarkdownBlockTests {
    typealias Item = NativeMarkdownListItem
    typealias Table = NativeMarkdownTable

    /// The reply that showed its table as raw pipes (a user's report), verbatim.
    static let toolsReply = """
    ## What Shepherd exposes

    The normal root-agent surface contains **31 model-callable tools**, depending on enabled settings.

    | Area | Tools |
    |---|---|
    | Terminal panes | `pane_list`, `pane_open`, `pane_run`, `pane_read`, `pane_focus`, `pane_close` |
    | Peer agents | `agent_list`, `agent_send`, `agent_read`, `agent_steer`, `agent_interrupt`, `agent_wait`, `agent_delete`, `agent_spawn` |
    | Automations | `automation_create`, `automation_list`, `automation_update`, `automation_delete`, `automation_start`, `automation_stop` |
    | Notifications and review | `notify`, `review_diff` |
    | Native children | `shepherd_child_agents`, `shepherd_child_start`, `shepherd_child_message`, `shepherd_child_result`, `shepherd_child_wait`, `shepherd_child_cancel`, `shepherd_child_resume` |
    | Orchestration and records | `shepherd_workflow`, `shepherd_mission` |

    Additional extension behavior includes:

    - Child-only `shepherd_parent_message` and an overridden child `bash` implementation.
    """

    @Test func theReportedReplyDrawsItsTableAsATable() throws {
        let blocks = nativeMarkdownBlocks(Self.toolsReply)
        #expect(blocks.count == 5)
        #expect(blocks[0] == .heading(level: 2, text: "What Shepherd exposes"))
        #expect(blocks[3] == .paragraph("Additional extension behavior includes:"))
        #expect(blocks[4] == .list(ordered: false, start: 1, items: [
            Item(text: "Child-only `shepherd_parent_message` and an overridden child `bash` implementation."),
        ]))
        guard case .table(let table) = blocks[2] else { Issue.record("not a table: \(blocks[2])"); return }
        #expect(table.header == ["Area", "Tools"])
        #expect(table.alignments == [.none, .none])
        #expect(table.rows.count == 6)
        #expect(table.rows.allSatisfy { $0.count == 2 })
        #expect(table.rows[3] == ["Notifications and review", "`notify`, `review_diff`"])
        #expect(table.rows[5] == ["Orchestration and records", "`shepherd_workflow`, `shepherd_mission`"])
        #expect(table.source.hasPrefix("| Area | Tools |\n|---|---|\n| Terminal panes |"))
        #expect(table.source.hasSuffix("| Orchestration and records | `shepherd_workflow`, `shepherd_mission` |"))
    }

    @Test func aDocumentSplitsIntoItsBlocks() {
        let text = """
        # Plan
        Intro line
        continues here.

        - first **bold**
        - second
          - nested `code`
          - nested two
        - third

        1. one
        2. two
           ```swift
           let x = "```"
           - not a list
           ```

        > quoted
        > more

        ---

        ## Sub
        tail
        """
        #expect(nativeMarkdownBlocks(text) == [
            .heading(level: 1, text: "Plan"),
            .paragraph("Intro line\ncontinues here."),
            .list(ordered: false, start: 1, items: [
                Item(text: "first **bold**"),
                Item(text: "second", children: [.list(ordered: false, start: 1, items: [Item(text: "nested `code`"), Item(text: "nested two")])]),
                Item(text: "third"),
            ]),
            .list(ordered: true, start: 1, items: [
                Item(text: "one"),
                Item(text: "two", children: [.code("let x = \"```\"\n- not a list", language: "swift")]),
            ]),
            .quote([.paragraph("quoted\nmore")]),
            .rule,
            .heading(level: 2, text: "Sub"),
            .paragraph("tail"),
        ])
    }

    /// Whether the text ends inside a fence still open: the block a streaming reply is writing.
    @Test(arguments: [
        ("```swift\nlet a = 1", true),
        ("Here:\n\n```swift\nlet a = 1\n", true),
        ("- item\n  ```sh\n  ls", true),
        ("```swift\nlet a = 1\n```", false),
        ("```\nx\n```\n\nafter", false),
        ("```\nx\n```\n```\ny", true),
        ("~~~\nx", true),
        ("no code at all", false),
        ("- item\n  ```sh\n  ls\n\nafter", false),
    ])
    func aTextEndsInAnOpenFenceOnlyWhileTheFenceRunsToTheEnd(text: String, open: Bool) {
        #expect(nativeMarkdownParse(text).endsInOpenFence == open)
        #expect(nativeMarkdownParse(text).blocks == nativeMarkdownBlocks(text))
    }

    @Test(arguments: [
        ("", [NativeMarkdownBlock]()),
        ("3) c\n4) d", [.list(ordered: true, start: 3, items: [Item(text: "c"), Item(text: "d")])]),
        ("```\npartial", [.code("partial", language: nil)]),
        ("```sh extra\nls\n```", [.code("ls", language: "sh")]),
        ("~~~python\nprint(1)\n~~~", [.code("print(1)", language: "python")]),
        ("#hashtag and -dash", [.paragraph("#hashtag and -dash")]),
        ("####### seven", [.paragraph("####### seven")]),
        ("###### six", [.heading(level: 6, text: "six")]),
        ("## Closed ##", [.heading(level: 2, text: "Closed")]),
        ("* * *", [.rule]),
        ("__", [.paragraph("__")]),
        (">bare quote", [.quote([.paragraph("bare quote")])]),
        ("+ plus", [.list(ordered: false, start: 1, items: [Item(text: "plus")])]),
        ("1234567890. too long", [.paragraph("1234567890. too long")]),
        ("~~struck~~ and ~kept~", [.paragraph("~~struck~~ and ~kept~")]),
        ("see https://example.com and <https://a.b>", [.paragraph("see https://example.com and <https://a.b>")]),
        ("Line one\r\nLine two", [.paragraph("Line one\nLine two")]),
    ])
    func singleConstructs(text: String, expected: [NativeMarkdownBlock]) {
        #expect(nativeMarkdownBlocks(text) == expected)
    }

    @Test func aBlankLineEndsAListUnlessTheNextLineIsIndented() {
        #expect(nativeMarkdownBlocks("- a\n\nafter") == [.list(ordered: false, start: 1, items: [Item(text: "a")]), .paragraph("after")])
        #expect(nativeMarkdownBlocks("- a\n\n  still a") == [
            .list(ordered: false, start: 1, items: [Item(text: "a", children: [.paragraph("still a")])]),
        ])
    }

    @Test func aLazyContinuationLineJoinsTheItem() {
        #expect(nativeMarkdownBlocks("- a\nmore") == [.list(ordered: false, start: 1, items: [Item(text: "a\nmore")])])
    }

    @Test func switchingMarkerKindStartsANewList() {
        #expect(nativeMarkdownBlocks("- a\n1. b") == [
            .list(ordered: false, start: 1, items: [Item(text: "a")]),
            .list(ordered: true, start: 1, items: [Item(text: "b")]),
        ])
    }

    @Test func fencesKeepTheirContentsLiteral() {
        #expect(nativeMarkdownBlocks("```\n# not a heading\n- not a list\n| a | b |\n|---|---|\n```\nafter") == [
            .code("# not a heading\n- not a list\n| a | b |\n|---|---|", language: nil), .paragraph("after"),
        ])
    }

    // MARK: Lists

    @Test func listsNestToAnyDepthWithMixedKindsAndBlocksInside() {
        let text = """
        1. Plan
           - Parse
             1. Tables
                - Alignment
             2. Lists

             A paragraph under Tables' list.
           - Render
             ```swift
             let x = 1
             ```
        2. Ship
        """
        #expect(nativeMarkdownBlocks(text) == [
            .list(ordered: true, start: 1, items: [
                Item(text: "Plan", children: [.list(ordered: false, start: 1, items: [
                    Item(text: "Parse", children: [
                        .list(ordered: true, start: 1, items: [
                            Item(text: "Tables", children: [.list(ordered: false, start: 1, items: [Item(text: "Alignment")])]),
                            Item(text: "Lists"),
                        ]),
                        .paragraph("A paragraph under Tables' list."),
                    ]),
                    Item(text: "Render", children: [.code("let x = 1", language: "swift")]),
                ])]),
                Item(text: "Ship"),
            ]),
        ])
    }

    @Test func twoSpacesNestUnderAnOrderedItemAsAgentsWriteIt() {
        #expect(nativeMarkdownBlocks("1. one\n  - sub\n2. two") == [
            .list(ordered: true, start: 1, items: [
                Item(text: "one", children: [.list(ordered: false, start: 1, items: [Item(text: "sub")])]),
                Item(text: "two"),
            ]),
        ])
    }

    @Test(arguments: [
        ("- [ ] open", Item(text: "open", task: .open)),
        ("- [x] done", Item(text: "done", task: .done)),
        ("- [X] Done", Item(text: "Done", task: .done)),
        ("* [ ]", Item(text: "", task: .open)),
        ("- [link](x) is not a task", Item(text: "[link](x) is not a task")),
        ("- [ ]not a box", Item(text: "[ ]not a box")),
    ])
    func taskItemsCarryTheirBox(text: String, item: Item) {
        #expect(nativeMarkdownBlocks(text) == [.list(ordered: false, start: 1, items: [item])])
    }

    @Test func aTaskListNestsAndKeepsItsOrder() {
        #expect(nativeMarkdownBlocks("- [x] Parse\n  - [ ] Nested\n- [ ] Render") == [
            .list(ordered: false, start: 1, items: [
                Item(text: "Parse", task: .done, children: [.list(ordered: false, start: 1, items: [Item(text: "Nested", task: .open)])]),
                Item(text: "Render", task: .open),
            ]),
        ])
    }

    @Test func aBlankLineBetweenItemsKeepsOneList() {
        #expect(nativeMarkdownBlocks("- a\n\n- b") == [.list(ordered: false, start: 1, items: [Item(text: "a"), Item(text: "b")])])
    }

    @Test func aRuleAfterAListIsARuleNotAnItem() {
        #expect(nativeMarkdownBlocks("- a\n* * *\n- b") == [
            .list(ordered: false, start: 1, items: [Item(text: "a")]), .rule, .list(ordered: false, start: 1, items: [Item(text: "b")]),
        ])
    }

    @Test func quotesHoldBlocks() {
        #expect(nativeMarkdownBlocks("> **Note**\n> - one\n> - two\nlazy") == [
            .quote([.paragraph("**Note**"), .list(ordered: false, start: 1, items: [Item(text: "one"), Item(text: "two\nlazy")])]),
        ])
    }

    // MARK: Tables

    @Test(arguments: [
        ("|:--|:-:|--:|---|", [Table.Alignment.leading, .center, .trailing, .none]),
        ("| :--- | :---: | ---: | --- |", [.leading, .center, .trailing, .none]),
        (":--|--:", [.leading, .trailing]),
    ])
    func delimiterRowsSetColumnAlignment(delimiter: String, alignments: [Table.Alignment]) throws {
        let header = alignments.indices.map { "h\($0)" }.joined(separator: " | ")
        let blocks = nativeMarkdownBlocks("| \(header) |\n\(delimiter)\n| a |")
        guard case .table(let table)? = blocks.first else { Issue.record("\(blocks)"); return }
        #expect(table.alignments == alignments)
    }

    @Test(arguments: [
        // Escaped pipes stay inside their cell (the renderer's Markdown reads `\|` as a pipe).
        ("| a \\| b | c |", ["a \\| b", "c"]),
        // A pipe inside a code span never splits, and an escaped one there reads as a pipe.
        ("| `x || y` | `a \\| b` |", ["`x || y`", "`a | b`"]),
        // Inline Markdown stays for the renderer.
        ("| **bold** | *it* | [link](https://x.y) | ~~no~~ |", ["**bold**", "*it*", "[link](https://x.y)", "~~no~~"]),
        // Without outer pipes.
        ("a | b", ["a", "b"]),
        // An empty cell.
        ("| a || c |", ["a", "", "c"]),
    ])
    func rowsSplitIntoCells(row: String, cells: [String]) throws {
        let columns = cells.count
        let header = (0..<columns).map { "h\($0)" }.joined(separator: " | ")
        let delimiter = Array(repeating: "---", count: columns).joined(separator: " | ")
        let blocks = nativeMarkdownBlocks("| \(header) |\n| \(delimiter) |\n\(row)")
        guard case .table(let table)? = blocks.first else { Issue.record("\(blocks)"); return }
        #expect(table.rows == [cells])
    }

    @Test func unevenRowsArePaddedAndNoCellIsDropped() throws {
        let blocks = nativeMarkdownBlocks("| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |")
        guard case .table(let table)? = blocks.first else { Issue.record("\(blocks)"); return }
        #expect(table.header == ["a", "b", "c", ""])
        #expect(table.alignments.count == 4)
        #expect(table.rows == [["1", "", "", ""], ["1", "2", "3", "4"]])
    }

    @Test(arguments: [
        // A table interrupts the paragraph before it, and ends at a blank line.
        ("Intro\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter", 3),
        // It ends at a line without a pipe, or a block.
        ("| a | b |\n|---|---|\n| 1 | 2 |\n- item", 2),
    ])
    func aTableSitsBetweenItsNeighbours(text: String, count: Int) {
        let blocks = nativeMarkdownBlocks(text)
        #expect(blocks.count == count)
        #expect(blocks.contains { if case .table = $0 { true } else { false } })
    }

    @Test(arguments: [
        // A single-column delimiter under a two-cell line is a rule, as in CommonMark.
        "Some text with a | pipe\n---",
        // A header without a delimiter row is prose.
        "| not | a table |\nstill prose",
        // A delimiter row with other characters is not one.
        "| a | b |\n|--x|---|",
    ])
    func linesThatOnlyLookLikeATableStayProse(text: String) {
        #expect(!nativeMarkdownBlocks(text).contains { if case .table = $0 { true } else { false } })
    }

    @Test func aTableInsideAListItemIsTheItems() {
        let blocks = nativeMarkdownBlocks("- Results:\n  | a | b |\n  |---|---|\n  | 1 | 2 |")
        guard case .list(_, _, let items)? = blocks.first, case .table(let table)? = items.first?.children.first else {
            Issue.record("\(blocks)")
            return
        }
        #expect(items.first?.text == "Results:")
        #expect(table.rows == [["1", "2"]])
    }

    // MARK: Streaming

    /// A reply streaming the reported table, cut at every character: from the moment its
    /// delimiter row lands it is a table, it only ever gains whole rows, and it never shows
    /// its pipes as a paragraph on the way.
    @Test func aStreamingTableNeverFlickersThroughProse() {
        let text = Self.toolsReply
        var sawTable = false
        var rows = 0
        // Every cut that matters (each pipe, backtick, and line end) and a spread of others.
        let cuts = text.indices.enumerated().filter { offset, index in "|`\n".contains(text[index]) || offset % 7 == 0 }.map(\.1)
        for end in cuts {
            let prefix = String(text[..<end])
            let blocks = nativeMarkdownParse(prefix, streaming: true).blocks
            let paragraphs = blocks.compactMap { if case .paragraph(let p) = $0 { p } else { nil } }
            #expect(!paragraphs.contains { $0.contains("|") }, "pipes as prose at \(prefix.count): \(paragraphs)")
            let table = blocks.lazy.compactMap { if case .table(let t) = $0 { t } else { nil } }.first
            if sawTable, !prefix.hasSuffix("\n\n") || table != nil {
                #expect(table != nil || !prefix.contains("|---|---|\n"), "the table vanished at \(prefix.count)")
            }
            if let table {
                sawTable = true
                #expect(table.rows.count >= rows, "rows went backwards at \(prefix.count)")
                #expect(table.rows.allSatisfy { $0.count == 2 }, "a partial row at \(prefix.count): \(table.rows)")
                rows = table.rows.count
            }
        }
        #expect(sawTable && rows == 6)
    }

    @Test(arguments: [
        // A header line still arriving, and one waiting for its delimiter row, draw nothing yet.
        ("Intro\n\n| Area | To", [NativeMarkdownBlock.paragraph("Intro")]),
        ("Intro\n\n| Area | Tools |\n", [.paragraph("Intro")]),
        ("Intro\n\n| Area | Tools |\n|--", [.paragraph("Intro")]),
        // The delimiter row makes it a table at once; a row still arriving waits.
        ("| Area | Tools |\n|---|---|\n", [.table(Table(alignments: [.none, .none], header: ["Area", "Tools"], rows: [],
                                                      source: "| Area | Tools |\n|---|---|"))]),
        ("| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | `fo", [.table(Table(alignments: [.none, .none], header: ["A", "B"], rows: [["1", "2"]],
                                                             source: "| A | B |\n|---|---|\n| 1 | 2 |"))]),
        // Bare markers wait for the text that says what they are.
        ("Intro\n-", [.paragraph("Intro")]),
        ("Intro\n12.", [.paragraph("Intro")]),
        ("Intro\n##", [.paragraph("Intro")]),
        ("Intro\n``", [.paragraph("Intro")]),
        ("Intro\n```swi", [.paragraph("Intro")]),
        ("Intro\n<deta", [.paragraph("Intro")]),
        ("Intro\n![scre", [.paragraph("Intro")]),
        // Anything else streams as it arrives.
        ("Intro\n- ite", [.paragraph("Intro"), .list(ordered: false, start: 1, items: [Item(text: "ite")])]),
        ("Intro\n12 files", [.paragraph("Intro\n12 files")]),
        ("```swift\nlet a", [.code("let a", language: "swift")]),
    ])
    func aStreamingReplyHoldsBackOnlyWhatWouldDrawAsSomethingElse(text: String, blocks: [NativeMarkdownBlock]) {
        #expect(nativeMarkdownParse(text, streaming: true).blocks == blocks)
    }

    @Test func aFinishedReplyDrawsEveryLine() {
        #expect(nativeMarkdownBlocks("| not | a table |") == [.paragraph("| not | a table |")])
        #expect(nativeMarkdownBlocks("| A | B |\n|---|---|\n| 1 | 2 |").first.map {
            if case .table(let t) = $0 { t.rows.count } else { 0 }
        } == 1)
    }

    // MARK: Images, HTML, footnotes, math

    @Test(arguments: [
        ("![Shot](docs/shot.png)", [NativeMarkdownBlock.image(alt: "Shot", source: "docs/shot.png")]),
        ("![A](/tmp/a.png) ![B](https://x.y/b.png \"title\")", [.image(alt: "A", source: "/tmp/a.png"), .image(alt: "B", source: "https://x.y/b.png")]),
        ("![Spaced](<my shot.png>)", [.image(alt: "Spaced", source: "my shot.png")]),
        ("See ![inline](a.png) here", [.paragraph("See ![inline](a.png) here")]),
        ("<img src=\"logo.png\" alt=\"Logo\" width=\"80\">", [.image(alt: "Logo", source: "logo.png")]),
        ("<p align=\"center\"><img data-src=\"no\" src='a.png'></p>", [.image(alt: "", source: "a.png")]),
    ])
    func imagesOnTheirOwnLineAreImageBlocks(text: String, blocks: [NativeMarkdownBlock]) {
        #expect(nativeMarkdownBlocks(text) == blocks)
    }

    @Test(arguments: [
        ("<details><summary>Full log</summary>\n\n- one\n- two\n\n</details>",
         [NativeMarkdownBlock.details(summary: "Full log", blocks: [.list(ordered: false, start: 1, items: [Item(text: "one"), Item(text: "two")])])]),
        ("<details>\n<summary>\nWhy <b>this</b>\n</summary>\n\nBecause.\n</details>\nAfter",
         [.details(summary: "Why <b>this</b>", blocks: [.paragraph("Because.")]), .paragraph("After")]),
        ("<details>\nNo summary\n</details>", [.details(summary: "Details", blocks: [.paragraph("No summary")])]),
        ("<details><summary>Outer</summary>\n<details><summary>Inner</summary>\nx\n</details>\n</details>",
         [.details(summary: "Outer", blocks: [.details(summary: "Inner", blocks: [.paragraph("x")])])]),
    ])
    func detailsBecomeADisclosure(text: String, blocks: [NativeMarkdownBlock]) {
        #expect(nativeMarkdownBlocks(text) == blocks)
    }

    @Test(arguments: [
        // Block tags are dropped and their text kept; inline tags stay for the renderer.
        ("<div align=\"center\">Centered <b>text</b></div>", [NativeMarkdownBlock.paragraph("Centered <b>text</b>")]),
        ("<h2>Title</h2>", [.heading(level: 2, text: "Title")]),
        ("<hr>", [.rule]),
        ("one\n<br>\ntwo", [.paragraph("one"), .paragraph("two")]),
        ("<!-- a comment -->\nshown", [.paragraph("shown")]),
        ("<ul>\n<li>one</li>\n</ul>", [.paragraph("• one")]),
        // Something that only looks like a tag is text.
        ("<Int> is the parameter", [.paragraph("<Int> is the parameter")]),
        ("Press <kbd>⌘</kbd><kbd>K</kbd>", [.paragraph("Press <kbd>⌘</kbd><kbd>K</kbd>")]),
    ])
    func htmlIsNeverRenderedRaw(text: String, blocks: [NativeMarkdownBlock]) {
        #expect(nativeMarkdownBlocks(text) == blocks)
    }

    @Test func footnotesAreNumberedByFirstReferenceAndGatheredAtTheEnd() {
        let text = """
        Tables render natively[^tables] and so do lists[^1].

        - A list cites[^tables] again.

        [^1]: Nested to any depth.
        [^tables]: GitHub-flavoured,
          with alignment.
        [^unused]: Never cited.

        `[^1]` in code stays, and [^missing] reads as written.
        """
        #expect(nativeMarkdownBlocks(text) == [
            .paragraph("Tables render natively[^1] and so do lists[^2]."),
            .list(ordered: false, start: 1, items: [Item(text: "A list cites[^1] again.")]),
            .paragraph("`[^1]` in code stays, and \\[^missing] reads as written."),
            .footnotes([
                NativeMarkdownFootnote(number: 1, text: "GitHub-flavoured,\nwith alignment."),
                NativeMarkdownFootnote(number: 2, text: "Nested to any depth."),
                NativeMarkdownFootnote(number: 3, text: "Never cited."),
            ]),
        ])
    }

    @Test(arguments: [
        ("```mermaid\ngraph TD\n  A-->B\n```", [NativeMarkdownBlock.code("graph TD\n  A-->B", language: "mermaid")]),
        ("$$\nE = mc^2\n$$", [.code("E = mc^2", language: "math")]),
        ("$$ a^2 + b^2 $$", [.code("a^2 + b^2", language: "math")]),
        ("```latex\n\\frac{a}{b}\n```", [.code("\\frac{a}{b}", language: "latex")]),
    ])
    func diagramsAndMathStayFencedCode(text: String, blocks: [NativeMarkdownBlock]) {
        #expect(nativeMarkdownBlocks(text) == blocks)
    }

    /// Malformed Markdown degrades to readable text: nothing is lost or garbled.
    @Test(arguments: [
        "| lonely pipe",
        "<details>",
        "[^",
        "![broken](",
        "```",
        "- \n-",
        "> ",
        "<div",
        "**unclosed bold",
    ])
    func malformedMarkdownKeepsItsText(text: String) {
        let blocks = nativeMarkdownBlocks(text)
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let drawn = "\(blocks)"
        for word in words { #expect(drawn.contains(word), "\(word) lost from \(blocks)") }
    }
}

@Suite("Scroll follower")
struct ScrollFollowerTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var start: NativeScrollFollower
        var distance: Double
        var intent = false
        var gesture = false
        var sticky: Bool
        var unseen: Bool
    }

    static let cases: [Case] = [
        Case(testDescription: "programmatic growth keeps a sticky view sticky", start: .init(), distance: 300, sticky: true, unseen: false),
        Case(testDescription: "user intent away from the bottom detaches", start: .init(), distance: 300, intent: true, sticky: false, unseen: false),
        Case(testDescription: "a gesture without an upward move stays stuck", start: .init(), distance: 40, gesture: true, sticky: true, unseen: false),
        Case(testDescription: "layout jitter without intent never detaches", start: .init(), distance: 500, sticky: true, unseen: false),
        Case(testDescription: "a detached view moving is not output arriving", start: .init(sticky: false), distance: 300, sticky: false, unseen: false),
        Case(testDescription: "returning near the bottom re-sticks and clears unseen", start: .init(sticky: false, unseen: true), distance: 3, sticky: true, unseen: false),
        Case(testDescription: "exactly the threshold counts as the bottom", start: .init(sticky: false, unseen: true), distance: NativeScrollFollower.threshold, sticky: true, unseen: false),
        Case(testDescription: "intent inside the threshold does not detach", start: .init(), distance: 10, intent: true, sticky: true, unseen: false),
    ]

    @Test(arguments: cases)
    func observation(_ c: Case) {
        var follower = c.start
        follower.userScrolling = c.gesture
        follower.observe(distanceFromBottom: c.distance, userIntent: c.intent)
        #expect(follower.sticky == c.sticky)
        #expect(follower.unseen == c.unseen)
    }

    @Test func theJumpPillShowsWhileDetachedAndSomethingIsHappeningBelow() {
        var detached = NativeScrollFollower(sticky: false, unseen: true)
        #expect(detached.showsJump(running: false) && detached.showsJump(running: true))
        detached.unseen = false
        #expect(!detached.showsJump(running: false) && detached.showsJump(running: true))
        #expect(!NativeScrollFollower().showsJump(running: true))
    }

    @Test func jumpingToLatestSticksAndForgetsWhatWasMissed() {
        var follower = NativeScrollFollower(sticky: false, unseen: true)
        follower.jumpToLatest()
        #expect(follower.sticky && !follower.unseen && !follower.showsJump(running: true))
    }

    @Test func theThresholdIsEightyPoints() {
        #expect(NativeScrollFollower.threshold == 80)
    }
}
