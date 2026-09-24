import Foundation
import ShepherdCore
import ShepherdRemote

/// One `NativeThreadStore` per agent (local `AgentID` or remote `RemoteAgentRef`), kept for
/// the agent's lifetime so drafts, history pages, and scroll state survive switching.
@MainActor
final class NativeThreadStores<Key: Hashable> {
    private var stores: [Key: NativeThreadStore] = [:]
    /// The keys whose thread is on screen: its store's poll loop runs (`NativeThreadStore.isLive`).
    private(set) var live: Set<Key> = []
    /// Told the new `live` whenever it changes: the local app asks its server to push revisions
    /// for these threads only.
    var onLiveChange: ((Set<Key>) -> Void)?

    func store(for key: Key) -> NativeThreadStore {
        if let store = stores[key] { return store }
        let store = NativeThreadStore()
        install(store, for: key)
        return store
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
    }

    /// The agent's store if its thread has been shown, without making one: a pushed revision
    /// for a thread never shown has nothing to wake.
    func existing(for key: Key) -> NativeThreadStore? { stores[key] }

    func prune(live: Set<Key>) {
        for key in Set(stores.keys).subtracting(live) { stores.removeValue(forKey: key)?.stop() }
    }
}

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
