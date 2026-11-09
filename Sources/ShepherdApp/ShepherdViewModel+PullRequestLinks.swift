import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI
import SwiftUI

/// Close threads when their pull request merges (Settings ▸ Worktrees), kept by the server
/// (`PullRequestLinks`): what the app passes it, and the sidebar's badges.
@MainActor
extension ShepherdViewModel {
    /// Keeps the links in the server (`SessionServer.servePullRequestLinks`): the switch read from
    /// Settings, the busy-checkout checks of Delete Worktree, and banners. `pullRequestLinks` and
    /// `pullRequestCloseNotes` follow the server's. Installed once at VM creation.
    func installPullRequestLinks() {
        var hosting = PullRequestLinkHosting(
            // The background host closes its own merged threads; its app only shows their links.
            closeOnMerge: { [weak self] in self?.localHost == nil && self?.settings.worktreeCloseOnMerge == true },
            lookup: { [weak self] cwd in await self?.branchPullRequestLookup(cwd) },
            removeWorktreeAgent: { [weak self] id in
                guard let self else { throw CancellationError() }
                try await self.removeWorktreeAgent(id)
            })
        hosting.state = { [weak self] in self?.localHost == nil ? nil : self?.state }
        hosting.changed = { [weak self] in
            guard let self, let links = server.pullRequestLinks else { return }
            if pullRequestLinks != links.links { pullRequestLinks = links.links }
            if pullRequestCloseNotes != links.closeNotes { pullRequestCloseNotes = links.closeNotes }
        }
        hosting.closed = { [weak self] agent, link, branch, remote in
            self?.notifications.post(AgentBanners.pullRequestClosed(agent, number: link.ref.number, branch: branch, remote: remote))
        }
        hosting.keptOpen = { [weak self] agent, link, reason in
            self?.notifications.post(AgentBanners.pullRequestKept(agent, number: link.ref.number, reason: reason))
        }
        server.servePullRequestLinks(hosting)
    }

    /// Looks the thread's pull request up again (`PullRequestLinks.refresh`).
    @discardableResult
    func refreshPullRequestLink(_ id: AgentID) async -> ThreadPullRequest? {
        await server.pullRequestLinks?.refresh(id)
    }

    /// The poll, started only where checkouts are read (the app, not model-only tests).
    func installPullRequestPoll() {
        guard checkouts != nil else { return }
        pullRequestPoll?.cancel()
        pullRequestPoll = server.pullRequestLinks?.startPolling()
    }

    /// A deleted thread's link goes with it.
    func forgetPullRequestLink(_ id: AgentID) {
        server.pullRequestLinks?.forget(id)
        if pullRequestLinks[id] != nil { pullRequestLinks.removeValue(forKey: id) }
        if pullRequestCloseNotes[id] != nil { pullRequestCloseNotes.removeValue(forKey: id) }
        if branchPullRequests[id] != nil { branchPullRequests.removeValue(forKey: id) }
    }

    /// What the sidebar's badges draw: each linked thread's number in its state's color; a merged
    /// one kept open draws in the attention color and its help says why.
    var sidebarPullRequests: [AgentID: SidebarPullRequest] {
        Dictionary(uniqueKeysWithValues: pullRequestLinks.map { id, link in
            let (word, tone) = ForgePresentation.badge(link.state)
            let kept = pullRequestCloseNotes[id]
            return (id, SidebarPullRequest(
                badge: SHSidebarRow.Badge("#\(link.ref.number)", color: kept == nil ? tone.color : Color.sh.lanternText),
                line: "Pull request #\(link.ref.number) \(word.lowercased())" + (kept.map { ", kept open: \($0)" } ?? "")))
        })
    }
}

/// A thread row's pull request: its badge, and the line its help and VoiceOver label gain.
struct SidebarPullRequest: Equatable {
    var badge: SHSidebarRow.Badge
    var line: String
}

extension SidebarListRow {
    mutating func attach(_ pull: SidebarPullRequest) {
        pullRequest = pull.badge
        help += "\n" + pull.line
        accessibilityLabel += ", " + pull.line
    }
}
