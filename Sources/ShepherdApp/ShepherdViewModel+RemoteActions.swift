import Foundation
import ShepherdCore
import ShepherdProtocol

extension ShepherdViewModel {
    func remoteAgent(_ target: RemoteAgentRef) -> Agent? {
        remoteHosts.connections.first { $0.id == target.hostID }?.state.agents.first { $0.id == target.agentID }
    }

    func performRemoteAction(_ target: RemoteAgentRef, action: RemoteAgentAction) {
        Task {
            do { try await remoteHosts.agentAction(target, action: action) }
            catch { remoteActionError = String(describing: error) }
        }
    }

    func requestRemoteDelete(_ target: RemoteAgentRef) {
        guard let agent = remoteAgent(target) else { return }
        if agent.worktreeBranch != nil {
            remoteWorktreeFinalize = false
            remoteWorktreeSheet = target
        }
        else { performRemoteAction(target, action: .deleteKeepingWorktree) }
    }

    static func dragPayload(remote target: RemoteAgentRef) -> String {
        "remoteAgent:\(target.hostID.uuidString):\(target.agentID.rawValue)"
    }

    /// The host only moves an agent *before* another, so a drop below the last agent of a
    /// group is two moves: above the target, then the target above it.
    @discardableResult
    func dropRemoteAgent(payload: String, on target: RemoteAgentRef, edge: SidebarDropEdge = .above,
                         validateOnly: Bool = false) -> Bool {
        let prefix = "remoteAgent:\(target.hostID.uuidString):"
        guard payload.hasPrefix(prefix),
              let agents = remoteHosts.connections.first(where: { $0.id == target.hostID })?.state.agents else { return false }
        let source = RemoteAgentRef(hostID: target.hostID, agentID: AgentID(rawValue: String(payload.dropFirst(prefix.count))))
        guard let moved = Self.reorderedAgents(agents, moving: source.agentID, beside: target.agentID, edge: edge) else { return false }
        guard !validateOnly else { return true }
        let spaceID = agents.first { $0.id == target.agentID }?.spaceID
        let group = moved.filter { $0.spaceID == spaceID && ($0.worktreeBranch != nil) == (remoteAgent(target)?.worktreeBranch != nil) }
        let next = group.firstIndex { $0.id == source.agentID }.flatMap { group.indices.contains($0 + 1) ? group[$0 + 1].id : nil }
        Task {
            do {
                if let next {
                    try await remoteHosts.agentAction(source, action: .reorder(target: next))
                } else {
                    try await remoteHosts.agentAction(source, action: .reorder(target: target.agentID))
                    try await remoteHosts.agentAction(target, action: .reorder(target: source.agentID))
                }
            } catch {
                remoteActionError = String(describing: error)
            }
        }
        return true
    }
}
