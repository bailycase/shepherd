import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

extension ShepherdViewModel {
    func remoteAgent(_ target: RemoteAgentRef) -> Agent? {
        remoteHosts.allConnections.first { $0.id == target.hostID }?.state.agents.first { $0.id == target.agentID }
    }

    func performRemoteAction(_ target: RemoteAgentRef, action: RemoteAgentAction) {
        if case .rename(let name) = action { renameThread(.remote(target), to: name); return }
        if case .deleteKeepingWorktree = action, !beginClosingThread(.remote(target)) { return }
        Task {
            do { try await remoteHosts.agentAction(target, action: action) }
            catch {
                if case .deleteKeepingWorktree = action { closingThreads.remove(.remote(target)) }
                fail("The host refused the action", error)
            }
        }
    }

    /// Delete on a host's agent (its row's menu, or ⇧⌘W) does what it does to This Mac's
    /// (`requestDeleteAgent`): a plain agent asks first unless Delete agent's "Don't ask again" is
    /// set. A remembered worktree removal probes in the background; loss still needs confirmation.
    func requestRemoteDelete(_ target: RemoteAgentRef) {
        guard let agent = remoteAgent(target) else { return }
        if agent.worktreeBranch != nil {
            if settings.worktreeDeleteAction == .keepWorktree { performRemoteAction(target, action: .deleteKeepingWorktree) }
            else if settings.worktreeDeleteAction == .removeWorktree, remoteWorktreeOperationIDs[target] == nil,
                    let connection = remoteHosts.connections.first(where: { $0.id == target.hostID }) {
                removeHostWorktree(target, confirmed: nil, endpoint: connection.endpointID, transport: connection.transportID)
            } else { remoteWorktreeSheet = target }
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
    func localHostWorktreeInfo(_ target: RemoteAgentRef, endpoint: UUID? = nil, transport: UUID? = nil) async throws -> RemoteWorktreeInfo {
        guard case .worktreeInfo(let info) = try await remoteHosts.agentQuery(target, query: .worktreeInfo, endpointID: endpoint, transportID: transport) else {
            throw RemoteHostClientError.rejected(code: "unexpected", message: "Shepherd's background service didn't describe the worktree.")
        }
        return info
    }

    /// Navigate before the checkout probe. A remembered removal never acknowledges lost work.
    func removeHostWorktree(_ target: RemoteAgentRef, confirmed: RemoteWorktreeInfo?, endpoint: UUID? = nil, transport: UUID? = nil,
                            askBeforeLoss: Bool = true) {
        let remote = endpoint != nil
        let row = remote ? SidebarRowID.remote(target) : .local(target.agentID)
        guard beginClosingThread(row) else { return }
        Task {
            do {
                let info: RemoteWorktreeInfo
                if let confirmed { info = confirmed }
                else if !askBeforeLoss { info = try await localHostWorktreeInfo(target, endpoint: endpoint, transport: transport) }
                else {
                    let probe = try? await localHostWorktreeInfo(target, endpoint: endpoint, transport: transport)
                    guard let probe, probe.warning == nil else {
                        closingThreads.remove(row)
                        if remote { remoteWorktreeSheet = target }
                        else { hostWorktreeInfo[target.agentID] = probe; worktreeDeleteTarget = target.agentID }
                        return
                    }
                    info = probe
                }
                let id = UUID()
                if remote {
                    remoteWorktreeOperationIDs[target] = id
                    remoteWorktreeOperationEndpoints[target] = endpoint
                }
                var result: RemoteAgentResult
                do {
                    result = try await remoteHosts.agentQuery(target, query: .deleteWorktree(
                        operationID: id, confirmedWarning: info.warning, fingerprint: info.fingerprint), endpointID: endpoint, transportID: transport)
                } catch RemoteHostClientError.rejected(let code, let message) {
                    remoteWorktreeOperationIDs[target] = nil
                    remoteWorktreeOperationEndpoints[target] = nil
                    throw RemoteHostClientError.rejected(code: code, message: message)
                }
                while case .worktreeOperation(let operation) = result {
                    if operation.finished {
                        if remote { remoteWorktreeOperationIDs[target] = nil; remoteWorktreeOperationEndpoints[target] = nil }
                        if let error = operation.error {
                            closingThreads.remove(row)
                            actionError = ActionError(title: "Couldn’t delete the worktree", message: error)
                        }
                        return
                    }
                    try await Task.sleep(for: .milliseconds(250))
                    result = try await remoteHosts.agentQuery(target, query: .worktreeStatus(operationID: id), endpointID: endpoint)
                }
                throw RemoteHostClientError.outcomeUnknown(message: "The host didn't report the worktree operation's status.")
            } catch {
                closingThreads.remove(row)
                if remote, remoteWorktreeOperationIDs[target] != nil { remoteWorktreeSheet = target }
                else { fail("Couldn’t delete the worktree", error) }
            }
        }
    }
}
