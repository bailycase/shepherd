import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// Commit from review, served by the agent's host (the background host for This Mac's): the
/// info, a drafted message, and the commit as an operation polled by id.
extension ShepherdViewModel {
    /// The store behind a review pane's Commit… sheet: the agent's host (nil when that host can't
    /// commit from review).
    func reviewCommitStore(for session: ReviewSession) -> ReviewCommitStore? {
        if let store = reviewCommitStores[session.id] { return store }
        // A local review commits through the background host, in the agent's folder.
        guard let target = remoteReviews.first(where: { $0.value === session })?.key ?? localRef(session.agentID),
              remoteHosts.allConnections.first(where: { $0.id == target.hostID })?.supportsReviewCommit == true else { return nil }
        let query: (RemoteAgentQuery) async throws -> RemoteAgentResult = { [weak self] query in
            guard let self else { throw ReviewCommitRefusal("Shepherd is closing.") }
            return try await self.remoteHosts.agentQuery(target, query: query)
        }
        let store = ReviewCommitStore(query: query)
        reviewCommitStores[session.id] = store
        return store
    }

    /// Whether the review can commit directly (a local review, or a host that takes it).
    func reviewCanCommit(_ session: ReviewSession) -> Bool {
        guard let target = remoteReviews.first(where: { $0.value === session })?.key else { return true }
        return remoteHosts.allConnections.first(where: { $0.id == target.hostID })?.supportsReviewCommit == true
    }

    /// Once a commit sheet closes on a finished commit, the review shows what is left.
    func reviewCommitClosed(_ session: ReviewSession) {
        guard let store = reviewCommitStores[session.id], store.outcome != .running else { return }
        let succeeded = if case .succeeded = store.outcome { true } else { false }
        reviewCommitStores.removeValue(forKey: session.id)
        if succeeded { reloadReview(session, reference: session.reference) }
    }
}
