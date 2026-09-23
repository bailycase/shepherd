import Foundation
import ShepherdProtocol
import Testing
@testable import ShepherdApp

/// The inspector's transcript pages: a reload keeps what the reader already paged in.
@Suite("Subagent transcript")
struct SubagentTranscriptTests {
    private static func message(_ id: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: id)])
    }

    @Test func aFreshNewestPageKeepsTheOlderPagesAlreadyLoaded() {
        let current = ["a", "b", "c", "d"].map(Self.message)
        let page = NativeSubagentTranscript(runID: "r", messages: ["c", "d", "e"].map(Self.message), olderCursor: "c", earlierCount: 2)
        let spliced = SubagentTranscriptModel.splice(current, newest: page)
        #expect(spliced.messages.map(\.entryID) == ["a", "b", "c", "d", "e"])
        #expect(!spliced.replaced)
    }

    @Test func aPageThatDoesNotOverlapReplacesTheTranscript() {
        let current = ["a", "b"].map(Self.message)
        let page = NativeSubagentTranscript(runID: "r", messages: ["x", "y"].map(Self.message))
        let spliced = SubagentTranscriptModel.splice(current, newest: page)
        #expect(spliced.messages.map(\.entryID) == ["x", "y"])
        #expect(spliced.replaced)
    }
}
