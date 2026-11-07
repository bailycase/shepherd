import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

extension ShepherdViewModel {
    /// What this Mac's worktree queries act through: Settings ▸ Worktrees, the view model's own
    /// delete, its tabs and its utility terminals.
    func installWorktreeHosting() {
        worktrees.hosting = WorktreeHosting(defaults: { [unowned self] in settings.worktreeHostingDefaults }, deleteAgent: { [weak self] id, worktreeOperation in
            guard let self else { throw RemoteCreateAgentError("Host is shutting down") }
            if worktreeOperation, let tail = persistenceTail { await tail.value }
            try await deleteAgentPersisted(id, worktreeOperation: worktreeOperation)
        }, tabs: { [weak self] in self?.state.tabs ?? [] }, terminal: { [weak self] agent, cwd, key, command in
            guard let self else { throw RemoteCreateAgentError("Host is shutting down") }
            return try await openRemoteUtilityTerminal(agent: agent, cwd: cwd, key: key, command: command)
        }, committed: { [weak self] agentID in
            // This Mac's open reviews of the committed checkout reload, so the committed files
            // leave the diff.
            guard let self else { return }
            for session in reviewSessions.values where session.agentID == agentID {
                reloadReview(session, reference: session.reference)
            }
        })
    }

    func handleRemoteWorktree(_ agentID: AgentID, query: RemoteAgentQuery) async throws -> RemoteAgentResult {
        try await worktrees.worktree(agentID, query: query)
    }

    func verifyCheckoutAvailable(_ cwd: String) throws {
        try worktrees.verifyCheckoutAvailable(cwd)
    }

    func verifyCheckoutUnused(_ path: String, except agentID: AgentID) throws {
        try worktrees.verifyCheckoutUnused(path, except: agentID)
    }
}

extension AppSettings {
    /// Settings ▸ Worktrees, as the worktree queries read them (here and in the headless host).
    var worktreeHostingDefaults: WorktreeHosting.Defaults {
        WorktreeHosting.Defaults(autoCommit: worktreeAutoCommit, deleteLocalBranch: worktreeDeleteLocalBranch,
                                 autoMergePR: worktreeAutoMergePR, mergeMethod: worktreeMergeMethod.rawValue,
                                 generateDescription: worktreeGeneratePRDescription)
    }
}
