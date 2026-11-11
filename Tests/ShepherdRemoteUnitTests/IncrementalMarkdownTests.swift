import Foundation
import Testing
@testable import ShepherdRemote

/// A reply that grows is parsed from its last unfinished block: the blocks before the freeze point are
/// final, in streaming and in finished mode. Every state below is compared with a full parse of the
/// same prefix, so the shortcut can only be faster, never different.
@Suite("Incremental markdown")
struct IncrementalMarkdownTests {
    struct Sample: CustomTestStringConvertible, Sendable {
        let name: String
        let text: String
        /// The text has a terminated block before its end, so advancing from a cut can skip it.
        var freezes = true
        var testDescription: String { name }
    }

    static let everyBlock = """
    # Title ##
    ## Second with closing hashes ##
    ### Third level

    ---
    ***
    ___

    Intro paragraph
    continues on a second line.

    - item one
    - item two
      - nested a
      - nested b
        - deep
    - [ ] open task
    - [x] done task

    3) third
    4) fourth

    - loose one

    - loose two
    lazy line

    > quote line
    lazy quote line
    > - quoted item
    > - quoted item two

    ```swift
    let a = 1

    let b = 2
    ````

    ~~~
    tilde code
    ~~~~

    $$ x = 1 $$

    $$
    a + b
    $$

    | Left | Center | Right |
    |:-----|:------:|------:|
    | a | b | c |
    | uneven |

    | held |
    text after a header without a delimiter

    - item with table
      | a | b |
      |---|---|
      | 1 | 2 |

    <details>
    <summary>More</summary>

    Hidden **text**

    </details>

    <!-- a comment
    spanning lines -->

    <div>html text</div>
    <hr>
    <img src="a.png" alt="A">
    <br>

    ![one](a.png) ![two](b.png)

    Final paragraph.
    """

    static let footnotes = """
    Reference before[^1] and another[^note] and undefined[^zz].

    Plain paragraph.

    [^1]: First note
        continued on an indented line

    [^note]: Second note

    After the notes[^1] and late[^late].

    [^late]: Defined last
    """

    static let listEdges = """
    - dash item
    * star item
    1. ordered after a bullet
    - back to bullets

    - a
    - - -
    - b
    # heading right after the list
    - one


    - two after two blank lines
    1) paren one
    2) paren two
      continued
    text right after
    """

    /// Enough parts and weight for the greedy chunker to close chunks.
    static let manyParts = (1...40).map { "Paragraph \($0) of the long reply." }.joined(separator: "\n\n")
        + "\n\n" + (1...40).map { "- item \($0)" }.joined(separator: "\n")
        + "\n\n" + (1...20).map { "```\ncode \($0)\n```" }.joined(separator: "\n\n") + "\n\nEnd."

    static let samples: [Sample] = [
        Sample(name: "the reported tools reply", text: MarkdownBlockTests.toolsReply),
        Sample(name: "every block", text: everyBlock),
        Sample(name: "footnotes", text: footnotes, freezes: false),
        Sample(name: "an unclosed fence", text: "Intro.\n\n- a\n- b\n\n```swift\nlet x = 1\n\nstill open"),
        Sample(name: "an unclosed details block", text: "Intro.\n\n# Head\n\n<details><summary>S</summary>\nopen text\n\nmore"),
        Sample(name: "an unclosed comment", text: "Intro.\n\n---\n\n<!-- never closed\nmore text\n\nand more"),
        Sample(name: "two cycles of the fake model", text: NativeMountedCostTests.bigReply(cycles: 2)),
        Sample(name: "a cycle ending in a fence", text: NativeMountedCostTests.bigReply(cycles: 1, endingMidCycle: true)),
        Sample(name: "list edges", text: listEdges),
        Sample(name: "many parts", text: manyParts),
        Sample(name: "every block with CRLF", text: everyBlock.replacingOccurrences(of: "\n", with: "\r\n")),
        Sample(name: "the tools reply with CRLF", text: MarkdownBlockTests.toolsReply.replacingOccurrences(of: "\n", with: "\r\n")),
        Sample(name: "every block with tabs", text: everyBlock.replacingOccurrences(of: "\n  ", with: "\n\t")),
        Sample(name: "list edges with tabs", text: listEdges.replacingOccurrences(of: "\n  ", with: "\n\t")),
        Sample(name: "accents, CJK and emoji", text: "Café ☕\n\n日本語の段落\nと続き\n\n- 🙂 one\n- two\n\n> naïve quote\n\n```\nλ\n```\n\nEnd 🙂"),
    ]

    /// Every Unicode scalar for a small text; for a larger one every line end and its two scalars on
    /// each side, and every 16th scalar.
    static func cuts(_ scalars: [Unicode.Scalar]) -> [Int] {
        if String(String.UnicodeScalarView(scalars)).utf8.count <= 600 { return Array(1...scalars.count) }
        var cuts: Set<Int> = [scalars.count]
        for n in stride(from: 16, to: scalars.count, by: 16) { cuts.insert(n) }
        for (index, scalar) in scalars.enumerated() where scalar == "\n" {
            for delta in -2...2 where (1...scalars.count).contains(index + 1 + delta) { cuts.insert(index + 1 + delta) }
        }
        return cuts.sorted()
    }

    static func prefix(_ scalars: [Unicode.Scalar], _ count: Int) -> String {
        String(String.UnicodeScalarView(scalars[0..<count]))
    }

    // MARK: Equivalence

    @Test(arguments: samples, [true, false])
    func advancingThroughEveryCutGivesAFullParse(_ sample: Sample, streaming: Bool) {
        let scalars = Array(sample.text.unicodeScalars)
        var markdown: NativeMarkdownState?
        var prose: NativeProseState?
        var advanced = 0
        for count in Self.cuts(scalars) {
            let text = Self.prefix(scalars, count)
            let expected = nativeMarkdownParse(text, streaming: streaming)

            if var state = markdown, state.advance(to: text, streaming: streaming) {
                markdown = state
                advanced += 1
            } else {
                markdown = NativeMarkdownState(text, streaming: streaming)
            }
            #expect(markdown?.blocks == expected.blocks, "blocks at \(count)")
            #expect(markdown?.endsInOpenFence == expected.endsInOpenFence, "open fence at \(count)")
            #expect(markdown?.text == text && markdown?.streaming == streaming)

            if var state = prose, state.advance(to: text, streaming: streaming) {
                prose = state
            } else {
                prose = NativeProseState(text, streaming: streaming, reusing: prose?.prose)
            }
            #expect(prose?.prose == NativeProse(expected), "prose at \(count)")
            #expect(prose?.prose.blocks == expected.blocks, "prose blocks at \(count)")
        }
        #expect(!sample.freezes || advanced > 0, "the cuts never took the incremental path")
    }

    /// The turn ends on a state that streamed: the same text, in the other mode.
    @Test(arguments: samples)
    func theTurnEndAdvancesAStreamedStateIntoFinishedMode(_ sample: Sample) throws {
        let scalars = Array(sample.text.unicodeScalars)
        var markdown: NativeMarkdownState?
        var prose: NativeProseState?
        for count in Self.cuts(scalars) where count % 3 == 0 || count == scalars.count {
            let text = Self.prefix(scalars, count)
            if var state = markdown, state.advance(to: text, streaming: true) { markdown = state } else { markdown = NativeMarkdownState(text, streaming: true) }
            if var state = prose, state.advance(to: text, streaming: true) { prose = state } else { prose = NativeProseState(text, streaming: true) }
        }
        var streamed = try #require(markdown)
        var streamedProse = try #require(prose)
        let expected = nativeMarkdownParse(sample.text, streaming: false)
        let advancedMarkdown = streamed.advance(to: sample.text, streaming: false)
        let advancedProse = streamedProse.advance(to: sample.text, streaming: false)
        #expect(advancedMarkdown && advancedProse, "the mode change is an ordinary advance")
        #expect(streamed.blocks == expected.blocks && streamed.endsInOpenFence == expected.endsInOpenFence)
        #expect(streamedProse.prose == NativeProse(expected))
        #expect(streamed.streaming == false)
    }

    // MARK: A seeded walk

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func generated(seed: UInt64, bytes: Int) -> String {
        var rng = SplitMix64(state: seed)
        let words = ["alpha", "bé", "日本語", "🙂", "code", "`tick`", "**bold**", "[link](x)", "x|y", "naïve", "1.", "-"]
        func sentence() -> String {
            (0..<Int.random(in: 3...14, using: &rng)).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
        }
        func lines(_ range: ClosedRange<Int>, _ make: () -> String) -> [String] {
            (0..<Int.random(in: range, using: &rng)).map { _ in make() }
        }
        var text = ""
        while text.utf8.count < bytes {
            switch Int.random(in: 0..<13, using: &rng) {
            case 0: text += "# \(sentence())\n"
            case 1: text += "## \(sentence()) ##\n\n"
            case 2...4: text += sentence() + "\n\n"
            case 5: text += sentence() + "\n" + sentence() + "\n\n"
            case 6:
                let items = lines(1...6) { "- \(sentence())\n" + (Bool.random(using: &rng) ? "  - nested \(sentence())\n" : "") }
                text += items.joined() + (Bool.random(using: &rng) ? "\n" : "")
            case 7: text += lines(1...5) { "1. \(sentence())\n" }.joined() + "\n"
            case 8:
                let body = lines(1...5) { Bool.random(using: &rng) ? sentence() : "" }.joined(separator: "\n")
                text += "```swift\n\(body)\n```\n" + (Bool.random(using: &rng) ? "\n" : "")
            case 9: text += "| a | b |\n|---|:-:|\n" + lines(0...4) { "| \(sentence()) | x |\n" }.joined() + "\n"
            case 10: text += "> \(sentence())\nlazy \(sentence())\n\n"
            case 11: text += ["---\n", "<br>\n", "<!-- note -->\n", "$$ x $$\n"].randomElement(using: &rng)!
            default: text += sentence() + "\n"
            }
        }
        return text
    }

    @Test(arguments: [UInt64(1), 42, 2026], [true, false])
    func aSeededWalkOverGeneratedTextMatchesAFullParse(_ seed: UInt64, streaming: Bool) {
        let text = Self.generated(seed: seed, bytes: 20_000)
        let scalars = Array(text.unicodeScalars)
        var rng = SplitMix64(state: seed ^ 0xFEED)
        var markdown = NativeMarkdownState("", streaming: streaming)
        var prose = NativeProseState("", streaming: streaming)
        var count = 0, steps = 0, advanced = 0
        var nextCheck = scalars.count / 10
        while count < scalars.count {
            count = min(scalars.count, count + Int.random(in: 1...300, using: &rng))
            let prefix = Self.prefix(scalars, count)
            if markdown.advance(to: prefix, streaming: streaming) { advanced += 1 } else { markdown = NativeMarkdownState(prefix, streaming: streaming) }
            if !prose.advance(to: prefix, streaming: streaming) { prose = NativeProseState(prefix, streaming: streaming, reusing: prose.prose) }
            steps += 1
            guard count >= nextCheck || count == scalars.count else { continue }
            nextCheck += scalars.count / 10
            let expected = nativeMarkdownParse(prefix, streaming: streaming)
            #expect(markdown.blocks == expected.blocks && markdown.endsInOpenFence == expected.endsInOpenFence, "blocks at \(count)")
            #expect(prose.prose == NativeProse(expected), "prose at \(count)")
        }
        #expect(advanced > steps / 2, "most steps advance: \(advanced) of \(steps)")
        let finished = nativeMarkdownParse(text, streaming: false)
        let toFinished = markdown.advance(to: text, streaming: false)
        #expect(toFinished && markdown.blocks == finished.blocks)
    }

    // MARK: Random markup

    /// Characters that start, join and end Markdown constructs, in no order.
    static let markup: [String] = [
        "-", " ", " ", "\n", "\n", "\n\n", "|", "`", "`", ">", "#", "1", ".", ")", "[", "^", "]", ":", "<", "!", "$", "~", "\t", "x", "a",
        "*", "_", "\r", "/", "d", "e", "t", "s", "(", "=",
    ]

    static func randomMarkup(_ rng: inout SplitMix64, length: ClosedRange<Int>) -> String {
        (0..<Int.random(in: length, using: &rng)).map { _ in markup.randomElement(using: &rng)! }.joined()
    }

    /// Texts of broken, half-written and nested Markdown, grown a few characters at a time, in either mode.
    @Test func aWalkOverRandomMarkupMatchesAFullParse() {
        var mismatches: [String] = []
        for seed in 1...300 as ClosedRange<UInt64> {
            var rng = SplitMix64(state: seed &* 104_729)
            let scalars = Array(Self.randomMarkup(&rng, length: 1...70).unicodeScalars)
            var markdown = NativeMarkdownState("", streaming: true)
            var prose = NativeProseState("", streaming: true)
            var count = 0
            while count < scalars.count {
                count = min(scalars.count, count + Int.random(in: 1...3, using: &rng))
                let streaming = Bool.random(using: &rng)
                let text = Self.prefix(scalars, count)
                let expected = nativeMarkdownParse(text, streaming: streaming)
                if !markdown.advance(to: text, streaming: streaming) { markdown = NativeMarkdownState(text, streaming: streaming) }
                if !prose.advance(to: text, streaming: streaming) { prose = NativeProseState(text, streaming: streaming, reusing: prose.prose) }
                if markdown.blocks != expected.blocks || markdown.endsInOpenFence != expected.endsInOpenFence || prose.prose != NativeProse(expected) {
                    mismatches.append("\(text.debugDescription) (streaming \(streaming))")
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) texts differ, the first: \(mismatches.first ?? "")")
    }

    /// The freeze rule holds for any later text that keeps the guard, not only for the text the state grew into.
    @Test func aTextThatKeepsTheGuardAndGoesItsOwnWayMatchesAFullParse() {
        var mismatches: [String] = []
        var accepted = 0
        for seed in 1...600 as ClosedRange<UInt64> {
            var rng = SplitMix64(state: seed &* 15_485_863)
            let first = Self.randomMarkup(&rng, length: 1...80)
            let scalars = Array(first.unicodeScalars)
            let second = Self.prefix(scalars, Int.random(in: 0...scalars.count, using: &rng)) + Self.randomMarkup(&rng, length: 0...40)
            for (from, to) in [(true, true), (true, false), (false, false), (false, true)] {
                var markdown = NativeMarkdownState(first, streaming: from)
                var prose = NativeProseState(first, streaming: from)
                guard markdown.advance(to: second, streaming: to) else { continue }
                accepted += 1
                let expected = nativeMarkdownParse(second, streaming: to)
                let advancedProse = prose.advance(to: second, streaming: to)
                if !advancedProse || markdown.blocks != expected.blocks || markdown.endsInOpenFence != expected.endsInOpenFence
                    || prose.prose != NativeProse(expected) {
                    mismatches.append("\(first.debugDescription) then \(second.debugDescription) (\(from) to \(to))")
                }
            }
        }
        #expect(accepted > 600, "\(accepted) advances were accepted")
        #expect(mismatches.isEmpty, "\(mismatches.count) texts differ, the first: \(mismatches.first ?? "")")
    }

    // MARK: The freeze rule

    @Test func anEditInsideTheFrozenPrefixCannotBeAdvanced() {
        let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph.\n\nFourth"
        var state = NativeMarkdownState(text, streaming: false)
        #expect(state.frozenCount == 2, "everything before the last terminated block start is final")
        let before = state
        let edited = state.advance(to: text.replacingOccurrences(of: "First", with: "Zeroth"), streaming: false)
        #expect(!edited && state == before, "a refused advance leaves the state alone")
        #expect(state.tail(of: text.replacingOccurrences(of: "Second", with: "2nd")) == nil)
        #expect(state.tail(of: text.replacingOccurrences(of: "Third", with: "3rd")) == nil, "the freeze line is guarded too")
        let shorter = state.advance(to: String(text.prefix(10)), streaming: false)
        #expect(!shorter, "shorter text is no extension")
        let grown = state.advance(to: text + " grows", streaming: false)
        #expect(grown && state.blocks.last == .paragraph("Fourth grows"))
    }

    @Test func aFootnoteKeepsTheFreezePointBeforeIt() {
        let text = "One.\n\nTwo.\n\nThree[^a] here.\n\nFour.\n\nFive.\n\n[^a]: note\n"
        let state = NativeMarkdownState(text, streaming: false)
        #expect(state.frozenOffset == "One.\n\nTwo.\n\n".utf8.count)
        #expect(state.frozenCount == 2)
        #expect(state.guardOffset == state.frozenOffset + "Three[^a] here.\n".utf8.count)
        var later = state
        let advanced = later.advance(to: text + "\nSix.\n", streaming: false)
        #expect(advanced && later.frozenCount == 2, "a late definition still reaches the reference before it")
        #expect(later.blocks == nativeMarkdownParse(text + "\nSix.\n").blocks)
        let plain = NativeMarkdownState("One.\n\nTwo.\n\nThree.\n\nFour.\n", streaming: false)
        #expect(plain.frozenCount == 3)
    }

    @Test func aFreezeLineNeedsItsNewline() {
        #expect(NativeMarkdownState("One.\n\nTwo.", streaming: false).frozenCount == 0, "the last line is still being written")
        #expect(NativeMarkdownState("One.\n\nTwo.\n", streaming: false).frozenCount == 1)
        let single = NativeMarkdownState(String(repeating: "word ", count: 5_000), streaming: true)
        #expect(single.frozenOffset == 0 && single.guardOffset == 0 && single.frozenCount == 0, "one line is all tail")
        #expect(single.tail(of: single.text + "more")?.bytes == single.text.utf8.count + 4)
        #expect(NativeMarkdownState("", streaming: false).blocks.isEmpty)
    }

    /// The parser's lookahead calls a line of vertical tabs or line separators blank, its block rules do not: such a
    /// line ends a held table header's wait for more text, so it is no place to resume from.
    @Test(arguments: ["\u{0B}", "\u{85}", "\u{2028}"])
    func aLineOfOtherWhitespaceIsNoPlaceToResumeFrom(_ blank: String) {
        let text = "Intro.\n\n| a | b\n\(blank)\n"
        var state = NativeMarkdownState(text, streaming: true)
        #expect(state.frozenCount == 1, "the held header's line is the last place to resume from")
        let grown = text + "more\n"
        let advanced = state.advance(to: grown, streaming: true)
        #expect(advanced && state.blocks == nativeMarkdownParse(grown, streaming: true).blocks)
        let finished = state.advance(to: grown, streaming: false)
        #expect(finished && state.blocks == nativeMarkdownParse(grown, streaming: false).blocks)
    }

    @Test func aGrowingParagraphOrFenceIsItsOwnTail() throws {
        let paragraph = "Intro.\n\nline one\nline two\nline three"
        let state = NativeMarkdownState(paragraph, streaming: false)
        #expect(state.frozenCount == 1, "only the intro is final: a paragraph's later lines are no checkpoints")
        let fence = NativeMarkdownState("Intro.\n\n```swift\nlet a = 1\n\nlet b = 2\n", streaming: true)
        #expect(fence.frozenCount == 1 && fence.endsInOpenFence)
        let tail = try #require(fence.tail(of: fence.text + "let c = 3\n"))
        #expect(tail.lines == 6 && tail.bytes == "```swift\nlet a = 1\n\nlet b = 2\nlet c = 3\n".utf8.count)
    }

    @Test func frozenBlocksAreAllButTheLastFewOfALongReply() {
        let reply = NativeMountedCostTests.bigReply(cycles: 12)
        for streaming in [true, false] {
            let state = NativeMarkdownState(reply, streaming: streaming)
            let total = nativeMarkdownParse(reply, streaming: streaming).blocks.count
            #expect(state.blocks.count == total)
            #expect(state.frozenCount >= total - 3, "\(state.frozenCount) of \(total) blocks are final")
        }
    }

    // MARK: Work

    @Test func aThousandAppendsParseAboutOneBlockEach() {
        let blocks = [
            "Paragraph first line\nsecond line\n\n",
            "- one\n- two\n- three\n\n",
            "```\nl1\nl2\n```\n\n",
            "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\n",
        ]
        let text = (0..<60).map { blocks[$0 % blocks.count] }.joined()
        let scalars = Array(text.unicodeScalars)
        let largest = 5
        var state = NativeMarkdownState("", streaming: true)
        var fresh = 0
        let appends = 1_000
        for step in 1...appends {
            let prefix = Self.prefix(scalars, max(1, scalars.count * step / appends))
            if !state.advance(to: prefix, streaming: true) {
                state = NativeMarkdownState(prefix, streaming: true)
                fresh += 1
            }
        }
        #expect(state.blocks == nativeMarkdownParse(text, streaming: true).blocks)
        let lines = text.components(separatedBy: "\n").count
        #expect(fresh == 0, "text that only grows is always advanced")
        #expect(state.parsedLines <= lines + appends * (largest + 2),
                "\(state.parsedLines) lines parsed for \(lines); a full parse per append would be about \(appends * lines / 2)")
    }

    @Test func closedChunksKeepTheirStorageAcrossSteps() {
        let paragraphs = (0..<80).map { "Paragraph \($0) " + String(repeating: "word ", count: 220) }
        var state = NativeProseState("", streaming: true)
        var restarts = 0
        for count in 1...paragraphs.count {
            let text = paragraphs.prefix(count).joined(separator: "\n\n") + "\n"
            let old = state.prose
            let closed = state.closed.count
            if !state.advance(to: text, streaming: true) {
                state = NativeProseState(text, streaming: true, reusing: old)
                restarts += 1
            }
            for index in 0..<closed {
                #expect(state.prose.chunks[index].sharesStorage(with: old.chunks[index]), "chunk \(index) at \(count)")
            }
        }
        #expect(restarts == 0)
        #expect(state.closed.count >= 3 && state.prose.chunks.count > state.closed.count)
        #expect(state.prose == NativeProse(nativeMarkdownParse(paragraphs.joined(separator: "\n\n") + "\n", streaming: true)))
    }
}
