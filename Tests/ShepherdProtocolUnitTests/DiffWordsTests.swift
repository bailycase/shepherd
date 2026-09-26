import Foundation
import Testing
@testable import ShepherdProtocol

@Suite("Word diffs")
struct DiffWordsTests {
    /// The changed text of `line` at `ranges`.
    static func pieces(_ line: String, _ ranges: [Range<Int>]) -> [String] {
        DiffWords.stringRanges(ranges, in: line).map { String(line[$0]) }
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let old: String
        let new: String
        let removed: [String]
        let added: [String]
        var testDescription: String { "\(old) → \(new)" }
    }

    @Test(arguments: [
        Case(old: "return err", new: "return fmt.Errorf(\"outbox: encode %s: %w\", e.Kind, err)",
             removed: [], added: ["fmt.Errorf(\"outbox: encode %s: %w\", e.Kind, ", ")"]),
        Case(old: "let count = 1", new: "let count = 2", removed: ["1"], added: ["2"]),
        // Changes separated only by whitespace read as one.
        Case(old: "a b c d", new: "a x y d", removed: ["b c"], added: ["x y"]),
        // Offsets are UTF-16: an emoji before the change counts two units.
        Case(old: "👋 hello world", new: "👋 hello there", removed: ["world"], added: ["there"]),
    ])
    func changedWordsAreTheOnesThatDiffer(_ c: Case) throws {
        let ranges = try #require(DiffWords.ranges(old: c.old, new: c.new))
        #expect(Self.pieces(c.old, ranges.old) == c.removed)
        #expect(Self.pieces(c.new, ranges.new) == c.added)
    }

    /// ChangesUnified's line: the codec call replaces json.Marshal; what both keep stays plain.
    @Test func theBoardsLineHighlightsOnlyTheCall() throws {
        let old = "payload, err := json.Marshal(e.Payload)"
        let new = "payload, err := o.codec.Encode(e.Kind, e.Payload)"
        let ranges = try #require(DiffWords.ranges(old: old, new: new))
        let kept = "payload, err := ".utf16.count
        #expect(ranges.old.allSatisfy { $0.lowerBound >= kept } && ranges.new.allSatisfy { $0.lowerBound >= kept })
        #expect(Self.pieces(old, ranges.old).joined().contains("Marshal"))
        #expect(Self.pieces(new, ranges.new).joined().contains("Encode"))
        #expect(!Self.pieces(new, ranges.new).joined().contains("Payload"))
    }

    @Test(arguments: [
        ("same line", "same line"),
        // Nothing in common: two different lines, not an edit of one.
        ("func flush(rows []row) {", "if err := o.send(ctx, r); err != nil {"),
        (String(repeating: "x ", count: 1_500), String(repeating: "y ", count: 1_500)),
    ])
    func unrelatedIdenticalOrHugeLinesGetNone(old: String, new: String) {
        #expect(DiffWords.ranges(old: old, new: new) == nil)
    }

    @Test func tokensAreWordsSpacesAndSingleSymbols() {
        #expect(DiffWords.tokens("o.codec_x  (42)").map(\.text) == ["o", ".", "codec_x", "  ", "(", "42", ")"])
        #expect(DiffWords.tokens("").isEmpty)
    }

    /// Removals pair line for line with the additions after them, as the split view draws them;
    /// an extra addition has no partner.
    @Test func removalsPairWithTheAdditionsThatFollowThem() throws {
        let file = try #require(DiffFile.parse("""
        diff --git a/a.go b/a.go
        --- a/a.go
        +++ b/a.go
        @@ -1,4 +1,5 @@
         keep
        -let x = 1
        -let y = 2
        +let x = 10
        +let y = 20
        +let z = 30
         keep
        """).first)
        let hunk = try #require(file.hunks.first)
        #expect(DiffWords.pairs(in: hunk).map { "\($0.removed.text)|\($0.added.text)" } == ["let x = 1|let x = 10", "let y = 2|let y = 20"])
        let changes = DiffWords.changes(in: file)
        let lines = hunk.lines
        #expect(Self.pieces(lines[1].text, changes[lines[1].id] ?? []) == ["1"])
        #expect(Self.pieces(lines[3].text, changes[lines[3].id] ?? []) == ["10"])
        #expect(changes[lines[5].id] == nil, "let z has no partner")
        #expect(changes[lines[0].id] == nil, "context lines never carry word diffs")
    }

    @Test func editScriptMatchesTheLongestCommonRun() throws {
        let a: [Substring] = ["a", "b", "c", "a", "b", "b", "a"]
        let b: [Substring] = ["c", "b", "a", "b", "a", "c"]
        let script = try #require(DiffWords.editScript(a, b))
        #expect(script.matches.count == 4, "Myers' example: an LCS of length 4")
        #expect(script.oldChanged.count + script.newChanged.count == 5)
    }
}
