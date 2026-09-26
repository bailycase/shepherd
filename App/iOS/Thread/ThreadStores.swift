import Foundation
import Observation
import ShepherdRemote

/// One `NativeThreadStore` per agent, kept while the app runs, so a thread shown again keeps
/// its draft, history pages and scroll state, and a flip between agents on iPad is instant.
/// A store polls only while its thread is on screen (`ThreadScreen` runs it through
/// `viewers(for:)`, so a thread on screen in two iPad windows shares one poll loop). Every
/// window shares these stores: a draft typed in one window is the draft in another.
@MainActor
@Observable
final class ThreadStores {
    @ObservationIgnored private var stores: [AgentRef: NativeThreadStore] = [:]
    @ObservationIgnored private var viewers: [AgentRef: NativeThreadViewers] = [:]

    /// Names the host a thread's agent runs on, for its errors' Details.
    @ObservationIgnored var hostName: ((AgentRef) -> String?)?

    func store(for ref: AgentRef) -> NativeThreadStore {
        if let store = stores[ref] { return store }
        let store = NativeThreadStore()
        store.hostName = hostName?(ref)
        stores[ref] = store
        return store
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
    }
}
