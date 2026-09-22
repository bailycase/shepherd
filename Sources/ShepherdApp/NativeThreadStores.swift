import Foundation
import ShepherdCore
import ShepherdRemote

/// One `NativeThreadStore` per agent (local `AgentID` or remote `RemoteAgentRef`), kept for
/// the agent's lifetime so drafts, history pages, and scroll state survive switching.
@MainActor
final class NativeThreadStores<Key: Hashable> {
    private var stores: [Key: NativeThreadStore] = [:]

    func store(for key: Key) -> NativeThreadStore {
        if let store = stores[key] { return store }
        let store = NativeThreadStore()
        stores[key] = store
        return store
    }

    func prune(live: Set<Key>) {
        for key in Set(stores.keys).subtracting(live) { stores.removeValue(forKey: key)?.stop() }
    }
}

/// The agent whose pi runs in `pane` (its primary pane). Auxiliary panes are shells.
func primaryAgent(in tab: Tab, pane: LeafPane, agents: [Agent]) -> Agent? {
    guard !tab.isShell, pane.isReview != true, tab.inspectorFor == nil else { return nil }
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
