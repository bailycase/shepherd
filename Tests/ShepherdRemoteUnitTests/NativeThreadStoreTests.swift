import Foundation
import Observation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// A scripted host for `NativeThreadStore`. Snapshot requests serve `snapshot` unless a result
/// is queued in `next`; actions answer through `action`. Every request is recorded.
@MainActor
final class FakeHost {
    var snapshot: NativeThreadSnapshot
    /// While true, snapshot requests answer that the agent's pi is still starting.
    var starting = false
    var next: [Result<NativeThreadResult, Error>] = []
    var action: (NativeThreadRequest) throws -> NativeThreadResult = { _ in .failure(code: "x", message: "unscripted") }
    private(set) var requests: [NativeThreadRequest] = []
    fileprivate var onServed: (() -> Void)?
    /// Sees each request as it arrives, before it is answered.
    var onRequest: ((NativeThreadRequest) -> Void)?

    init(_ snapshot: NativeThreadSnapshot) { self.snapshot = snapshot }

    func handle(_ request: NativeThreadRequest) throws -> NativeThreadResult {
        requests.append(request)
        onRequest?(request)
        if !next.isEmpty { return try next.removeFirst().get() }
        guard case .snapshot = request else { return try action(request) }
        defer { onServed?(); onServed = nil }
        if starting { return .failure(code: NativeThreadCode.starting, message: "pi is starting.") }
        return .snapshot(value: snapshot)
    }

    var actions: [NativeThreadRequest] {
        requests.filter { if case .snapshot = $0 { return false } else { return true } }
    }

    /// Accept every action with its own operation id.
    func acceptAll() {
        action = { request in
            switch request {
            case .send(_, _, let id, _, _, _, _), .abort(_, _, let id), .answer(_, _, let id, _, _),
                 .setModel(_, _, let id, _), .setThinking(_, _, let id, _), .subagentCommand(_, _, let id, _, _, _, _),
                 .queue(_, _, let id, _):
                return .accepted(operationID: id)
            default:
                return .failure(code: "x", message: "unexpected")
            }
        }
    }
}

/// Suspends until `condition` holds, woken by the store's observation rather than polling.
@MainActor
func until(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
            withObservationTracking { _ = condition() } onChange: { changed.resume() }
        }
    }
}

/// Holds a thread's first snapshot request until the test opens it.
@MainActor
@Observable
final class FirstPullGate {
    var asked = false
    var held = true
}

/// A store whose run loop never polls on its own: its pause ends only when the loop is
/// cancelled. Every refresh is the test's, so no poll lands between a test's steps however
/// slowly the machine runs it.
@MainActor
func manualStore(startingLimit: Duration = .seconds(60)) -> NativeThreadStore {
    NativeThreadStore(startingLimit: startingLimit) { _ in
        let (cancelled, continuation) = AsyncStream<Void>.makeStream()
        for await _ in cancelled {}
        continuation.finish()
        throw CancellationError()
    }
}

/// Starts the store's run loop and returns once the first answer (a snapshot, or pi still
/// starting) has been applied.
@MainActor
func start(_ store: NativeThreadStore, _ host: FakeHost) async -> Task<Void, Never> {
    var task: Task<Void, Never>?
    await withCheckedContinuation { (served: CheckedContinuation<Void, Never>) in
        host.onServed = { served.resume() }
        task = Task { await store.run { try host.handle($0) } }
    }
    return task!
}

@Suite("NativeThreadStore", .timeLimit(.minutes(1)))
@MainActor
struct NativeThreadStoreTests {
    typealias F = Fixture
    let hi = F.assistant("hi", id: "a")

    private func started(_ snapshot: NativeThreadSnapshot? = nil) async -> (NativeThreadStore, FakeHost, Task<Void, Never>) {
        let host = FakeHost(snapshot ?? F.snapshot(messages: [hi]))
        let store = manualStore()
        let task = await start(store, host)
        return (store, host, task)
    }

    // MARK: Recorded turns

    /// A reply carries the turn its host recorded for the message that opened it (its
    /// "Edited N files" card); an Undo arriving with the next snapshot changes that row alone.
    @Test func aReplyCarriesTheTurnRecordedForItsPrompt() async {
        var prompt = F.user("fix it", id: "u")
        prompt.timestamp = 42
        var turn = ChangesTurn(messageTimestamp: 42, startedAt: 42, endedAt: 50, state: .ready,
                               files: [ChangesFile(path: "a.go", status: .modified, added: 1, removed: 1)], canUndo: true)
        var snapshot = F.snapshot(messages: [prompt, hi])
        snapshot.turnChanges = [turn]
        let (store, host, task) = await started(snapshot)
        defer { task.cancel() }
        #expect(store.rows.map(\.recordedTurn) == [nil, turn])

        turn.state = .undone
        snapshot.turnChanges = [turn]
        snapshot.revision = 2
        host.snapshot = snapshot
        await store.refresh()
        #expect(store.rows.last?.recordedTurn?.state == .undone)
    }

    // MARK: Design comments

    /// A message carrying a design comment names it on its row, and the reply to it names it too,
    /// so a design's chat draws the reply inside the comment's card.
    @Test func aDesignCommentsRowAndItsReplyNameTheComment() async {
        let id = UUID()
        var comment = F.user("Show the counts", id: "u1")
        comment.origin = .designComment(id: id)
        let plain = F.user("and the phone", id: "u2")
        let (store, _, task) = await started(F.snapshot(messages: [comment, hi, plain]))
        defer { task.cancel() }
        #expect(store.rows.map(\.designComment) == [id, id, nil])
        #expect(store.rows.map(\.commentAnswered) == [true, false, false])

        let (unanswered, _, other) = await started(F.snapshot(messages: [F.assistant("hello", id: "a0"), comment]))
        defer { other.cancel() }
        #expect(unanswered.rows.last?.designComment == id && unanswered.rows.last?.commentAnswered == false)
    }

    /// A message carrying Pencil markup names its counts on its row, and the reply that proposed
    /// comments from it names them, so a design's chat draws the line and the proposals card.
    @Test func markupRowsNameTheirCountsAndTheReplyItsProposals() async {
        var markup = F.user("Pencil markup · 2 strokes · 1 note", id: "u1")
        markup.origin = .designMarkup(strokes: 2, notes: 1)
        let block = DesignMarkupProposals(proposals: [
            DesignCommentDraft(board: DesignPath("A.dc.html")!, tid: 2, path: [1], target: "KPI row", text: "Counts too.", proposal: "c#0"),
        ]).block
        let proposed = NativeThreadMessage(entryID: "t1", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: "Proposed 1 comment\n" + block)],
                                           toolName: "markup_propose", toolCallID: "c", status: "complete")
        let (store, _, task) = await started(F.snapshot(messages: [markup, proposed, F.assistant("One comment.", id: "a1"), F.user("thanks", id: "u2")]))
        defer { task.cancel() }
        #expect(store.rows.map(\.designMarkup) == [NativeMarkupCounts(strokes: 2, notes: 1), nil, nil])
        #expect(store.rows.map { $0.markupProposals?.ids } == [nil, ["c#0"], nil])
    }

    // MARK: Turn errors

    /// A thread whose last reply failed reads failed until a new turn starts; while pi retries,
    /// the live turn ends in the retry line and the thread does not.
    @Test func aLastReplyThatFailedReadsFailedUntilTheNextTurn() async {
        let failed = F.assistant("529 overloaded", status: "error", id: "e")
        let (store, host, task) = await started(F.snapshot(messages: [F.user("go", id: "u"), failed]))
        defer { task.cancel() }
        #expect(store.lastTurnFailed)

        var retrying = F.snapshot(revision: 2, messages: [F.user("go", id: "u"), failed])
        retrying.running = true
        retrying.retry = NativeThreadRetry(attempt: 1, maxAttempts: 3, retryAt: 8_000)
        host.snapshot = retrying
        await store.refresh()
        #expect(!store.lastTurnFailed)
        guard case .retrying? = store.rows.last?.presentation?.items.last else { Issue.record("expected the retry line"); return }

        host.snapshot = F.snapshot(revision: 3, messages: [F.user("go", id: "u"), failed, F.user("again", id: "u2")])
        await store.refresh()
        #expect(!store.lastTurnFailed)
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

    // MARK: Starting

    private func startedWhileStarting(_ store: NativeThreadStore = manualStore()) async -> (NativeThreadStore, FakeHost, Task<Void, Never>) {
        let host = FakeHost(F.snapshot(messages: [hi]))
        host.starting = true
        let task = await start(store, host)
        return (store, host, task)
    }

    @Test func aPiThatIsStillStartingIsNotAnErrorAndIsPolledQuickly() async {
        let (store, _, task) = await startedWhileStarting()
        defer { task.cancel() }
        #expect(store.starting && !store.ready && store.loadError == nil && store.snapshot == nil)
        #expect(store.pollInterval == .milliseconds(200))
        #expect(!store.supports("send") && store.acceptsSend, "a send is offered, and waits for pi")
    }

    @Test func oncePiAnswersTheThreadIsReadyAndNoLongerStarting() async {
        let (store, host, task) = await startedWhileStarting()
        defer { task.cancel() }
        host.starting = false
        await store.refresh()
        #expect(store.ready && !store.starting && store.loadError == nil && store.messages == [hi])
        #expect(store.pollInterval == .seconds(2))
    }

    /// History read from disk shows while pi starts, with nothing enabled, and pi's snapshot
    /// replaces it.
    @Test func aPreviewShowsUntilPisFirstSnapshotReplacesIt() async {
        let (store, host, task) = await startedWhileStarting()
        defer { task.cancel() }
        let fromDisk = F.assistant("from disk", id: "a")
        store.preview(F.snapshot(generation: "preview", messages: [fromDisk]))
        #expect(store.previewing && store.messages == [fromDisk] && store.rows.count == 1)
        #expect(!store.ready && !store.supports("send") && store.starting)

        host.starting = false
        await store.refresh()
        #expect(store.ready && !store.previewing && store.messages == [hi] && store.snapshot?.generation == "g")
    }

    /// Disk never overwrites what pi served, even once the thread has stopped.
    @Test func aPreviewNeverReplacesPisThread() async {
        let (store, _, task) = await started()
        defer { task.cancel() }
        store.preview(F.snapshot(generation: "preview", messages: []))
        #expect(!store.previewing && store.messages == [hi])
        store.stop()
        store.preview(F.snapshot(generation: "preview", messages: []))
        #expect(!store.previewing && store.messages == [hi])
    }

    /// The run loop reads the preview alongside its first pull, while pi has nothing to show.
    @Test func runningAThreadLoadsItsPreviewWhilePiStarts() async {
        let host = FakeHost(F.snapshot(messages: [hi]))
        host.starting = true
        let store = manualStore()
        let fromDisk = F.assistant("from disk", id: "a")
        let task = Task { await store.run(request: { try host.handle($0) }, preview: { F.snapshot(generation: "preview", messages: [fromDisk]) }) }
        defer { task.cancel() }
        await until { store.previewing }
        #expect(store.messages == [fromDisk] && !store.ready)
    }

    /// Before the thread's first answer (a new agent's empty thread, drawn at once) Send is
    /// offered, and a send waits for the thread to be ready.
    @Test func aSendBeforeTheFirstAnswerWaitsForIt() async throws {
        let host = FakeHost(F.snapshot(messages: [hi]))
        host.acceptAll()
        let gate = FirstPullGate()
        let (opened, open) = AsyncStream<Void>.makeStream()
        let store = manualStore()
        store.preview(F.snapshot(generation: "preview", messages: []))
        #expect(store.acceptsSend && store.previewing && !store.starting)
        let task = Task {
            await store.run { request in
                if gate.held, case .snapshot = request {
                    gate.held = false
                    gate.asked = true
                    for await _ in opened { break }
                }
                return try host.handle(request)
            }
        }
        defer { task.cancel() }
        await until { gate.asked }
        store.draft = "start with this"
        let sending = Task { await store.send() }
        await until { store.busy }
        #expect(host.actions.isEmpty && store.draft == "start with this")

        open.yield()
        await sending.value

        #expect(host.actions.count == 1 && store.sentCount == 1 && store.draft.isEmpty && store.ready)
    }

    /// What the composer's "Starting…" watches: a thread waiting for its pi, never one that
    /// is ready, in trouble, or a thread kept from before that is only refreshing.
    @Test func aThreadAwaitsPiOnlyWhileItsPiHasNotAnswered() async {
        let fresh = manualStore()
        #expect(fresh.awaitingPi, "nothing from pi yet")

        let (starting, host, task) = await startedWhileStarting()
        defer { task.cancel() }
        #expect(starting.awaitingPi)
        host.starting = false
        await starting.refresh()
        #expect(!starting.awaitingPi, "ready")

        starting.stop()
        #expect(!starting.awaitingPi, "a thread kept from before, refreshing")

        let (failed, failing, failedTask) = await startedWhileStarting()
        defer { failedTask.cancel() }
        failing.next = [.failure(RemoteHostClientError.rejected(code: NativeThreadCode.unavailable, message: "gone"))]
        await failed.refresh()
        #expect(!failed.awaitingPi, "an error")

        let previewed = manualStore()
        previewed.preview(F.snapshot(generation: "preview", messages: [hi]))
        #expect(previewed.awaitingPi, "shown from disk")
    }

    /// The host's signal that pi serves (pushed as a revision) pulls the thread at once; its poll
    /// never ran here.
    @Test func wakingAStartingThreadPullsItsFirstSnapshotAtOnce() async {
        let (store, host, task) = await startedWhileStarting(pushedStore(Pauses()))
        defer { task.cancel() }
        host.starting = false
        store.revisionAvailable()
        await until { store.ready }
        #expect(host.requests == [.snapshot(), .snapshot()])
        #expect(!store.starting && store.messages == [hi])
    }

    /// The host answers starting from the thread itself (a result) or before it reaches one (a
    /// refusal); a thread kept from before stays on screen, not running, with no error.
    @Test(arguments: [
        Result<NativeThreadResult, Error>.success(.failure(code: NativeThreadCode.starting, message: "pi is starting.")),
        .failure(RemoteHostClientError.rejected(code: NativeThreadCode.starting, message: "pi is starting.")),
    ])
    func eitherShapeOfStartingKeepsTheLastThreadWithoutAnError(_ answer: Result<NativeThreadResult, Error>) async {
        let (store, host, task) = await started(F.snapshot(running: true, messages: [hi]))
        defer { task.cancel() }
        host.next = [answer]
        await store.refresh()
        #expect(store.starting && !store.ready && store.loadError == nil)
        #expect(store.messages == [hi] && !store.settledRunning)
    }

    @Test func aSendDuringStartupWaitsForPiAndThenGoes() async throws {
        let (store, host, task) = await startedWhileStarting()
        defer { task.cancel() }
        host.acceptAll()
        store.draft = "do the thing"
        let sending = Task { await store.send() }
        await until { store.busy }
        #expect(host.actions.isEmpty && store.draft == "do the thing" && !store.acceptsSend)

        host.starting = false
        await store.refresh()
        await sending.value

        guard case .send(let session, _, _, let text, _, _, _) = try #require(host.actions.first) else { Issue.record("expected a send"); return }
        #expect(session == "s" && text == "do the thing" && host.actions.count == 1)
        #expect(store.draft.isEmpty && store.sentCount == 1 && !store.busy && store.notice == nil)
    }

    /// The waiting message stays in the field, so the field is what goes: edited while pi
    /// starts, the edit is sent; cleared, nothing is.
    @Test(arguments: [("do the other thing", "do the other thing"), ("  ", nil)])
    func aSendWaitingForPiGoesAsTheFieldHasIt(edited: String, sent: String?) async throws {
        let (store, host, task) = await startedWhileStarting()
        defer { task.cancel() }
        host.acceptAll()
        store.draft = "do the thing"
        let sending = Task { await store.send() }
        await until { store.busy }
        store.draft = edited

        host.starting = false
        await store.refresh()
        await sending.value

        let texts = host.actions.compactMap { action -> String? in
            if case .send(_, _, _, let text, _, _, _) = action { return text } else { return nil }
        }
        #expect(texts == (sent.map { [$0] } ?? []))
        #expect(store.draft == (sent == nil ? edited : "") && !store.busy)
    }

    @Test func aThreadThatStopsWhileASendWaitsKeepsTheDraftWithNothingSent() async {
        let (store, host, task) = await startedWhileStarting()
        defer { task.cancel() }
        store.draft = "do the thing"
        let sending = Task { await store.send() }
        await until { store.busy }
        store.stop()
        await sending.value
        #expect(host.actions.isEmpty && store.draft == "do the thing" && store.sentCount == 0)
        #expect(!store.busy && store.notice == nil, "nothing was dispatched, so the outcome is known")
    }

    @Test func aFailureWhileASendWaitsKeepsTheDraftAndShowsTheError() async {
        let (store, host, task) = await startedWhileStarting()
        defer { task.cancel() }
        store.draft = "do the thing"
        let sending = Task { await store.send() }
        await until { store.busy }
        host.next = [.failure(RemoteHostClientError.rejected(code: NativeThreadCode.unavailable, message: "The agent exited (code 127)."))]
        await store.refresh()
        await sending.value
        #expect(host.actions.isEmpty && store.draft == "do the thing" && !store.busy)
        #expect(!store.starting && store.loadError == "native_unavailable: The agent exited (code 127).")
    }

    @Test func aPiThatNeverStartsBecomesAnErrorAfterTheLimitAndClearsWhenItAnswers() async {
        let (store, host, task) = await startedWhileStarting(manualStore(startingLimit: .zero))
        defer { task.cancel() }
        #expect(!store.starting && !store.acceptsSend)
        #expect(store.loadError?.hasPrefix("The agent has not started after") == true)
        await store.refresh()
        #expect(!store.starting && store.loadError != nil, "still over the limit: the error stays")
        host.starting = false
        await store.refresh()
        #expect(store.ready && store.loadError == nil)
    }

    @Test func aServingThreadWhosePiGoesAwayIsALostConnection() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.next = [.failure(RemoteHostClientError.rejected(code: NativeThreadCode.unavailable, message: "The agent no longer exists."))]
        await store.refresh()
        #expect(!store.starting && !store.ready && store.loadError == "native_unavailable: The agent no longer exists.")
    }

    // MARK: Sending

    @Test func aRejectedSendKeepsTheDraftAndShowsWhy() async throws {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.action = { _ in .failure(code: "busy", message: "not yet") }
        store.draft = "do the thing"
        await store.send()
        #expect(store.draft == "do the thing" && store.pending.isEmpty && store.notice == "not yet")
        guard case .send(let session, let generation, _, let text, let delivery, let images, _) = try #require(host.actions.first) else {
            Issue.record("expected a send"); return
        }
        #expect(session == "s" && generation == "g" && text == "do the thing" && delivery == .followUp && images == nil)
        #expect(host.requests.last == .snapshot(), "every action ends with a fresh snapshot")
        #expect(!store.busy)
    }

    /// A design chat's send carries what its design screen shows, where the host takes it.
    @Test(arguments: [(true, true), (false, false)])
    func aSendCarriesTheDesignRecordOnlyWhereTheHostTakesOne(_ hostTakesIt: Bool, _ carried: Bool) async throws {
        let actions = ["send", "abort"] + (hostTakesIt ? ["designContext"] : [])
        let (store, host, task) = await started(F.snapshot(actions: actions, messages: [hi]))
        defer { task.cancel() }
        host.acceptAll()
        let element = try #require(DesignElementID("A.dc.html#4:1/0"))
        let record = DesignViewRecord(visibleBoards: ["A.dc.html"], selectedBoards: ["A.dc.html"], selected: [element],
                                      selection: [.init(id: element, kind: .text, label: "Checkout funnel")])
        store.designContext = { record }
        store.draft = "make it taller"
        await store.send()
        guard case .send(_, _, _, let text, _, _, let context) = try #require(host.actions.first) else { Issue.record("expected a send"); return }
        #expect(text == "make it taller")
        #expect(context == (carried ? NativeDesignContext(record) : nil))
    }

    /// Files attached beside the draft (a design's boards) go under the words as their paths, and
    /// leave the composer with the message; a refused send keeps them.
    @Test func attachedFilesGoWithTheMessageAndLeaveWithIt() async throws {
        let (store, host, task) = await started()
        defer { task.cancel() }
        let files = [NativeAttachedFile(name: "A.html", path: "/drops/d1/A.html"),
                     NativeAttachedFile(name: "tokens.css", path: "/drops/d1/tokens.css")]
        store.attach(files: files)
        store.attach(files: [NativeAttachedFile(name: "A.html", path: "/drops/d1/A.html")])
        #expect(store.attachedFiles == files, "each file once")
        #expect(store.hasDraft, "files alone are something to send")

        host.action = { _ in .failure(code: "busy", message: "not yet") }
        store.draft = "Build this"
        await store.send()
        #expect(store.attachedFiles == files && store.draft == "Build this")
        guard case .send(_, _, _, let text, _, _, _) = try #require(host.actions.last) else { Issue.record("expected a send"); return }
        #expect(text == "Build this\n\nAttached files:\n- /drops/d1/A.html\n- /drops/d1/tokens.css")

        host.acceptAll()
        await store.send()
        #expect(store.attachedFiles.isEmpty && store.draft.isEmpty && store.sentCount == 1)

        store.attach(files: [files[1]])
        store.detachFile(files[1].id)
        #expect(store.attachedFiles.isEmpty && !store.hasDraft)
    }

    @Test(arguments: [("", "Attached files:\n- /a.html"), ("  ", "Attached files:\n- /a.html"), ("Hi", "Hi\n\nAttached files:\n- /a.html")])
    func anAttachedFilesMessageListsThemUnderTheWords(_ words: String, _ message: String) {
        #expect(NativeAttachedFile.message(words, files: [NativeAttachedFile(name: "a.html", path: "/a.html")]) == message)
        #expect(NativeAttachedFile.message(words, files: []) == words)
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
        guard case .send(_, _, let operation, _, _, _, _) = try #require(host.actions.first) else { Issue.record("expected a send"); return }
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

    /// Only a send that goes into the thread now brings the reader to the tail; a follow-up sent
    /// while pi works waits in Up next (DESIGN.md › Thread › Following).
    @Test(arguments: [
        (running: false, delivery: NativeThreadDelivery.followUp, queued: false),
        (running: false, delivery: .steer, queued: false),
        (running: true, delivery: .followUp, queued: true),
        (running: true, delivery: .steer, queued: false),
    ])
    func aSendSaysWhetherItWaitsInUpNext(_ c: (running: Bool, delivery: NativeThreadDelivery, queued: Bool)) async {
        let (store, host, task) = await started(F.snapshot(running: c.running, messages: [hi], queue: NativeQueue(items: [])))
        defer { task.cancel() }
        host.acceptAll()
        store.draft = "next"
        await store.send(delivery: c.delivery)
        #expect(store.sentCount == 1 && store.lastSendQueued == c.queued)
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
        guard case .send(_, _, _, _, let delivery, _, _) = try #require(host.actions.first) else { Issue.record("expected a send"); return }
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

    // MARK: Switching away and back

    /// Hiding an agent suspends its thread: polling stops, and everything the thread shows stays
    /// as it was (ready, still running, the same rows), so showing it again is a flip.
    @Test func suspendingKeepsTheThreadAsItIs() async {
        let (store, host, task) = await started(F.snapshot(running: true, messages: [F.user("go", id: "u"), hi]))
        defer { task.cancel() }
        let rows = store.rows
        #expect(store.ready && store.settledRunning && store.running)

        store.suspend()
        await store.refresh()

        #expect(host.requests.count == 1, "a suspended thread stops pulling")
        #expect(store.ready && store.settledRunning && store.running && store.rows == rows)
        #expect(store.catchUp == nil, "it is no longer caught up")
    }

    /// Four older pages loaded, the agent hidden and shown again: the newest page merges onto
    /// them as a poll's does, instead of the thread starting over from one page.
    @Test func aResumedRunOfTheSameSessionKeepsOlderPages() async {
        let m2 = F.assistant("two", id: "m2"), m3 = F.assistant("three", id: "m3")
        let (store, host, task) = await started(F.snapshot(messages: [m2, m3], olderCursor: "m2"))
        let m0 = F.user("zero", id: "m0"), m1 = F.assistant("one", id: "m1")
        host.next = [.success(.snapshot(value: F.snapshot(messages: [m0, m1, m2], olderCursor: "m0")))]
        await store.loadOlder()
        store.suspend()
        task.cancel()

        host.snapshot = F.snapshot(revision: 2, messages: [m3, F.assistant("four", id: "m4")], olderCursor: "m3")
        let resumed = await start(store, host)
        defer { resumed.cancel() }

        #expect(host.requests.last == .snapshot())
        #expect(store.messages.map(\.entryID) == ["m0", "m1", "m2", "m3", "m4"] && store.olderCursor == "m0")
        #expect(store.catchUp != nil)
    }

    /// A new generation of the session (or another session) is another thread: it starts over.
    @Test func aResumedRunOfAnotherGenerationStartsOver() async {
        let m2 = F.assistant("two", id: "m2"), m3 = F.assistant("three", id: "m3")
        let (store, host, task) = await started(F.snapshot(messages: [m2, m3], olderCursor: "m2"))
        host.next = [.success(.snapshot(value: F.snapshot(messages: [F.user("zero", id: "m0"), m2], olderCursor: nil)))]
        await store.loadOlder()
        store.suspend()
        task.cancel()

        host.snapshot = F.snapshot(generation: "g2", messages: [m3], olderCursor: "m3")
        let resumed = await start(store, host)
        defer { resumed.cancel() }

        #expect(store.messages.map(\.entryID) == ["m3"] && store.olderCursor == "m3")
    }

    /// The catch-up latch: set, with the versions of what the thread and the chrome showed then,
    /// by the first pull after a run starts, and cleared when the run ends.
    @Test func theFirstPullOfARunCatchesTheThreadUp() async {
        let host = FakeHost(F.snapshot(messages: [hi]))
        let store = manualStore()
        #expect(store.catchUp == nil)
        let task = await start(store, host)
        let first = try? #require(store.catchUp)
        #expect(first?.thread == store.threadVersion && first?.chrome == store.chromeVersion)

        host.snapshot = F.snapshot(revision: 2, messages: [hi, F.user("more", id: "u")])
        await store.refresh()
        #expect(store.catchUp == first, "later pulls leave it")
        #expect(store.threadVersion > first?.thread ?? .max, "the thread changed since")

        store.suspend()
        task.cancel()
        #expect(store.catchUp == nil)
    }

    // MARK: Pushed revisions

    /// A store whose poll interval never ends but whose short waits (the spacing between pushed
    /// pulls) end at once: only a push makes it pull. `pauses` counts the intervals it began.
    private func pushedStore(_ pauses: Pauses) -> NativeThreadStore {
        NativeThreadStore { duration in
            guard duration > NativeThreadStore.pushedPullSpacing else { return }
            await pauses.began()
            let (cancelled, continuation) = AsyncStream<Void>.makeStream()
            for await _ in cancelled {}
            continuation.finish()
            throw CancellationError()
        }
    }

    @Test func aPushedRevisionIsPulledWithoutWaitingTheInterval() async {
        let pauses = Pauses()
        let host = FakeHost(F.snapshot(messages: [hi]))
        let store = pushedStore(pauses)
        let task = await start(store, host)
        defer { task.cancel() }
        await until { pauses.count == 1 }

        host.snapshot = F.snapshot(revision: 2, messages: [hi, F.assistant("more", id: "b")])
        store.revisionAvailable()
        await until { store.snapshot?.revision == 2 }
        await until { pauses.count == 2 }

        #expect(host.requests == [.snapshot(), .snapshot(expectedSessionID: "s", afterRevision: 1)])
    }

    /// However many revisions are pushed while a pull is in flight, the loop pulls once more
    /// after it, then waits out its interval again.
    @Test func pushesDuringAPullCauseOneFollowUp() async {
        let pauses = Pauses()
        let gate = Gate()
        let host = FakeHost(F.snapshot(messages: [hi]))
        let store = pushedStore(pauses)
        let task = Task {
            await store.run { request in
                if gate.holding { await gate.hold() }
                return try host.handle(request)
            }
        }
        defer { task.cancel() }
        await until { pauses.count == 1 }

        gate.holding = true
        host.snapshot = F.snapshot(revision: 2, messages: [hi, F.assistant("more", id: "b")])
        store.revisionAvailable()
        await until { gate.held }
        for _ in 0..<5 { store.revisionAvailable() }
        gate.release()
        await until { pauses.count == 2 }

        #expect(host.requests.count == 3, "the first pull, the pushed one, and one follow-up")
        #expect(store.snapshot?.revision == 2)
    }

    /// The store says when its poll loop starts and ends, so the host pushes revisions only for
    /// threads on screen.
    @Test func aStoreSaysWhileItsThreadIsOnScreen() async {
        let host = FakeHost(F.snapshot(messages: [hi]))
        let store = pushedStore(Pauses())
        var changes: [Bool] = []
        store.onLiveChange = { changes.append($0) }
        let task = await start(store, host)
        #expect(store.isLive && changes == [true])

        store.suspend()
        #expect(!store.isLive && changes == [true, false])
        task.cancel()
        await task.value
        let shownAgain = await start(store, host)
        store.stop()
        #expect(changes == [true, false, true, false])
        shownAgain.cancel()
    }

    /// A thread off screen has no poll loop: a push neither pulls nor leaves a pull owed for
    /// when it is shown again.
    @Test func aSuspendedStoreIgnoresPushes() async {
        let pauses = Pauses()
        let host = FakeHost(F.snapshot(messages: [hi]))
        let store = pushedStore(pauses)
        let task = await start(store, host)
        await until { pauses.count == 1 }

        store.suspend()
        for _ in 0..<3 { store.revisionAvailable() }
        task.cancel()
        await task.value
        #expect(host.requests.count == 1)

        let resumed = await start(store, host)
        defer { resumed.cancel() }
        await until { pauses.count == 2 }
        #expect(host.requests.count == 2, "shown again, it pulls once and waits")
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

    // MARK: Rows

    @Test func eachReplyRowCarriesItsPresentationAndItsPrompt() async throws {
        let (store, _, task) = await started(F.snapshot(messages: [F.user("go", id: "u"), F.assistant("Reading.", id: "a"), F.tool("read", callID: "r")]))
        defer { task.cancel() }
        #expect(store.rows.map(\.id) == ["u", "u/reply"])
        let reply = try #require(store.rows.last)
        #expect(reply.promptText == "go" && !reply.live)
        #expect(reply.presentation?.items.count == 2)
    }

    @Test func onlyTheLastReplyIsLiveWhileTheAgentRuns() async {
        let (store, _, task) = await started(F.snapshot(running: true, messages: [F.user(id: "u1"), hi, F.user(id: "u2")],
                                                        provisional: [F.assistant("streaming", id: "live")]))
        defer { task.cancel() }
        #expect(store.rows.map(\.live) == [false, false, false, true])
    }

    /// LiveText: the thread ends in "Thinking…" only while nothing else moves.
    @Test func theThreadShowsThinkingOnlyWhileNothingElseMoves() async {
        let prompt = F.user(id: "u")
        let (store, host, task) = await started(F.snapshot(running: true, messages: [prompt]))
        defer { task.cancel() }
        #expect(store.showsThinking, "before pi's reply has a row")
        host.snapshot = F.snapshot(revision: 2, running: true, messages: [prompt],
                                   provisional: [F.assistant("Writing", status: "streaming", id: "p")])
        await store.refresh()
        #expect(!store.showsThinking, "the reply being written is what moves")
        host.snapshot = F.snapshot(revision: 3, running: true, messages: [prompt],
                                   provisional: [F.tool("bash", args: #"{"command":"swift test"}"#, status: "running", id: "b", callID: "b")])
        await store.refresh()
        #expect(!store.showsThinking, "the running call is what moves")
        host.snapshot = F.snapshot(revision: 4, running: true, messages: [prompt],
                                   provisional: [F.tool("bash", args: #"{"command":"swift test"}"#, id: "b", callID: "b")])
        await store.refresh()
        #expect(store.showsThinking, "between tools")
        host.snapshot = F.snapshot(revision: 5, messages: [prompt, F.assistant("Done.", id: "a")])
        await store.refresh()
        #expect(!store.showsThinking, "an idle thread")
    }

    @Test func aRunningCallsTailFollowsOutputThatKeepsItsLength() async throws {
        let running = { (output: String) in
            F.tool("bash", args: #"{"command":"swift build"}"#, output: output, status: "running", id: "provisional:tool:b", callID: "b")
        }
        let (store, host, task) = await started(F.snapshot(running: true, messages: [F.user(id: "u")], provisional: [running("step 1")]))
        defer { task.cancel() }
        host.snapshot = F.snapshot(revision: 2, running: true, messages: [F.user(id: "u")], provisional: [running("step 2")])
        await store.refresh()
        guard case .activity(_, let bursts)? = store.rows.last?.presentation?.items.last, let burst = bursts.last else {
            Issue.record("no live line")
            return
        }
        #expect(burst.state == .running && burst.tail == ["step 2"])
    }

    @Test func aFollowUpSentWhileRunningIsQueuedBelowTheLiveReply() async throws {
        let live = F.assistant("streaming reply", id: "live")
        let (store, host, task) = await started(F.snapshot(running: true, messages: [F.user(id: "u0"), hi], provisional: [live]))
        defer { task.cancel() }
        host.acceptAll()
        store.draft = "and then this"
        await store.send()
        let echo = try #require(store.pending.first)
        #expect(echo.status == "queued")
        #expect(store.displayedMessages.map(\.entryID) == ["u0", "a", "live", echo.entryID])
        #expect(store.rows.map(\.live) == [false, true, false], "the streaming reply stays live above the queued prompt")
    }

    @Test func aQueuedFollowUpDoesNotRestartTheRunningTurnsClock() async throws {
        var prompt = F.user(id: "u0")
        prompt.timestamp = 1_000
        let (store, host, task) = await started(F.snapshot(running: true, messages: [prompt, hi], provisional: [F.assistant("streaming", id: "live")]))
        defer { task.cancel() }
        #expect(store.lastPromptAt == 1_000)
        host.acceptAll()
        store.draft = "and then this"
        await store.send()
        #expect(store.pending.first?.status == "queued")
        #expect(store.lastPromptAt == 1_000)
    }

    @Test func aPersistedPromptKeepsTheTurnIdentityOfItsEcho() async throws {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.acceptAll()
        store.draft = "do the thing"
        await store.send()
        let echo = try #require(store.pending.first)
        #expect(store.rows.last?.id == echo.entryID)
        host.snapshot = F.snapshot(revision: 2, messages: [hi, F.user("do the thing", id: "u"), F.assistant("done", id: "r")])
        await store.refresh()
        #expect(store.pending.isEmpty)
        #expect(store.rows.map(\.id) == ["a", echo.entryID, echo.entryID + "/reply"])
    }

    @Test func typingADraftOrAnUnchangedPollInvalidatesNothingTheThreadDraws() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        let invalidated = Flag()
        withObservationTracking {
            _ = store.rows
            _ = store.displayedMessages
            _ = store.placements
        } onChange: {
            invalidated.set()
        }
        store.draft = "typing"
        host.snapshot = F.snapshot(revision: 2, messages: [hi])
        await store.refresh()
        #expect(store.snapshot?.revision == 2)
        #expect(!invalidated.value)
    }

    // MARK: What the chrome reads

    /// The chrome's properties (see `NativeThreadStore.session`) and how to read each.
    private static let chrome: [(String, @MainActor (NativeThreadStore) -> Void)] = [
        ("session", { _ = $0.session }), ("dialogs", { _ = $0.dialogs }), ("dialogsSupported", { _ = $0.dialogsSupported }),
        ("widgets", { _ = $0.widgets }), ("commands", { _ = $0.commands }), ("model", { _ = $0.model }),
        ("thinking", { _ = $0.thinking }), ("stats", { _ = $0.stats }), ("supportedActions", { _ = $0.supportedActions }),
        ("clipped", { _ = $0.clipped }), ("running", { _ = $0.running }), ("hostRunning", { _ = $0.hostRunning }),
        ("showsThinking", { _ = $0.showsThinking }), ("userTurnCount", { _ = $0.userTurnCount }),
        ("hasSubagents", { _ = $0.hasSubagents }),
    ]

    /// Which chrome properties announced a change while `change` ran.
    private func changed(_ store: NativeThreadStore, _ change: () async -> Void) async -> Set<String> {
        let fired = Names()
        for (name, read) in Self.chrome {
            withObservationTracking { read(store) } onChange: { fired.insert(name) }
        }
        await change()
        return fired.value
    }

    /// A streamed chunk moves the rows and nothing the composer or the toolbar reads;
    /// a poll that moves only the context count moves only `stats`; and each other change moves
    /// what it shows.
    @Test func eachChromePropertyChangesOnlyWithWhatItShows() async {
        let read = { (id: String) in F.tool("read", args: #"{"path":"\#(id).swift"}"#, id: id, callID: id) }
        var snapshot = F.snapshot(running: true, messages: [F.user("go", id: "u")], provisional: [read("p1")], model: "a/one")
        snapshot.stats = NativeThreadStats(contextTokens: 1_000)
        let (store, host, task) = await started(snapshot)
        defer { task.cancel() }
        #expect(store.running && store.showsThinking && store.userTurnCount == 1)

        func serve(_ edit: (inout NativeThreadSnapshot) -> Void) async -> Set<String> {
            await changed(store) {
                edit(&snapshot)
                snapshot.revision += 1
                host.snapshot = snapshot
                await store.refresh()
            }
        }

        let steps: [(Set<String>, (inout NativeThreadSnapshot) -> Void)] = [
            ([], { $0.provisional = [read("p1"), read("p2")] }),
            (["stats"], { $0.stats = NativeThreadStats(contextTokens: 2_000) }),
            (["model"], { $0.model = "a/two" }),
            (["thinking"], { $0.thinking = "high" }),
            (["supportedActions"], { $0.supportedActions.append("sendImages") }),
            (["widgets"], { $0.widgets = [NativeThreadWidget(namespace: "x", key: "k", kind: .status, text: "on")] }),
            (["commands"], { $0.commands = [NativeCommand(name: "review")] }),
            (["clipped"], { $0.clipped = true }),
            (["hasSubagents"], { $0.subagents = [F.run("r")] }),
            (["userTurnCount"], { $0.messages += [F.assistant("Done.", id: "a"), F.user("next", id: "u2")] }),
            (["dialogs", "showsThinking"], { $0.dialogs = [NativeThreadDialog(id: "d", kind: .confirm, title: "Go?")] }),
            (["session"], { $0.generation = "g2" }),
        ]
        for (index, (expected, edit)) in steps.enumerated() {
            let fired = await serve(edit)
            #expect(fired == expected, "step \(index)")
        }
    }

    @Test func stopDetachesTheStoreFromItsHost() async {
        let (store, host, task) = await started()
        defer { task.cancel() }
        store.stop()
        await store.refresh()
        #expect(host.requests.count == 1 && !store.supports("send"))
    }
}

/// Names collected from observations' change handlers.
private final class Names: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []
    var value: Set<String> { lock.withLock { names } }
    func insert(_ name: String) { _ = lock.withLock { names.insert(name) } }
}

/// Set once from an observation's change handler.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}

/// The poll intervals a store's run loop began waiting out.
@MainActor @Observable
private final class Pauses {
    private(set) var count = 0
    func began() { count += 1 }
}

/// Holds snapshot requests while `holding`: a pull in flight, for as long as a test needs.
@MainActor @Observable
private final class Gate {
    var holding = false
    private(set) var held = false
    @ObservationIgnored private var waiter: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation { waiter = $0; held = true }
    }

    func release() {
        holding = false
        held = false
        waiter?.resume()
        waiter = nil
    }
}
