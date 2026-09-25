import Testing
@testable import ShepherdRemote

/// Markdown that sits on the edges of the parser's rules: tables written loosely, lists that mix
/// kinds and hold other blocks, Windows line ends, and a reply streamed one character at a time.
@Suite("Markdown edge cases")
struct MarkdownEdgeCaseTests {
    typealias Item = NativeMarkdownListItem
    typealias Table = NativeMarkdownTable

    private static func table(_ blocks: [NativeMarkdownBlock]) -> Table? {
        blocks.lazy.compactMap { if case .table(let t) = $0 { t } else { nil } }.first
    }

    // MARK: Tables

    @Test(arguments: [
        // A code span's pipes, escaped or not, never split its cell.
        ("| `a|b` | `c \\| d` |\n|---|---|\n| `x||y` | z |", ["`a|b`", "`c | d`"], [["`x||y`", "z"]]),
        // No outer pipes on any line.
        ("a | b\n--- | ---\n1 | 2\n3 | 4", ["a", "b"], [["1", "2"], ["3", "4"]]),
        // Outer pipes on some lines only.
        ("| a | b\n---|---:\n1 | 2 |", ["a", "b"], [["1", "2"]]),
        // Wide spacing around the delimiter's cells and alignment colons.
        ("| a | b | c |\n|   :---   |   :---:   |   ---:   |\n| 1 | 2 | 3 |", ["a", "b", "c"], [["1", "2", "3"]]),
        // Cells that are nothing but inline Markdown, and an escaped pipe outside code.
        ("| **k** | v |\n|-|-|\n| [a\\|b](https://x.y) | ~~old~~ |", ["**k**", "v"], [["[a\\|b](https://x.y)", "~~old~~"]]),
        // Non-ASCII text around the pipes.
        ("| Größe | 名前 |\n|---|---|\n| ✓ | 🐑 |", ["Größe", "名前"], [["✓", "🐑"]]),
    ])
    func looselyWrittenTablesStillParse(text: String, header: [String], rows: [[String]]) throws {
        let table = try #require(Self.table(nativeMarkdownBlocks(text)), "no table in \(nativeMarkdownBlocks(text))")
        #expect(table.header == header)
        #expect(table.rows == rows)
        #expect(table.alignments.count == header.count)
    }

    @Test func aDelimiterRowWithSpacesSetsEveryAlignment() throws {
        let text = "| L | C | R | N |\n| :-- | :-: | --: | --- |\n| 1 | 2 | 3 | 4 |"
        let table = try #require(Self.table(nativeMarkdownBlocks(text)))
        #expect(table.alignments == [.leading, .center, .trailing, .none])
    }

    @Test func aTableRightAfterAParagraphEndsIt() {
        let blocks = nativeMarkdownBlocks("Here is the summary:\n| a | b |\n|---|---|\n| 1 | 2 |\nAfter the table.")
        #expect(blocks == [
            .paragraph("Here is the summary:"),
            .table(Table(alignments: [.none, .none], header: ["a", "b"], rows: [["1", "2"]],
                         source: "| a | b |\n|---|---|\n| 1 | 2 |")),
            .paragraph("After the table."),
        ])
    }

    @Test func pipesInProseCodeSpansAreNotATable() {
        #expect(nativeMarkdownBlocks("Run `ls | wc -l` to count.\nThen `a || b`.") == [
            .paragraph("Run `ls | wc -l` to count.\nThen `a || b`."),
        ])
    }

    @Test func aListItemHoldsATableBetweenItsParagraphs() throws {
        let text = """
        1. Tools:
           | Area | Count |
           |:--|--:|
           | Panes | 6 |

           Counted by hand.
        2. Next
        """
        let blocks = nativeMarkdownBlocks(text)
        guard case .list(true, 1, let items)? = blocks.first, items.count == 2 else { Issue.record("\(blocks)"); return }
        #expect(items[0].text == "Tools:")
        #expect(items[0].children == [
            .table(Table(alignments: [.leading, .trailing], header: ["Area", "Count"], rows: [["Panes", "6"]],
                         source: "| Area | Count |\n|:--|--:|\n| Panes | 6 |")),
            .paragraph("Counted by hand."),
        ])
        #expect(items[1] == Item(text: "Next"))
    }

    // MARK: Lists

    @Test func orderedAndUnorderedListsMixAtEveryLevel() {
        let text = """
        - Mac
          1. Parse
             - Tables
               1. Alignment
          2. Render
        - iOS
          * [ ] Shots
        """
        #expect(nativeMarkdownBlocks(text) == [
            .list(ordered: false, start: 1, items: [
                Item(text: "Mac", children: [.list(ordered: true, start: 1, items: [
                    Item(text: "Parse", children: [.list(ordered: false, start: 1, items: [
                        Item(text: "Tables", children: [.list(ordered: true, start: 1, items: [Item(text: "Alignment")])]),
                    ])]),
                    Item(text: "Render"),
                ])]),
                Item(text: "iOS", children: [.list(ordered: false, start: 1, items: [Item(text: "Shots", task: .open)])]),
            ]),
        ])
    }

    @Test func anOrderedListKeepsItsStartAndNestsByFourSpacesToo() {
        #expect(nativeMarkdownBlocks("7. seven\n    - four spaces\n8. eight") == [
            .list(ordered: true, start: 7, items: [
                Item(text: "seven", children: [.list(ordered: false, start: 1, items: [Item(text: "four spaces")])]),
                Item(text: "eight"),
            ]),
        ])
    }

    // MARK: Line ends

    @Test func windowsLineEndsParseAsUnixOnes() {
        let unix = MarkdownBlockTests.toolsReply + "\n\n- [x] done\n  1. nested\n\n```swift\nlet a = 1\n```\n"
        let windows = unix.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(windows.contains("\r\n"))
        #expect(nativeMarkdownBlocks(windows) == nativeMarkdownBlocks(unix))
    }

    // MARK: Streaming

    /// The reported reply streamed one character at a time (and with Windows line ends): no cut
    /// ever shows a table's pipes as prose, a delimiter row as a rule or list, or a table that
    /// loses rows, columns, or itself once it has appeared.
    @Test(arguments: ["\n", "\r\n"])
    func aReplyStreamedCharacterByCharacterNeverDrawsGarbledMarkup(lineEnd: String) {
        let text = MarkdownBlockTests.toolsReply.replacingOccurrences(of: "\n", with: lineEnd)
        var prefix = ""
        var rows = -1
        // By scalar, so a Windows line end is also cut between its "\r" and "\n".
        for scalar in text.unicodeScalars {
            prefix.unicodeScalars.append(scalar)
            let blocks = nativeMarkdownParse(prefix, streaming: true).blocks
            let at = prefix.count
            for block in blocks {
                switch block {
                case .paragraph(let p): #expect(!p.contains("|"), "pipes as prose at \(at): \(p)")
                case .rule: Issue.record("a delimiter row drew as a rule at \(at)")
                case .table(let table):
                    #expect(table.header == ["Area", "Tools"], "header at \(at): \(table.header)")
                    #expect(table.rows.allSatisfy { $0.count == 2 && !$0.contains("") }, "a partial row at \(at): \(table.rows)")
                    #expect(table.rows.count >= rows, "rows went backwards at \(at)")
                    rows = table.rows.count
                case .list(_, _, let items):
                    #expect(!items.contains { $0.text.hasPrefix("-") || $0.text.contains("|") }, "a table line as a list item at \(at)")
                default: break
                }
            }
            if rows >= 0 { #expect(Self.table(blocks) != nil, "the table vanished at \(at)") }
        }
        #expect(rows == 6)
        #expect(nativeMarkdownParse(prefix, streaming: true).blocks == nativeMarkdownBlocks(text))
    }

    /// Every cut of a table inside a nested list item: the item never shows the table's lines.
    @Test func aTableStreamingInsideAListItemIsHeldTheSameWay() {
        let text = "- Tools:\n  | Area | Count |\n  |---|--:|\n  | Panes | 6 |\n  | Agents | 8 |\n"
        var prefix = ""
        for character in text {
            prefix.append(character)
            let blocks = nativeMarkdownParse(prefix, streaming: true).blocks
            #expect(!"\(blocks)".contains("paragraph(\"|"), "a table line as prose at \(prefix.count): \(blocks)")
            #expect(!"\(blocks)".contains("text: \"Tools:\\n|"), "a table line joined the item at \(prefix.count): \(blocks)")
        }
    }

    @Test(arguments: [
        // A task box still arriving waits, so an item never shows "[x" before its check.
        ("Plan\n- [", [NativeMarkdownBlock.paragraph("Plan")]),
        ("Plan\n- [x", [.paragraph("Plan")]),
        ("Plan\n- [ ] Ship", [.paragraph("Plan"), .list(ordered: false, start: 1, items: [Item(text: "Ship", task: .open)])]),
        // A footnote definition's label waits for its colon.
        ("Text[^1]\n\n[^1]", [.paragraph("Text[^1]")]),
    ])
    func streamingHoldsATaskBoxAndANoteLabelUntilTheyAreWhole(text: String, blocks: [NativeMarkdownBlock]) {
        #expect(nativeMarkdownParse(text, streaming: true).blocks == blocks)
    }
}
