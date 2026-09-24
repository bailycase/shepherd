import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// The store against a host that holds the queue (`NativeThreadSnapshot.queue`): sends during a
/// run join the queue, the host's rows are the thread, and queue edits show at once.
@Suite("NativeThreadStore queue", .timeLimit(.minutes(1)))
@MainActor
struct NativeThreadStoreQueueTests {
    typealias F = Fixture
    static let actions = ["send", "abort", "answer", "setModel", "setThinking", "sendImages", "subagents", "queue"]
    let hi = F.assistant("hi", id: "a")

    static func item(_ text: String, _ n: Int, state: NativeQueuedMessage.State = .queued) -> NativeQueuedMessage {
        NativeQueuedMessage(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, text: text, sentAt: Double(n), state: state)
    }

    static let a = item("a", 1), b = item("b", 2)

    private func snapshot(revision: UInt64 = 1, running: Bool = true, items: [NativeQueuedMessage] = [],
                          provisional: [NativeThreadMessage] = []) -> NativeThreadSnapshot {
        F.snapshot(revision: revision, running: running, actions: Self.actions, messages: [hi], provisional: provisional,
                   queue: NativeQueue(items: items, mode: .all))
    }

    private func started(running: Bool = true, items: [NativeQueuedMessage] = []) async -> (NativeThreadStore, FakeHost, Task<Void, Never>) {
        let host = FakeHost(snapshot(running: running, items: items))
        let store = manualStore()
        let task = await start(store, host)
        return (store, host, task)
    }

    private func queueActions(_ host: FakeHost) -> [NativeQueueAction] {
        host.actions.compactMap { if case .queue(_, _, _, let action) = $0 { action } else { nil } }
    }

    /// What the store showed each time it asked the host for a snapshot after a change.
    private func queueSeenAtEachPull(_ store: NativeThreadStore, _ host: FakeHost) -> () -> [[String]] {
        var seen: [[String]] = []
        host.onRequest = { request in
            if case .snapshot = request { seen.append(store.queue.map(\.text)) }
        }
        return { seen }
    }

    // MARK: Catching up

    /// The composer draws the queue, so it counts as chrome: a queue that changed while the
    /// thread was away moves `chromeVersion`, and the catch-up lands it without motion. A queue
    /// change leaves the thread's rows (`threadVersion`) alone.
    @Test func aQueueChangeMovesTheChromeVersionAndNotTheThreads() async {
        let (store, host, task) = await started(items: [Self.a])
        defer { task.cancel() }
        let chrome = store.chromeVersion, thread = store.threadVersion

        host.snapshot = snapshot(revision: 2, items: [Self.a, Self.b])
        await store.refresh()
        #expect(store.queue.map(\.id) == [Self.a.id, Self.b.id])
        #expect(store.chromeVersion > chrome)
        #expect(store.threadVersion == thread)

        let before = store.chromeVersion
        host.snapshot = F.snapshot(revision: 3, running: true, actions: Self.actions, messages: [hi],
                                   queue: NativeQueue(items: [Self.a, Self.b], mode: .oneAtATime, paused: true, notice: "Refused."))
        await store.refresh()
        #expect(store.queueMode == .oneAtATime && store.queuePaused && store.queueNotice == "Refused.")
        #expect(store.chromeVersion > before)
    }

    // MARK: Sending

    /// The reported bug: a follow-up sent while pi works was a thread row ("queued" at the tail,
    /// where it could stay). It is the host's queue item, shown at once, and never in the thread.
    @Test func aSendWhilePiWorksShowsInTheQueueNotTheThread() async throws {
        let (store, host, task) = await started()
        defer { task.cancel() }
        let seen = queueSeenAtEachPull(store, host)
        var sent: UUID?
        host.action = { [self] request in
            guard case .send(_, _, let op, let text, _, _) = request else { return .failure(code: "x", message: "x") }
            sent = op
            // The host queues it; its next snapshot says so.
            host.snapshot = snapshot(revision: 2, items: [NativeQueuedMessage(id: op, text: text, sentAt: 42)])
            return .accepted(operationID: op)
        }
        store.draft = "and then tests"
        await store.send()
        let op = try #require(sent)
        #expect(seen() == [["and then tests"]], "shown before the host's snapshot came back")
        #expect(store.queue == [NativeQueuedMessage(id: op, text: "and then tests", sentAt: 42)])
        #expect(store.pending.isEmpty && store.displayedMessages == [hi], "not a thread row")
        #expect(store.supportsQueue && store.draft.isEmpty)
    }

    @Test func aSteerIsSentAsASteerAndShowsAsSteeringOnTop() async throws {
        let (store, host, task) = await started(items: [Self.a])
        defer { task.cancel() }
        let seen = queueSeenAtEachPull(store, host)
        host.acceptAll()
        store.draft = "turn left"
        await store.send(delivery: .steer)
        guard case .send(_, _, _, _, let delivery, _) = try #require(host.actions.first) else { Issue.record("expected a send"); return }
        #expect(delivery == .steer)
        #expect(seen() == [["turn left", "a"]])
    }

    @Test func imagesQueuedStayWithTheClientThatSentThem() async throws {
        let (store, host, task) = await started()
        defer { task.cancel() }
        host.acceptAll()
        let png = NativeImage(mimeType: "image/png", data: Data([1, 2]), name: "checkout.png")
        store.draft = "look"
        await store.send(images: [png])
        guard case .send(_, _, let op, _, _, let images) = try #require(host.actions.first) else { return }
        #expect(images == [png])
        #expect(store.queuedImages(op) == [png])
        #expect(store.queuedImages(UUID()).isEmpty)
    }

    /// The other half of the reported bug: an idle send's echo waited to find its text on the
    /// newest page, which a long run had already pushed it off, and stayed at the tail for
    /// good. It now leaves at the host's next snapshot, whatever that holds.
    @Test func anIdleSendsEchoLeavesAtTheHostsNextSnapshotWhateverItsPageHolds() async throws {
        let (store, host, task) = await started(running: false)
        defer { task.cancel() }
        host.acceptAll()
        host.starting = true   // the pull after the send brings no snapshot
        store.draft = "ye"
        await store.send()
        let echo = try #require(store.pending.first)
        host.starting = false
        host.snapshot = snapshot(revision: 2, running: true, provisional: [F.assistant("step 30", id: "provisional:assistant:30")])
        await store.refresh()
        #expect(store.pending.isEmpty, "gone without its text being anywhere in the snapshot")
        #expect(!store.displayedMessages.contains { $0.entryID == echo.entryID })
    }

    /// The host's pending row, then pi's message (carrying the send's operation id), keep the
    /// echo's turn identity: the row never re-lays out.
    @Test func theHostsRowsKeepTheEchosTurnIdentity() async throws {
        let (store, host, task) = await started(running: false)
        defer { task.cancel() }
        var sent: UUID?
        host.action = { request in
            guard case .send(_, _, let op, _, _, _) = request else { return .failure(code: "x", message: "x") }
            sent = op
            return .accepted(operationID: op)
        }
        store.draft = "ye"
        await store.send()
        let op = try #require(sent)
        let id = "pending:\(op.uuidString)"
        var row = NativeThreadMessage(entryID: id, role: "user", blocks: [NativeThreadBlock(kind: .text, text: "ye")], status: "pending", operationID: op)
        host.snapshot = snapshot(revision: 2, provisional: [row])
        await store.refresh()
        #expect(store.rows.last?.id == id)
        row.entryID = "user:5"
        row.status = nil
        host.snapshot = snapshot(revision: 3, provisional: [row, F.assistant("on it", id: "provisional:assistant:1")])
        await store.refresh()
        #expect(Array(store.rows.map(\.id).suffix(2)) == [id, id + "/reply"])
    }

    // MARK: Editing

    @Test func changesShowAtOnceAndGoToTheHost() async throws {
        let (store, host, task) = await started(items: [Self.a, Self.b])
        defer { task.cancel() }
        let seen = queueSeenAtEachPull(store, host)
        host.acceptAll()
        await store.editQueued(Self.a.id, text: "a!")
        await store.moveQueued(Self.b.id, to: 0)
        await store.holdQueued(Self.a.id, true)
        await store.setQueueMode(.oneAtATime)
        #expect(queueActions(host) == [.edit(id: Self.a.id, text: "a!"), .move(id: Self.b.id, index: 0),
                                       .hold(id: Self.a.id, held: true), .setMode(mode: .oneAtATime)])
        #expect(seen() == [["a!", "b"], ["b", "a"], ["a", "b"], ["a", "b"]], "each shown until the host's snapshot answered")
        #expect(store.queue.map(\.text) == ["a", "b"], "the host's snapshot is the truth once it answers")
    }

    @Test func deleteAndClearReturnWhatAnUndoRestores() async throws {
        let (store, host, task) = await started(items: [Self.item("s", 9, state: .steering), Self.a, Self.b])
        defer { task.cancel() }
        let seen = queueSeenAtEachPull(store, host)
        host.acceptAll()
        let deleted = try #require(await store.deleteQueued(Self.b.id))
        #expect(deleted.message == Self.b && deleted.index == 1)
        #expect(await store.deleteQueued(UUID()) == nil)
        let cleared = await store.clearQueue()
        #expect(cleared == [Self.a, Self.b], "steering stays")
        await store.restoreQueued(cleared, at: 0)
        #expect(queueActions(host) == [.delete(id: Self.b.id), .clear, .restore(ids: [Self.a.id, Self.b.id], index: 0)])
        #expect(seen() == [["s", "a"], ["s"], ["s", "a", "b"]])
    }

    @Test func steerUnsteerAndSendNowGoToTheHost() async throws {
        let (store, host, task) = await started(items: [Self.a, Self.b])
        defer { task.cancel() }
        let seen = queueSeenAtEachPull(store, host)
        host.acceptAll()
        await store.steerQueued([Self.b.id])
        await store.unsteer(Self.a.id)
        await store.sendQueuedNow([Self.b.id])
        #expect(queueActions(host) == [.steer(ids: [Self.b.id]), .unsteer(id: Self.a.id), .sendNow(ids: [Self.b.id])])
        #expect(seen().first == ["b", "a"], "a steered message moves on top")
        #expect(seen().last == ["a"], "sent now: it leaves the queue")
    }

    @Test func aRefusedChangeRollsBackAndSaysWhy() async throws {
        let (store, host, task) = await started(items: [Self.a, Self.b])
        defer { task.cancel() }
        host.action = { _ in .failure(code: "queue_item_unavailable", message: "That message is no longer queued.") }
        await store.moveQueued(Self.b.id, to: 0)
        #expect(store.queue.map(\.text) == ["a", "b"])
        #expect(store.notice == "That message is no longer queued.")
    }

    /// A change whose answer arrives after its thread went off screen still settles: accepted,
    /// it gives way to the host's snapshot once the thread is back; refused, it rolls back.
    /// Before, it stayed on top of every later snapshot until the session changed.
    @Test(arguments: [true, false])
    func aChangeAnsweredWhileTheThreadIsHiddenGivesWayToTheHost(accepted: Bool) async throws {
        let host = FakeHost(snapshot(items: [Self.a, Self.b]))
        let answer = HeldAnswer()
        let store = manualStore()
        let request: NativeThreadStore.Request = { request in
            if case .queue = request { await answer.hold() }
            return try host.handle(request)
        }
        let shown = Task { await store.run(request: request) }
        await until { store.ready }
        if accepted { host.acceptAll() } else { host.action = { _ in .failure(code: "queue_item_unavailable", message: "Gone.") } }

        let move = Task { await store.moveQueued(Self.b.id, to: 0) }
        await until { answer.waiting }
        #expect(store.queue.map(\.text) == ["b", "a"], "shown at once")
        store.suspend()
        shown.cancel()
        await shown.value
        answer.release()
        await move.value

        // Another client moved it back meanwhile (or the host refused it): the host has a, b.
        host.snapshot = snapshot(revision: 2, items: [Self.a, Self.b])
        let again = Task { await store.run(request: request) }
        defer { again.cancel() }
        await until { store.snapshot?.revision == 2 }
        await store.refresh()
        #expect(store.queue.map(\.text) == ["a", "b"])
    }

    /// Queue edits are not the draft's: they never make the composer busy.
    @Test func queueEditsNeverMakeTheComposerBusy() async throws {
        let (store, host, task) = await started(items: [Self.a])
        defer { task.cancel() }
        var sawBusy = false
        host.action = { request in
            sawBusy = sawBusy || store.busy
            guard case .queue(_, _, let id, _) = request else { return .failure(code: "x", message: "x") }
            return .accepted(operationID: id)
        }
        await store.editQueued(Self.a.id, text: "a2")
        #expect(!sawBusy && queueActions(host).count == 1)
    }

    @Test func thePausedStateAndNoticeComeFromTheHost() async throws {
        let (store, host, task) = await started(running: false)
        defer { task.cancel() }
        #expect(!store.queuePaused && store.queueNotice == nil && store.queueMode == .all)
        host.snapshot = F.snapshot(revision: 2, actions: Self.actions, messages: [hi],
                                   queue: NativeQueue(items: [Self.a], mode: .oneAtATime, paused: true, notice: "pi refused it."))
        await store.refresh()
        #expect(store.queuePaused && store.queueNotice == "pi refused it." && store.queueMode == .oneAtATime)
    }

    @Test func aHostWithoutAQueueOffersNone() async throws {
        let host = FakeHost(F.snapshot(running: true, messages: [hi]))
        let store = manualStore()
        let task = await start(store, host)
        defer { task.cancel() }
        host.acceptAll()
        #expect(!store.supportsQueue)
        await store.editQueued(Self.a.id, text: "x")
        #expect(host.actions.isEmpty)
        store.draft = "later"
        await store.send()
        #expect(store.pending.first?.status == "queued", "an older host's pi queues it; the echo says so")
        #expect(store.queue.isEmpty)
    }
}

/// Holds one queue action's answer until the test releases it.
@MainActor @Observable
private final class HeldAnswer {
    private(set) var waiting = false
    @ObservationIgnored private var waiter: CheckedContinuation<Void, Never>?

    func hold() async {
        await withCheckedContinuation { waiter = $0; waiting = true }
    }

    func release() {
        waiting = false
        waiter?.resume()
        waiter = nil
    }
}
