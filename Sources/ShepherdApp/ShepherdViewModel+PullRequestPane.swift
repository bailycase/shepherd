import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The side pane's Pull request tab (PRPane, PRPaneMerged): the thread branch's pull request,
/// read and changed through the Issues & PRs forge like the destination's page, in a store of its own.
@MainActor
extension ShepherdViewModel {
    /// Looks the branch's pull request up again (the pane opened, a turn ended) and reads it.
    /// No pull request, or none gh can find, drops the tab.
    func refreshBranchPullRequest(_ agentID: AgentID) {
        guard !branchPullRequestLookups.contains(agentID), let agent = state.agents.first(where: { $0.id == agentID }) else { return }
        branchPullRequestLookups.insert(agentID)
        let cwd = agentCwd(agent)
        Task {
            let found = await branchPullRequestLookup(cwd)
            branchPullRequestLookups.remove(agentID)
            guard let ref = found, ref.kind == .pullRequest, state.agents.contains(where: { $0.id == agentID }) else {
                if branchPullRequests[agentID] != nil { branchPullRequests.removeValue(forKey: agentID) }
                return
            }
            let store: ForgeStore
            if let existing = branchPullRequests[agentID] {
                store = existing
            } else {
                store = ForgeStore(transport: { [server] in await server.forge($0) })
                branchPullRequests[agentID] = store
            }
            if store.selection == ref { await store.loadDetail() } else { await store.open(ref) }
        }
    }

    /// Send feedback to agent: what reviewers asked, to this thread.
    func sendPullRequestFeedback(_ store: ForgeStore, to agentID: AgentID) {
        guard var detail = store.pullRequest else { return }
        let comments = ForgePresentation.reviewFeedback(detail)
        guard !comments.isEmpty else { return }
        // The pane's thread is on the branch already, whether or not the host linked it.
        if detail.summary.thread == nil { detail.summary.thread = ForgeThreadLink(agentID: agentID, title: "", running: false) }
        let brief = ForgeBriefs.feedbackPrompt(detail, comments: comments, repoPath: nil)
        Task { await runForgeBriefNow(brief, name: nil, done: "Sent the review feedback to the agent", store: store) }
    }
}
