import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI

// The thread's branch card (BranchCard, BranchCardMenu boards): where the agent works, read when
// the card opens. Reading only: git's status and GitHub's pull request. The menu offers the
// existing Commit… (the Changes pane's commit sheet) and Finalize… flows; nothing here writes to a
// repository.

/// What the card shows before anything is read: the space, the branch, and the space's other
/// branches.
struct BranchCardModel: Equatable {
    var space: String
    var branch: String
    /// A worktree Shepherd made: Finalize… applies.
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
}

struct BranchCardStatus: Equatable, Sendable {
    var git: BranchCardGit
    var pull: PullRequestSummary?
}

enum BranchCardAction: Equatable {
    case showChanges, commit, finalize, copyBranch, showInFinder
    case openPull(ForgeItemRef)
    case select(AgentID)
}

/// The header's way into the card for one agent; equal by agent, so the toolbar's equality holds.
struct BranchCardHandle: Equatable {
    let agentID: AgentID
    let card: @MainActor () -> BranchCardModel?
    let load: @MainActor (BranchCardModel) async -> BranchCardStatus
    let perform: @MainActor (BranchCardAction) -> Void

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
        // A worktree's base as Finalize reads it (origin's copy first); else origin's default branch.
        let candidates = base.map { ["origin/\($0)", $0] } ?? [git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])].compactMap { $0 }
        let ref = candidates.first { git(["rev-parse", "--verify", "--quiet", "\($0)^{commit}"]) != nil }
        var status = BranchCardGit()
        if let ref {
            status.base = baseName(ref)
            status.behind = git(["rev-list", "--count", "HEAD..\(ref)"]).flatMap { Int($0) } ?? 0
        }
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
/// or its changed files move, when a turn ends, and every `interval` while it is on screen.
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
        }, perform: { [weak self] action in self?.performBranchCard(action, on: id) })
    }

    private func branchCard(_ id: AgentID) -> BranchCardModel? {
        guard let agent = state.agents.first(where: { $0.id == id }), let label = AgentBranchLabel(agent: agent) else { return nil }
        return BranchCardModel(space: state.spaces.first { $0.id == agent.spaceID }?.name ?? "", branch: label.branch,
                               worktree: agent.worktreeBranch != nil, directory: checkoutDirectory(of: id),
                               others: BranchCardModel.others(of: agent, in: state.agents))
    }

    private func loadBranchCard(_ id: AgentID, _ card: BranchCardModel) async -> BranchCardStatus {
        guard let directory = card.directory else { return BranchCardStatus(git: BranchCardGit()) }
        let base = state.agents.first { $0.id == id }?.worktreeBase
        let forge = server.forge
        async let git = Task.detached { BranchCardGitReader.read(cwd: directory, base: base) }.value
        async let pull = forge.pullRequest(directory: (directory as NSString).expandingTildeInPath, branch: card.branch)
        let read = await git
        // The base branch itself has no pull request of its own.
        return BranchCardStatus(git: read, pull: read.base == card.branch ? nil : await pull)
    }

    func performBranchCard(_ action: BranchCardAction, on id: AgentID) {
        switch action {
        case .showChanges: openReview(agentID: id, path: nil)
        case .commit:
            openReview(agentID: id, path: nil)
            reviewSessions.values.first { $0.agentID == id }?.commitRequested = true
        case .finalize: beginFinalizeWorktree(id)
        case .copyBranch:
            guard let branch = branchCard(id)?.branch else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(branch, forType: .string)
        case .showInFinder:
            guard let directory = checkoutDirectory(of: id) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)])
        case .openPull(let ref): openForgeItem(ref)
        case .select(let other): selectAgent(other)
        }
    }
}
