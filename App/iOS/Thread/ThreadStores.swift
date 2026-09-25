import Foundation
import Observation
import ShepherdRemote

/// One `NativeThreadStore` per agent, kept while the app runs, so a thread shown again keeps
/// its draft, history pages and scroll state, and a flip between agents on iPad is instant.
/// A store polls only while its thread is on screen (`ThreadScreen` runs it).
@MainActor
@Observable
final class ThreadStores {
    @ObservationIgnored private var stores: [AgentRef: NativeThreadStore] = [:]

    func store(for ref: AgentRef) -> NativeThreadStore {
        if let store = stores[ref] { return store }
        let store = NativeThreadStore()
        stores[ref] = store
        return store
    }

    /// Drops every thread of a forgotten host.
    func forget(host: UUID) {
        for (ref, store) in stores where ref.host == host {
            store.stop()
            stores[ref] = nil
        }
    }
}
