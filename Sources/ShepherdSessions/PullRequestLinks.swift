import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// A local thread's link to its branch's pull request, as `gh pr view` in its checkout read it.
public struct ThreadPullRequest: Equatable, Sendable {
    public var ref: ForgeItemRef
    public var state: PullRequestState
    public var headRefName: String
    /// The head commit GitHub has: a checkout still at it has nothing unpushed.
    public var headRefOid: String

    public static let fields = "url,number,state,isDraft,headRefName,headRefOid"

    /// gh's `--json` answer; nil for anything that isn't a pull request.
    public init?(json: String) {
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

    public init(ref: ForgeItemRef, state: PullRequestState, headRefName: String = "", headRefOid: String = "") {
        self.ref = ref
        self.state = state
        self.headRefName = headRefName
        self.headRefOid = headRefOid
    }

    public var isOpen: Bool { state == .open || state == .draft }

    /// `gh pr view` in `cwd` through a login shell: the lookup a host with no app uses.
    public static func lookup(cwd: String) async -> ThreadPullRequest? {
        await Task.detached {
            ChangesService.runLoginShell("GH_PROMPT_DISABLED=1 gh pr view --json \(fields)", in: cwd, timeout: 20)
                .flatMap { ThreadPullRequest(json: String(decoding: $0, as: UTF8.self)) }
        }.value
    }
}

/// What whoever hosts pull request links decides: the switch as a value, the lookup, the
/// worktree delete, and what the user is told. The app passes its own (busy-checkout checks, its
/// banners); a host with no app takes `SessionServer.headlessPullRequestHosting`.
public struct PullRequestLinkHosting {
    /// Settings ▸ Worktrees ▸ Close threads when their pull request merges (`HostSettings.closeOnMerge`).
    public var closeOnMerge: @MainActor () -> Bool
    /// The branch's pull request in a checkout; nil for none, or gh couldn't say.
    public var lookup: @MainActor (_ cwd: String) async -> ThreadPullRequest?
    /// Deletes a worktree thread with its checkout and local branch, or throws having kept them.
    public var removeWorktreeAgent: @MainActor (AgentID) async throws -> Void
    /// Links or notes changed.
    public var changed: @MainActor () -> Void = {}
    /// A merged thread was closed; `remote` says what became of its branch on GitHub.
    public var closed: @MainActor (_ agent: Agent, _ link: ThreadPullRequest, _ branch: String, _ remote: String) -> Void = { _, _, _, _ in }
    /// A merged thread was kept, for `reason` (said once per reason).
    public var keptOpen: @MainActor (_ agent: Agent, _ link: ThreadPullRequest, _ reason: String) -> Void = { _, _, _ in }
    /// The workspace whose threads are linked, when it isn't the server's own (the background
    /// host's, mirrored in its app); nil reads the server's.
    public var state: @MainActor () -> ShepherdState? = { nil }

    public init(closeOnMerge: @escaping @MainActor () -> Bool,
                lookup: @escaping @MainActor (String) async -> ThreadPullRequest?,
                removeWorktreeAgent: @escaping @MainActor (AgentID) async throws -> Void) {
        self.closeOnMerge = closeOnMerge
        self.lookup = lookup
        self.removeWorktreeAgent = removeWorktreeAgent
    }
}

extension SessionServer {
    /// Hosting with no app: gh through a login shell, and `deleteAgentRemovingWorktree`. What the
    /// user is told is only logged unless the host replaces `closed` and `keptOpen`.
    @MainActor
    public func headlessPullRequestHosting(closeOnMerge: @escaping @MainActor () -> Bool) -> PullRequestLinkHosting {
        var hosting = PullRequestLinkHosting(
            closeOnMerge: closeOnMerge,
            lookup: { await ThreadPullRequest.lookup(cwd: $0) },
            removeWorktreeAgent: { [unowned self] id in try await self.deleteAgentRemovingWorktree(id) })
        hosting.closed = { agent, link, _, _ in ShepherdLog.info("closed \(agent.id): pull request #\(link.ref.number) merged") }
        hosting.keptOpen = { agent, link, reason in ShepherdLog.info("kept \(agent.id) after #\(link.ref.number) merged: \(reason)") }
        return hosting
    }

    /// Keeps each thread's pull request link from here on, closing merged ones per the switch.
    /// Once per server.
    @MainActor
    @discardableResult
    public func servePullRequestLinks(_ hosting: PullRequestLinkHosting) -> PullRequestLinks {
        let links = PullRequestLinks(server: self, hosting: hosting)
        pullRequestLinks = links
        return links
    }
}

/// Close threads when their pull request merges: the link each local thread keeps to its branch's
/// pull request, looked up at turn end, as the side pane opens and on a poll, and the close it
/// drives once a merge is seen. Not persisted.
@MainActor
public final class PullRequestLinks {
    /// How often open pull requests are looked up again: merges usually land while a thread idles.
    public static let pollInterval: Duration = .seconds(180)

    /// Each thread's link, as last looked up.
    public private(set) var links: [AgentID: ThreadPullRequest] = [:]
    /// Why a merged pull request's thread was kept open (running, uncommitted changes…).
    public private(set) var closeNotes: [AgentID: String] = [:]
    /// The pull request each thread was last seen with open in this host's run: only a merge seen
    /// happening closes a thread, never one found merged after a restart.
    private var seenOpen: [AgentID: ForgeItemRef] = [:]
    /// Threads the poll has looked up at least once in this host's run.
    private var polled: Set<AgentID> = []
    private var closing: Set<AgentID> = []
    private var lookups: Set<AgentID> = []
    private weak var server: SessionServer?
    private let hosting: PullRequestLinkHosting
    private var workspace: ShepherdState? { hosting.state() ?? server?.state }

    init(server: SessionServer, hosting: PullRequestLinkHosting) {
        self.server = server
        self.hosting = hosting
    }

    /// A host's client's own badges: links looked up against `hosting.state`; it closes nothing.
    public init(hosting: PullRequestLinkHosting) {
        self.hosting = hosting
    }

    /// A lookup for the thread is under way.
    public func isLookingUp(_ id: AgentID) -> Bool { lookups.contains(id) }

    /// Looks the thread's pull request up again and records the link; a merge seen happening may
    /// close the thread. Returns the link (nil: none, or gh couldn't say).
    @discardableResult
    public func refresh(_ id: AgentID) async -> ThreadPullRequest? {
        guard !lookups.contains(id), let state = workspace, let agent = state.agents.first(where: { $0.id == id }) else { return links[id] }
        lookups.insert(id)
        let found = await hosting.lookup(Self.cwd(of: agent, in: state))
        lookups.remove(id)
        guard workspace?.agents.contains(where: { $0.id == id }) == true else { return nil }
        if links[id] != found {
            links[id] = found
            hosting.changed()
        }
        if let found, found.isOpen { seenOpen[id] = found.ref }
        await closeIfMerged(id)
        return found
    }

    /// The poll, every `pollInterval` until the task is cancelled.
    @discardableResult
    public func startPolling() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                await self?.poll()
            }
        }
    }

    /// Every thread once per run, then only those with an open pull request or a merged one kept open.
    // ponytail: one gh call per thread, threads sharing a checkout included; group by folder if that shows up.
    public func poll() async {
        guard let state = workspace else { return }
        for agent in state.agents where state.isOrdinaryThread(agent) {
            let id = agent.id
            guard !polled.contains(id) || links[id]?.isOpen == true || closeNotes[id] != nil else { continue }
            polled.insert(id)
            guard GitWorktree.isRepo(Self.cwd(of: agent, in: state)) else { continue }
            await refresh(id)
        }
    }

    /// A deleted thread's link goes with it.
    public func forget(_ id: AgentID) {
        let had = links.removeValue(forKey: id) != nil
        let noted = closeNotes.removeValue(forKey: id) != nil
        seenOpen.removeValue(forKey: id)
        polled.remove(id)
        if had || noted { hosting.changed() }
    }

    /// With the switch on, a worktree thread whose pull request merged (seen open first, this
    /// run) is deleted with its worktree, its local branch and its branch on GitHub. A thread
    /// that is running, asking, or whose checkout holds work GitHub doesn't have stays, with a note.
    public func closeIfMerged(_ id: AgentID) async {
        guard hosting.closeOnMerge(), let link = links[id], link.state == .merged,
              seenOpen[id] == link.ref, !closing.contains(id), let server,
              let agent = server.state.agents.first(where: { $0.id == id }), let branch = agent.worktreeBranch,
              let repo = server.state.spaces.first(where: { $0.id == agent.spaceID })?.path else { return }
        closing.insert(id)
        defer { closing.remove(id) }
        let path = agent.worktreePath ?? GitWorktree.destination(repo: repo, branch: branch)
        if let reason = await Self.closeBlocker(agent, link: link, branch: branch, repo: repo, path: path) {
            noteKeptOpen(agent, link: link, reason: reason)
            return
        }
        // The checks took a moment: a turn that started meanwhile keeps it.
        if let now = server.state.agents.first(where: { $0.id == id })?.status, now == .working || now == .blocked {
            noteKeptOpen(agent, link: link, reason: now == .working ? "it's running" : "it's waiting on your answer")
            return
        }
        do {
            try await hosting.removeWorktreeAgent(id)
        } catch {
            noteKeptOpen(agent, link: link, reason: error.localizedDescription)
            return
        }
        // GitHub may have deleted it on merge already; the forge deletes only a merged, same-repo head.
        var remote = "its branch on GitHub"
        if case .failure(let error) = await server.forge(.deleteBranch(ref: link.ref)), !error.message.contains("Reference does not exist") {
            remote = "the branch on GitHub was kept (\(error.message))"
        }
        forget(id)
        hosting.closed(agent, link, branch, remote)
    }

    /// The folder a thread's lookups run in: its pane's, else its space's.
    static func cwd(of agent: Agent, in state: ShepherdState) -> String {
        state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd
            ?? state.spaces.first { $0.id == agent.spaceID }?.path
            ?? NSHomeDirectory()
    }

    /// Why the thread must stay: nil when closing loses nothing.
    private static func closeBlocker(_ agent: Agent, link: ThreadPullRequest, branch: String, repo: String, path: String) async -> String? {
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

    /// Keeps the thread and says why, once per reason.
    private func noteKeptOpen(_ agent: Agent, link: ThreadPullRequest, reason: String) {
        guard closeNotes[agent.id] != reason else { return }
        closeNotes[agent.id] = reason
        hosting.changed()
        hosting.keptOpen(agent, link, reason)
    }
}
