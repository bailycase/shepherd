import Foundation
import ShepherdCore
import ShepherdProtocol

// What the Mac's Changes pane calls directly and what the server answers remote
// `RemoteAgentQuery.changes*` with. Each call runs on the engine's queue and returns there;
// `cwd` reviews another directory than the agent's own (an agent's `review_diff` with a cwd).
extension ChangesService {
    func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            work.async { continuation.resume(with: Result { try body() }) }
        }
    }

    func context(_ agentID: AgentID?, cwd: String?) throws -> AgentContext {
        if let agentID, var context = agentContext(agentID) {
            if let cwd { context.cwd = cwd }
            return context
        }
        guard let cwd else { throw ChangesError(ChangesError.unavailable, "The agent no longer exists.") }
        return AgentContext(cwd: cwd)
    }

    /// The scope menu: every scope's diffstat, the branch's commits, the pull request, and the
    /// scope the pane opens on.
    public func overview(agentID: AgentID?, cwd: String? = nil) async throws -> ChangesOverview {
        let context = try context(agentID, cwd: cwd)
        return try await perform { try self.overviewNow(agentID: agentID, context: context) }
    }

    /// A scope's files, counts, compare row and revision.
    public func list(agentID: AgentID?, scope: ChangesScope, options: ChangesOptions = ChangesOptions(), cwd: String? = nil) async throws -> ChangesList {
        let context = try context(agentID, cwd: cwd)
        return try await perform {
            let repository = try self.repository(context.cwd)
            let resolution = try self.resolve(scope, agentID: agentID, context: context, repository: repository)
            let files = try self.files(repository, resolution.revision, options)
            return ChangesList(scope: scope, revision: resolution.revision, comparison: resolution.comparison, files: files,
                               skipped: resolution.skipped)
        }
    }

    /// One file's hunks from a list's revision.
    public func file(agentID: AgentID?, revision: ChangesRevision, path: String, oldPath: String? = nil,
                     options: ChangesOptions = ChangesOptions(), cwd: String? = nil) async throws -> ChangesFileDiff {
        let context = try context(agentID, cwd: cwd)
        return try await perform {
            try self.fileDiff(try self.repository(context.cwd), revision, path: path, oldPath: oldPath, options: options)
        }
    }

    /// Every file's hunks from a list's revision, each cut at `ChangesLimits.fileLines`.
    public func diffs(agentID: AgentID?, revision: ChangesRevision, options: ChangesOptions = ChangesOptions(),
                      cwd: String? = nil) async throws -> [DiffFile] {
        let context = try context(agentID, cwd: cwd)
        return try await perform { try self.allDiffs(try self.repository(context.cwd), revision, options: options) }
    }

    /// The base picker's branches.
    public func branches(agentID: AgentID?, cwd: String? = nil) async throws -> ChangesBranches {
        let context = try context(agentID, cwd: cwd)
        return try await perform { try self.branches(try self.repository(context.cwd), context: context) }
    }

    /// A revision's diff as a patch (Copy as patch, Copy git apply command).
    public func patch(agentID: AgentID?, revision: ChangesRevision, options: ChangesOptions = ChangesOptions(),
                      cwd: String? = nil) async throws -> String {
        let context = try context(agentID, cwd: cwd)
        return try await perform { try self.patch(try self.repository(context.cwd), revision, options: options) }
    }

    // MARK: Overview

    func overviewNow(agentID: AgentID?, context: AgentContext) throws -> ChangesOverview {
        let repository: Repository
        do {
            repository = try self.repository(context.cwd)
        } catch let error as ChangesError {
            return ChangesOverview(repository: nil, reason: error.message, defaultScope: .uncommitted)
        }
        let branch = currentBranch(repository)
        // gh answers over the network: asked alongside the git work, not after it.
        let pullBox = ChangesLocked<ChangesPullRequest?>(nil)
        let pullDone = DispatchGroup()
        pullDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let value = self.pullRequest(repository, branch: branch)
            pullBox.withValue { $0 = value }
            pullDone.leave()
        }
        let head = commit("HEAD", in: repository)
        let empty = try emptyTree(repository)
        let working = try snapshot(repository).tree
        let index = try? indexTree(repository)
        let base = defaultBase(repository, agentBase: context.worktreeBase)
        let lastTurn = agentID.flatMap { turnStore.published($0).last }

        func entry(_ scope: ChangesScope, _ old: String?, _ new: String?, unavailable: String? = nil) -> ChangesOverview.Entry {
            guard let old, let new, unavailable == nil else { return .init(scope: scope, unavailable: unavailable ?? "Not available.") }
            guard let files = try? files(repository, ChangesRevision(old: old, new: new), ChangesOptions()) else {
                return .init(scope: scope, unavailable: "git could not compare them.")
            }
            return .init(scope: scope, files: files.count, added: files.reduce(0) { $0 + $1.added },
                         removed: files.reduce(0) { $0 + $1.removed })
        }
        func mergeBase(_ ref: String?, _ tip: String?) -> String? {
            guard let ref, let tip, let id = commit(ref, in: repository) else { return nil }
            let result = try? ChangesGit.run(["merge-base", id, tip], in: repository.root)
            return result?.status == 0 ? result?.trimmed : nil
        }

        var entries: [ChangesOverview.Entry] = []
        if let agentID, let record = turnStore.latest(agentID) {
            let usable = record.startTree.map { exists($0, in: repository) } ?? false
            entries.append(entry(.lastTurn, usable ? record.startTree : nil, record.endTree ?? working,
                                 unavailable: usable ? nil : (record.turn.reason ?? "The turn’s starting point is gone.")))
        } else {
            entries.append(.init(scope: .lastTurn, unavailable: "No turn yet."))
        }
        entries.append(entry(.uncommitted, head ?? empty, working))
        entries.append(entry(.unstaged, index, working, unavailable: index == nil ? "The index has unresolved conflicts." : nil))
        entries.append(entry(.staged, head ?? empty, index, unavailable: index == nil ? "The index has unresolved conflicts." : nil))
        let history: (commits: [ChangesCommit], base: String?) = head == nil ? ([], nil) : commits(repository, base: base)
        if let newest = history.commits.first, let oldest = history.commits.last {
            entries.append(.init(scope: .commits(first: oldest.id, last: newest.id), count: history.commits.count))
        } else {
            entries.append(.init(scope: .commits(first: "", last: ""), count: 0, unavailable: "No commits yet."))
        }
        let branchBase = mergeBase(base, head)
        entries.append(entry(.branch(base: nil), branchBase, working,
                             unavailable: base == nil ? "No base branch to compare against." : branchBase == nil ? "No shared history with \(base!)." : nil))
        _ = pullDone.wait(timeout: .now() + 12)
        let pull = pullBox.withValue { $0 }
        if let pull, let prBase = pullRequestBase(pull, repository: repository), let head, let old = mergeBase(prBase, head) {
            entries.append(entry(.pullRequest, old, head))
        } else {
            entries.append(.init(scope: .pullRequest, unavailable: pull == nil ? "No pull request for this branch." : "The pull request’s base is not here. Fetch it first."))
        }
        let worktree = context.isWorktree || repository.isLinkedWorktree
        return ChangesOverview(repository: repository.root, branch: branch, head: head.map(shortID),
                               defaultScope: worktree && base != nil ? .branch(base: nil) : .uncommitted,
                               defaultBase: base, entries: entries, commits: history.commits, commitsBase: history.base,
                               pullRequest: pull, lastTurn: lastTurn)
    }

    // MARK: Remote

    /// Answers a remote client's `changes*` query for an agent. The reply is kept under the
    /// remote frame cap: a file's hunks and a patch are cut to `ChangesLimits.remoteBytes`.
    public func answer(_ query: RemoteAgentQuery, agentID: AgentID) async throws -> RemoteAgentResult {
        switch query {
        case .changesOverview:
            return .changesOverview(try await overview(agentID: agentID))
        case .changesList(let scope, let options):
            return .changesList(try await list(agentID: agentID, scope: scope, options: options))
        case .changesFile(let revision, let path, let oldPath, let options):
            let diff = try await file(agentID: agentID, revision: revision, path: path, oldPath: oldPath, options: options)
            return .changesFile(Self.fitting(diff, bytes: ChangesLimits.remoteBytes))
        case .changesBranches:
            return .changesBranches(try await branches(agentID: agentID))
        case .changesPatch(let revision, let options):
            let text = try await patch(agentID: agentID, revision: revision, options: options)
            guard text.utf8.count > ChangesLimits.remoteBytes else { return .changesPatch(text: text, truncated: false) }
            let cut = String(decoding: text.utf8.prefix(ChangesLimits.remoteBytes), as: UTF8.self)
            return .changesPatch(text: cut, truncated: true)
        case .changesUndoTurn(let turnID):
            return .changesTurn(try await undoTurn(agentID: agentID, turnID: turnID))
        case .changesRedoTurn(let turnID):
            return .changesTurn(try await redoTurn(agentID: agentID, turnID: turnID))
        default:
            throw ChangesError(ChangesError.invalid, "Not a changes query.")
        }
    }

    /// `diff` cut until its JSON fits in `bytes`.
    static func fitting(_ diff: ChangesFileDiff, bytes: Int) -> ChangesFileDiff {
        var current = diff
        var lines = current.file.hunks.reduce(0) { $0 + $1.lines.count }
        while lines > 0, ((try? JSONEncoder().encode(current))?.count ?? Int.max) > bytes {
            lines /= 2
            current = truncated(diff.file, lines: lines)
        }
        return current
    }
}
