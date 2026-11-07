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
    /// Closed-thread banners name no thread; clicking one opens nothing in particular.
    nonisolated static let pullRequestBannerHost = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!

    /// Keeps the links in the server (`SessionServer.servePullRequestLinks`): the switch read from
    /// Settings, the busy-checkout checks of Delete Worktree, and banners. `pullRequestLinks` and
    /// `pullRequestCloseNotes` follow the server's. Installed once at VM creation.
    func installPullRequestLinks() {
        var hosting = PullRequestLinkHosting(
            closeOnMerge: { [weak self] in self?.settings.worktreeCloseOnMerge ?? false },
            lookup: { [weak self] cwd in await self?.branchPullRequestLookup(cwd) },
            removeWorktreeAgent: { [weak self] id in
                guard let self else { throw CancellationError() }
                try await self.removeWorktreeAgent(id)
            })
        hosting.changed = { [weak self] in
            guard let self, let links = server.pullRequestLinks else { return }
            if pullRequestLinks != links.links { pullRequestLinks = links.links }
            if pullRequestCloseNotes != links.closeNotes { pullRequestCloseNotes = links.closeNotes }
        }
        hosting.closed = { [weak self] agent, link, branch, remote in
            self?.notifications.post(AgentBanner(
                identifier: "pull-request-closed-\(agent.id.rawValue)", target: .host(Self.pullRequestBannerHost),
                title: "Closed \(agent.name)", subtitle: "Pull request #\(link.ref.number) merged",
                body: "Deleted the thread, its worktree, \(branch) and \(remote).", level: .passive, actions: [],
                group: "pull-request-closed"))
        }
        hosting.keptOpen = { [weak self] agent, link, reason in
            let target = BannerTarget.agent(agent.id)
            self?.notifications.post(AgentBanner(
                identifier: "pull-request-kept-\(agent.id.rawValue)", target: target,
                title: "Kept \(agent.name)", subtitle: "Pull request #\(link.ref.number) merged",
                body: "Not closed: \(reason).", level: .active, actions: [], group: AgentBanners.group(target)))
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
