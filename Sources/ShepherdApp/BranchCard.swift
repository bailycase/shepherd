import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI

// The thread's branch card (BranchCard, BranchCardMenu boards): where the agent works, read when
// the card opens (git's status and GitHub's pull request). Its menu runs the branch changes in
// `BranchGit` (Commit…, Push, Update from the base, Switch, New and Rename branch), each on the
// person's click; Change base only rewrites Shepherd's record.

/// What the card shows before anything is read: the space, the branch, and the space's other
/// branches.
struct BranchCardModel: Equatable {
    var space: String
    var branch: String
    /// A worktree Shepherd made: Change Base… applies.
    var worktree: Bool
    var directory: String?
    var others: [BranchCardOther]
}

/// Another thread's branch in the same space.
struct BranchCardOther: Equatable, Identifiable {
    var id: AgentID
    var branch: String
    var state: AgentState
    /// "asked you", "running", or how long since it last worked ("3d").
    var detail: String
}

/// What git says once the card opens: the lines changed since the base, and how far behind it the
/// branch is. `base` nil when no base resolves (no origin, no such branch).
struct BranchCardGit: Equatable, Sendable {
    var additions = 0
    var deletions = 0
    var base: String?
    var behind = 0
    /// Commits Push sends: ahead of the upstream, or of the base before the first push.
    var ahead = 0
}

struct BranchCardStatus: Equatable, Sendable {
    var git: BranchCardGit
    var pull: PullRequestSummary?
}

enum BranchCardAction: Equatable {
    case showChanges, commit, copyBranch, showInFinder
    case push, update, newBranch, renameBranch
    /// The card swaps itself for the Branch picker (the view handles these).
    case pickBranch, pickBase
    case switchBranch(String)
    /// Re-point the thread at another checkout that has the branch (branch, path); no git runs.
    case moveToCheckout(String, String)
    case changeBase(String)
    case openPull(ForgeItemRef)
    case select(AgentID)
}

/// The header's way into the card for one agent; equal by agent, so the toolbar's equality holds.
struct BranchCardHandle: Equatable {
    let agentID: AgentID
    let card: @MainActor () -> BranchCardModel?
    let load: @MainActor (BranchCardModel) async -> BranchCardStatus
    let perform: @MainActor (BranchCardAction) -> Void
    /// The checkout's branches for the Switch branch and Change base pickers.
    var branches: @MainActor () async throws -> BranchPickerList = { throw BranchGit.Failure(message: "This thread has no checkout.") }

    static func == (a: Self, b: Self) -> Bool { a.agentID == b.agentID }
}

/// The card's git reads, in one checkout. Blocking; call off the main thread.
enum BranchCardGitReader {
    static func read(cwd: String, base: String?, executable: String = "/usr/bin/git") -> BranchCardGit {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let directory = (cwd as NSString).expandingTildeInPath
        func git(_ arguments: [String]) -> String? {
            guard let result = try? BoundedCommand.run([executable, "--no-optional-locks", "-C", directory] + arguments,
                                                       environment: environment, timeout: 10, outputLimit: 1 << 20),
                  result.status == 0 else { return nil }
            return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A worktree's recorded base (origin's copy first); else origin's default branch.
        let candidates = base.map { ["origin/\($0)", $0] } ?? [git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])].compactMap { $0 }
        let ref = candidates.first { git(["rev-parse", "--verify", "--quiet", "\($0)^{commit}"]) != nil }
        var status = BranchCardGit()
        if let ref {
            status.base = baseName(ref)
            status.behind = git(["rev-list", "--count", "HEAD..\(ref)"]).flatMap { Int($0) } ?? 0
        }
        status.ahead = (git(["rev-list", "--count", "@{upstream}..HEAD"]) ?? ref.flatMap { git(["rev-list", "--count", "\($0)..HEAD"]) })
            .flatMap { Int($0) } ?? 0
        // ponytail: tracked files only (`git diff` skips untracked ones); the Changes pane has the full count.
        let from = ref.flatMap { git(["merge-base", $0, "HEAD"]) } ?? "HEAD"
        (status.additions, status.deletions) = shortstat(git(["diff", "--shortstat", from]) ?? "")
        return status
    }

    /// "origin/main" reads as "main".
    static func baseName(_ ref: String) -> String { ref.hasPrefix("origin/") ? String(ref.dropFirst("origin/".count)) : ref }

    /// `git diff --shortstat`: " 3 files changed, 71 insertions(+), 8 deletions(-)".
    static func shortstat(_ text: String) -> (additions: Int, deletions: Int) {
        var additions = 0, deletions = 0
        for part in text.split(separator: ",") {
            let words = part.split(separator: " ")
            guard let count = words.first.flatMap({ Int($0) }), let kind = words.dropFirst().first else { continue }
            if kind.hasPrefix("insertion") { additions = count } else if kind.hasPrefix("deletion") { deletions = count }
        }
        return (additions, deletions)
    }
}

extension BranchCardModel {
    /// Every other thread in the space on a branch of its own: the ones asking first, then running,
    /// then the most recently active.
    static func others(of agent: Agent, in agents: [Agent], now: Date = Date()) -> [BranchCardOther] {
        let own = AgentBranchLabel(agent: agent)?.branch
        var seen: Set<String> = own.map { [$0] } ?? []
        func rank(_ status: AgentStatus) -> Int { status == .blocked ? 0 : status == .working ? 1 : 2 }
        let peers = agents.filter { $0.id != agent.id && $0.spaceID == agent.spaceID }
            .sorted { (rank($0.status), -($0.lastActiveAt ?? 0)) < (rank($1.status), -($1.lastActiveAt ?? 0)) }
        return peers.compactMap { peer in
            guard let branch = AgentBranchLabel(agent: peer)?.branch, seen.insert(branch).inserted else { return nil }
            let detail = switch peer.status {
            case .blocked: "asked you"
            case .working: "running"
            default: peer.lastActiveAt.map { ForgePresentation.age(Date(timeIntervalSince1970: $0 / 1000), now: now) } ?? ""
            }
            return BranchCardOther(id: peer.id, branch: branch, state: AgentState(peer.status), detail: detail)
        }
    }
}

/// One thread's branch card: what it last read, read again when the card shows, when the branch
/// moves, when the view model asks (its checkout's count moved while the thread was on screen),
/// when a turn ends, and every `interval` while it is on screen.
@MainActor
@Observable
final class BranchCardStore {
    static let interval: Duration = .seconds(30)

    private(set) var card: BranchCardModel?
    private(set) var status: BranchCardStatus?
    /// Bumped to read again now (a turn ended).
    private(set) var refreshRequest = 0
    @ObservationIgnored let handle: BranchCardHandle

    init(handle: BranchCardHandle) { self.handle = handle }

    func requestRefresh() { refreshRequest &+= 1 }

    func refresh() async {
        let next = handle.card()
        if next != card { card = next }
        guard let next else { return }
        let read = await handle.load(next)
        if read != status { status = read }
    }
}

@MainActor
extension ShepherdViewModel {
    func branchCardStore(for id: AgentID) -> BranchCardStore {
        if let store = branchCardStores[id] { return store }
        let store = BranchCardStore(handle: branchCardHandle(for: id))
        branchCardStores[id] = store
        return store
    }

    /// The branch card's reads and actions for one of this Mac's agents.
    func branchCardHandle(for id: AgentID) -> BranchCardHandle {
        return BranchCardHandle(agentID: id, card: { [weak self] in self?.branchCard(id) }, load: { [weak self] card in
            await self?.loadBranchCard(id, card) ?? BranchCardStatus(git: BranchCardGit())
        }, perform: { [weak self] action in self?.performBranchCard(action, on: id) }, branches: { [weak self] in
            guard let self, let directory = self.checkoutDirectory(of: id) else { throw BranchGit.Failure(message: "This thread has no checkout.") }
            return try await self.branchPickerList(cwd: directory, for: self.cardAgent(id)?.agent)
        })
    }

    /// A checkout's branches for a picker: `ChangesBranches` with each worktree's thread named,
    /// and whether `agent` could move to another checkout now.
    func branchPickerList(cwd: String, for agent: Agent? = nil) async throws -> BranchPickerList {
        let directory = (cwd as NSString).expandingTildeInPath
        let read = try await server.changes.branches(agentID: nil, cwd: directory)
        let threads = Dictionary(state.agents.compactMap { agent in agent.worktreePath.map { (Self.standard($0), agent.name) } },
                                 uniquingKeysWith: { first, _ in first })
        // git names worktrees by their real path (/private/var, not /var).
        let main = await Task.detached { (try? GitWorktree.primaryCheckout(at: directory)).map { Self.standard(PiSessionFolder.realPath($0)) } }.value
        return BranchPickerList(branches: read, threads: threads, mainCheckout: main, busy: agent.flatMap(Self.moveBlocker))
    }

    /// Why a thread can't move to another checkout now, in the picker's words; nil when it can.
    nonisolated static func moveBlocker(_ agent: Agent) -> String? {
        if agent.status == .blocked || agent.waitingOn != nil { return "it asks you" }
        return agent.status == .working ? "running" : nil
    }

    /// The agent the card is for, and the workspace it is listed in.
    func cardAgent(_ id: AgentID) -> (agent: Agent, state: ShepherdState)? {
        state.agents.first(where: { $0.id == id }).map { ($0, state) }
    }

    /// Record a worktree thread's branch or base where it runs: This Mac's host.
    func recordWorktree(_ id: AgentID, branch: String? = nil, base: String? = nil) async throws {
        guard let ref = localRef(id) else { throw BackgroundHostClient.HostStarting() }
        _ = try await remoteHosts.agentQuery(ref, query: .setWorktree(branch: branch, base: base))
    }

    nonisolated static func standard(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardized.path
    }

    private func branchCard(_ id: AgentID) -> BranchCardModel? {
        guard let (agent, state) = cardAgent(id), let label = AgentBranchLabel(agent: agent) else { return nil }
        return BranchCardModel(space: state.spaces.first { $0.id == agent.spaceID }?.name ?? "", branch: label.branch,
                               worktree: agent.worktreeBranch != nil, directory: checkoutDirectory(of: id),
                               others: BranchCardModel.others(of: agent, in: state.agents))
    }

    private func loadBranchCard(_ id: AgentID, _ card: BranchCardModel) async -> BranchCardStatus {
        guard let directory = card.directory else { return BranchCardStatus(git: BranchCardGit()) }
        let base = cardAgent(id)?.agent.worktreeBase
        let forge = server.forge
        async let git = Task.detached { BranchCardGitReader.read(cwd: directory, base: base) }.value
        async let pull = forge.pullRequest(directory: (directory as NSString).expandingTildeInPath, branch: card.branch)
        let read = await git
        // The base branch itself has no pull request of its own.
        return BranchCardStatus(git: read, pull: read.base == card.branch ? nil : await pull)
    }

    func performBranchCard(_ action: BranchCardAction, on id: AgentID) {
        switch action {
        case .showChanges:
            openReview(agentID: id, path: nil)
        case .commit: branchSheet = .commit(id)
        case .copyBranch:
            guard let branch = branchCard(id)?.branch else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(branch, forType: .string)
        case .showInFinder:
            guard let directory = checkoutDirectory(of: id) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)])
        // The thread's own pull request opens beside it, in the side pane's Pull request tab.
        case .openPull(let ref): showBranchPullRequest(ref, for: id)
        case .select(let other):
            selectAgent(other)
        case .pickBranch, .pickBase: break
        case .update: branchSheet = .update(id)
        case .newBranch: branchSheet = .newBranch(id)
        case .renameBranch: branchSheet = .renameBranch(id)
        case .push:
            guard let card = branchCard(id), let cwd = card.directory else { return }
            branchGit(id, "Couldn’t push \(card.branch)") { try BranchGit.push(cwd: cwd, branch: card.branch) }
        case .switchBranch(let name):
            guard let cwd = checkoutDirectory(of: id) else { return }
            branchGit(id, "Couldn’t switch to \(name)", record: { local in (local, nil) }) { try BranchGit.switchBranch(cwd: cwd, to: name) }
        case .moveToCheckout(let branch, let path):
            Task {
                do {
                    try await moveThreadToCheckout(id, path: path, branch: branch)
                } catch {
                    actionError = ActionError(title: "Couldn’t move to \(branch)", message: ActionError.describe(error))
                }
                checkouts?.refresh(id, priority: true)
                branchCardStores[id]?.requestRefresh()
            }
        case .changeBase(let base):
            Task {
                do { try await recordWorktree(id, base: base) }
                catch { actionError = ActionError(title: "Couldn’t change the base", message: ActionError.describe(error)) }
            }
        }
    }

    /// One `BranchGit` change off the main thread: its failure in words, then the checkout read
    /// again and, for a worktree, the branch Shepherd records for it (`record` → branch, base).
    func branchGit<T: Sendable>(_ id: AgentID, _ failure: String, record: ((T) -> (String?, String?))? = nil,
                                _ work: @escaping @Sendable () throws -> T) {
        Task {
            do {
                let value = try await Task.detached(priority: .userInitiated, operation: work).value
                if let record, cardAgent(id)?.agent.worktreeBranch != nil {
                    let (branch, base) = record(value)
                    try await recordWorktree(id, branch: branch, base: base)
                }
            } catch {
                actionError = ActionError(title: failure, message: ActionError.describe(error))
            }
            checkouts?.refresh(id, priority: true)
            branchCardStores[id]?.requestRefresh()
        }
    }
}

/// A sheet the branch card opens over the window.
enum BranchSheet: Identifiable, Equatable {
    case commit(AgentID), update(AgentID), newBranch(AgentID), renameBranch(AgentID)

    var id: String {
        switch self {
        case .commit(let id): "commit-\(id.rawValue)"
        case .update(let id): "update-\(id.rawValue)"
        case .newBranch(let id): "new-\(id.rawValue)"
        case .renameBranch(let id): "rename-\(id.rawValue)"
        }
    }
}
