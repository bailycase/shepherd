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

    /// Names the host a thread's agent runs on, for its errors' Details.
    @ObservationIgnored var hostName: ((AgentRef) -> String?)?

    /// How many threads off screen keep their history and images.
    static let retainedHistories = 6

    func store(for ref: AgentRef) -> NativeThreadStore {
        touch(ref)
        if let store = stores[ref] { return store }
        let store = NativeThreadStore()
        store.hostName = hostName?(ref)
        stores[ref] = store
        return store
    }

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
        return shared
    }

    /// Drops every thread of a forgotten host.
    func forget(host: UUID) {
        for (ref, store) in stores where ref.host == host {
            store.stop()
            stores[ref] = nil
            viewers[ref] = nil
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
            for (ref, store) in stores where ref.host == host && !agents.contains(ref.agent) && !shown(ref) {
                store.stop()
                stores[ref] = nil
                viewers[ref] = nil
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
