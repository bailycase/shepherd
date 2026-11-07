import Foundation
import ShepherdCore

extension SessionServer {
    /// Deletes a worktree agent and removes its checkout and local branch. The checkout is checked
    /// as the agent's before anything is retired; after the agent is retired (`retire`, else
    /// `deleteAgent`), its processes must stop within `processTimeout` and `checkUnused` must pass,
    /// or the checkout is kept. Nothing happens for an agent that isn't on a worktree.
    @MainActor
    public func deleteAgentRemovingWorktree(_ id: AgentID, checkUnused: () throws -> Void = {},
                                            retire: (() async throws -> Void)? = nil,
                                            processTimeout: Duration = .seconds(10)) async throws {
        let state = self.state
        guard let agent = state.agents.first(where: { $0.id == id }),
              let branch = agent.worktreeBranch,
              let repo = state.spaces.first(where: { $0.id == agent.spaceID })?.path else { return }
        let path = agent.worktreePath ?? GitWorktree.destination(repo: repo, branch: branch)
        let sessionIDs = state.tabs.filter { $0.id == agent.tabID }.flatMap { $0.layout.leaves.compactMap(\.sessionID) }
        let (checkoutBranch, fingerprint) = try await Task.detached {
            let identity = try GitWorktree.identity(at: path)
            try GitWorktree.verifyIdentity(worktree: path, repo: repo, branch: identity.branch)
            return (identity.branch, try GitWorktree.deletionFingerprint(worktree: path))
        }.value
        if let retire { try await retire() } else { try await deleteAgent(id) }
        let deadline = ContinuousClock.now + processTimeout
        for sessionID in sessionIDs {
            while await sessionInfo(sessionID: sessionID)?.isAlive == true {
                guard ContinuousClock.now < deadline else { throw GitWorktree.Failure(message: "Agent processes have not stopped. Checkout was kept.") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try checkUnused()
        try await Task.detached {
            try GitWorktree.remove(repo: repo, branch: branch, worktree: path, fingerprint: fingerprint, checkoutBranch: checkoutBranch)
        }.value
    }
}
