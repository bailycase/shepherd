import Foundation
import SystemConfiguration
import ShepherdCore
import ShepherdRemote
import ShepherdUI

/// What a pass that lets hidden threads' rows go finds the app doing when it looks (`NativeThreadStores.busy`).
enum ThreadPassWait: Equatable {
    /// Nothing the pass waits for.
    case idle
    /// The person is typing or scrolling: the pass waits for as long as that lasts, never running in the middle of a keystroke.
    case input
    /// A thread on screen is streaming a reply: the pass waits, but only so long (`NativeThreadStores.patience`).
    case streaming
}

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
/// recently shown hidden threads let their rows go (`NativeThreadStore.releaseTranscript`), a pass at a time and the oldest
/// rows of the thread shown longest ago first: `releaseStep` bytes of them from one thread, or what the hidden threads are over by,
/// at most `releaseCeiling` while the app is idle or a stream lasts and a pass can take much off them, and at most `releaseFarCeiling`
/// while the app is idle and a pass can take much off them (`farOverBudget`). Unpinned threads go first, then readers left scrolled up beyond
/// the `keepPinned` most recently shown. The newest hidden thread, the ones on screen and the selected one are never taken. Only the thread view's rows go,
/// and not its last screen (`NativeThreadStore.keptRows`): the host, the page, the history, the caches, the draft and the rows
/// at the end of the thread stay, so showing a thread draws its tail in the update that shows it, never blank and with nothing
/// to build, and the rows above it come back after that frame (`ThreadView`). A reader taken this way comes back at the tail of
/// its thread, not at its place (`ThreadView`). A pass waits (`busy`) for as long as the person scrolls or types, and while a thread
/// on screen streams for at most `patience` looks, so that a long stream cannot hold it off for good (it takes a step then), or not
/// at all while it can take much off the hidden threads (`farOverBudget`; it takes `releaseCeiling` at most).
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
    /// How many rows at the end of `store`'s thread its view builds: the rows it last drew (`NativeThreadStore.drawnEagerRows`), or
    /// where it has not drawn yet, what the rule gives (`NativeThreadStore.eagerTailRows`) for the default window and every row: the
    /// view may leave some out (a Project's wake-ups) or be another height, which it corrects when it draws.
    private func eagerRows(of store: NativeThreadStore) -> Int {
        min(eagerRows, store.drawnEagerRows ?? store.eagerTailRows(maxRows: eagerRows, costCap: eagerCostCap, coveringHeight: eagerCoverHeight))
    }

    /// What the views of `store`'s thread hold, as the passes count it (`NativeThreadStore.mountedCost` of the rows its view builds).
    func mountedCost(of store: NativeThreadStore) -> Int { store.mountedCost(eagerRows: eagerRows(of: store)) }

    /// The keys whose threads have a view mounted, hidden or not; nil where no hidden thread has a view to hold rows (a set
    /// of stores nothing mounts), so nothing is released.
    var mounted: (() -> Set<Key>)?
    /// How many rows at the end of a thread its view builds, at most (`NativeThreadStore.mountedCost`).
    var eagerRows = ThreadView.eagerRows
    /// What the views of those rows may hold before the view builds fewer (`NativeThreadStore.eagerTailRows`).
    var eagerCostCap = NativeMountedCost.eagerTailCap
    /// The height of rows a view builds at least, for a thread whose view has not drawn yet (one that has says how many it built).
    var eagerCoverHeight = AppLayout.eagerTailHeight(cover: AppLayout.eagerCoverHeight(forViewport: AppLayout.windowDefaultHeight))
    /// Readers left scrolled up, most recently shown first, that a pass leaves alone: older ones lose their place once the
    /// budget is over and come back at their tail.
    var keepPinned = 2
    /// How long after the last show the first pass runs, and between the passes that follow while the budget is over.
    var releaseDelay: Duration = .seconds(2)
    var releaseSpacing: Duration = .milliseconds(250)
    /// How long after a show the first pass runs while the hidden threads are far over the budget (`farOverBudget`): the shows come
    /// faster than passes that waited `releaseDelay` for each let go of what they build.
    var releaseUrgentDelay: Duration = .milliseconds(500)
    /// The estimated bytes of rows a pass lets go of, at most (a row larger than it goes whole, as a pass lets go of at least one), from one
    /// thread, after a thread on screen has streamed for `patience` looks without a pass being far over the budget (`farOverBudget`); it is
    /// also the least a quiet pass takes. A pass costs the main thread a layout of the whole mounted tree, tens of milliseconds, whether it
    /// takes one row or eight, so a smaller step makes more passes and more of those stalls for the same memory, and shortens none.
    var releaseStep = 32 << 20
    /// What a pass lets go of, at most, while the app is idle (no key or scroll, no thread on screen streaming), or a thread streams and a
    /// pass can take much off the hidden threads (`farOverBudget`): what they are over by, if that is more than a step. Showing a thread
    /// builds its rows again, hundreds of megabytes of them in a few seconds, and the time to the next show gives the passes a few looks: a
    /// step a pass never caught up with the shows while the person switched from one thread to the next, and the hidden threads grew to
    /// the abort. A stream's pass takes no more than this, so that it stalls the stream no more than a quiet one's.
    var releaseCeiling = 128 << 20
    /// What a pass lets go of, at most, while the app is idle and a pass can take much off the hidden threads (`farOverBudget`). Letting rows
    /// go costs the main thread a sixth of what building them does, and a pass that takes one 250 MB row between two steps of a restore that
    /// builds one lets go of no more than the restore builds: the threads stayed at 5 GB or more, and the app aborted after fifty minutes.
    var releaseFarCeiling = 1 << 30
    /// What the app is doing that a pass waits for (`ThreadPassWait`): it waits `releaseSpacing` and looks again.
    var busy: (() -> ThreadPassWait)?
    /// How many looks in a row a pass waits for a thread on screen to stop streaming before it runs anyway (ten seconds at the default
    /// spacing), so that a thread that streams for minutes cannot hold the budget off for good; the pass after it waits as long again.
    /// Typing and scrolling use none of it: a pass never runs while they last.
    var patience = 40
    private var putOff = 0
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
    /// looked at once the show has settled (`releaseDelay` after the last one, `releaseUrgentDelay` while they are far over the budget).
    func noteShown(_ key: Key) {
        recent.removeAll { $0 == key }
        recent.append(key)
        // After the show, not in it: views call this as they draw, and the costs read here are never read, or tracked, in a view body.
        Task { @MainActor [weak self] in
            guard let self else { return }
            enforceHistoryBounds()
            scheduleMountedPass(after: farOverBudget() ? releaseUrgentDelay : releaseDelay)
        }
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
        /// It draws rows beyond its last screen; a thread that does not still counts against the budget, and a pass cannot take more from it.
        var releasable = true
    }

    /// The default `mountedBudget`: an eighth of the memory, and at most 2 GiB. The aborts this bounds look like a limit of
    /// the process (SwiftUI's attribute graph, at a footprint of about 5 GB however much memory the Mac has), so the cap
    /// follows the process and not the machine. 2 GiB is what eight code-heavy hidden threads hold, so a Mac of 16 GB or more releases nothing
    /// that today's bounds keep; an 8 GB Mac gets 1 GiB.
    static func defaultMountedBudget(physicalMemory: UInt64) -> Int {
        Int(min(2 << 30, physicalMemory / 8))
    }

    /// The threads a pass may take from, in the order it takes them, from `entries` (oldest first, the hidden threads that hold rows): the
    /// oldest unpinned ones with rows beyond their last screen, then the readers (pinned) older than the `keepPinned` most recent. The `keep`
    /// newest are never taken, whatever they are.
    private static func takeable(_ entries: [MountedEntry<Key>], keep: Int, keepPinned: Int) -> [MountedEntry<Key>] {
        let newest = Set(entries.suffix(max(0, keep)).map(\.key))
        let readers = Set(entries.filter(\.pinned).suffix(max(0, keepPinned)).map(\.key))
        return entries.filter { $0.releasable && !$0.pinned && !newest.contains($0.key) }
            + entries.filter { $0.releasable && $0.pinned && !readers.contains($0.key) && !newest.contains($0.key) }
    }

    /// The keys whose rows to let go, in the order to take them, from `entries` (oldest first, the hidden threads that hold
    /// rows): while their costs add up to more than `budget`, the threads `takeable` names.
    static func viewReleases(_ entries: [MountedEntry<Key>], keep: Int, keepPinned: Int, budget: Int) -> [Key] {
        var total = entries.reduce(0) { $0 + $1.cost }
        guard total > budget else { return [] }
        var released: [Key] = []
        for entry in takeable(entries, keep: keep, keepPinned: keepPinned) {
            guard total > budget else { break }
            total -= entry.cost
            released.append(entry.key)
        }
        return released
    }

    /// How far over `budget` the hidden threads are by what a pass can take: what they hold over it, at most what the threads `takeable`
    /// names hold. The `keep` newest, the readers kept and the threads with nothing beyond their last screen hold memory that no pass
    /// frees, so they are not part of what a pass has to catch up with.
    static func overBudget(_ entries: [MountedEntry<Key>], keep: Int, keepPinned: Int, budget: Int) -> Int {
        let held = entries.reduce(0) { $0 + $1.cost }
        guard held > budget else { return 0 }
        return min(held - budget, takeable(entries, keep: keep, keepPinned: keepPinned).reduce(0) { $0 + $1.cost })
    }

    /// What `mountedEntries` read: the hidden threads that hold rows, oldest first, and what each one's views hold.
    typealias MountedSnapshot = (entries: [MountedEntry<Key>], costs: [Key: Int])

    /// The hidden threads that hold rows, oldest first, and what their views hold (`mountedCost`); nil where nothing mounts a thread. The
    /// threads on screen and the selected one are not in it, and neither are threads that hold nothing (released whole already).
    private func mountedEntries() -> MountedSnapshot? {
        guard let mounted = mounted?() else { return nil }
        recent.removeAll { stores[$0] == nil }
        let onScreen = self.onScreen
        // Threads never shown (a hidden view built from a preview) count as the oldest.
        let shown = recent.filter(mounted.contains)
        var costs: [Key: Int] = [:]
        let entries = (Array(mounted.subtracting(shown)) + shown).compactMap { key -> MountedEntry<Key>? in
            guard !onScreen.contains(key), let store = stores[key] else { return nil }
            let cost = mountedCost(of: store)
            guard cost > 0 else { return nil }
            costs[key] = cost
            return MountedEntry(key: key, cost: cost, pinned: pins?.isPinned(store) == true, releasable: store.canReleaseTranscript)
        }
        return (entries, costs)
    }

    /// A pass can take more than a quarter of the budget or the ceiling, whichever is more, off the hidden threads (`overBudget`: not the
    /// newest one, the readers kept or what holds nothing more to give): waiting for a stream to end, or for the show that came before to
    /// settle, means more rows built meanwhile than the passes then let go of, and the abort this budget exists to prevent.
    func farOverBudget() -> Bool {
        mountedEntries().map { isFarOver($0.entries) } ?? false
    }

    private func isFarOver(_ entries: [MountedEntry<Key>]) -> Bool {
        Self.overBudget(entries, keep: 1, keepPinned: keepPinned, budget: mountedBudget) > max(mountedBudget / 4, releaseCeiling)
    }

    /// Lets the rows of the hidden threads go while their estimated views (`mountedCost`) add up to more than the budget: `step`
    /// bytes of them in all (`releaseStep` unless given), the oldest rows of the thread `viewReleases` names first, from at most
    /// `limit` threads, then the next pass `releaseSpacing` later while it is still over, so that no one pass tears down much. A thread's
    /// first step lets go of its lazy stack's rows, which the estimate does not count, and ends the pass (the thread's own rows
    /// are for the next). `ceiling`, for a pass while the app is idle or the threads are far over the budget (`farOverBudget`): what
    /// the threads are over by is the step if that is more, at most `ceiling`, a row that does not fit goes too (a step is not
    /// spent on small rows before a large one), and a thread goes on to its rows in the pass that let go of its lazy stack, but one
    /// lazy stack a pass. Threads on screen, selected or holding nothing are not asked. Costs are read here, in a pass, never in a
    /// view body. Returns the threads it took from and the bytes it took.
    @discardableResult
    func enforceMountedBudget(budget: Int? = nil, keep: Int = 1, keepPinned: Int? = nil, limit: Int = 1, step: Int? = nil, ceiling: Int? = nil, snapshot: MountedSnapshot? = nil) -> (threads: Int, bytes: Int) {
        guard let (entries, costs) = snapshot ?? mountedEntries() else { return (0, 0) }
        let budget = budget ?? mountedBudget
        let held = entries.reduce(0) { $0 + $1.cost }
        let releases = Self.viewReleases(entries, keep: keep, keepPinned: keepPinned ?? self.keepPinned, budget: budget)
        let quiet = ceiling != nil
        var room = step ?? ceiling.map { max(releaseStep, min(held - budget, $0)) } ?? releaseStep
        var freed = 0, taken = 0, more = false, lazy = false
        for key in releases {
            guard let store = stores[key] else { continue }
            guard taken < limit, room > 0 else {
                more = true
                break
            }
            let eager = eagerRows(of: store)
            // A step of everything (`.max`) lets go of the lazy stack with the rows.
            let first = room < .max && store.releasesLazyStackFirst(eagerRows: eager)
            if quiet, first, lazy {
                more = true
                continue
            }
            store.releaseTranscript(bytes: room, eagerRows: eager, keepingLastScreen: true, crossing: quiet)
            if quiet, first {
                lazy = true
                store.releaseTranscript(bytes: room, eagerRows: eager, keepingLastScreen: true, crossing: true)
            }
            let gone = (costs[key] ?? 0) - mountedCost(of: store)
            freed += gone
            if room < .max { room -= gone }
            taken += 1
            if store.canReleaseTranscript { more = true }
            SHRenderProbe.tick("thread.rowsReleased")
            AppSignposts.thread.emitEvent("thread rows released")
            if first, !quiet { break }
        }
        if more, held - freed > budget { scheduleMountedPass(after: releaseSpacing) }
        return (taken, freed)
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
            runMountedPass()
        }
    }

    /// A scheduled pass: the budget is enforced unless the app is busy (`busy`), when the pass waits and looks again: for as long as
    /// the person types or scrolls, and while a thread streams up to `patience` times in a row, unless a pass can take much off the
    /// hidden threads (`farOverBudget`). What a pass lets go of depends on what the app is doing: a gibibyte at most while it is idle and the
    /// threads are far over the budget, `releaseCeiling` while it is idle, or a thread streams and they are far over, and a step of one
    /// thread after a stream's patience, so that a stream's pass never tears down more than a quiet one's. Returns whether it ran.
    @discardableResult
    func runMountedPass() -> Bool {
        let wait = busy?() ?? .idle
        // The looks while the person types or scrolls read no costs.
        if wait == .input {
            scheduleMountedPass(after: releaseSpacing)
            return false
        }
        let snapshot = mountedEntries()
        let farOver = snapshot.map { isFarOver($0.entries) } ?? false
        if wait == .streaming, putOff < patience, !farOver {
            putOff += 1
            scheduleMountedPass(after: releaseSpacing)
            return false
        }
        putOff = 0
        let ceiling: Int? = switch (wait, farOver) {
        case (.idle, true): releaseFarCeiling
        case (.idle, false), (.streaming, true): releaseCeiling
        case (.streaming, false), (.input, _): nil
        }
        enforceMountedBudget(limit: ceiling == nil ? 1 : .max, ceiling: ceiling, snapshot: snapshot)
        return true
    }

    /// The threads on screen and the selected one.
    private var onScreen: Set<Key> { (protected?() ?? []).union(live) }

    /// The content version (`NativeThreadStore.threadVersion`) of each thread on screen, by store: what `busy` compares between
    /// two looks to tell that one is streaming.
    func shownVersions() -> [ObjectIdentifier: Int] {
        var versions: [ObjectIdentifier: Int] = [:]
        for key in onScreen {
            if let store = stores[key] { versions[ObjectIdentifier(store)] = store.threadVersion }
        }
        return versions
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
    /// The stores no view shows, the one left longest ago first, until a view shows one again (`leftRecently`).
    private var left: [ObjectIdentifier] = []

    /// `owner`'s view started the store's loop; `resume` has it run the loop again.
    func started(_ store: NativeThreadStore, owner: UUID, resume: @escaping @MainActor () -> Void) {
        let id = ObjectIdentifier(store)
        var list = runners[id] ?? []
        list.removeAll { $0.owner == owner }
        list.append(Runner(owner: owner, resume: resume))
        runners[id] = list
        left.removeAll { $0 == id }
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
        if list.isEmpty {
            left.removeAll { $0 == id }
            left.append(id)
            if left.count > Self.leftLimit { left.removeFirst(left.count - Self.leftLimit) }
        }
        if handsOver, let next = list.last { next.resume() }
    }

    /// How many left stores are remembered: far more than any caller asks about, so that the list never grows with the threads closed.
    private static let leftLimit = 64

    /// Whether `store` is among the `count` stores that were left most recently: its last view stopped showing it, and no other has
    /// since, while fewer than `count` other threads were left after it.
    func leftRecently(_ store: NativeThreadStore, within count: Int) -> Bool {
        left.suffix(count).contains(ObjectIdentifier(store))
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
