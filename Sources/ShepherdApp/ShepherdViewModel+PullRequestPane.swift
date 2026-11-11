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
        guard pullRequestLinker?.isLookingUp(agentID) != true, state.agents.contains(where: { $0.id == agentID }) else { return }
        Task {
            guard let ref = await refreshPullRequestLink(agentID)?.ref, state.agents.contains(where: { $0.id == agentID }) else {
                if branchPullRequests[agentID] != nil { branchPullRequests.removeValue(forKey: agentID) }
                return
            }
            let store: ForgeStore
            if let existing = branchPullRequests[agentID] {
                store = existing
            } else {
                store = ForgeStore(transport: { [weak self] in
                    await self?.forge($0) ?? .failure(ForgeError(.unreachable, "Shepherd is closing."))
                })
                branchPullRequests[agentID] = store
            }
            if store.selection == ref { await store.loadDetail() } else { await store.open(ref) }
        }
    }

    /// The branch card's pull request: open it beside the thread, in the side pane's Pull request
    /// tab. The card already knows the pull request, so the tab is offered before the pane's own
    /// lookup has caught up.
    func showBranchPullRequest(_ ref: ForgeItemRef, for agentID: AgentID) {
        let store: ForgeStore
        if let existing = branchPullRequests[agentID] {
            store = existing
        } else {
            store = ForgeStore(transport: { [weak self] in
                await self?.forge($0) ?? .failure(ForgeError(.unreachable, "Shepherd is closing."))
            })
            branchPullRequests[agentID] = store
        }
        if store.selection != ref { Task { await store.open(ref) } }
        showSidePane(.local(agentID), tab: .pullRequest)
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
