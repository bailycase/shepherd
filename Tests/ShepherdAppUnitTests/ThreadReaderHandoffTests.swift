import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// One thread on screen in two Mac views (a deck thread and a Mission station): the history stays
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

    @Test func theOlderViewKeepsItsHistoryAndRunsTheThreadAgainWhenTheNewerLeaves() async {
        let pins = ThreadReaderPins()
        let stores = NativeThreadStores<String>()
        stores.pins = pins
        stores.retainedHistories = 0
        stores.protected = { ["selected"] }
        let store = stores.store(for: "shared")
        let asks = Asks()
        let deck = UUID(), mission = UUID()
        var loops: [Task<Void, Never>] = []
        defer { loops.forEach { $0.cancel() } }
        // What a thread view does when it shows the thread (and again when the loop is handed back to it).
        func show(_ owner: UUID, _ who: String) {
            pins.pin(store, owner: owner)
            pins.started(store, owner: owner) { show(owner, who) }
            let request = asks.request(who, snapshot(who))
            loops.append(Task { await store.run(request: request, owner: owner) })
        }

        await asks.next("A") { show(deck, "A") }
        await asks.next("B") { show(mission, "B") }
        // The newer view leaves: only its own pin goes, and the older view runs the loop again.
        await asks.next("A") {
            store.stop(owner: mission)
            pins.stopped(store, owner: mission)
            pins.unpin(store, owner: mission)
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

    /// A loop stopped for another reason than its view leaving (the store detached) is not restarted.
    @Test func aLoopStoppedElsewhereIsNotRestarted() async {
        let pins = ThreadReaderPins()
        let store = manualStore()
        let asks = Asks()
        let owner = UUID()
        var resumed = 0
        pins.started(store, owner: owner) { resumed += 1 }
        var loop: Task<Void, Never>?
        defer { loop?.cancel() }
        await asks.next("A") {
            loop = Task { await store.run(request: asks.request("A", snapshot("a")), owner: owner) }
        }
        // Detached elsewhere while its view still shows it.
        store.stop()
        #expect(!store.isLive)
        #expect(resumed == 0)
        // Its own view hiding hands nothing back either: no other view shows the thread.
        pins.stopped(store, owner: owner)
        #expect(resumed == 0)
    }
}
