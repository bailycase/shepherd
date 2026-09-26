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
}
