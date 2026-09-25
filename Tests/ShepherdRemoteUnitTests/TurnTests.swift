import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

@Suite("Turns and turn items")
struct TurnTests {
    typealias F = Fixture

    @Test func consecutiveNonUserMessagesFormOneAgentTurn() {
        let user = F.user(id: "u1"), prose = F.assistant("Doing it.", id: "p"), read = F.tool("read", id: "r")
        let turns = nativeTurns([user, prose, read, F.user(id: "u2")])
        #expect(turns.map(\.isUser) == [true, false, true])
        #expect(turns.map(\.id) == ["u1", "u1/reply", "u2"], "a user turn is its first entry; a reply is the turn it answers")
        #expect(turns[1].messages == [prose, read])
    }

    @Test func aReplyKeepsItsIdentityWhenPiPersistsIt() {
        let live = nativeTurns([F.user(id: "u1"), F.assistant("streaming", id: "provisional:assistant:1")])
        let saved = nativeTurns([F.user(id: "u1"), F.assistant("streaming", id: "entry-7")])
        #expect(live.map(\.id) == saved.map(\.id))
    }

    @Test func aSavedPromptKeepsTheIdentityOfTheEchoItReplaced() {
        let turns = nativeTurns([F.user(id: "saved"), F.assistant("reply")], aliases: ["saved": "pending:1"])
        #expect(turns.map(\.id) == ["pending:1", "pending:1/reply"])
    }

    @Test func aReplyAtTheStartOfAPagedHistoryIsItsFirstEntry() {
        #expect(nativeTurns([F.assistant("tail of an older turn", id: "a0"), F.user(id: "u")]).map(\.id) == ["a0", "u"])
    }

    @Test func consecutiveUserMessagesShareATurn() {
        #expect(nativeTurns([F.user(), F.user()]).count == 1)
    }

    /// Real sessions carry pi system entries and blank assistant messages; neither is readable.
    @Test func systemEntriesAndBlankMessagesAreDropped() {
        let turns = nativeTurns([
            F.message("system", "prompt update"), F.user(id: "u"),
            F.assistant("", id: "blank"), F.assistant("   \n", id: "space"), F.assistant("Done.", id: "r"),
        ])
        #expect(turns.map(\.isUser) == [true, false])
        #expect(turns[1].messages.map(\.entryID) == ["r"])
    }

    @Test func anEmptyUserMessageStillOpensATurn() {
        #expect(nativeTurns([F.user("", id: "u0"), F.assistant("hi")]).count == 2)
    }

    @Test func blankMessagesWithSomethingToShowAreKept() {
        let image = NativeThreadMessage(entryID: "i", role: "user", blocks: [NativeThreadBlock(kind: .unsupportedImage, text: "")])
        let truncated = NativeThreadMessage(entryID: "t", role: "assistant", blocks: [], truncated: true)
        let failed = NativeThreadMessage(entryID: "e", role: "assistant", blocks: [], status: "error")
        let toolless = NativeThreadMessage(entryID: "tr", role: "toolResult", blocks: [])
        let turns = nativeTurns([F.user(id: "u"), truncated, failed, toolless, image])
        #expect(turns.flatMap(\.messages).map(\.entryID) == ["u", "t", "e", "tr", "i"])
    }

    @Test func consecutiveToolsCollapseAndProseSplitsThem() {
        let prose = F.assistant("Doing it.", thinking: "hmm")
        let a = F.tool("read"), b = F.tool("edit"), c = F.tool("bash")
        #expect(nativeTurnItems([prose, a, b, prose, c]) == [
            .thinking("hmm"), .prose("Doing it."), .tools([a, b]), .thinking("hmm"), .prose("Doing it."), .tools([c]),
        ])
    }

    @Test func repeatedIdenticalProviderFailuresFoldIntoACount() {
        let failed = { F.assistant("503 no available server", status: "error") }
        #expect(nativeTurnItems([failed(), failed(), F.assistant("Done.")]) == [
            .error("503 no available server", count: 2), .prose("Done."),
        ])
        #expect(nativeTurnItems([failed(), F.assistant("other", status: "error")]).count == 2)
        #expect(nativeTurnItems([NativeThreadMessage(entryID: "e", role: "assistant", blocks: [], status: "error")])
            == [.error("Request failed", count: 1)])
    }

    @Test func otherRolesBecomeNotesNamedByTheirRole() {
        #expect(nativeTurnItems([F.message("custom", "Workflow w1: done")]) == [.note("Workflow w1: done")])
        #expect(nativeTurnItems([F.message("branch_summary", "Went left")]) == [.note("branch summary · Went left")])
    }

    @Test func imagesAndTruncationBecomeNotes() {
        let image = NativeThreadMessage(entryID: "i", role: "user", blocks: [NativeThreadBlock(kind: .unsupportedImage, text: "")])
        let cut = NativeThreadMessage(entryID: "c", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "partial")], truncated: true)
        #expect(nativeTurnItems([image, cut]) == [.note("Image attached"), .prose("partial"), .note("Output truncated")])
    }

    @Test func toolGroupSummaryCountsInFirstSeenOrder() {
        let read = F.tool("read"), edit = F.tool("edit"), bash = F.tool("bash")
        #expect(nativeToolGroupSummary([read]) == "1 tool call · read 1")
        #expect(nativeToolGroupSummary([bash, read, bash, edit, edit, edit]) == "6 tool calls · bash 2 · read 1 · edit 3")
        let unnamed = NativeThreadMessage(entryID: "x", role: "toolResult", blocks: [])
        #expect(nativeToolGroupSummary([unnamed, unnamed]) == "2 tool calls · result 2")
        #expect(nativeToolGroupSummary([]) == "0 tool calls")
    }

    @Test func workingLabelPrefersTheRunningToolThenStreamingThinking() {
        #expect(nativeWorkingLabel([]) == "Working…")
        #expect(nativeWorkingLabel([F.assistant("", thinking: "hm", status: "streaming")]) == "Thinking…")
        #expect(nativeWorkingLabel([F.assistant("answer", thinking: "hm")]) == "Working…")
        #expect(nativeWorkingLabel([F.assistant("", thinking: "hm"), F.tool("bash", status: "running")]) == "Running bash…")
        #expect(nativeWorkingLabel([F.tool("bash", status: "complete")]) == "Working…")
    }

    @Test func touchedPathsAreTheCurrentTurnsEditsAndWritesWhileRunning() {
        let messages = [
            F.tool("edit", args: #"{"path":"old.swift"}"#), F.user(),
            F.tool("edit", args: #"{"path":"/repo/a.swift"}"#, status: "running"),
            F.tool("write", args: #"{"path":"b.swift","content":"x"}"#),
            F.tool("read", args: #"{"path":"c.swift"}"#),
            F.tool("edit", args: #"{"path":""}"#), F.tool("edit", args: "not json"),
        ]
        #expect(nativeTouchedPaths(messages, running: true) == ["/repo/a.swift", "b.swift"])
        #expect(nativeTouchedPaths(messages, running: false).isEmpty)
    }

    @Test func withoutAUserMessageTheWholeHistoryIsTheTurn() {
        #expect(nativeTouchedPaths([F.tool("write", args: #"{"path":"x"}"#)], running: true) == ["x"])
    }

    // MARK: Steers and the queue

    static func steered(_ text: String, id: String) -> NativeThreadMessage {
        var message = Fixture.user(text, id: id)
        message.origin = .steered
        return message
    }

    /// A steer stays in the reply it steered, where pi read it: the reply keeps its identity,
    /// one footer, and one changes card.
    @Test func aSteerStaysInsideTheReplyItSteered() {
        let read = F.tool("read", id: "r"), steer = Self.steered("use tables", id: "s"), after = F.assistant("Switching.", id: "a")
        let turns = nativeTurns([F.user(id: "u"), read, steer, after, F.user(id: "u2")])
        #expect(turns.map(\.id) == ["u", "u/reply", "u2"])
        #expect(turns[1].messages == [read, steer, after])
    }

    /// Only the host's mark makes a steer: a tool can end pi's run by itself, so a prompt after
    /// a tool result is still a new turn.
    @Test func aUserMessageAfterAToolResultIsANewTurnUnlessMarkedSteered() {
        #expect(nativeTurns([F.user(id: "u"), F.tool("read"), F.user(id: "u2")]).map(\.id) == ["u", "u/reply", "u2"])
        #expect(nativeTurns([Self.steered("x", id: "s"), F.assistant("hi")]).map(\.isUser) == [true, false],
                "with no reply above it, a steer opens a turn")
    }

    @Test func aSteerDoesNotStartANewTurnForTouchedPaths() {
        let messages = [F.user(), F.tool("edit", args: #"{"path":"a.swift"}"#), Self.steered("go on", id: "s"),
                        F.tool("write", args: #"{"path":"b.swift","content":"x"}"#)]
        #expect(nativeTouchedPaths(messages, running: true) == ["a.swift", "b.swift"])
    }

    /// A delivery from the queue shows one bubble per queued message, each at the time it was
    /// sent; a message sent straight to pi is one bubble at pi's time.
    @Test func aQueueDeliveryShowsEachPartAsItsOwnBubble() {
        var delivered = F.user("one\n\ntwo", id: "u")
        delivered.timestamp = 30
        delivered.origin = .queue(parts: [NativeQueuePart(text: "one", sentAt: 10), NativeQueuePart(text: "two", sentAt: 20, images: 1)])
        let turn = nativeTurns([delivered])[0]
        #expect(turn.fromQueue == 2)
        #expect(turn.bubbles == [
            NativeUserBubble(id: "u/0", text: "one", sentAt: 10, images: 0, pending: false),
            NativeUserBubble(id: "u/1", text: "two", sentAt: 20, images: 1, pending: false),
        ])
        var direct = F.user("hi", id: "d")
        direct.timestamp = 5
        let plain = nativeTurns([direct])[0]
        #expect(plain.fromQueue == nil)
        #expect(plain.bubbles == [NativeUserBubble(id: "d", text: "hi", sentAt: 5, images: 0, pending: false)])
        #expect(nativeTurns([F.user(id: "u0"), F.assistant("r")])[1].bubbles.isEmpty, "a reply has none")
    }
}
