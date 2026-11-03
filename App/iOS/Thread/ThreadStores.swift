import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// One `NativeThreadStore` per agent, kept while the app runs, so a thread shown again keeps
/// its draft, history pages and scroll state, and a flip between agents on iPad is instant.
/// A store polls only while its thread is on screen (`ThreadScreen` runs it through
/// `viewers(for:)`, so a thread on screen in two iPad windows shares one poll loop). Every
/// window shares these stores: a draft typed in one window is the draft in another.
///
/// Memory is bounded across threads: the `retainedHistories` most recently shown threads keep
/// their history off screen; older ones let it go (`NativeThreadStore.release`, the draft stays)
/// and reload when shown again. A thread its connected host no longer has loses its store once
/// nothing shows it.
@MainActor
@Observable
final class ThreadStores {
    @ObservationIgnored private var stores: [AgentRef: NativeThreadStore] = [:]
    @ObservationIgnored private var viewers: [AgentRef: NativeThreadViewers] = [:]
    /// Threads by when they were last asked for, most recent last.
    @ObservationIgnored private var recent: [AgentRef] = []
    /// Bumped as viewer groups come and go, so `shownRefs` is observed for new ones too.
    private var viewerGroups = 0

    /// Names the host a thread's agent runs on, for its errors' Details.
    @ObservationIgnored var hostName: ((AgentRef) -> String?)?

    /// Sends an earlier launch kept (`ThreadRecovery`): shown beside the composer to restore or
    /// discard; never sent again by the app. Loaded with the thread's store.
    private(set) var recovered: [AgentRef: [ThreadRecoveryRecord]] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    /// The agents each connected host had when its saved records were last pruned.
    @ObservationIgnored private var pruned: [UUID: Set<AgentID>] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// How many threads off screen keep their history and images.
    static let retainedHistories = 6

    func store(for ref: AgentRef) -> NativeThreadStore {
        touch(ref)
        if let store = stores[ref] { return store }
        let store = NativeThreadStore()
        store.hostName = hostName?(ref)
        stores[ref] = store
        let saved = ThreadRecovery.load(ref, defaults: defaults)
        if !saved.isEmpty { recovered[ref] = saved }
        keepSaved(ref, store: store)
        return store
    }

    /// Saves `ref`'s unresolved sends whenever its store's change (captured, refused, unknown,
    /// taken, restored, discarded), wherever the thread is shown or not: the store clears the
    /// composer when it captures a send, and the text must outlive a quit before the host answers.
    private func keepSaved(_ ref: AgentRef, store: NativeThreadStore) {
        let submissions = withObservationTracking { store.submissions } onChange: { [weak self, weak store] in
            Task { @MainActor [weak self, weak store] in
                guard let self, let store, self.stores[ref] === store else { return }
                self.keepSaved(ref, store: store)
            }
        }
        save(ref, submissions: submissions)
    }

    private func save(_ ref: AgentRef, submissions: [NativeThreadSubmission]? = nil) {
        let live = submissions ?? stores[ref]?.submissions ?? []
        ThreadRecovery.save(ThreadRecovery.records(recovered: recovered[ref] ?? [], submissions: live), for: ref, defaults: defaults)
    }

    /// Whether `ref` may capture one more send of `typed`: refused before the store clears
    /// anything once its kept sends, this launch's and earlier ones', reach the bounds.
    func admits(_ typed: String, for ref: AgentRef) -> Bool {
        ThreadRecovery.admits(typed, recovered: recovered[ref] ?? [], submissions: stores[ref]?.submissions ?? [])
    }

    /// An earlier launch's refused send, back as the draft of an empty composer; false otherwise.
    /// Its images were not kept.
    @discardableResult
    func restoreRecovered(_ id: UUID, for ref: AgentRef) -> ThreadRecoveryRecord? {
        guard let store = stores[ref], !store.hasDraft,
              let record = recovered[ref]?.first(where: { $0.id == id && $0.state == .failed }) else { return nil }
        store.draft = record.typed
        dropRecovered(id, for: ref)
        return record
    }

    /// Lets go of an earlier launch's kept send: this device's copy only; the host hears nothing.
    func discardRecovered(_ id: UUID, for ref: AgentRef) {
        dropRecovered(id, for: ref)
    }

    private func dropRecovered(_ id: UUID, for ref: AgentRef) {
        let rest = (recovered[ref] ?? []).filter { $0.id != id }
        recovered[ref] = rest.isEmpty ? nil : rest
        save(ref)
    }

    /// `ref`'s store if one exists, never making one (a revision hint wakes only what is there).
    func existingStore(for ref: AgentRef) -> NativeThreadStore? { stores[ref] }

    /// The snapshot `ref`'s store holds while its thread is on screen and polling (`isLive`), for
    /// Home to digest instead of asking the host again (`HomeFeed.openSnapshot`); nil for a thread
    /// not open, whose store may be stale.
    func liveSnapshot(for ref: AgentRef) -> NativeThreadSnapshot? {
        guard let store = stores[ref], store.isLive else { return nil }
        return store.snapshot
    }

    /// The views showing `ref`'s thread, which run its store's poll loop between them.
    func viewers(for ref: AgentRef) -> NativeThreadViewers {
        if let viewers = viewers[ref] { return viewers }
        let shared = NativeThreadViewers(store: store(for: ref))
        viewers[ref] = shared
        viewerGroups &+= 1
        return shared
    }

    /// The threads some view runs now, in any window (`NativeThreadViewers.count`): what the
    /// host's revision hints watch (`ThreadRevisionHints`). Observed.
    var shownRefs: [AgentRef] {
        _ = viewerGroups
        return viewers.compactMap { ref, group in group.count > 0 ? ref : nil }
    }

    /// Drops every thread of a forgotten host.
    func forget(host: UUID) {
        ThreadRecovery.forget(host: host, defaults: defaults)
        recovered = recovered.filter { $0.key.host != host }
        pruned[host] = nil
        for (ref, store) in stores where ref.host == host {
            store.stop()
            stores[ref] = nil
            viewers[ref] = nil
            viewerGroups &+= 1
        }
        recent.removeAll { $0.host == host }
    }

    /// Follows every host's state: a thread a connected host lost (deleted there) loses its
    /// store once nothing shows it, and a thread far from the screen lets its history go.
    func track(_ hosts: MobileHosts) {
        let live = withObservationTracking {
            hosts.hosts.map { host in (host.id, host.phase.isConnected, Set(host.state.agents.map(\.id))) }
        } onChange: { [weak self, weak hosts] in
            Task { @MainActor [weak self, weak hosts] in
                guard let self, let hosts else { return }
                self.track(hosts)
            }
        }
        for (host, connected, agents) in live where connected {
            // A thread deleted on its host takes its kept sends with it.
            if pruned[host] != agents {
                pruned[host] = agents
                let hostPrefix = ThreadRecovery.prefix + host.uuidString + "."
                for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(hostPrefix)
                    && !agents.contains(AgentID(rawValue: String(key.dropFirst(hostPrefix.count)))) {
                    defaults.removeObject(forKey: key)
                }
                for ref in recovered.keys where ref.host == host && !agents.contains(ref.agent) { recovered[ref] = nil }
            }
            for (ref, store) in stores where ref.host == host && !agents.contains(ref.agent) && !shown(ref) {
                store.stop()
                stores[ref] = nil
                viewers[ref] = nil
            viewerGroups &+= 1
                recent.removeAll { $0 == ref }
            }
        }
    }

    private func shown(_ ref: AgentRef) -> Bool {
        (viewers[ref]?.count ?? 0) > 0 || stores[ref]?.isLive == true
    }

    /// `ref` is the thread asked for now: the threads shown longest ago past `retainedHistories`
    /// let their history go, unless something still shows them. Views ask for stores as they
    /// draw, so the release lands after the pass.
    private func touch(_ ref: AgentRef) {
        if recent.last == ref { return }
        recent.removeAll { $0 == ref }
        recent.append(ref)
        var kept = 0
        var stale: [NativeThreadStore] = []
        for old in recent.reversed() where old != ref {
            guard let store = stores[old], store.holdsHistory, !shown(old) else { continue }
            kept += 1
            if kept > Self.retainedHistories { stale.append(store) }
        }
        guard !stale.isEmpty else { return }
        Task { @MainActor in
            for store in stale { store.release() }
        }
    }
}
