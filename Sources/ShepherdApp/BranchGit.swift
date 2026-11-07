import Foundation
import ShepherdSessions

/// The branch card's git changes in an agent's checkout, each on the person's click (docs/rules.md
/// "Only these paths mutate repositories"): Push (never forced), Update from the base (fetch, then
/// rebase or merge; a conflict stops and Abort restores the branch), Switch branch, New branch from
/// here and Rename branch. Every name reaches git only after `check-ref-format --branch`, never as an
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
    static func push(cwd: String, branch: String) throws {
        try checkName(branch, cwd: cwd)
        try git(["push", "--set-upstream", "origin", "refs/heads/\(branch):refs/heads/\(branch)"], cwd: cwd, timeout: 120)
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
