import Foundation
import Testing
import ShepherdProtocol

/// `board_edit`'s algorithm: find-and-replace edits applied in order to a board's text.
@Suite("Design board edits")
struct DesignBoardEditTests {
    static func apply(_ edits: [DesignBoardEdit], to source: String) throws -> DesignBoardEdits.Applied {
        try DesignBoardEdits.apply(edits, to: source)
    }

    static func failure(_ edits: [DesignBoardEdit], on source: String) -> DesignBoardEdits.Failure? {
        do { _ = try DesignBoardEdits.apply(edits, to: source); return nil } catch { return error }
    }

    @Test func anEditThatMatchesOnceReplacesIt() throws {
        let applied = try Self.apply([DesignBoardEdit(find: "Pay now", replace: "Buy")], to: "<b>Pay now</b> or later")
        #expect(applied.source == "<b>Buy</b> or later" && applied.replaced == [1])
    }

    @Test func editsApplyInOrderEachOnWhatTheOneBeforeLeft() throws {
        let applied = try Self.apply([DesignBoardEdit(find: "one", replace: "two"), DesignBoardEdit(find: "two", replace: "three")],
                                     to: "one")
        #expect(applied.source == "three" && applied.replaced == [1, 1])
        // The same pair the other way round finds nothing for the second edit's text yet.
        #expect(Self.failure([DesignBoardEdit(find: "two", replace: "three"), DesignBoardEdit(find: "one", replace: "two")], on: "one")
                == .notFound(index: 1, of: 2, find: "two", hint: nil))
    }

    @Test func anEditCanMatchWhatAnEarlierOneWrote() throws {
        let applied = try Self.apply([DesignBoardEdit(find: "<hr>", replace: "<hr class=\"rule\">"),
                                      DesignBoardEdit(find: "class=\"rule\"", replace: "class=\"rule thin\"")], to: "<hr>")
        #expect(applied.source == "<hr class=\"rule thin\">")
    }

    @Test func aFindThatMatchesNothingFailsNamingItsEdit() {
        let failure = Self.failure([DesignBoardEdit(find: "a", replace: "b"), DesignBoardEdit(find: "zzz", replace: "x")], on: "abc")
        guard case .notFound(let index, let total, let find, _) = failure else { Issue.record("\(String(describing: failure))"); return }
        #expect(index == 2 && total == 2 && find == "zzz")
        #expect(failure?.code == "edit_not_found")
        #expect(failure?.description.contains("edit 2 of 2") == true)
    }

    @Test func aFindThatMatchesSeveralTimesFailsWithTheLinesItIsOn() {
        let source = "<p>Hi</p>\n<p>Hi</p>\n<div>\n  <p>Hi</p>\n</div>\n<p>Hi</p>"
        let failure = Self.failure([DesignBoardEdit(find: "Hi", replace: "Yo")], on: source)
        guard case .ambiguous(let index, _, _, let lines, let excerpts) = failure else { Issue.record("\(String(describing: failure))"); return }
        #expect(index == 1 && lines == [1, 2, 4, 6])
        #expect(excerpts == ["\"<p>Hi</p>\"", "\"<p>Hi</p>\"", "\"<p>Hi</p>\""], "the first three, trimmed")
        #expect(failure?.code == "edit_ambiguous")
        let text = failure?.description ?? ""
        #expect(text.contains("matched 4 times") && text.contains("line 4") && text.contains("and 1 more") && text.contains("set all"))
    }

    @Test func allReplacesEveryMatchAndCountsThem() throws {
        let applied = try Self.apply([DesignBoardEdit(find: "#4f46e5", replace: "#4338ca", all: true)],
                                     to: "a{color:#4f46e5} b{color:#4f46e5;border:1px solid #4f46e5}")
        #expect(applied.source == "a{color:#4338ca} b{color:#4338ca;border:1px solid #4338ca}")
        #expect(applied.replaced == [3])
    }

    @Test func allStillFailsWhenNothingMatches() {
        #expect(Self.failure([DesignBoardEdit(find: "x", replace: "y", all: true)], on: "abc") == .notFound(index: 1, of: 1, find: "x", hint: nil))
    }

    @Test func matchesThatOverlapAreSeveralWithoutAllAndTakenLeftToRightWithIt() throws {
        let failure = Self.failure([DesignBoardEdit(find: "aa", replace: "b")], on: "aaa")
        guard case .ambiguous(_, _, _, let lines, _) = failure else { Issue.record("\(String(describing: failure))"); return }
        #expect(lines.count == 2, "\"aa\" starts at 0 and at 1")
        let applied = try Self.apply([DesignBoardEdit(find: "aa", replace: "b", all: true)], to: "aaaaa")
        #expect(applied.source == "bba" && applied.replaced == [2])
    }

    @Test func anEmptyFindOrNoEditsOrTooManyIsRefused() {
        #expect(Self.failure([DesignBoardEdit(find: "", replace: "x")], on: "abc") == .emptyFind(index: 1))
        #expect(Self.failure([DesignBoardEdit(find: "a", replace: "b"), DesignBoardEdit(find: "", replace: "x", all: true)], on: "abc")
                == .emptyFind(index: 2))
        #expect(Self.failure([], on: "abc") == .noEdits)
        let many = (0...DesignBoardEdits.maxEdits).map { _ in DesignBoardEdit(find: "a", replace: "a") }
        #expect(Self.failure(many, on: "a") == .tooMany(DesignBoardEdits.maxEdits + 1))
        #expect(Self.failure([], on: "x")?.code == "invalid_edit")
    }

    @Test func aReplacementMayBeEmptyAndMayHoldTheFindItself() throws {
        #expect(try Self.apply([DesignBoardEdit(find: " class=\"old\"", replace: "")], to: "<p class=\"old\">x</p>").source == "<p>x</p>")
        #expect(try Self.apply([DesignBoardEdit(find: "<p>", replace: "<p><p>")], to: "<p>x").source == "<p><p>x")
        #expect(try Self.apply([DesignBoardEdit(find: "p", replace: "pp", all: true)], to: "pop").replaced == [2])
    }

    @Test func matchingIsExactOnBytesNotOnUnicodeEquivalenceOrCase() throws {
        let precomposed = "caf\u{00E9}", decomposed = "cafe\u{0301}"
        #expect(precomposed == decomposed, "Swift calls them equal; the edit does not")
        #expect(Self.failure([DesignBoardEdit(find: decomposed, replace: "x")], on: precomposed)?.code == "edit_not_found")
        #expect(try Self.apply([DesignBoardEdit(find: precomposed, replace: "x")], to: precomposed + " " + decomposed).source == "x " + decomposed)
        #expect(Self.failure([DesignBoardEdit(find: "PAY", replace: "x")], on: "pay")?.code == "edit_not_found")
    }

    @Test func unicodeSurvivesEditsAroundIt() throws {
        let applied = try Self.apply([DesignBoardEdit(find: "“Hi” · 👋", replace: "“Bye” · 🌱"),
                                      DesignBoardEdit(find: "é", replace: "e", all: true)], to: "<p>“Hi” · 👋</p><p>été</p>")
        #expect(applied.source == "<p>“Bye” · 🌱</p><p>ete</p>" && applied.replaced == [1, 2])
        // An emoji made of several scalars matches whole, and a prefix of its scalars matches inside it.
        let family = "👨‍👩‍👧"
        #expect(try Self.apply([DesignBoardEdit(find: family, replace: "F")], to: "a\(family)b").source == "aFb")
    }

    @Test func aBoardWithCRLFLinesIsEditedAndABareLFFindSaysWhy() throws {
        let board = "<div>\r\n  <p>Hi</p>\r\n</div>\r\n"
        let applied = try Self.apply([DesignBoardEdit(find: "<div>\r\n  <p>Hi</p>", replace: "<div>\r\n  <p>Yo</p>")], to: board)
        #expect(applied.source == "<div>\r\n  <p>Yo</p>\r\n</div>\r\n", "the other line endings are untouched")
        #expect(try Self.apply([DesignBoardEdit(find: "Hi", replace: "Yo")], to: board).source == "<div>\r\n  <p>Yo</p>\r\n</div>\r\n")
        guard case .notFound(_, _, _, let hint) = Self.failure([DesignBoardEdit(find: "<div>\n  <p>Hi</p>", replace: "x")], on: board) else {
            Issue.record("a bare LF matched inside CRLF"); return
        }
        #expect(hint?.contains("CRLF") == true)
    }

    @Test func aFindWhoseFirstLineAppearsSaysWhere() {
        let board = "<div>\n  <p class=\"a\">Hi</p>\n</div>"
        guard case .notFound(_, _, _, let hint) = Self.failure([DesignBoardEdit(find: "<div>\n  <p class=\"b\">Hi</p>", replace: "x")], on: board) else {
            Issue.record("expected a miss"); return
        }
        #expect(hint?.contains("line 1") == true && hint?.contains("<div>") == true)
        guard case .notFound(_, _, _, let none) = Self.failure([DesignBoardEdit(find: "nothing here\nnor here", replace: "x")], on: board) else {
            Issue.record("expected a miss"); return
        }
        #expect(none == nil)
    }

    @Test func aResultOverTheBoardLimitIsRefusedBeforeItIsBuilt() {
        let board = String(repeating: "a", count: 1_000)
        let failure = Self.failure([DesignBoardEdit(find: "a", replace: String(repeating: "b", count: 1_000), all: true)], on: board)
        guard case .tooLarge(let index, _, let bytes) = failure else { Issue.record("\(String(describing: failure))"); return }
        #expect(index == 1 && bytes == 1_000 + 1_000 * 999 && failure?.code == "board_too_large")
    }

    @Test func aFailedEditLeavesNothingHalfApplied() {
        // apply is pure: the first edits' result is dropped with the failure.
        let source = "one two"
        #expect(Self.failure([DesignBoardEdit(find: "one", replace: "1"), DesignBoardEdit(find: "nope", replace: "x")], on: source) != nil)
        #expect(source == "one two")
    }

    @Test func editsRoundTripOnTheWire() throws {
        let edits = [DesignBoardEdit(find: "a", replace: "b"), DesignBoardEdit(find: "c", replace: "d", all: true)]
        let data = try JSONEncoder().encode(edits)
        #expect(try JSONDecoder().decode([DesignBoardEdit].self, from: data) == edits)
        let text = String(decoding: try JSONEncoder().encode(DesignBoardEdit(find: "a", replace: "b")), as: UTF8.self)
        #expect(!text.contains("all"), "all is written only when true")
        #expect(try JSONDecoder().decode(DesignBoardEdit.self, from: Data(#"{"find":"a","replace":"b"}"#.utf8)).all == false)
    }
}
