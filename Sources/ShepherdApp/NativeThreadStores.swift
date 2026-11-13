import Foundation
import SystemConfiguration
import ShepherdCore
import ShepherdRemote
import ShepherdUI

/// One `NativeThreadStore` per agent (local `AgentID` or remote `RemoteAgentRef`), kept for
/// the agent's lifetime so drafts, history pages, and scroll state survive switching.
///
/// Threads off screen are bounded across threads in two tiers, each by recency of showing.
///
/// Loaded history: past the `retainedHistories` most recently shown, or past `historyBudget` bytes in all, the threads
/// shown longest ago let their history go (`NativeThreadStore.release`) and reload when shown again. The store, its
/// draft, attachments and deck identity stay. A thread is never released while on screen, selected (`protected`),
/// pinned by a view showing it or scrolled into its history (`ThreadReaderPins`), or while the store says it holds
/// unsettled work (`canReleaseHistory`); protected threads may keep the total over budget.
///
/// Row views: a hidden layout stays mounted and its thread keeps the views of its last rows, which are most of what the
/// app holds (`NativeThreadStore.mountedCost` estimates them). Past `mountedBudget` bytes of them in all, the least
/// recently shown hidden threads let their rows go (`NativeThreadStore.releaseTranscript`), one thread a pass and `releaseStep`
/// bytes of its rows at a time, unpinned ones first, then readers left scrolled up beyond the `keepPinned` most recently
/// shown. The newest hidden thread, the ones on screen and the selected one are never taken. Only the thread view's rows go:
/// the host, the page, the history, the caches and the draft stay, so showing a thread draws its rows from them in the
/// update that shows it, never blank. A reader taken this way comes back at the tail of its thread, not at its place
/// (`ThreadView`).
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

    /// Estimated bytes (`NativeThreadStore.mountedCost`) the row views of the hidden threads may hold in all before the
    /// least recently shown let their rows go. Setting it runs a pass.
    var mountedBudget = NativeThreadStores.defaultMountedBudget(physicalMemory: ProcessInfo.processInfo.physicalMemory) {
        didSet { if mountedBudget != oldValue { enforceMountedBudget() } }
    }
    /// The keys whose threads have a view mounted, hidden or not; nil where no hidden thread has a view to hold rows (a set
    /// of stores nothing mounts), so nothing is released.
    var mounted: (() -> Set<Key>)?
    /// How many rows at the end of a thread its view builds (`NativeThreadStore.mountedCost`).
    var eagerRows = ThreadView.eagerRows
    /// Readers left scrolled up, most recently shown first, that a pass leaves alone: older ones lose their place once the
    /// budget is over and come back at their tail.
    var keepPinned = 2
    /// How long after the last show the first pass runs, and between the passes that follow while the budget is over.
    var releaseDelay: Duration = .seconds(2)
    var releaseSpacing: Duration = .milliseconds(250)
    /// The estimated bytes of one thread's rows a pass lets go of, at most (a row larger than it goes whole, as a pass lets go
    /// of at least one): a thread's views take a few hundred milliseconds to tear down in one update, with a code-heavy
    /// thread's rows tens of milliseconds each, so no pass takes much of the main thread.
    var releaseStep = 32 << 20
    /// Waits out a pass's delay (a test replaces it, and the timer with it).
    var pause: @MainActor @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    private var mountedPass: Task<Void, Never>?

    /// Image drafts belong to the agent, not to a mounted SwiftUI view.
    func input(for key: Key) -> ThreadInput {
        if let input = inputs[key] { return input }
        let input = ThreadInput()
        inputs[key] = input
        return input
    }
    /// The keys whose thread is on screen, in a window that can be seen: its store wants the host's pushed
    /// revisions (`NativeThreadStore.wantsRevisions`). A resting store (`rest`) is not in it, though its loop runs.
    private(set) var live: Set<Key> = []
    /// Told the new `live` whenever it changes: the hosts are asked to push revisions for these threads only.
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

    /// The store's captured sends, kept through a quit or crash (text only). A capture is written at the
    /// capture itself (`captureAdmission`, the exact payload, before the draft clears or anything is sent);
    /// a record leaving (accepted, discarded, restored into the draft) is written with the draft as it is
    /// then, draft first, so restored words are never only in memory. A pruned agent's store writes nothing.
    private func watchRecoveries(_ store: NativeThreadStore, key: Key, id: String, drafts: ComposerDrafts) {
        store.captureAdmission = { [weak self, weak store] submission in
            guard let self, let store, self.stores[key] === store else { return true }
            let record = NativeRecoveredSubmission(id: submission.id, typed: submission.typed, sessionID: store.snapshot?.piSessionID,
                                                   generation: store.snapshot?.generation, capturedAt: Date().timeIntervalSince1970 * 1000)
            drafts.saveRecoveries(id, store.recoverySnapshot + [record])
            return true
        }
        store.onRecoveryChanged = { [weak self, weak store] records in
            guard let self, let store, self.stores[key] === store, records.count < drafts.recovered(id).count else { return }
            Task { @MainActor [weak self, weak store] in
                // Written from the store as it is then: a record discarded meanwhile never comes back.
                guard let self, let store, self.stores[key] === store else { return }
                drafts.note(id, draft: store.draft)
                drafts.saveRecoveries(id, store.recoverySnapshot)
            }
        }
    }

    /// Gives `key` a store made elsewhere (a test's, which never polls on its own).
    func install(_ store: NativeThreadStore, for key: Key) {
        stores[key] = store
        store.onLiveChange = { [weak self] isLive in self?.setLive(key, isLive) }
        setLive(key, store.wantsRevisions)
    }

    private func setLive(_ key: Key, _ isLive: Bool) {
        let changed = isLive ? live.insert(key).inserted : live.remove(key) != nil
        if changed { onLiveChange?(live) }
        if changed, isLive { noteShown(key) }
    }

    /// `key`'s thread came on screen: the least recent threads past the bounds let their history go,
    /// after the pass that showed it (views ask for stores as they draw), and the hidden threads' rows are
    /// looked at once the show has settled (`releaseDelay` after the last one).
    func noteShown(_ key: Key) {
        recent.removeAll { $0 == key }
        recent.append(key)
        Task { @MainActor [weak self] in self?.enforceHistoryBounds() }
        scheduleMountedPass(after: releaseDelay)
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

    // MARK: Hidden threads' row views

    /// One thread whose hidden view holds rows, for `viewReleases`.
    struct MountedEntry<K> {
        let key: K
        /// What its row views hold (`NativeThreadStore.mountedCost`); above zero.
        let cost: Int
        /// A reader is left scrolled up in it (`ThreadReaderPins`): letting its rows go brings it back at its tail.
        let pinned: Bool
    }

    /// The default `mountedBudget`: an eighth of the memory, and at most 2 GiB. The aborts this bounds look like a limit of
    /// the process (SwiftUI's attribute graph, at a footprint of about 5 GB however much memory the Mac has), so the cap
    /// follows the process and not the machine. 2 GiB is what eight code-heavy hidden threads hold, so a Mac of 16 GB or more releases nothing
    /// that today's bounds keep; an 8 GB Mac gets 1 GiB.
    static func defaultMountedBudget(physicalMemory: UInt64) -> Int {
        Int(min(2 << 30, physicalMemory / 8))
    }

    /// The keys whose rows to let go, in the order to take them, from `entries` (oldest first, the hidden threads that hold
    /// rows): while their costs add up to more than `budget`, the oldest unpinned ones, then the readers (pinned) older than
    /// the `keepPinned` most recent. The `keep` newest are never taken, whatever they are.
    static func viewReleases(_ entries: [MountedEntry<Key>], keep: Int, keepPinned: Int, budget: Int) -> [Key] {
        var total = entries.reduce(0) { $0 + $1.cost }
        guard total > budget else { return [] }
        let newest = Set(entries.suffix(max(0, keep)).map(\.key))
        let readers = Set(entries.filter(\.pinned).suffix(max(0, keepPinned)).map(\.key))
        let order = entries.filter { !$0.pinned && !newest.contains($0.key) }
            + entries.filter { $0.pinned && !readers.contains($0.key) && !newest.contains($0.key) }
        var released: [Key] = []
        for entry in order {
            guard total > budget else { break }
            total -= entry.cost
            released.append(entry.key)
        }
        return released
    }

    /// Lets the rows of the hidden threads go while their estimated views (`mountedCost`) add up to more than the budget:
    /// `step` bytes of at most `limit` threads (`releaseStep` unless given), then the next pass `releaseSpacing` later while it is
    /// still over, so that no one pass tears down much. Threads on screen, selected or holding nothing (released whole already)
    /// are not asked. Costs are read here, in a pass, never in a view body. Returns the threads it took from and the bytes it took.
    @discardableResult
    func enforceMountedBudget(budget: Int? = nil, keep: Int = 1, keepPinned: Int? = nil, limit: Int = 1, step: Int? = nil) -> (threads: Int, bytes: Int) {
        guard let mounted = mounted?() else { return (0, 0) }
        recent.removeAll { stores[$0] == nil }
        let onScreen = (protected?() ?? []).union(live)
        // Threads never shown (a hidden view built from a preview) count as the oldest.
        let shown = recent.filter(mounted.contains)
        var costs: [Key: Int] = [:]
        let entries = (Array(mounted.subtracting(shown)) + shown).compactMap { key -> MountedEntry<Key>? in
            guard !onScreen.contains(key), let store = stores[key] else { return nil }
            let cost = store.mountedCost(eagerRows: eagerRows)
            guard cost > 0 else { return nil }
            costs[key] = cost
            return MountedEntry(key: key, cost: cost, pinned: pins?.isPinned(store) == true)
        }
        let budget = budget ?? mountedBudget
        let releases = Self.viewReleases(entries, keep: keep, keepPinned: keepPinned ?? self.keepPinned, budget: budget)
        var freed = 0, more = releases.count > limit
        for key in releases.prefix(limit) {
            guard let store = stores[key] else { continue }
            store.releaseTranscript(bytes: step ?? releaseStep, eagerRows: eagerRows)
            let left = store.mountedCost(eagerRows: eagerRows)
            freed += (costs[key] ?? 0) - left
            if left > 0 { more = true }
            SHRenderProbe.tick("thread.rowsReleased")
            AppSignposts.thread.emitEvent("thread rows released")
        }
        if more, entries.reduce(0, { $0 + $1.cost }) - freed > budget { scheduleMountedPass(after: releaseSpacing) }
        return (min(limit, releases.count), freed)
    }

    /// The next pass, `delay` from now in place of any waiting.
    private func scheduleMountedPass(after delay: Duration) {
        mountedPass?.cancel()
        mountedPass = nil
        guard mounted != nil else { return }
        let pause = pause
        mountedPass = Task { @MainActor [weak self] in
            await pause(delay)
            guard !Task.isCancelled, let self else { return }
            mountedPass = nil
            enforceMountedBudget()
        }
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
/// one's loop polls the store, and a hidden but mounted one (a deck layout, a design chat)
/// left scrolled up into the history, so its place survives. Per view owner, so one view
/// leaving or hiding never unpins another's.
///
/// It also hands a store's poll loop back when views share it: the newest view to show the
/// thread runs the loop (a run ends the one before it);
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
