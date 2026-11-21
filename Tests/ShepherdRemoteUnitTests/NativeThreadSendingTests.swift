import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Holds a send's request until the test answers it, and says which operation it carried.
@MainActor
@Observable
private final class SendHold {
    var operation: UUID?
    var held = true
    var answer: (UUID) throws -> NativeThreadResult = { .accepted(operationID: $0) }
}

/// A captured send is a row of the transcript ("Sending…") from capture until the host answers, under the
/// id its accepted echo and the host's own row take, so the turn never doubles, remounts or moves the reader.
@Suite("Sending row", .timeLimit(.minutes(1)))
@MainActor
struct NativeThreadSendingTests {
    typealias F = Fixture
    let hi = F.assistant("hi", id: "a")

    private func started(_ snapshot: NativeThreadSnapshot, hold: SendHold, host: FakeHost)
        async -> (NativeThreadStore, Task<Void, Never>) {
        let store = manualStore()
        let request: NativeThreadStore.Request = { request in
            if case .send(_, _, let id, _, _, _, _, _, _) = request {
                _ = try host.handle(request)
                hold.operation = id
                await until { !hold.held }
                return try hold.answer(id)
            }
            return try host.handle(request)
        }
        let loop = Task { await store.run(request: request) }
        await until { store.ready }
        return (store, loop)
    }

    private static let withImages = ["send", "sendImages", "abort", "answer"]

    private func userRows(_ store: NativeThreadStore) -> [NativeThreadRow] { store.rows.filter(\.isUser) }
    private func userMessages(_ store: NativeThreadStore) -> [NativeThreadMessage] { store.displayedMessages.filter { $0.role == "user" } }

    @Test func aSendIsInTheTranscriptAsSendingAndItsEchoKeepsTheTurn() async throws {
        let hold = SendHold()
        let host = FakeHost(F.snapshot(actions: Self.withImages, messages: [hi]))
        let (store, loop) = await started(F.snapshot(messages: [hi]), hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        store.draft = "look at this"
        let image = NativeImage(mimeType: "image/png", data: Data([1]), name: "shot")
        let send = Task { await store.send(images: [image], delivery: .followUp) }
        await until { hold.operation != nil }
        let operation = try #require(hold.operation)
        let sending = try #require(userRows(store).last)
        #expect(sending.id == "pending:\(operation)" && store.draft.isEmpty && store.sentCount == 0)
        #expect(sending.turn.bubbles.map(\.text) == ["look at this"] && sending.turn.bubbles.first?.images == 1)
        #expect(sending.turn.bubbles.allSatisfy { $0.pending && $0.sending } && sending.turn.sendingNote == "Sending…")
        #expect(store.rows.last?.id == sending.id && store.pending.isEmpty)
        #expect(store.lastPromptAt == nil, "a send nobody accepted opens no turn")
        hold.held = false
        #expect(await send.value)
        let echoed = try #require(userRows(store).last)
        #expect(echoed.id == sending.id && userRows(store).count == 1, "the accepted echo is the same turn, never a second")
        #expect(echoed.turn.sendingNote == nil && echoed.turn.bubbles.allSatisfy { $0.pending && !$0.sending })
        #expect(echoed.turn.bubbles.first?.images == 1 && store.pending.count == 1)
        #expect(store.lastSendShownEarly && !store.lastSendQueued && store.sentCount == 1)
        // Then the host's own history for it: the turn keeps its identity again.
        var saved = F.user("look at this", id: "u1")
        saved.operationID = operation
        host.snapshot = F.snapshot(revision: 2, messages: [hi, saved])
        await store.refresh()
        #expect(userRows(store).map(\.id) == ["pending:\(operation)"] && store.pending.isEmpty)
        #expect(userRows(store).last?.turn.bubbles.allSatisfy { !$0.pending && !$0.sending } == true)
    }

    @Test func theHostsOwnRowForTheSendIsNeverDrawnBesideTheSendingRow() async throws {
        let hold = SendHold()
        let host = FakeHost(F.snapshot(messages: [hi]))
        let (store, loop) = await started(F.snapshot(messages: [hi]), hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        store.draft = "hello"
        let send = Task { await store.send(delivery: .followUp) }
        await until { hold.operation != nil }
        let operation = try #require(hold.operation)
        #expect(userRows(store).count == 1)
        // A poll lands first with the host's pending row (and, on another host, pi's saved message) for the same send.
        var hosted = F.user("hello", id: "pending:\(operation)")
        hosted.status = "pending"
        hosted.operationID = operation
        host.snapshot = F.snapshot(revision: 2, messages: [hi], provisional: [hosted], queue: NativeQueue())
        await store.refresh()
        #expect(userRows(store).map(\.id) == ["pending:\(operation)"], "one turn, not the host's and a sending one")
        #expect(store.displayedMessages.filter { $0.role == "user" }.count == 1)
        hold.held = false
        #expect(await send.value)
        #expect(userRows(store).map(\.id) == ["pending:\(operation)"])
    }

    /// The host's history already holds the message and the reply while its answer to the send is still on its way (or
    /// never comes): the "Sending…" copy goes, its record settles, and the composer is free. A host that never names the
    /// operation on its saved message (an older one) is matched by the words it saved after what the thread held.
    @Test(arguments: [true, false])
    func aDeliveredMessageReplacesItsSendingCopyWhateverTheHostCallsIt(_ named: Bool) async throws {
        let hold = SendHold()
        let host = FakeHost(F.snapshot(messages: [hi]))
        let (store, loop) = await started(F.snapshot(messages: [hi]), hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        store.draft = "hello"
        let send = Task { await store.send(delivery: .followUp) }
        await until { hold.operation != nil }
        let operation = try #require(hold.operation)
        #expect(userRows(store).count == 1 && store.busy)
        var saved = F.user("hello", id: "u1")
        if named { saved.operationID = operation }
        host.snapshot = F.snapshot(revision: 2, messages: [hi, saved, F.assistant("hi there", id: "a2")])
        await store.refresh()
        #expect(userRows(store).count == 1 && userRows(store).allSatisfy { $0.turn.sendingNote == nil },
                "the saved message is the only copy")
        // Only a message that names the send settles it. Words alone hide the duplicate row and keep the record for the host's answer.
        #expect(store.submissions.isEmpty == named && store.busy == !named)
        hold.held = false
        #expect(await send.value)
        #expect(userRows(store).count == 1 && store.pending.isEmpty && store.submissions.isEmpty && !store.busy)
    }

    /// Rule: a text match is display-only. Turn A (provisional) and held send B say the same words; A saves under a new untagged
    /// id, which matches B by text. B's record stays until the host answers, so a refusal still restores the draft.
    @Test func aTextMatchNeverDeletesTheRecordOfASendTheHostRefuses() async throws {
        let hold = SendHold()
        hold.answer = { _ in .failure(code: "rejected", message: "No") }
        let running = F.snapshot(running: true, actions: ["send", "abort"], messages: [hi],
                                 provisional: [F.user("continue", id: "provisional:a"), F.assistant("working", status: "streaming", id: "r")])
        let host = FakeHost(running)
        let (store, loop) = await started(running, hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        store.draft = "continue"
        let send = Task { await store.send(delivery: .followUp) }
        await until { hold.operation != nil }
        host.snapshot = F.snapshot(revision: 2, messages: [hi, F.user("continue", id: "u1"), F.assistant("done", id: "a2")])
        await store.refresh()
        #expect(store.submissions.first?.state == .sending, "words alone never settle the send")
        hold.held = false
        #expect(await send.value == false)
        let record = try #require(store.submissions.first)
        #expect(record.state == .failed)
        #expect(store.restoreSubmission(record.id) != nil && store.draft == "continue")
    }

    /// Rule: a text match counts only for rows after the send's capture anchor. A page of older history loaded afterwards
    /// never hides the accepted echo.
    @Test func anOlderPageLoadedAfterTheAcceptanceNeverHidesTheEcho() async throws {
        let hold = SendHold()
        hold.held = false
        let start = F.snapshot(messages: [hi], olderCursor: "a")
        let host = FakeHost(start)
        let (store, loop) = await started(start, hold: hold, host: host)
        defer { loop.cancel(); store.stop() }
        store.draft = "continue"
        #expect(await store.send(delivery: .followUp))
        let operation = try #require(hold.operation)
        #expect(store.pending.count == 1)
        host.next = [.success(.snapshot(value: F.snapshot(messages: [F.user("continue", id: "u0"), hi], olderCursor: nil)))]
        await store.loadOlder()
        #expect(store.messages.map(\.entryID) == ["u0", "a"])
        host.snapshot = F.snapshot(revision: 2, messages: [hi], olderCursor: "a")
        await store.refresh()
        #expect(store.pending.count == 1 && userRows(store).count == 2, "the older \"continue\" is not this send")
        var saved = F.user("continue", id: "u2")
        saved.operationID = operation
        host.snapshot = F.snapshot(revision: 3, messages: [hi, saved], olderCursor: "a")
        await store.refresh()
        #expect(store.pending.isEmpty, "a matching row after the anchor replaces the echo")
    }

    /// The command and its reply are saved while the answer is held. The acceptance then adds an echo, and a host that
    /// answers "unchanged" gives no snapshot to settle it with: it settles against the history already loaded.
    @Test func anEchoAddedByALateAcceptanceSettlesAgainstTheLoadedHistory() async throws {
        let hold = SendHold()
        let host = FakeHost(F.snapshot(messages: [hi]))
        let (store, loop) = await started(F.snapshot(messages: [hi]), hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        store.draft = "/review"
        let send = Task { await store.send(delivery: .followUp) }
        await until { hold.operation != nil }
        host.snapshot = F.snapshot(revision: 2, messages: [hi, F.user("Review the diff carefully", id: "u1"), F.assistant("done", id: "a2")])
        await store.refresh()
        #expect(store.submissions.first?.state == .sending, "an expanded command is only a guess until the host answers")
        // Before the answer: the thread shows the delivered message and its reply, no "Sending…" copy below them, and the record
        // that restores the draft is still there.
        #expect(userRows(store).map(\.id) == ["u1"] && store.rows.last?.isUser == false)
        #expect(store.displayedMessages.allSatisfy { $0.status != NativeThreadMessage.sendingStatus })
        #expect(store.submissions.count == 1 && store.recoverySnapshot.count == 1)
        host.answersUnchanged = true
        hold.held = false
        #expect(await send.value)
        #expect(store.pending.isEmpty && userRows(store).count == 1 && !store.busy)
    }

    /// An idle thread and a send that left no user message at all (a command that only ran): the finished turn ends the copy,
    /// the record stays.
    @Test func aFinishedTurnAfterAnIdleSendHidesItsCopyAndKeepsTheRecord() async throws {
        let hold = SendHold()
        let host = FakeHost(F.snapshot(messages: [hi]))
        let (store, loop) = await started(F.snapshot(messages: [hi]), hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        store.draft = "/review"
        let send = Task { await store.send(delivery: .followUp) }
        await until { hold.operation != nil }
        host.snapshot = F.snapshot(revision: 2, messages: [hi, F.assistant("done", id: "a2")])
        await store.refresh()
        #expect(userRows(store).isEmpty && store.recoverySnapshot.count == 1 && store.submissions.first?.state == .sending)
        hold.held = false
        #expect(await send.value)
    }

    /// Rule: a send that is not the composer's (a design's, Forge's) is captured too. An old host that is still running when it
    /// goes shows it below the reply; an earlier message with the same words does not hide it, and a snapshot taken while the
    /// thread still runs keeps it.
    @Test func aDirectSendWhileRunningIsNotHiddenByAnEarlierMessageWithTheSameWords() async throws {
        let hold = SendHold()
        hold.held = false
        let earlier = F.user("continue", id: "u0")
        let running = F.snapshot(running: true, actions: ["send", "abort"], messages: [earlier, hi],
                                 provisional: [F.assistant("working", status: "streaming", id: "r")])
        let host = FakeHost(running)
        let (store, loop) = await started(running, hold: hold, host: host)
        defer { loop.cancel(); store.stop() }
        await store.send(text: "continue")
        #expect(store.pending.count == 1)
        host.snapshot = F.snapshot(revision: 2, running: true, actions: ["send", "abort"], messages: [earlier, hi],
                                   provisional: [F.assistant("still working", status: "streaming", id: "r")])
        await store.refresh()
        #expect(store.pending.count == 1 && userRows(store).count == 2, "the earlier \"continue\" is not this send")
        host.snapshot = F.snapshot(revision: 3, messages: [earlier, hi, F.user("continue", id: "u2"), F.assistant("done", id: "a2")])
        await store.refresh()
        #expect(store.pending.isEmpty && userRows(store).count == 2 && userRows(store).first?.id == "u0")
    }

    /// Two identical sends, the first accepted and the second still waiting for its answer, and the history holds one message
    /// with those words: it replaces one copy (the first's), and the second send stays on screen with its record.
    @Test func oneDeliveredMessageReplacesOneOfTwoIdenticalSends() async throws {
        let hold = SendHold()
        hold.held = false
        let host = FakeHost(F.snapshot(messages: [hi]))
        host.answersUnchanged = true
        let (store, loop) = await started(F.snapshot(messages: [hi]), hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        store.draft = "continue"
        #expect(await store.send(delivery: .followUp))
        hold.held = true
        hold.operation = nil
        store.draft = "continue"
        let second = Task { await store.send(delivery: .followUp) }
        await until { hold.operation != nil }
        #expect(userMessages(store).count == 2 && store.pending.count == 1 && store.submissions.count == 1)
        host.snapshot = F.snapshot(revision: 2, messages: [hi, F.user("continue", id: "u1")])
        await store.refresh()
        #expect(userMessages(store).count == 2 && store.pending.isEmpty, "the saved message, and the second send still Sending…")
        #expect(userMessages(store).filter { $0.status == NativeThreadMessage.sendingStatus }.count == 1)
        #expect(store.submissions.first?.state == .sending)
        hold.held = false
        #expect(await second.value)
        #expect(userMessages(store).count == 2 && store.pending.count == 1, "the second send waits for a message of its own")
    }

    /// Turn A is still live (its message shown as it streams) when B, with the same words, is sent. The live message is not B
    /// landing: B stays on screen while the host holds it.
    @Test func aLiveMessageWithTheSameWordsDoesNotHideANewSend() async throws {
        let hold = SendHold()
        hold.held = false
        let live = F.snapshot(running: true, actions: ["send", "abort"], messages: [hi],
                              provisional: [F.user("continue", id: "provisional:a"), F.assistant("working", status: "streaming", id: "r")])
        let host = FakeHost(live)
        host.answersUnchanged = true
        let (store, loop) = await started(live, hold: hold, host: host)
        defer { loop.cancel(); store.stop() }
        store.draft = "continue"
        #expect(await store.send(delivery: .followUp))
        #expect(store.pending.count == 1)
        host.snapshot = F.snapshot(revision: 2, running: true, actions: ["send", "abort"], messages: [hi],
                                   provisional: [F.user("continue", id: "provisional:a"), F.assistant("more", status: "streaming", id: "r")])
        await store.refresh()
        #expect(store.pending.count == 1 && userRows(store).count == 2, "A is live, B is queued: two messages")
        // A is saved under a new id: that is A, not B. B's message comes after it.
        host.snapshot = F.snapshot(revision: 3, running: true, actions: ["send", "abort"],
                                   messages: [hi, F.user("continue", id: "u1")], provisional: [F.assistant("more", status: "streaming", id: "r")])
        await store.refresh()
        #expect(store.pending.count == 1 && userRows(store).count == 2)
        host.snapshot = F.snapshot(revision: 4, messages: [hi, F.user("continue", id: "u1"), F.assistant("done", id: "a1"),
                                                           F.user("continue", id: "u2"), F.assistant("again", id: "a2")])
        await store.refresh()
        #expect(store.pending.isEmpty && userRows(store).count == 2 && userRows(store).first?.id == "u1")
    }

    /// The same words sent before are not this send landing.
    @Test func anEarlierMessageWithTheSameWordsIsNotTheSendLanding() async throws {
        let hold = SendHold()
        let earlier = F.user("continue", id: "u0")
        let host = FakeHost(F.snapshot(messages: [earlier, hi]))
        let (store, loop) = await started(F.snapshot(messages: [earlier, hi]), hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        store.draft = "continue"
        let send = Task { await store.send(delivery: .followUp) }
        await until { hold.operation != nil }
        host.snapshot = F.snapshot(revision: 2, messages: [earlier, hi])
        await store.refresh()
        #expect(userRows(store).count == 2 && store.submissions.first?.state == .sending && store.busy)
        hold.held = false
        #expect(await send.value)
    }

    /// The history is replaced by a page that no longer holds the message the thread held at the send: the delivered
    /// message is still found, by the user messages that were not there before.
    @Test func aReplacementPageWithoutTheAnchorStillShowsTheSendLanding() async throws {
        let hold = SendHold()
        let earlier = F.user("continue", id: "u0")
        let host = FakeHost(F.snapshot(messages: [earlier, hi]))
        let (store, loop) = await started(F.snapshot(messages: [earlier, hi]), hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        store.draft = "continue"
        let send = Task { await store.send(delivery: .followUp) }
        await until { hold.operation != nil }
        host.snapshot = F.snapshot(revision: 2, messages: [F.assistant("later", id: "a1"), F.user("continue", id: "u1"), F.assistant("ok", id: "a2")])
        await store.refresh()
        #expect(userRows(store).map(\.id) == ["u1"], "the delivered message is the only copy")
        #expect(store.submissions.first?.state == .sending, "its words do not settle the send: the host's answer does")
        hold.held = false
        #expect(await send.value)
        #expect(store.submissions.isEmpty && store.pending.isEmpty && userRows(store).map(\.id) == ["u1"])
    }

    /// Another client's turn (it names its own operation) is not this send landing, so the record that restores a
    /// refused draft stays.
    @Test func anotherClientsTurnDoesNotSettleThisSend() async throws {
        let hold = SendHold()
        let host = FakeHost(F.snapshot(messages: [hi]))
        let (store, loop) = await started(F.snapshot(messages: [hi]), hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        store.draft = "hello"
        let send = Task { await store.send(delivery: .followUp) }
        await until { hold.operation != nil }
        for words in ["hello", "something else"] {
            var theirs = F.user(words, id: "u1")
            theirs.operationID = UUID()
            host.snapshot = F.snapshot(revision: 2, messages: [hi, theirs, F.assistant("done", id: "a2")])
            await store.refresh()
            #expect(store.submissions.first?.state == .sending && store.busy, "\"\(words)\": still this send's to settle")
        }
        hold.held = false
        #expect(await send.value)
    }

    /// An old host (no queue) is still on turn A when B is sent. A finishing saves an untagged message with a reply: that is
    /// not B landing, so B's record stays and a later refusal still restores it.
    @Test func anotherTurnFinishingDoesNotSettleASendTheHostLaterRefuses() async throws {
        let hold = SendHold()
        hold.answer = { _ in .failure(code: "rejected", message: "No") }
        let running = F.snapshot(running: true, actions: ["send", "abort"], messages: [hi],
                                 provisional: [F.user("first", id: "provisional:a"), F.assistant("working", status: "streaming", id: "r")])
        let host = FakeHost(running)
        let (store, loop) = await started(running, hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        store.draft = "second"
        let send = Task { await store.send(delivery: .followUp) }
        await until { hold.operation != nil }
        host.snapshot = F.snapshot(revision: 2, messages: [hi, F.user("first", id: "u1"), F.assistant("done", id: "a2")])
        await store.refresh()
        #expect(store.submissions.first?.state == .sending && store.busy, "turn A ending is no evidence B was delivered")
        hold.held = false
        #expect(await send.value == false)
        let record = try #require(store.submissions.first)
        #expect(record.state == .failed)
        #expect(store.restoreSubmission(record.id) != nil && store.draft == "second")
    }

    /// An accepted echo on a host without a queue is hidden only by a message the thread did not hold when the send was
    /// captured: an earlier one with the same words, or another client's, leaves it showing.
    @Test func anAcceptedEchoIsNotHiddenByAnEarlierMessageWithTheSameWords() async throws {
        let hold = SendHold()
        hold.held = false
        let earlier = F.user("continue", id: "u0")
        let start = F.snapshot(messages: [earlier, hi])
        let host = FakeHost(start)
        let (store, loop) = await started(start, hold: hold, host: host)
        defer { loop.cancel(); store.stop() }
        store.draft = "continue"
        #expect(await store.send(delivery: .followUp))
        let operation = try #require(hold.operation)
        #expect(store.pending.count == 1)
        host.snapshot = F.snapshot(revision: 2, messages: [earlier, hi])
        await store.refresh()
        #expect(store.pending.count == 1 && userRows(store).count == 2, "the earlier \"continue\" is not this send")
        var theirs = F.user("continue", id: "u1")
        theirs.operationID = UUID()
        host.snapshot = F.snapshot(revision: 3, messages: [earlier, hi, theirs])
        await store.refresh()
        #expect(store.pending.count == 1, "another client's message is not this send")
        var saved = F.user("continue", id: "u2")
        saved.operationID = operation
        host.snapshot = F.snapshot(revision: 4, messages: [earlier, hi, theirs, saved])
        await store.refresh()
        #expect(store.pending.isEmpty, "its own message replaces the echo")
    }

    /// The composer's images go when the store captures the send, while the host has not answered, not after: a send the store
    /// never captured keeps them.
    @Test func theComposerLetsGoOfItsImagesAtCaptureNotAtTheAnswer() async throws {
        let hold = SendHold()
        let host = FakeHost(F.snapshot(messages: [hi]))
        let (store, loop) = await started(F.snapshot(messages: [hi]), hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        var captures = 0
        #expect(await store.send(images: [], delivery: .followUp) { captures += 1 } == false, "nothing to send, nothing captured")
        #expect(captures == 0)
        store.draft = "look"
        let send = Task { await store.send(images: [], delivery: .followUp) { captures += 1 } }
        await until { hold.operation != nil }
        #expect(captures == 1, "captured before the host answered")
        hold.held = false
        #expect(await send.value)
        #expect(captures == 1)
    }

    /// A send the host took, whose saved message reads differently from the words sent (a command or skill pi expanded):
    /// once its turn is over the echo does not wait for a match that never comes.
    @Test(arguments: [true, false])
    func anAcceptedEchoDoesNotOutliveItsSettledTurn(_ hostQueues: Bool) async throws {
        let hold = SendHold()
        hold.held = false
        let start = F.snapshot(messages: [hi], queue: hostQueues ? NativeQueue() : nil)
        let host = FakeHost(start)
        let (store, loop) = await started(start, hold: hold, host: host)
        defer { loop.cancel(); store.stop() }
        store.draft = "/review"
        #expect(await store.send(delivery: .followUp))
        #expect(store.pending.count == (hostQueues ? 0 : 1), "a host with a queue shows its own row for it")
        host.snapshot = F.snapshot(revision: 2, messages: [hi, F.user("Review the diff carefully", id: "u1"), F.assistant("done", id: "a2")],
                                   queue: hostQueues ? NativeQueue() : nil)
        await store.refresh()
        await store.refresh()
        #expect(store.pending.isEmpty, "the turn settled; nothing is still pending")
        #expect(userRows(store).count == 1 && !store.busy)
    }

    @Test(arguments: [NativeThreadDelivery.followUp, .steer])
    func aSendWhileRunningWaitsBelowTheReplyAndLeavesForUpNext(_ delivery: NativeThreadDelivery) async throws {
        let reply = F.assistant("working", status: "streaming", id: "r")
        let snapshot = F.snapshot(running: true, actions: ["send", "abort", "queue"], messages: [F.user("start", id: "u0")],
                                  provisional: [reply], queue: NativeQueue())
        let hold = SendHold()
        let host = FakeHost(snapshot)
        let (store, loop) = await started(snapshot, hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        let live = try #require(store.liveRowID)
        store.draft = "and then this"
        let send = Task { await store.send(delivery: delivery) }
        await until { hold.operation != nil }
        let operation = try #require(hold.operation)
        let sending = try #require(store.rows.last)
        #expect(sending.id == "pending:\(operation)" && sending.turn.sendingNote == "Sending…")
        #expect(store.liveRowID == live, "the reply still streaming keeps its row")
        #expect(store.displayedMessages.last?.status == NativeThreadMessage.sendingStatus)
        hold.held = false
        #expect(await send.value)
        // The host holds it in Up next: it is not a row of the thread.
        #expect(!store.rows.contains { $0.id == "pending:\(operation)" } && store.rows.last?.id == live)
        #expect(store.liveRowID == live && store.pending.isEmpty)
        #expect(store.lastSendShownEarly == false)
        #expect(store.lastSendQueued == (delivery == .followUp))
    }

    @Test func aRefusalTakesTheRowOutAndKeepsEverythingForRestoreWithoutResending() async throws {
        let hold = SendHold()
        hold.answer = { _ in .failure(code: "rejected", message: "No") }
        let host = FakeHost(F.snapshot(actions: Self.withImages, messages: [hi]))
        let (store, loop) = await started(F.snapshot(messages: [hi]), hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        let image = NativeImage(mimeType: "image/png", data: Data([1, 2]), name: "kept")
        store.draft = "keep this"
        let send = Task { await store.send(images: [image], delivery: .followUp) }
        await until { hold.operation != nil }
        #expect(userRows(store).count == 1)
        hold.held = false
        #expect(await send.value == false)
        #expect(userRows(store).isEmpty && store.pending.isEmpty && store.sentCount == 0)
        let record = try #require(store.submissions.first)
        #expect(record.state == .failed && record.images == [image])
        #expect(host.actions.count == 1, "a refusal is never resent")
        let restored = try #require(store.restoreSubmission(record.id))
        #expect(store.draft == "keep this" && restored.images == [image] && userRows(store).isEmpty)
        #expect(host.actions.count == 1)
    }

    @Test(arguments: [true, false])
    func anUnknownOutcomeLeavesTheTranscriptAsUncertainAndNeverResends(_ thrown: Bool) async throws {
        let hold = SendHold()
        hold.answer = { _ in
            if thrown { throw RemoteHostClientError.outcomeUnknown(message: "Check the thread") }
            return .failure(code: "outcome_unknown", message: "Check the thread")
        }
        let host = FakeHost(F.snapshot(messages: [hi]))
        let (store, loop) = await started(F.snapshot(messages: [hi]), hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        store.draft = "maybe arrived"
        let send = Task { await store.send(delivery: .followUp) }
        await until { hold.operation != nil }
        #expect(userRows(store).count == 1)
        hold.held = false
        #expect(await send.value == false)
        #expect(userRows(store).isEmpty && store.submissions.first?.state == .uncertain)
        #expect(store.restoreSubmission(store.submissions[0].id) == nil && store.draft.isEmpty)
        #expect(host.actions.count == 1)
    }

    @Test func leavingTheThreadMidSendMakesItUncertainAndDropsItsRow() async throws {
        let hold = SendHold()
        let host = FakeHost(F.snapshot(messages: [hi]))
        let (store, loop) = await started(F.snapshot(messages: [hi]), hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        store.draft = "in flight"
        let send = Task { await store.send(delivery: .followUp) }
        await until { hold.operation != nil }
        #expect(userRows(store).count == 1)
        store.suspend()
        #expect(store.submissions.first?.state == .uncertain && userRows(store).isEmpty)
        hold.held = false
        _ = await send.value
        #expect(userRows(store).isEmpty && host.actions.count == 1)
    }

    @Test func aDirectSendWithNoCapturedRecordDrawsNoSendingRow() async throws {
        let hold = SendHold()
        let host = FakeHost(F.snapshot(messages: [hi]))
        let (store, loop) = await started(F.snapshot(messages: [hi]), hold: hold, host: host)
        defer { hold.held = false; loop.cancel(); store.stop() }
        let send = Task { await store.send(text: "from a design") }
        await until { hold.operation != nil }
        #expect(userRows(store).isEmpty && store.submissions.isEmpty)
        hold.held = false
        await send.value
        #expect(userRows(store).count == 1 && store.lastSendShownEarly == false)
    }

    @Test func aSendingMessageReadsAsPendingWithItsNote() {
        var message = F.user("hi", id: "pending:x")
        message.status = NativeThreadMessage.sendingStatus
        let bubble = nativeUserBubbles(message)
        #expect(bubble.map(\.pending) == [true] && bubble.map(\.sending) == [true])
        message.status = "pending"
        #expect(nativeUserBubbles(message).map(\.sending) == [false])
        let turn = NativeTurn(id: "t", isUser: true, messages: [message])
        #expect(turn.sendingNote == nil)
    }

    @Test func aSendWhoseTurnIsAlreadyThereLeavesNothingToWaitFor() {
        var follower = NativeScrollFollower()
        follower.observe(distanceFromBottom: 600, userIntent: true)
        follower.sent(queued: false, turnPresent: true)
        #expect(follower.sticky && follower.followingSentTurn && !follower.awaitingSentTurn)
        #expect(follower.userTurnArrived() == false, "a later user turn is not this send landing")
        follower.sent(queued: false)
        #expect(follower.awaitingSentTurn && follower.userTurnArrived())
    }
}
