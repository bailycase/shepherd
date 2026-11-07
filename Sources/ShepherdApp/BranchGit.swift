import Foundation
import ShepherdSessions

/// The branch card's git changes in an agent's checkout, each on the person's click (docs/rules.md
/// "Only these paths mutate repositories"): Commit (the ticked files only, or Amend the last
/// commit), Push (never forced), Update from the base (fetch, then rebase or merge; a conflict
/// stops and Abort restores the branch), Switch branch, New branch from here and Rename branch. Every name reaches git only after `check-ref-format --branch`, never as an
/// option. Blocking; call off the main thread.
enum BranchGit {
    struct Failure: Error, LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    /// A rebase or merge stopped on conflicts: which, how far a rebase got, and the files both sides changed.
    struct Conflict: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case rebase, merge }
        var kind: Kind
        /// A rebase's commit it stopped at and how many it replays.
        var step: Int?
        var steps: Int?
        var files: [String]
    }

    enum Update: Equatable, Sendable {
        case done
        case conflict(Conflict)
    }

    // MARK: Reading

    /// Commits on HEAD its upstream lacks; nil when the branch has no upstream yet.
    static func ahead(cwd: String) -> Int? {
        (try? git(["rev-list", "--count", "@{upstream}..HEAD"], cwd: cwd)).flatMap { Int($0) }
    }

    /// A rebase or merge stopped in this checkout, else nil.
    static func conflict(cwd: String) -> Conflict? {
        func exists(_ gitPath: String) -> String? {
            guard let path = try? git(["rev-parse", "--path-format=absolute", "--git-path", gitPath], cwd: cwd),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return path
        }
        let files = ((try? git(["diff", "--name-only", "--diff-filter=U", "-z"], cwd: cwd)) ?? "")
            .split(separator: "\0").map(String.init)
        if let dir = exists("rebase-merge") ?? exists("rebase-apply") {
            func number(_ names: [String]) -> Int? {
                names.lazy.compactMap { try? String(contentsOfFile: dir + "/" + $0, encoding: .utf8) }
                    .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.first
            }
            return Conflict(kind: .rebase, step: number(["msgnum", "next"]), steps: number(["end", "last"]), files: files)
        }
        if exists("MERGE_HEAD") != nil { return Conflict(kind: .merge, files: files) }
        return nil
    }

    /// Why Amend can't replace the last commit, else nil: there is none, or a rebase or merge is stopped.
    static func amendBlocked(cwd: String) -> String? {
        guard (try? git(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], cwd: cwd)) != nil else { return "There’s no commit to amend yet." }
        if conflict(cwd: cwd) != nil { return "A rebase or merge is in progress." }
        return nil
    }

    /// The remote-tracking ref that already has the last commit ("origin/agent/x"), else nil.
    /// Amending it makes the branch differ from that ref, so a push afterwards is refused.
    static func pushedTo(cwd: String) -> String? {
        let remotes = (try? git(["branch", "--remotes", "--contains", "HEAD", "--format=%(refname:short)"], cwd: cwd)) ?? ""
        return remotes.split(separator: "\n").map(String.init).first { !$0.hasSuffix("/HEAD") }
    }

    /// A name git takes as a new branch, else why not.
    static func invalidName(_ name: String, cwd: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Name the branch." }
        if name.hasPrefix("-") || (try? git(["check-ref-format", "--branch", name], cwd: cwd)) == nil {
            return "“\(name)” isn’t a valid branch name."
        }
        if (try? git(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], cwd: cwd)) != nil {
            return "A branch named “\(name)” already exists."
        }
        return nil
    }

    // MARK: Changing

    /// `git push -u origin refs/heads/<b>:refs/heads/<b>`: never forced, so a diverged remote refuses.
    /// A rejection after the branch was rewritten here (amended after it was pushed) says so.
    static func push(cwd: String, branch: String) throws {
        try checkName(branch, cwd: cwd)
        do {
            try git(["push", "--set-upstream", "origin", "refs/heads/\(branch):refs/heads/\(branch)"], cwd: cwd, timeout: 120)
        } catch {
            guard rewrittenAfterPush(cwd: cwd, branch: branch) else { throw error }
            throw Failure(message: "\(branch) was amended after it was pushed; push with --force-with-lease in a terminal if you mean to replace it.")
        }
    }

    /// origin's copy of `branch` was once this branch's tip and HEAD has moved off it (an amend or
    /// reset here), rather than someone else pushing to it.
    static func rewrittenAfterPush(cwd: String, branch: String) -> Bool {
        guard let remote = try? git(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"], cwd: cwd),
              (try? git(["merge-base", "--is-ancestor", remote, "HEAD"], cwd: cwd)) == nil,
              let tips = try? git(["reflog", "--format=%H", "refs/heads/\(branch)"], cwd: cwd) else { return false }
        return tips.split(separator: "\n").contains { $0 == remote }
    }

    /// `git commit --only -- <paths>`: the ticked files as they are now, whatever else is staged
    /// stays staged. `amend` replaces the last commit instead (`amendBlocked` must be nil; with no
    /// paths only the message changes). Returns the new commit's short id.
    @discardableResult
    static func commit(cwd: String, paths: [String], message: String, amend: Bool) throws -> String {
        if conflict(cwd: cwd) != nil { throw Failure(message: "A rebase or merge is in progress here. Finish or abort it first.") }
        if amend, let reason = amendBlocked(cwd: cwd) { throw Failure(message: reason) }
        guard amend || !paths.isEmpty else { throw Failure(message: "Choose at least one file.") }
        guard paths.allSatisfy(ReviewCommitGit.isSafePath) else { throw Failure(message: "A file’s path is outside the repository.") }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure(message: "Write a commit message.") }
        // New files join the index as intent-to-add so `--only` takes them; a failed commit takes that back.
        let untracked = paths.isEmpty ? [] : try git(["--literal-pathspecs", "ls-files", "-z", "--others", "--"] + paths, cwd: cwd)
            .split(separator: "\0").map(String.init)
        if !untracked.isEmpty { try git(["--literal-pathspecs", "add", "-N", "--"] + untracked, cwd: cwd) }
        do {
            try git(["--literal-pathspecs", "commit", "-q", "-m", message] + (amend ? ["--amend"] : []) + ["--only", "--"] + paths, cwd: cwd)
        } catch {
            if !untracked.isEmpty { _ = try? git(["--literal-pathspecs", "reset", "-q", "--"] + untracked, cwd: cwd) }
            throw error
        }
        return try git(["rev-parse", "--short", "HEAD"], cwd: cwd)
    }

    /// Fetch `base` from origin (best effort: offline keeps the cached ref), then rebase or merge
    /// HEAD onto it. A dirty tree is refused first so nothing of the person's is rewritten; a
    /// conflict leaves git stopped for Abort, the editor or the agent.
    static func update(cwd: String, base: String, rebase: Bool) throws -> Update {
        try checkName(base, cwd: cwd)
        if conflict(cwd: cwd) != nil { throw Failure(message: "A rebase or merge is already in progress here.") }
        let dirty = (try? git(["status", "--porcelain", "--untracked-files=no"], cwd: cwd)) ?? ""
        guard dirty.isEmpty else { throw Failure(message: "Commit or revert the uncommitted changes first.") }
        _ = GitWorktree.fetch(repo: cwd, branch: base)
        let ref = (try? git(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(base)"], cwd: cwd)) != nil
            ? "refs/remotes/origin/\(base)" : "refs/heads/\(base)"
        do {
            try git(rebase ? ["rebase", ref] : ["merge", "--no-edit", ref], cwd: cwd)
            return .done
        } catch {
            if let conflict = conflict(cwd: cwd) { return .conflict(conflict) }
            throw error
        }
    }

    /// `git rebase --abort` or `git merge --abort`: the branch exactly as it was before Update.
    static func abort(cwd: String, _ kind: Conflict.Kind) throws {
        try git([kind == .rebase ? "rebase" : "merge", "--abort"], cwd: cwd)
    }

    /// Switch to `name`; a remote branch ("origin/x") switches to its local copy, made to track it
    /// when there is none. git refuses a branch another worktree has, or changes it would overwrite.
    /// Returns the local branch now checked out.
    @discardableResult
    static func switchBranch(cwd: String, to name: String) throws -> String {
        if name.hasPrefix("origin/") {
            let local = String(name.dropFirst("origin/".count))
            try checkName(local, cwd: cwd)
            if (try? git(["rev-parse", "--verify", "--quiet", "refs/heads/\(local)"], cwd: cwd)) == nil {
                try git(["switch", "--create", local, "--track", "refs/remotes/\(name)"], cwd: cwd)
                return local
            }
            try git(["switch", local], cwd: cwd)
            return local
        }
        try checkName(name, cwd: cwd)
        try git(["switch", name], cwd: cwd)
        return name
    }

    /// `git switch -c <name>` from HEAD, carrying uncommitted changes along.
    static func createBranch(cwd: String, name: String) throws {
        if let problem = invalidName(name, cwd: cwd) { throw Failure(message: problem) }
        try git(["switch", "--create", name.trimmingCharacters(in: .whitespacesAndNewlines)], cwd: cwd)
    }

    /// `git branch -m <old> <new>`: the local branch only; a pushed one keeps its remote name.
    static func renameBranch(cwd: String, from old: String, to new: String) throws {
        try checkName(old, cwd: cwd)
        if let problem = invalidName(new, cwd: cwd) { throw Failure(message: problem) }
        try git(["branch", "--move", old, new.trimmingCharacters(in: .whitespacesAndNewlines)], cwd: cwd)
    }

    /// `git fetch origin`: the picker's Fetch from origin. Remote-tracking refs only.
    static func fetchAll(cwd: String) throws {
        try git(["fetch", "--quiet", "origin"], cwd: cwd, timeout: GitWorktree.networkTimeout * 3)
    }

    // MARK: Running

    private static func checkName(_ name: String, cwd: String) throws {
        guard !name.hasPrefix("-"), (try? git(["check-ref-format", "--branch", name], cwd: cwd)) != nil else {
            throw Failure(message: "“\(name)” isn’t a valid branch name.")
        }
    }

    @discardableResult
    static func git(_ arguments: [String], cwd: String, timeout: TimeInterval = 60) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // A rebase or merge never stops for an editor: merges keep git's message.
        environment["GIT_EDITOR"] = "true"
        let result: BoundedCommand.Result
        do {
            result = try BoundedCommand.run(["/usr/bin/git", "-C", (cwd as NSString).expandingTildeInPath] + arguments,
                                            environment: environment, timeout: timeout, outputLimit: 8 << 20)
        } catch {
            throw Failure(message: "git stopped: \(error)")
        }
        guard result.status == 0 else {
            let errors = String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let output = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let text = errors.isEmpty ? output : errors
            throw Failure(message: text.isEmpty ? "git \(arguments.first ?? "") failed (exit \(result.status))." : text)
        }
        return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
