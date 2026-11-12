import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// Loaded history across Mac threads off screen: bounded by recency and bytes, never at the cost
/// of a draft, the selected thread, or a reader's place.
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
}
