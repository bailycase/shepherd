import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// Loaded history across Mac threads off screen: bounded by recency and bytes, never at the cost
/// of a draft, the selected thread, or a reader's place. And the rows their hidden views hold:
/// bounded by a budget, the history and the draft staying.
@Suite("Thread stores history budget")
@MainActor
struct NativeThreadStoresHistoryTests {
    private typealias Entry = NativeThreadStores<String>.HistoryEntry<String>

    @Test func releasesTheOldestUnpinnedPastTheCountAndTheBudget() {
        let entries = [Entry(key: "a", bytes: 10, pinned: false), Entry(key: "b", bytes: 10, pinned: true),
                       Entry(key: "c", bytes: 10, pinned: false), Entry(key: "d", bytes: 10, pinned: false)]
        #expect(NativeThreadStores<String>.evictions(entries, keep: 2, budget: 1_000) == ["a"])
        #expect(NativeThreadStores<String>.evictions(entries, keep: 8, budget: 25) == ["a", "c"])
        // Pinned threads alone over budget stay: the budget is exceeded rather than lose a reader's place.
        #expect(NativeThreadStores<String>.evictions([Entry(key: "b", bytes: 100, pinned: true)], keep: 0, budget: 1) == [])
    }

    private func snapshot(_ text: String) -> NativeThreadSnapshot {
        NativeThreadSnapshot(piSessionID: "session", generation: "generation", revision: 1, running: false, supportedActions: [],
                             dialogsSupported: true, dialogs: [],
                             messages: [NativeThreadMessage(entryID: text, role: "user", blocks: [NativeThreadBlock(kind: .text, text: text)])],
                             provisional: [], clipped: false)
    }

    @Test func evictionKeepsDraftsSelectionAndEachReadersPlace() {
        let stores = NativeThreadStores<String>()
        let pins = ThreadReaderPins()
        stores.pins = pins
        stores.retainedHistories = 0
        stores.protected = { ["selected"] }
        for key in ["a", "read", "selected", "newest"] {
            let store = stores.store(for: key)
            store.preview(snapshot(key))
            store.draft = "draft \(key)"
            stores.noteShown(key)
        }
        let reader = stores.store(for: "read")
        let deck = UUID(), second = UUID()
        pins.pin(reader, owner: deck)
        pins.pin(reader, owner: second)
        // One of two readers leaves: the other's place is still kept.
        pins.unpin(reader, owner: deck)
        stores.enforceHistoryBounds()
        #expect(!stores.store(for: "a").holdsHistory)
        #expect(reader.holdsHistory)
        #expect(stores.store(for: "selected").holdsHistory)
        #expect(stores.store(for: "newest").holdsHistory, "the thread just shown is never released")
        for key in ["a", "read", "selected", "newest"] { #expect(stores.store(for: key).draft == "draft \(key)") }

        pins.unpin(reader, owner: second)
        stores.enforceHistoryBounds()
        #expect(!reader.holdsHistory)
        #expect(reader.draft == "draft read")
        #expect(stores.existing(for: "read") === reader, "the store and its identity stay")
    }

    // MARK: Hidden threads' row views

    private typealias Mounted = NativeThreadStores<String>.MountedEntry<String>

    /// A pause that never ends until the test lets it, so a pass the stores schedule runs only when a test runs it.
    @MainActor private final class Pauses {
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func pause(_ duration: Duration) async {
            await withCheckedContinuation { waiting.append($0) }
        }

        func end() {
            let ended = waiting
            waiting = []
            for continuation in ended { continuation.resume() }
        }
    }

    /// Stores for `keys` whose threads each hold one turn, all mounted, with `selected` on screen, shown in order.
    private func mountedStores(_ keys: [String], selected: String, pauses: Pauses) -> NativeThreadStores<String> {
        let stores = NativeThreadStores<String>()
        stores.pause = { await pauses.pause($0) }
        stores.mounted = { Set(keys) }
        stores.protected = { [selected] }
        for key in keys {
            let store = stores.store(for: key)
            store.preview(snapshot(key))
            store.draft = "draft \(key)"
            stores.noteShown(key)
        }
        return stores
    }

    @Test func viewReleasesTakeUnpinnedThenOlderPinnedPastTheBudget() {
        // Oldest first, a hundred bytes each; b, d and e are readers left scrolled up.
        let entries = [Mounted(key: "a", cost: 100, pinned: false), Mounted(key: "b", cost: 100, pinned: true),
                       Mounted(key: "c", cost: 100, pinned: false), Mounted(key: "d", cost: 100, pinned: true),
                       Mounted(key: "e", cost: 100, pinned: true), Mounted(key: "f", cost: 100, pinned: false),
                       Mounted(key: "g", cost: 100, pinned: false)]
        func releases(_ entries: [Mounted] = entries, keep: Int = 1, keepPinned: Int = 2, budget: Int) -> [String] {
            NativeThreadStores<String>.viewReleases(entries, keep: keep, keepPinned: keepPinned, budget: budget)
        }
        #expect(releases(budget: 700) == [], "at the budget nothing goes")
        #expect(releases(budget: 500) == ["a", "c"], "the oldest unpinned first, and only as many as it takes")
        #expect(releases(budget: 100) == ["a", "c", "f", "b"], "then the readers older than the two most recent (d, e); the newest hidden (g) never")
        #expect(releases(budget: 0) == ["a", "c", "f", "b"], "whatever the budget")
        #expect(releases(keep: 0, keepPinned: 0, budget: 0) == ["a", "c", "f", "g", "b", "d", "e"], "with nothing kept every hidden thread goes, readers last")
        #expect(releases(keep: 0, budget: 0) == ["a", "c", "f", "g", "b"], "no newest kept: g goes, and the two most recent readers still stay")
        // The newest hidden thread is a reader: it is never taken, and counts among the two most recent readers.
        var newestReads = entries
        newestReads[6] = Mounted(key: "g", cost: 100, pinned: true)
        #expect(releases(newestReads, budget: 0) == ["a", "c", "f", "b", "d"])
        #expect(releases([], budget: 0) == [])
    }

    @Test func theDefaultMountedBudgetIsAGigabyteOnEightAndTwoFromSixteen() {
        let gigabyte: UInt64 = 1 << 30
        #expect(NativeThreadStores<String>.defaultMountedBudget(physicalMemory: 8 * gigabyte) == Int(gigabyte))
        #expect(NativeThreadStores<String>.defaultMountedBudget(physicalMemory: 16 * gigabyte) == 2 * Int(gigabyte))
        #expect(NativeThreadStores<String>.defaultMountedBudget(physicalMemory: 128 * gigabyte) == 2 * Int(gigabyte))
    }

    @Test func aPassReleasesOneThreadAndKeepsItsHistory() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d"], selected: "d", pauses: pauses)
        let a = stores.store(for: "a"), b = stores.store(for: "b")
        let rows = a.rows, messages = a.messages, cost = a.mountedCost(eagerRows: stores.eagerRows)
        #expect(cost > 0 && !rows.isEmpty)

        let first = stores.enforceMountedBudget(budget: 0)
        #expect(first.threads == 1 && first.bytes == cost, "the oldest hidden thread goes, alone")
        #expect(a.transcriptReleased && a.holdsHistory, "its history stays")
        #expect(a.rows == rows && a.messages == messages && a.draft == "draft a" && stores.existing(for: "a") === a)
        #expect(a.mountedCost(eagerRows: stores.eagerRows) == 0, "it holds nothing now")
        #expect(!b.transcriptReleased, "one thread a pass")

        #expect(stores.enforceMountedBudget(budget: 0).threads == 1)
        #expect(b.transcriptReleased && b.holdsHistory && b.draft == "draft b")
        #expect(stores.enforceMountedBudget(budget: 0) == (0, 0), "the newest hidden thread and the selected one are never taken")
        #expect(!stores.store(for: "c").transcriptReleased && !stores.store(for: "d").transcriptReleased)
        #expect(stores.enforceMountedBudget(budget: 0, keep: 0).threads == 1, "with none kept, the newest goes too")
        #expect(stores.store(for: "c").transcriptReleased && !stores.store(for: "d").transcriptReleased, "the selected thread stays")
    }

    @Test func aBudgetAboveWhatTheHiddenThreadsHoldReleasesNothing() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d"], selected: "d", pauses: pauses)
        let held = ["a", "b", "c"].reduce(0) { $0 + stores.store(for: $1).mountedCost(eagerRows: stores.eagerRows) }
        #expect(stores.enforceMountedBudget(budget: held, limit: .max) == (0, 0))
        #expect(stores.enforceMountedBudget(budget: held - 1, limit: .max).threads == 1, "one byte over takes the oldest")
        let none = NativeThreadStores<String>()
        none.store(for: "a").preview(snapshot("a"))
        #expect(none.enforceMountedBudget(budget: 0, keep: 0, limit: .max) == (0, 0), "stores nothing mounts have no views to release")
        #expect(!none.store(for: "a").transcriptReleased)
    }

    @Test func readersGoOnlyBeyondTheTwoMostRecentlyShown() {
        let pauses = Pauses()
        defer { pauses.end() }
        let stores = mountedStores(["a", "b", "c", "d", "e", "f"], selected: "f", pauses: pauses)
        let pins = ThreadReaderPins()
        stores.pins = pins
        for key in ["a", "b", "c", "d", "e"] { pins.pin(stores.store(for: key), owner: UUID()) }

        let taken = stores.enforceMountedBudget(budget: 0, limit: .max)
        #expect(taken.threads == 3)
        for key in ["a", "b", "c"] { #expect(stores.store(for: key).transcriptReleased, "\(key) is a reader older than the two most recent") }
        for key in ["d", "e", "f"] { #expect(!stores.store(for: key).transcriptReleased, "\(key) stays") }
    }
}
