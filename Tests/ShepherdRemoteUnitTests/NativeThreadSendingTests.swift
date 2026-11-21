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
        #expect(store.submissions.isEmpty, "a delivered send is not still sending")
        #expect(!store.busy, "the composer is not left spinning for an answer the thread already has")
        hold.held = false
        #expect(await send.value)
        #expect(userRows(store).count == 1 && store.pending.isEmpty && store.submissions.isEmpty)
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
        #expect(store.submissions.isEmpty && !store.busy, "the delivered message settles the send")
        #expect(userRows(store).map(\.id) == ["u1"])
        hold.held = false
        #expect(await send.value)
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
