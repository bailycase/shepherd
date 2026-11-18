import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// One thread on screen in two Mac views (a deck thread and a second view): the history stays
/// pinned for each view separately, and the older view runs the store again when the newer leaves.
@Suite("Thread reader handoff", .timeLimit(.minutes(1)))
@MainActor
struct ThreadReaderHandoffTests {
    /// A store whose pauses between pulls never end on their own: only a cancel or a wake does.
    private func manualStore() -> NativeThreadStore {
        NativeThreadStore(startingLimit: .seconds(60)) { _ in
            let (cancelled, continuation) = AsyncStream<Void>.makeStream()
            for await _ in cancelled {}
            continuation.finish()
            throw CancellationError()
        }
    }

    private func snapshot(_ text: String) -> NativeThreadSnapshot {
        NativeThreadSnapshot(piSessionID: "session", generation: "generation", revision: 1, running: false, supportedActions: ["send"],
                             dialogsSupported: true, dialogs: [],
                             messages: [NativeThreadMessage(entryID: text, role: "user", blocks: [NativeThreadBlock(kind: .text, text: text)])],
                             provisional: [], clipped: false)
    }

    /// Pauses between pulls that end when the test releases them.
    @MainActor final class Pauses {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        /// Once released, every pause (one still to come too) ends at once.
        private var open = false
        func wait() async {
            if open { await Task.yield(); return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func releaseAll() { open = true; let all = waiting; waiting = []; all.forEach { $0.resume() } }
    }

    /// Who asked for a snapshot, in order.
    @MainActor final class Asks {
        var log: [String] = []
        var waiter: (want: String, done: CheckedContinuation<Void, Never>)?
        func request(_ who: String, _ value: NativeThreadSnapshot) -> NativeThreadStore.Request {
            { [weak self] _ in
                self?.log.append(who)
                if let waiter = self?.waiter, waiter.want == who { self?.waiter = nil; waiter.done.resume() }
                return .snapshot(value: value)
            }
        }
        func next(_ who: String, _ start: () -> Void = {}) async {
            await withCheckedContinuation { waiter = (who, $0); start() }
        }
    }

    /// The threads left last are the ones a person goes back to: they keep their lazy stack (`AppLayout.keptStacks`), the others let it go.
    @Test func theThreadsLeftLastAreLeftRecentlyUntilAViewShowsThemAgain() {
        let pins = ThreadReaderPins()
        let stores = (0..<5).map { _ in manualStore() }
        let owners = stores.map { _ in UUID() }
        func show(_ index: Int) { pins.started(stores[index], owner: owners[index]) {} }
        func leave(_ index: Int) { pins.stopped(stores[index], owner: owners[index]) }
        func recent(_ count: Int) -> [Int] { stores.indices.filter { pins.leftRecently(stores[$0], within: count) } }

        #expect(recent(3).isEmpty, "none was shown")
        for index in 0..<4 { show(index); leave(index) }
        #expect(recent(3) == [1, 2, 3] && recent(1) == [3] && recent(0).isEmpty)
        #expect(!pins.leftRecently(stores[4], within: 3), "one never shown is not one left")

        show(1)
        #expect(recent(3) == [0, 2, 3], "shown again, it is not left: the thread left before the others is among the last three left")
        leave(1)
        #expect(recent(3) == [1, 2, 3])

        // Two views show a thread: it is left when the last of them goes.
        let second = UUID()
        pins.started(stores[0], owner: owners[0]) {}
        pins.started(stores[0], owner: second) {}
        pins.stopped(stores[0], owner: second)
        #expect(!pins.leftRecently(stores[0], within: 3), "its other view still shows it")
        leave(0)
        #expect(recent(1) == [0])
    }

    @Test func theOlderViewKeepsItsHistoryAndRunsTheThreadAgainWhenTheNewerLeaves() async {
        let pins = ThreadReaderPins()
        let stores = NativeThreadStores<String>()
        stores.pins = pins
        stores.retainedHistories = 0
        stores.protected = { ["selected"] }
        let store = stores.store(for: "shared")
        let asks = Asks()
        let deck = UUID(), second = UUID()
        var loops: [Task<Void, Never>] = []
        defer { loops.forEach { $0.cancel() } }
        // What a thread view does when it shows the thread (and again when the loop is handed back to it).
        func show(_ owner: UUID, _ who: String) {
            pins.pin(store, owner: owner)
            pins.started(store, owner: owner) { show(owner, who) }
            let request = asks.request(who, snapshot(who))
            loops.append(Task {
                await store.run(request: request, owner: owner)
                if !Task.isCancelled { pins.loopEnded(store, owner: owner) }
            })
        }

        await asks.next("A") { show(deck, "A") }
        await asks.next("B") { show(second, "B") }
        // The newer view leaves: only its own pin goes, and the older view runs the loop again.
        await asks.next("A") {
            store.stop(owner: second)
            pins.stopped(store, owner: second)
            pins.unpin(store, owner: second)
        }
        #expect(store.isLive)
        #expect(asks.log.last == "A")

        // Other threads shown since, one selected: the shared thread is still on screen in A, so it keeps its history.
        for key in ["other", "selected"] {
            stores.store(for: key).preview(snapshot(key))
            stores.noteShown(key)
        }
        stores.enforceHistoryBounds()
        #expect(store.holdsHistory, "A still shows it: its pin keeps the history")
        #expect(!stores.store(for: "other").holdsHistory)
        #expect(pins.isPinned(store), "the newer view's leaving removed only its own pin")
        #expect(stores.existing(for: "shared") === store)
    }

    /// Two views show the thread; the loop is stopped explicitly (the store detached), then the
    /// newer view goes: the older one does not start it again.
    @Test func anExplicitlyStoppedLoopIsNotHandedBackWhenAViewLeaves() async {
        let pins = ThreadReaderPins()
        // Pauses end only when the test says, so a stopped loop can be seen returning.
        let pauses = Pauses()
        let store = NativeThreadStore(startingLimit: .seconds(60)) { _ in await pauses.wait() }
        let asks = Asks()
        let deck = UUID(), second_ = UUID()
        var resumedDeck = 0
        var loops: [Task<Void, Never>] = []
        defer { loops.forEach { $0.cancel() } }
        func run(_ owner: UUID, _ who: String) -> Task<Void, Never> {
            let request = asks.request(who, snapshot(who))
            return Task {
                await store.run(request: request, owner: owner)
                if !Task.isCancelled { pins.loopEnded(store, owner: owner) }
            }
        }
        await asks.next("A") {
            pins.started(store, owner: deck) { resumedDeck += 1 }
            loops.append(run(deck, "A"))
        }
        var second: Task<Void, Never>?
        await asks.next("B") {
            pins.started(store, owner: second_) { }
            second = run(second_, "B")
        }
        // Detached elsewhere while both views still show the thread: B's loop returns on its own.
        store.stop()
        pauses.releaseAll()
        if let second { _ = await second.value }
        #expect(!store.isLive)
        pins.stopped(store, owner: second_)
        #expect(resumedDeck == 0, "a stopped loop stays stopped when the view that ran it goes")
        #expect(!store.isLive)
        pins.stopped(store, owner: deck)
        #expect(resumedDeck == 0)
    }
}
