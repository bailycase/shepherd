import Foundation
import Testing
@testable import ShepherdProtocol

/// The batch tools' requests and checkpoint names (docs/designs.md › The design agent).
@Suite("Design agent tools")
struct DesignAgentToolsTests {
    @Test(arguments: [
        ("before chip move", "before chip move"),
        ("  before   chip\tmove \n", "before chip move"),
        ("v2", "v2"),
        ("Round 3 (final): a.b-c_d, e'f #1 +2", "Round 3 (final): a.b-c_d, e'f #1 +2"),
        ("Überarbeitung 1", "Überarbeitung 1"),
    ] as [(String, String)])
    func aCheckpointNameIsCleanedToOneLine(_ raw: String, _ clean: String) {
        #expect(DesignCheckpointName.clean(raw) == clean)
    }

    @Test(arguments: [
        "", "   ", "-flag", ".hidden", "_x", "../etc", "a/b", "a\\b", "name\u{0}", "tab\u{7}bell", "emoji 👋", "a;b", "a|b", "$x", "x*",
        String(repeating: "a", count: 61),
    ])
    func aNameThatCouldBeAPathAFlagOrJunkIsRefused(_ raw: String) {
        #expect(DesignCheckpointName.clean(raw) == nil)
    }

    @Test func theLongestNameIsSixtyCharacters() {
        #expect(DesignCheckpointName.clean(String(repeating: "a", count: 60)) != nil)
    }

    @Test func theAutomaticNameBeforeARestoreFitsTheLimit() {
        #expect(DesignCheckpointName.beforeRestore("before chip move") == "before restore before chip move")
        let long = DesignCheckpointName.beforeRestore(String(repeating: "n", count: 60))
        #expect(long.count <= DesignCheckpointName.maxLength && long.hasPrefix("before restore n"))
        #expect(DesignCheckpointName.clean(long) == long)
    }

    @Test func aBatchRequestFromTheExtensionDefaultsWhatItLeavesOut() throws {
        let request = try JSONDecoder().decode(DesignBatchEditRequest.self, from: Data(#"{"boards":[{"path":"A.dc.html"}]}"#.utf8))
        #expect(request == DesignBatchEditRequest(boards: [.init(path: "A.dc.html")]))
        #expect(!request.atomic && !request.dryRun && request.checkpoint == nil && request.tokens == nil && !request.snapExisting)
        let empty = try JSONDecoder().decode(DesignBatchEditRequest.self, from: Data("{}".utf8))
        #expect(empty.boards.isEmpty && empty.edits.isEmpty, "the host answers it; decoding does not refuse it")
    }

    @Test func aBatchRequestRoundTripsEveryOption() throws {
        let request = DesignBatchEditRequest(
            boards: [.init(path: "A.dc.html"), .init(path: "B.dc.html", edits: [DesignBoardEdit(find: "a", replace: "b", all: true)])],
            edits: [DesignBoardEdit(find: "x", replace: "y")], atomic: true, dryRun: true, checkpoint: "before", tokens: .strict,
            snapExisting: true, baseRevision: 9)
        #expect(try JSONDecoder().decode(DesignBatchEditRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func aRenderRequestNeedsAPathAndNothingElse() throws {
        let bare = try JSONDecoder().decode(DesignRenderRequest.self, from: Data(#"{"path":"A.dc.html"}"#.utf8))
        #expect(bare == DesignRenderRequest(path: "A.dc.html"))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DesignRenderRequest.self, from: Data("{}".utf8)) }
        let full = DesignRenderRequest(path: "A.dc.html", width: 390, height: 844, scale: 1.5, props: .object(["density": .string("compact")]))
        #expect(try JSONDecoder().decode(DesignRenderRequest.self, from: JSONEncoder().encode(full)) == full)
    }

    @Test func aFailedEditExplainsItselfInOneLineForABatch() {
        let notFound = DesignBoardEdits.Failure.notFound(index: 2, of: 3, find: "Pay now", hint: nil).brief
        #expect(notFound.edit == 2 && notFound.matches == 0 && notFound.message.contains("edit 2 matched nothing"))
        let several = DesignBoardEdits.Failure.ambiguous(index: 1, of: 1, find: "Hi", lines: [1, 2, 4, 6, 9], excerpts: []).brief
        #expect(several.matches == 5 && several.message.contains("matched 5 times without all") && several.message.contains("…"))
        #expect(DesignBoardEdits.Failure.tooLarge(index: 1, of: 1, bytes: 1_000_000).brief.message.contains("1000000"))
        #expect(DesignBoardEdits.Failure.noEdits.brief.edit == nil)
    }

    @Test func aWriteResultFromBeforeReportsStillDecodes() throws {
        let old = #"{"revision":4,"changed":true,"warnings":[],"boardCount":1}"#
        let result = try JSONDecoder().decode(DesignWriteResult.self, from: Data(old.utf8))
        #expect(result.report == nil && result.revision == 4)
    }
}
