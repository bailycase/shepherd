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

    @discardableResult
    func dropRemoteAgent(payload: String, on target: RemoteAgentRef) -> Bool {
        let prefix = "remoteAgent:\(target.hostID.uuidString):"
        guard payload.hasPrefix(prefix) else { return false }
        let source = RemoteAgentRef(hostID: target.hostID, agentID: AgentID(rawValue: String(payload.dropFirst(prefix.count))))
        guard source != target, let agent = remoteAgent(source), let other = remoteAgent(target),
              agent.spaceID == other.spaceID else { return false }
        performRemoteAction(source, action: .reorder(target: target.agentID))
        return true
    }
}
