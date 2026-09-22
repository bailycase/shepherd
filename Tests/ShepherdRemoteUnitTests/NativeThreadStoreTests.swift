import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// A scripted host for `NativeThreadStore`. Snapshot requests serve `snapshot` unless a result
/// is queued in `next`; actions answer through `action`. Every request is recorded.
@MainActor
final class FakeHost {
    var snapshot: NativeThreadSnapshot
    var next: [Result<NativeThreadResult, Error>] = []
    var action: (NativeThreadRequest) throws -> NativeThreadResult = { _ in .failure(code: "x", message: "unscripted") }
    private(set) var requests: [NativeThreadRequest] = []
    fileprivate var onServed: (() -> Void)?

    init(_ snapshot: NativeThreadSnapshot) { self.snapshot = snapshot }

    func handle(_ request: NativeThreadRequest) throws -> NativeThreadResult {
        requests.append(request)
        if !next.isEmpty { return try next.removeFirst().get() }
        guard case .snapshot = request else { return try action(request) }
        defer { onServed?(); onServed = nil }
        return .snapshot(value: snapshot)
    }

    var actions: [NativeThreadRequest] {
        requests.filter { if case .snapshot = $0 { return false } else { return true } }
    }

    /// Accept every action with its own operation id.
    func acceptAll() {
        action = { request in
            switch request {
            case .send(_, _, let id, _, _, _), .abort(_, _, let id), .answer(_, _, let id, _, _),
                 .setModel(_, _, let id, _), .setThinking(_, _, let id, _), .subagentCommand(_, _, let id, _, _, _, _):
                return .accepted(operationID: id)
            default:
                return .failure(code: "x", message: "unexpected")
            }
        }
    }
}

/// Starts the store's run loop and returns once the first snapshot has been applied. The loop
/// then sleeps for its poll interval (2s while idle), far longer than any test here.
@MainActor
func start(_ store: NativeThreadStore, _ host: FakeHost) async -> Task<Void, Never> {
    var task: Task<Void, Never>?
    await withCheckedContinuation { (served: CheckedContinuation<Void, Never>) in
        host.onServed = { served.resume() }
        task = Task { await store.run { try host.handle($0) } }
    }
    return task!
}

@Suite("NativeThreadStore")
@MainActor
struct NativeThreadStoreTests {
    typealias F = Fixture
    let hi = F.assistant("hi", id: "a")

    private func started(_ snapshot: NativeThreadSnapshot? = nil) async -> (NativeThreadStore, FakeHost, Task<Void, Never>) {
        let host = FakeHost(snapshot ?? F.snapshot(messages: [hi]))
        let store = NativeThreadStore()
        let task = await start(store, host)
        return (store, host, task)
    }

    // MARK: Loading

    @Test func theFirstRequestIsAFreshSnapshot() async throws {
        let (store, host, task) = await started()
        defer { task.cancel() }
        #expect(host.requests == [.snapshot()])
        #expect(store.ready && store.snapshot?.revision == 1 && store.messages == [hi])
    }

    @Test func laterRefreshesAskOnlyForChangesSinceTheCurrentRevision() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        await store.refresh()
        #expect(host.requests.last == .snapshot(expectedSessionID: "s", afterRevision: 1))
    }

    @Test func anOlderRevisionOfTheSameSessionIsIgnored() async {
        let (store, host, task) = await started(F.snapshot(revision: 5, messages: [hi]))
        defer { task.cancel() }
        host.snapshot = F.snapshot(revision: 4, messages: [])
        await store.refresh()
        #expect(store.snapshot?.revision == 5 && store.messages == [hi])
    }

    @Test func unchangedKeepsTheThreadAsItIs() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.next = [.success(.unchanged(piSessionID: "s", generation: "g", revision: 1))]
        await store.refresh()
        #expect(store.ready && store.messages == [hi] && host.requests.count == 2)
    }

    @Test func unchangedForAnotherSessionForcesAFreshSnapshot() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.next = [.success(.unchanged(piSessionID: "other", generation: "g", revision: 1))]
        await store.refresh()
        #expect(host.requests.suffix(2) == [.snapshot(expectedSessionID: "s", afterRevision: 1), .snapshot()])
        #expect(store.ready)
    }

    @Test func aFailureShowsItsMessageAndMarksTheThreadNotReady() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.next = [.success(.failure(code: "boom", message: "Agent is gone"))]
        await store.refresh()
        #expect(!store.ready && store.loadError == "Agent is gone")
        #expect(!store.supports("send"))
    }

    @Test func aStaleSessionRefetchesFresh() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.next = [.success(.failure(code: "stale_session", message: "moved"))]
        await store.refresh()
        #expect(host.requests.last == .snapshot())
        #expect(store.ready && store.loadError == nil)
    }

    @Test func aThrownErrorBecomesTheLoadError() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.next = [.failure(RemoteHostClientError.disconnected)]
        await store.refresh()
        #expect(!store.ready && store.loadError == "connection closed")
    }

    @Test func anUnexpectedResultIsReported() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.next = [.success(.accepted(operationID: UUID()))]
        await store.refresh()
        #expect(!store.ready && store.loadError == "Unexpected thread response. Refresh to try again.")
    }

    // MARK: Sending

    @Test func aRejectedSendKeepsTheDraftAndShowsWhy() async throws {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.action = { _ in .failure(code: "busy", message: "not yet") }
        store.draft = "do the thing"
        await store.send()
        #expect(store.draft == "do the thing" && store.pending.isEmpty && store.notice == "not yet")
        guard case .send(let session, let generation, _, let text, let delivery, let images) = try #require(host.actions.first) else {
            Issue.record("expected a send"); return
        }
        #expect(session == "s" && generation == "g" && text == "do the thing" && delivery == .followUp && images == nil)
        #expect(host.requests.last == .snapshot(), "every action ends with a fresh snapshot")
        #expect(!store.busy)
    }

    @Test func anAcknowledgementForAnotherOperationIsNotAnAcceptance() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.action = { _ in .accepted(operationID: UUID()) }
        store.draft = "do the thing"
        await store.send()
        #expect(store.pending.isEmpty && store.draft == "do the thing")
        #expect(store.notice?.hasPrefix("Action outcome unknown.") == true)
    }

    @Test func anAcceptedSendClearsTheDraftAndEchoesAtTheTail() async throws {
        let live = F.assistant("streaming reply", id: "live")
        let (store, host, task) = await started(F.snapshot(messages: [hi], provisional: [live]))
        defer { task.cancel() }
        host.acceptAll()
        store.draft = "do the thing"
        await store.send()
        guard case .send(_, _, let operation, _, _, _) = try #require(host.actions.first) else { Issue.record("expected a send"); return }
        #expect(store.draft.isEmpty && store.sentCount == 1 && store.notice == nil)
        let echo = try #require(store.pending.first)
        #expect(echo.entryID == "pending:\(operation.uuidString)" && echo.role == "user" && echo.status == "pending")
        #expect(store.displayedMessages.map(\.entryID) == ["a", echo.entryID, "live"], "history, then the echo, then the live reply")
    }

    @Test func theEchoLeavesOnlyWhenPiPersistsTheSameText() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.acceptAll()
        store.draft = "do the thing"
        await store.send()
        host.snapshot = F.snapshot(revision: 2, messages: [hi, F.user("something else")])
        await store.refresh()
        #expect(store.pending.count == 1)
        host.snapshot = F.snapshot(revision: 3, messages: [hi, F.user("do the thing\n", id: "u")])
        await store.refresh()
        #expect(store.pending.isEmpty && store.displayedMessages.map(\.entryID) == ["a", "u"])
    }

    @Test func aSessionChangeDiscardsEchoes() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.acceptAll()
        store.draft = "again"
        await store.send()
        #expect(store.pending.count == 1)
        host.snapshot = F.snapshot(session: "other", revision: 1)
        await store.refresh(fresh: true)
        #expect(store.pending.isEmpty)
    }

    @Test func sendingRetryTextLeavesTheDraftAlone() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.acceptAll()
        store.draft = "half-written"
        await store.send(text: "retry this")
        #expect(store.draft == "half-written" && store.pending.count == 1 && store.sentCount == 1)
    }

    @Test func nothingIsSentForABlankDraftOrWhenSendIsUnsupported() async {
        let (store, host, task) = await started(F.snapshot(actions: ["abort"]))
        defer { task.cancel() }
        store.draft = "hello"
        await store.send()
        let (other, otherHost, otherTask) = await started()
        defer { otherTask.cancel() }
        other.draft = "  \n "
        await other.send()
        #expect(host.actions.isEmpty && otherHost.actions.isEmpty)
    }

    @Test(arguments: [(["send"], false), (["send", "sendImages"], true)])
    func imagesTravelOnlyWhenTheHostAcceptsThem(actions: [String], attached: Bool) async throws {
        let (store, host, task) = await started(F.snapshot(actions: actions))
        defer { task.cancel() }
        host.acceptAll()
        store.draft = "look"
        await store.send(images: [NativeImage(mimeType: "image/png", data: Data([1]))])
        #expect(try #require(host.actions.first).images.isEmpty == !attached)
    }

    @Test func steeringUsesTheSelectedDelivery() async throws {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.acceptAll()
        store.delivery = .steer
        store.draft = "focus"
        await store.send()
        guard case .send(_, _, _, _, let delivery, _) = try #require(host.actions.first) else { Issue.record("expected a send"); return }
        #expect(delivery == .steer)
    }

    @Test func anUnknownOutcomeErrorAsksTheUserToCheckBeforeRetrying() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.action = { _ in throw RemoteHostClientError.outcomeUnknown(message: "lost") }
        store.draft = "x"
        await store.send()
        #expect(store.notice == "Action outcome unknown. Refresh and check the thread before trying again. Nothing will be resent automatically.")
        #expect(store.draft == "x")
    }

    // MARK: Other actions

    @Test func modelAndThinkingChangesSkipTheCurrentValue() async {
        let (store, host, task) = await started(F.snapshot(model: "p/current"))
        defer { task.cancel() }
        host.acceptAll()
        await store.setModel("p/current")
        #expect(host.actions.isEmpty)
        await store.setModel("p/other")
        await store.setThinking("high")
        guard host.actions.count == 2, case .setModel(_, _, _, let model) = host.actions[0],
              case .setThinking(_, _, _, let level) = host.actions[1] else { Issue.record("\(host.actions)"); return }
        #expect(model == "p/other" && level == "high")
    }

    @Test func answersGoOnlyToAnAvailableDialogOfTheCurrentSession() async {
        let dialogs = [NativeThreadDialog(id: "ok", kind: .confirm, title: "Sure?"),
                       NativeThreadDialog(id: "ext", kind: .editor, title: "Edit", unavailable: "external-editor")]
        let (store, host, task) = await started(F.snapshot(dialogs: dialogs))
        defer { task.cancel() }
        host.acceptAll()
        await store.answer(dialogID: "ext", sessionID: "s", generation: "g", answer: .cancel)
        await store.answer(dialogID: "missing", sessionID: "s", generation: "g", answer: .cancel)
        await store.answer(dialogID: "ok", sessionID: "old", generation: "g", answer: .cancel)
        #expect(host.actions.isEmpty)
        await store.answer(dialogID: "ok", sessionID: "s", generation: "g", answer: .confirm(value: true))
        guard case .answer(_, _, _, let dialog, let answer)? = host.actions.first else { Issue.record("expected an answer"); return }
        #expect(dialog == "ok" && answer == .confirm(value: true))
    }

    @Test func stopAllCancelsEveryLiveSubagentThenAbortsTheTurn() async {
        let runs = [F.run("live1"), F.run("done", state: "complete"), F.run("live2", state: "queued")]
        let (store, host, task) = await started(F.snapshot(subagents: runs))
        defer { task.cancel() }
        host.acceptAll()
        await store.abortAll()
        let sent = host.actions.map { request -> String in
            switch request {
            case .subagentCommand(_, _, _, let runID, let action, _, _): return "\(action.rawValue) \(runID)"
            case .abort: return "abort"
            default: return "other"
            }
        }
        #expect(sent == ["cancel live1", "cancel live2", "abort"])
    }

    @Test func subagentCommandsNeedTheSubagentsAction() async {
        let (store, host, task) = await started(F.snapshot(actions: ["send"]))
        defer { task.cancel() }
        await store.subagentCommand(runID: "r", action: .pause)
        #expect(host.actions.isEmpty)
    }

    @Test func aTranscriptPageIsReturnedOrNilWhenRefused() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        let page = NativeSubagentTranscript(runID: "r", messages: [hi], olderCursor: "a", earlierCount: 3)
        host.action = { _ in .transcript(value: page) }
        #expect(await store.subagentTranscript(runID: "r") == page)
        host.action = { _ in .failure(code: "x", message: "no") }
        #expect(await store.subagentTranscript(runID: "r", beforeEntryID: "a") == nil)
        #expect(host.actions.last == .subagentTranscript(expectedSessionID: "s", runID: "r", beforeEntryID: "a"))
    }

    // MARK: History

    @Test func olderPagesPrependWithoutDuplicates() async {
        let m2 = F.assistant("two", id: "m2"), m3 = F.assistant("three", id: "m3")
        let (store, host, task) = await started(F.snapshot(messages: [m2, m3], olderCursor: "m2"))
        defer { task.cancel() }
        let m0 = F.user("zero", id: "m0"), m1 = F.assistant("one", id: "m1")
        host.next = [.success(.snapshot(value: F.snapshot(messages: [m0, m1, m2], olderCursor: "m0")))]
        await store.loadOlder()
        #expect(host.requests.last == .snapshot(expectedSessionID: "s", beforeEntryID: "m2"))
        #expect(store.messages.map(\.entryID) == ["m0", "m1", "m2", "m3"] && store.olderCursor == "m0")
        #expect(!store.loadingOlder)
    }

    @Test func aLiveRefreshKeepsLoadedHistoryAboveTheOverlap() async {
        let m2 = F.assistant("two", id: "m2"), m3 = F.assistant("three", id: "m3")
        let (store, host, task) = await started(F.snapshot(messages: [m2, m3], olderCursor: "m2"))
        defer { task.cancel() }
        host.next = [.success(.snapshot(value: F.snapshot(messages: [F.user(id: "m1"), m2], olderCursor: nil)))]
        await store.loadOlder()
        host.snapshot = F.snapshot(revision: 2, messages: [m3, F.assistant("four", id: "m4")], olderCursor: "m3")
        await store.refresh()
        #expect(store.messages.map(\.entryID) == ["m1", "m2", "m3", "m4"])
    }

    @Test func aStaleCursorResetsHistoryFromAFreshSnapshot() async {
        let (store, host, task) = await started(F.snapshot(messages: [hi], olderCursor: "a"))
        defer { task.cancel() }
        host.next = [.success(.failure(code: "stale_cursor", message: "gone"))]
        host.snapshot = F.snapshot(revision: 2, messages: [F.assistant("fresh", id: "f")])
        await store.loadOlder()
        #expect(host.requests.last == .snapshot())
        #expect(store.messages.map(\.entryID) == ["f"] && store.olderCursor == nil)
    }

    @Test func thereIsNoOlderPageWithoutACursor() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        await store.loadOlder()
        #expect(host.requests.count == 1)
    }

    @Test func provisionalRowsAlreadyInHistoryAreNotShownTwice() async {
        let persisted = F.tool("bash", id: "t1", callID: "call-1")
        let snapshot = F.snapshot(messages: [hi, persisted], provisional: [
            F.assistant("dup", id: "a"), F.tool("bash", status: "running", id: "p-call-1", callID: "call-1"), F.assistant("new", id: "n"),
        ])
        let (store, _, task) = await started(snapshot)
        defer { task.cancel() }
        #expect(store.displayedMessages.map(\.entryID) == ["a", "t1", "n"])
    }

    // MARK: Polling and running state

    @Test(arguments: [
        (false, false, nil as [ChildRun]?, Duration.seconds(2)),
        (true, false, nil, .milliseconds(500)),
        (false, true, nil, .milliseconds(500)),
        (false, false, [Fixture.run("live")], .milliseconds(500)),
        (false, false, [Fixture.run("done", state: "complete")], .seconds(2)),
    ])
    func pollingIsFastOnlyWhileSomethingIsHappening(running: Bool, dialog: Bool, subagents: [ChildRun]?, interval: Duration) async {
        let dialogs = dialog ? [NativeThreadDialog(id: "d", kind: .confirm, title: "?")] : []
        let (store, _, task) = await started(F.snapshot(running: running, dialogs: dialogs, subagents: subagents))
        defer { task.cancel() }
        #expect(store.pollInterval == interval)
    }

    /// The 400 ms decay itself is time-based and not covered here.
    @Test func runningIsHeldThroughABriefDropAndClearedByStop() async {
        let (store, host, task) = await started(F.snapshot(running: true))
        defer { task.cancel() }
        #expect(store.settledRunning)
        host.snapshot = F.snapshot(revision: 2, running: false)
        await store.refresh()
        #expect(store.snapshot?.running == false && store.settledRunning)
        store.stop()
        #expect(!store.settledRunning && !store.ready)
    }

    @Test func stopDetachesTheStoreFromItsHost() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        store.stop()
        await store.refresh()
        #expect(host.requests.count == 1 && !store.supports("send"))
    }
}
