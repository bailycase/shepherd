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
        if case .worktreeStatus(let id) = query {
            guard hostWorktreeOperationAgents[id] == agentID, let operation = hostWorktreeOperations[id] else {
                throw ReviewCommitRefusal("Operation is unknown. It may predate a host restart. Check the repository before committing again.")
            }
            return .worktreeOperation(operation)
        }
        guard let agent = server.state.agents.first(where: { $0.id == agentID }) else { throw ReviewCommitRefusal("Agent no longer exists") }
        let cwd = ((override ?? agentDirectory(agent)) as NSString).expandingTildeInPath
        switch query {
        case .commitInfo:
            return .commitInfo(try await ReviewCommitGit.info(cwd: cwd, agentWorking: agent.status == .working,
                                                              draftsMessage: settings.worktreeGeneratePRDescription,
                                                              runner: reviewCommitRunner))
        case .commitMessage(let paths):
            let root = try await ReviewCommitGit.inspect(cwd: cwd, runner: reviewCommitRunner).root
            guard settings.worktreeGeneratePRDescription else {
                let files = try await Task.detached { try GitDiff.load(cwd: root, reference: nil) }.value
                let wanted = Set(paths)
                let fallback = reviewCommitFallbackMessage(reviewCommitFiles(files) { _ in "" }.filter { $0.paths.contains(where: wanted.contains) })
                return .commitMessage(title: fallback.title, body: fallback.body, drafted: false)
            }
            let message = await ReviewCommitGit.draftMessage(root: root, paths: paths, engine: server.pi.engine) { await LoginShell.run($0, cwd: $1, timeout: 45) }
            return .commitMessage(title: message.title, body: message.body, drafted: message.drafted)
        case .commit(let id, let options):
            if let existing = hostWorktreeOperations[id] {
                guard hostWorktreeOperationAgents[id] == agentID else { throw ReviewCommitRefusal("Operation belongs to another agent") }
                return .worktreeOperation(existing)
            }
            if agent.status == .working && !options.confirmedWhileWorking {
                throw ReviewCommitRefusal("\(agent.name) is working, so its files may still change. Confirm to commit anyway.")
            }
            let root = try await ReviewCommitGit.inspect(cwd: cwd, runner: reviewCommitRunner).root
            let checkout = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardized.path
            // The inspection suspended: an operation with this id may have started meanwhile.
            if let existing = hostWorktreeOperations[id], hostWorktreeOperationAgents[id] == agentID { return .worktreeOperation(existing) }
            guard !hostBusyWorktrees.contains(where: { checkout == $0 || checkout.hasPrefix($0 + "/") || $0.hasPrefix(checkout + "/") }) else {
                throw ReviewCommitRefusal("Another operation is running in this checkout. Try again when it finishes.")
            }
            hostBusyWorktrees.insert(checkout)
            hostWorktreeOperationAgents[id] = agentID
            hostWorktreeOperations[id] = RemoteWorktreeOperation(id: id, progress: ["\(ReviewCommitStepLabel.check): working…"])
            let committer = ReviewCommitter()
            committer.runner = reviewCommitRunner
            Task {
                defer { hostBusyWorktrees.remove(checkout) }
                let progress = Task {
                    while !Task.isCancelled {
                        hostWorktreeOperations[id]?.progress = committer.progress
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                await committer.run(options, cwd: root)
                progress.cancel()
                hostWorktreeOperations[id]?.progress = committer.progress
                hostWorktreeOperations[id]?.prURL = committer.prURL
                if committer.phase != .succeeded {
                    hostWorktreeOperations[id]?.error = committer.failure ?? "The commit stopped. Nothing else changed."
                }
                hostWorktreeOperations[id]?.finished = true
                reviewCommitFinished(agentID: agentID)
            }
            return .worktreeOperation(hostWorktreeOperations[id]!)
        default:
            throw ReviewCommitRefusal("Unsupported commit request")
        }
    }

    /// The directory an agent works in: its pi pane's.
    private func agentDirectory(_ agent: Agent) -> String {
        let tab = server.state.tabs.first { $0.id == agent.tabID }
        return tab?.layout.leaves.first { $0.agentID == agent.id }?.cwd ?? tab?.layout.firstLeaf.cwd ?? ""
    }

    /// Reloads this Mac's open reviews of the committed checkout, so the committed files leave
    /// the diff.
    private func reviewCommitFinished(agentID: AgentID) {
        for session in reviewSessions.values where session.agentID == agentID {
            reloadReview(session, reference: session.reference)
        }
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
