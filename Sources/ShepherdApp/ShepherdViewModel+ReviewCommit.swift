import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// Commit from review, served by this Mac as a host: to its own review pane (with the directory
/// the pane's diff came from) and to remote clients (with the agent's directory). Both reach the
/// same code: the info, a drafted message, and the commit as an operation polled by id.
extension ShepherdViewModel {
    func handleReviewCommit(_ agentID: AgentID, query: RemoteAgentQuery, cwd override: String? = nil) async throws -> RemoteAgentResult {
        try await worktrees.commit(agentID, query: query, cwd: override)
    }

    /// The store behind a review pane's Commit… sheet: this Mac's host code for a local review,
    /// the agent's host for a remote one (nil when that host can't commit from review).
    func reviewCommitStore(for session: ReviewSession) -> ReviewCommitStore? {
        if let store = reviewCommitStores[session.id] { return store }
        let query: (RemoteAgentQuery) async throws -> RemoteAgentResult
        if let target = remoteReviews.first(where: { $0.value === session })?.key {
            guard remoteHosts.connections.first(where: { $0.id == target.hostID })?.supportsReviewCommit == true else { return nil }
            query = { [weak self] query in
                guard let self else { throw ReviewCommitRefusal("Shepherd is closing.") }
                return try await self.remoteHosts.agentQuery(target, query: query)
            }
        } else {
            let agentID = session.agentID
            let cwd = session.cwd
            query = { [weak self] query in
                guard let self else { throw ReviewCommitRefusal("Shepherd is closing.") }
                return try await self.handleReviewCommit(agentID, query: query, cwd: cwd)
            }
        }
        let store = ReviewCommitStore(query: query)
        reviewCommitStores[session.id] = store
        return store
    }

    /// Whether the review can commit directly (a local review, or a host that takes it).
    func reviewCanCommit(_ session: ReviewSession) -> Bool {
        guard let target = remoteReviews.first(where: { $0.value === session })?.key else { return true }
        return remoteHosts.connections.first(where: { $0.id == target.hostID })?.supportsReviewCommit == true
    }

    /// Once a commit sheet closes on a finished commit, the review shows what is left.
    func reviewCommitClosed(_ session: ReviewSession) {
        guard let store = reviewCommitStores[session.id], store.outcome != .running else { return }
        let succeeded = if case .succeeded = store.outcome { true } else { false }
        reviewCommitStores.removeValue(forKey: session.id)
        if succeeded { reloadReview(session, reference: session.reference) }
    }
}
