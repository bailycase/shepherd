import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI
import SwiftUI

/// A local thread's link to its branch's pull request, as `gh pr view` in its checkout read it.
struct ThreadPullRequest: Equatable {
    var ref: ForgeItemRef
    var state: PullRequestState
    var headRefName: String
    /// The head commit GitHub has: a checkout still at it has nothing unpushed.
    var headRefOid: String

    static let fields = "url,number,state,isDraft,headRefName,headRefOid"

    /// gh's `--json` answer; nil for anything that isn't a pull request.
    init?(json: String) {
        struct Read: Decodable { var url: String; var state: String; var isDraft: Bool?; var headRefName: String?; var headRefOid: String? }
        guard let read = try? JSONDecoder().decode(Read.self, from: Data(json.utf8)),
              let ref = ForgeItemRef(link: read.url), ref.kind == .pullRequest else { return nil }
        let state: PullRequestState = switch read.state.uppercased() {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: read.isDraft == true ? .draft : .open
        }
        self.init(ref: ref, state: state, headRefName: read.headRefName ?? "", headRefOid: read.headRefOid ?? "")
    }

    init(ref: ForgeItemRef, state: PullRequestState, headRefName: String = "", headRefOid: String = "") {
        self.ref = ref
        self.state = state
        self.headRefName = headRefName
        self.headRefOid = headRefOid
    }

    var isOpen: Bool { state == .open || state == .draft }
}

/// Close threads when their pull request merges (Settings ▸ Worktrees): the link each local thread
/// keeps to its branch's pull request, looked up at turn end, as the side pane opens and on a poll
/// while it is open, and the close it drives once a merge is seen.
@MainActor
extension ShepherdViewModel {
    /// How often open pull requests are looked up again: merges usually land while a thread idles.
    static let pullRequestPollInterval: Duration = .seconds(180)
    /// Closed-thread banners name no thread; clicking one opens nothing in particular.
    nonisolated static let pullRequestBannerHost = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!

    /// Looks the thread's pull request up again and records the link; a merge seen happening may
    /// close the thread. Returns the link (nil: none, or gh couldn't say).
    @discardableResult
    func refreshPullRequestLink(_ id: AgentID) async -> ThreadPullRequest? {
        guard !branchPullRequestLookups.contains(id), let agent = state.agents.first(where: { $0.id == id }) else { return pullRequestLinks[id] }
        branchPullRequestLookups.insert(id)
        let found = await branchPullRequestLookup(agentCwd(agent))
        branchPullRequestLookups.remove(id)
        guard state.agents.contains(where: { $0.id == id }) else { return nil }
        if pullRequestLinks[id] != found { pullRequestLinks[id] = found }
        if let found, found.isOpen { pullRequestsSeenOpen[id] = found.ref }
        await closeIfMerged(id)
        return found
    }

    /// The poll: every thread once per launch, then only those with an open pull request or a
    /// merged one kept open. Started only where checkouts are read (the app, not model-only tests).
    func installPullRequestPoll() {
        guard checkouts != nil else { return }
        pullRequestPoll?.cancel()
        pullRequestPoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pullRequestPollInterval)
                await self?.pollPullRequestLinks()
            }
        }
    }

    // ponytail: one gh call per thread, threads sharing a checkout included; group by folder if that shows up.
    func pollPullRequestLinks() async {
        for agent in state.agents where state.isOrdinaryThread(agent) {
            let id = agent.id
            guard !pullRequestsPolled.contains(id) || pullRequestLinks[id]?.isOpen == true || pullRequestCloseNotes[id] != nil else { continue }
            pullRequestsPolled.insert(id)
            guard GitWorktree.isRepo(agentCwd(agent)) else { continue }
            await refreshPullRequestLink(id)
        }
    }

    /// A deleted thread's link goes with it.
    func forgetPullRequestLink(_ id: AgentID) {
        if pullRequestLinks[id] != nil { pullRequestLinks.removeValue(forKey: id) }
        if pullRequestCloseNotes[id] != nil { pullRequestCloseNotes.removeValue(forKey: id) }
        if branchPullRequests[id] != nil { branchPullRequests.removeValue(forKey: id) }
        pullRequestsSeenOpen.removeValue(forKey: id)
        pullRequestsPolled.remove(id)
    }

    /// With the setting on, a worktree thread whose pull request merged (seen open first, this
    /// launch) is deleted with its worktree, its local branch and its branch on GitHub. A thread
    /// that is running, asking, or whose checkout holds work GitHub doesn't have stays, with a note.
    func closeIfMerged(_ id: AgentID) async {
        guard settings.worktreeCloseOnMerge, let link = pullRequestLinks[id], link.state == .merged,
              pullRequestsSeenOpen[id] == link.ref, !pullRequestsClosing.contains(id),
              let agent = state.agents.first(where: { $0.id == id }), let branch = agent.worktreeBranch,
              let repo = state.spaces.first(where: { $0.id == agent.spaceID })?.path else { return }
        pullRequestsClosing.insert(id)
        defer { pullRequestsClosing.remove(id) }
        let path = worktreeCheckoutPath(agent)
        if let reason = await closeBlocker(agent, link: link, branch: branch, repo: repo, path: path) {
            noteKeptOpen(agent, link: link, reason: reason)
            return
        }
        // The checks took a moment: a turn that started meanwhile keeps it.
        if let now = state.agents.first(where: { $0.id == id })?.status, now == .working || now == .blocked {
            noteKeptOpen(agent, link: link, reason: now == .working ? "it's running" : "it's waiting on your answer")
            return
        }
        do {
            try await removeWorktreeAgent(id)
        } catch {
            noteKeptOpen(agent, link: link, reason: error.localizedDescription)
            return
        }
        // GitHub may have deleted it on merge already; the forge deletes only a merged, same-repo head.
        var remote = "its branch on GitHub"
        if case .failure(let error) = await server.forge(.deleteBranch(ref: link.ref)), !error.message.contains("Reference does not exist") {
            remote = "the branch on GitHub was kept (\(error.message))"
        }
        forgetPullRequestLink(id)
        notifications.post(AgentBanner(
            identifier: "pull-request-closed-\(id.rawValue)", target: .host(Self.pullRequestBannerHost),
            title: "Closed \(agent.name)", subtitle: "Pull request #\(link.ref.number) merged",
            body: "Deleted the thread, its worktree, \(branch) and \(remote).", level: .passive, actions: [],
            group: "pull-request-closed"))
    }

    /// Why the thread must stay: nil when closing loses nothing.
    private func closeBlocker(_ agent: Agent, link: ThreadPullRequest, branch: String, repo: String, path: String) async -> String? {
        switch agent.status {
        case .working: return "it's running"
        case .blocked: return "it's waiting on your answer"
        case .idle, .done: break
        }
        guard link.headRefName == branch else { return "its pull request is for \(link.headRefName), not \(branch)" }
        // Only a worktree Shepherd made: one in its support folder, or an old one at the sibling it used to make.
        let ours = agent.worktreePath.map { worktree in
            let root = PiHome.canonical(ShepherdPaths.supportDirectory().appendingPathComponent("worktrees").path)
            return PiHome.canonical(worktree).hasPrefix(root + "/")
        } ?? true
        guard ours else { return "Shepherd didn't create its worktree" }
        return await Task.detached {
            do {
                // `identity` refuses a primary checkout; the branch must still be the pull request's.
                let identity = try GitWorktree.identity(at: path)
                try GitWorktree.verifyIdentity(worktree: path, repo: repo, branch: branch)
                guard identity.branch == branch else { return "its checkout moved to \(identity.branch)" }
                return try GitWorktree.closeBlocker(worktree: path, pushedHead: link.headRefOid)
            } catch {
                return error.localizedDescription
            }
        }.value
    }

    /// Keeps the thread and says why, once per reason: on its sidebar badge and in a banner.
    private func noteKeptOpen(_ agent: Agent, link: ThreadPullRequest, reason: String) {
        guard pullRequestCloseNotes[agent.id] != reason else { return }
        pullRequestCloseNotes[agent.id] = reason
        let target = BannerTarget.agent(agent.id)
        notifications.post(AgentBanner(
            identifier: "pull-request-kept-\(agent.id.rawValue)", target: target,
            title: "Kept \(agent.name)", subtitle: "Pull request #\(link.ref.number) merged",
            body: "Not closed: \(reason).", level: .active, actions: [], group: AgentBanners.group(target)))
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
