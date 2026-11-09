import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

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

    /// Delete on a host's agent (its row's menu, or ⇧⌘W) does what it does to This Mac's
    /// (`requestDeleteAgent`): a plain agent asks first unless Delete agent's "Don't ask again" is
    /// set. A worktree agent opens the host's sheet unless Settings ▸ Worktrees remembers keeping
    /// the checkout; a remembered removal opens it too: the sheet probes the host, starts on its
    /// own when nothing would be lost, and shows the host's progress.
    func requestRemoteDelete(_ target: RemoteAgentRef) {
        guard let agent = remoteAgent(target) else { return }
        if agent.worktreeBranch != nil {
            if settings.worktreeDeleteAction == .keepWorktree { performRemoteAction(target, action: .deleteKeepingWorktree) }
            else { remoteWorktreeSheet = target }
        }
        else if settings.skipped(.deleteAgent) != nil { performRemoteAction(target, action: .deleteKeepingWorktree) }
        else if remoteDeleteTarget != target { remoteDeleteTarget = target }
    }

    /// The dialog's Delete: the host deletes the agent once the sheet is down, as This Mac's
    /// deletion waits.
    func confirmRemoteDelete(_ target: RemoteAgentRef) {
        afterDialogDismiss = { [weak self] in self?.performRemoteAction(target, action: .deleteKeepingWorktree) }
        remoteDeleteTarget = nil
    }
}
