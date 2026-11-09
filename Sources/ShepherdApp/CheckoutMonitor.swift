import Foundation
import ShepherdCore

extension ShepherdViewModel {
    /// The directory an agent's pi works in: its thread pane's, else its worktree's.
    func checkoutDirectory(of id: AgentID) -> String? {
        // A thread of This Mac's background host checks out on this machine too.
        let state = state.agents.contains(where: { $0.id == id }) ? state : thisMacAgent(id)?.connection.state ?? state
        guard let agent = state.agents.first(where: { $0.id == id }) else { return nil }
        let layout = state.tabs.first { $0.id == agent.tabID }?.layout
        return layout?.leaves.first { $0.agentID == id }?.cwd ?? agent.worktreePath ?? layout?.firstLeaf.cwd
    }
}
