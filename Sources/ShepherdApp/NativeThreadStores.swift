import Foundation
import SystemConfiguration
import ShepherdCore
import ShepherdRemote

/// One `NativeThreadStore` per agent (local `AgentID` or remote `RemoteAgentRef`), kept for
/// the agent's lifetime so drafts, history pages, and scroll state survive switching.
///
/// Loaded history is bounded across threads off screen: past the `retainedHistories` most
/// recently shown, or past `historyBudget` bytes in all, the threads shown longest ago let
/// their history go (`NativeThreadStore.release`) and reload when shown again. The store, its
/// draft, attachments and deck identity stay. A thread is never released while on screen,
/// selected (`protected`), pinned by a view showing it or scrolled into its history (`ThreadReaderPins`), or
/// while the store says it holds unsettled work (`canReleaseHistory`); protected threads may
/// keep the total over budget.
@MainActor
final class NativeThreadStores<Key: Hashable> {
    private var stores: [Key: NativeThreadStore] = [:]
    private var inputs: [Key: ThreadInput] = [:]
    /// Threads off screen whose history is kept, most recent first, before older ones release it.
    var retainedHistories = 8
    /// Bytes of history (`retainedHistoryBytes`) kept across threads before older ones release it.
    var historyBudget = 96 * 1024 * 1024
    /// Readers scrolled into a hidden thread's history, shared by every window's views.
    var pins: ThreadReaderPins?
    /// Keys that are never released whatever their recency (the selected thread).
    var protected: (() -> Set<Key>)?
    /// Keys in the order their threads were last shown, oldest first.
    private(set) var recent: [Key] = []

    /// Image drafts belong to the agent, not to a mounted SwiftUI view.
    func input(for key: Key) -> ThreadInput {
        if let input = inputs[key] { return input }
        let input = ThreadInput()
        inputs[key] = input
        return input
    }
    /// The keys whose thread is on screen: its store's poll loop runs (`NativeThreadStore.isLive`).
    private(set) var live: Set<Key> = []
    /// Told the new `live` whenever it changes: the local app asks its server to push revisions
    /// for these threads only.
    var onLiveChange: ((Set<Key>) -> Void)?
    /// Names the machine a thread's agent runs on, for its errors' Details.
    var hostName: ((Key) -> String?)?
    /// Sets what the owner's state says about a store when it is made (a coordinator held off on purpose starts held off).
    var configure: ((Key, NativeThreadStore) -> Void)?
    /// Unsent drafts kept across launches, for keys with a string raw value (an `AgentID`); nil keeps none.
    var drafts: ComposerDrafts?

    func store(for key: Key) -> NativeThreadStore {
        if let store = stores[key] { return store }
        let store = NativeThreadStore()
        store.hostName = hostName?(key)
        configure?(key, store)
        install(store, for: key)
        if let drafts, let id = Self.draftID(key) {
            if store.draft.isEmpty, let saved = drafts.restore(id) { store.draft = saved }
            // Sends captured before the last quit or crash: back as of unknown outcome, never sent again.
            store.adoptRecovered(drafts.recovered(id))
            watchRecoveries(store, key: key, id: id, drafts: drafts)
            watchDraft(store, key: key, id: id, drafts: drafts)
        }
        return store
    }

    private static func draftID(_ key: Key) -> String? { (key as? any RawRepresentable)?.rawValue as? String }

    /// Each change of the store's draft is noted (debounced in `drafts`), for as long as the store is this key's.
    private func watchDraft(_ store: NativeThreadStore, key: Key, id: String, drafts: ComposerDrafts) {
        withObservationTracking { _ = store.draft } onChange: { [weak self, weak store] in
            Task { @MainActor [weak self, weak store] in
                guard let self, let store, stores[key] === store else { return }
                drafts.note(id, draft: store.draft)
                watchDraft(store, key: key, id: id, drafts: drafts)
            }
        }
    }

    /// The store's captured sends, kept as they change. A capture is written at once, before its emptied
    /// draft can be; a record leaving (accepted, discarded, restored into the draft) is written with
    /// the draft as it is then, so restored words are never only in memory.
    private func watchRecoveries(_ store: NativeThreadStore, key: Key, id: String, drafts: ComposerDrafts) {
        store.onRecoveryChanged = { [weak self, weak store] records in
            guard let self, let store, stores[key] === store else { return }
            if records.count >= drafts.recovered(id).count {
                drafts.saveRecoveries(id, records)
            } else {
                Task { @MainActor [weak self, weak store] in
                    // A deleted agent's store writes nothing late.
                    guard let self, let store, self.stores[key] === store else { return }
                    drafts.note(id, draft: store.draft)
                    drafts.saveRecoveries(id, store.recoverySnapshot)
                }
            }
        }
    }

    /// Gives `key` a store made elsewhere (a test's, which never polls on its own).
    func install(_ store: NativeThreadStore, for key: Key) {
        stores[key] = store
        store.onLiveChange = { [weak self] isLive in self?.setLive(key, isLive) }
        setLive(key, store.isLive)
    }

    private func setLive(_ key: Key, _ isLive: Bool) {
        let changed = isLive ? live.insert(key).inserted : live.remove(key) != nil
        if changed { onLiveChange?(live) }
        if changed, isLive { noteShown(key) }
    }

    /// `key`'s thread came on screen: the least recent threads past the bounds let their history go,
    /// after the pass that showed it (views ask for stores as they draw).
    func noteShown(_ key: Key) {
        recent.removeAll { $0 == key }
        recent.append(key)
        Task { @MainActor [weak self] in self?.enforceHistoryBounds() }
    }

    /// Releases what `Self.evictions` picks. Costs are read here, once per thread shown, never in a view body.
    func enforceHistoryBounds() {
        recent.removeAll { stores[$0] == nil }
        let protected = (protected?() ?? []).union(live).union(recent.suffix(1))
        let entries = recent.compactMap { key -> HistoryEntry<Key>? in
            guard let store = stores[key], store.holdsHistory else { return nil }
            let pinned = protected.contains(key) || pins?.isPinned(store) == true || !store.canReleaseHistory
            return HistoryEntry(key: key, bytes: store.retainedHistoryBytes, pinned: pinned)
        }
        for key in Self.evictions(entries, keep: retainedHistories, budget: historyBudget) {
            stores[key]?.release()
        }
    }

    struct HistoryEntry<K> {
        let key: K
        let bytes: Int
        /// On screen, selected, read, or holding unsettled work: kept whatever the bounds.
        let pinned: Bool
    }

    /// The keys to release, oldest first, from `entries` (oldest first, only threads holding
    /// history): unpinned ones past the `keep` most recent, then more while the total is over `budget`.
    static func evictions(_ entries: [HistoryEntry<Key>], keep: Int, budget: Int) -> [Key] {
        var total = entries.reduce(0) { $0 + $1.bytes }
        var unpinned = entries.filter { !$0.pinned }
        var released: [Key] = []
        while let oldest = unpinned.first, unpinned.count > keep || total > budget {
            unpinned.removeFirst()
            total -= oldest.bytes
            released.append(oldest.key)
        }
        return released
    }

    /// The agent's store if its thread has been shown, without making one: a pushed revision
    /// for a thread never shown has nothing to wake.
    func existing(for key: Key) -> NativeThreadStore? { stores[key] }

    func prune(live: Set<Key>) {
        for key in Set(stores.keys).subtracting(live) { stores.removeValue(forKey: key)?.stop() }
        recent.removeAll { stores[$0] == nil }
        for key in Set(inputs.keys).subtracting(live) { inputs.removeValue(forKey: key) }
    }
}

/// The views that need a thread's loaded history: every view showing it on screen, whichever
/// one's loop polls the store, and a hidden but mounted one (a deck layout, a Mission station, a
/// design chat) left scrolled up into the history, so its place survives. Per view owner, so one
/// view leaving or hiding never unpins another's.
///
/// It also hands a store's poll loop back when views share it (a deck thread and a Mission
/// station): the newest view to show the thread runs the loop (a run ends the one before it);
/// when that view hides or goes, the most recent view still showing the thread runs it again. A
/// loop stopped for any other reason (the store detached, the agent held off) is not restarted.
/// Pins (who needs the history) and the loop (who polls) stay separate.
@MainActor
final class ThreadReaderPins {
    private var owners: [ObjectIdentifier: Set<UUID>] = [:]
    private struct Runner {
        let owner: UUID
        let resume: @MainActor () -> Void
        /// Its loop returned on its own (stopped, detached, or taken over), not because the view left.
        var ended = false
    }
    /// Views showing each store, oldest first; the last started the loop that runs.
    private var runners: [ObjectIdentifier: [Runner]] = [:]

    /// `owner`'s view started the store's loop; `resume` has it run the loop again.
    func started(_ store: NativeThreadStore, owner: UUID, resume: @escaping @MainActor () -> Void) {
        let id = ObjectIdentifier(store)
        var list = runners[id] ?? []
        list.removeAll { $0.owner == owner }
        list.append(Runner(owner: owner, resume: resume))
        runners[id] = list
    }

    /// `owner`'s loop returned while its view still shows the thread: it was stopped or detached
    /// (or another view took it over). Its view leaving later hands nothing back.
    func loopEnded(_ store: NativeThreadStore, owner: UUID) {
        let id = ObjectIdentifier(store)
        guard let index = runners[id]?.firstIndex(where: { $0.owner == owner }) else { return }
        runners[id]?[index].ended = true
    }

    /// `owner`'s view no longer shows the store. If its loop was the one still running, the most
    /// recent view still showing the thread runs it again; a loop that was stopped stays stopped.
    func stopped(_ store: NativeThreadStore, owner: UUID) {
        let id = ObjectIdentifier(store)
        guard var list = runners[id], let index = list.firstIndex(where: { $0.owner == owner }) else { return }
        let handsOver = index == list.count - 1 && !list[index].ended
        list.remove(at: index)
        runners[id] = list.isEmpty ? nil : list
        if handsOver, let next = list.last { next.resume() }
    }

    func pin(_ store: NativeThreadStore, owner: UUID) {
        owners[ObjectIdentifier(store), default: []].insert(owner)
    }

    func unpin(_ store: NativeThreadStore, owner: UUID) {
        let id = ObjectIdentifier(store)
        owners[id]?.remove(owner)
        if owners[id]?.isEmpty == true { owners[id] = nil }
    }

    func isPinned(_ store: NativeThreadStore) -> Bool { owners[ObjectIdentifier(store)] != nil }
}

/// This Mac's name ("build-01"), read once: the host its own agents' errors name.
let localHostName: String? = {
    let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return name?.isEmpty == false ? name : nil
}()

/// The agent whose pi runs in `pane` (its primary pane). Other panes are terminals.
func primaryAgent(in tab: Tab, pane: LeafPane, agents: [Agent]) -> Agent? {
    guard tab.spaceID != nil, pane.isReview != true, tab.inspectorFor == nil else { return nil }
    return agents.first { $0.id == pane.agentID && $0.tabID == tab.id && $0.paneID == pane.id }
}

/// Every agent now runs over RPC. Agents persisted by the terminal era carry
/// `"runtime": "terminal"`, which `Agent` ignores, so on relaunch each one resumes its own pi
/// session (`--session-id`) as an RPC agent, all at once. What remains is presentation state
/// from that era, which this clears.
enum LegacyTerminalAgents {
    static let obsoleteKeys = [
        "shepherd.nativeAgents",
        "shepherd.nativeDefault",
        "shepherd.agent.defaultRuntime",
    ]

    static func forgetPresentationPreferences(in defaults: UserDefaults) {
        for key in obsoleteKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }
}
