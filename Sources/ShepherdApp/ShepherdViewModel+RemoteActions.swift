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
            catch { fail("The host refused the action", error) }
        }
    }

    /// A remote worktree agent's delete opens the host's sheet, unless Settings ▸ Worktrees
    /// remembers keeping the checkout. A remembered removal opens it too: the sheet probes the
    /// host, starts on its own when nothing would be lost, and shows the host's progress.
    func requestRemoteDelete(_ target: RemoteAgentRef) {
        guard let agent = remoteAgent(target) else { return }
        if agent.worktreeBranch != nil, settings.worktreeDeleteAction != .keepWorktree {
            remoteWorktreeFinalize = false
            remoteWorktreeSheet = target
        }
        else { performRemoteAction(target, action: .deleteKeepingWorktree) }
    }
}
