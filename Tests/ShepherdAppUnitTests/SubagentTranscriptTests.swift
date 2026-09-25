import Foundation
import ShepherdProtocol
import ShepherdRemote
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

    /// Subagents, MobileSubagent: the live tail continues the run's last turn, under its lines at
    /// their spacing, rather than standing a turn apart.
    @MainActor
    @Test(arguments: [
        ("lines", AppLayout.activitySpacing),
        ("prose", AppLayout.turnItemSpacing),
        ("parent", AppLayout.inspectorTurnSpacing),
        ("nothing", AppLayout.inspectorTurnSpacing),
    ])
    func theLiveTailContinuesTheLastTurn(_ last: String, gap: CGFloat) {
        let read = NativeThreadMessage(entryID: "gap-r", role: "toolResult", blocks: [], toolName: "read", toolCallID: "gap-r",
                                       argumentsText: #"{"path":"A.swift"}"#, status: "complete")
        let turn: NativeTurn? = switch last {
        case "lines": nativeTurns([Self.message("gap-p"), read]).last
        case "prose": nativeTurns([read, Self.message("gap-q")]).last
        case "parent": nativeTurns([NativeThreadMessage(entryID: "gap-u", role: "user", blocks: [])]).last
        default: nil
        }
        #expect(RunLiveTail.gap(after: turn) == gap)
    }
}
