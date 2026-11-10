import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

extension ShepherdViewModel {
    func remoteAgent(_ target: RemoteAgentRef) -> Agent? {
        remoteHosts.allConnections.first { $0.id == target.hostID }?.state.agents.first { $0.id == target.agentID }
    }

    func performRemoteAction(_ target: RemoteAgentRef, action: RemoteAgentAction) {
        Task {
            do { try await remoteHosts.agentAction(target, action: action) }
            catch { fail("The host refused the action", error) }
        }
    }

    /// Delete on a host's agent (its row's menu, or ⇧⌘W) does what it does to This Mac's
    /// (`requestDeleteAgent`): a plain agent asks first unless Delete agent's "Don't ask again" is
    /// set. A worktree agent of a paired Mac opens the host's sheet unless Settings ▸ Worktrees
    /// remembers keeping the checkout; a remembered removal opens it too: the sheet probes the
    /// host, starts on its own when nothing would be lost, and shows the host's progress.
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

    /// The host's checkout for the dialog, and the warning and fingerprint its removal is bound to.
    func localHostWorktreeInfo(_ target: RemoteAgentRef) async throws -> RemoteWorktreeInfo {
        guard case .worktreeInfo(let info) = try await remoteHosts.agentQuery(target, query: .worktreeInfo) else {
            throw RemoteHostClientError.rejected(code: "unexpected", message: "Shepherd's background service didn't describe the worktree.")
        }
        return info
    }

    /// `deleteWorktreeAgent`, done by the host: keeps the checkout when `info` is nil, else
    /// removes the checkout `info` describes. The thread leaves the sidebar as the host retires
    /// it; a failure reads as This Mac's.
    func deleteLocalHostWorktreeAgent(_ target: RemoteAgentRef, removing info: RemoteWorktreeInfo?) {
        Task {
            guard let info else {
                do { try await remoteHosts.agentAction(target, action: .deleteKeepingWorktree) }
                catch { fail("Couldn’t delete the agent", error) }
                return
            }
            do {
                let id = UUID()
                var result = try await remoteHosts.agentQuery(target, query: .deleteWorktree(
                    operationID: id, confirmedWarning: info.warning, fingerprint: info.fingerprint))
                while case .worktreeOperation(let operation) = result, !operation.finished {
                    try await Task.sleep(for: .milliseconds(250))
                    result = try await remoteHosts.agentQuery(target, query: .worktreeStatus(operationID: id))
                }
                if case .worktreeOperation(let operation) = result, let error = operation.error {
                    actionError = ActionError(title: "Couldn’t delete the worktree", message: error)
                }
            } catch { fail("Couldn’t delete the worktree", error) }
        }
    }
}
