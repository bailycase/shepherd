import Foundation

/// The New Agent sheet's "worktree" option and the space context menu's
/// "New Worktree…": create a git worktree beside the checkout and start an
/// agent there. This is the one deliberate exception to "Shepherd does not
/// mutate repository state" — explicit, user-initiated, and additive (a new
/// branch + directory). The single subtractive counterpart is `remove`,
/// reachable only through the confirmed Delete Worktree Agent dialog.
enum GitWorktree {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Cheap probe for showing the sheet row. `.git` may be a directory (a
    /// primary checkout) or a file (an existing worktree).
    static func isRepo(_ path: String) -> Bool {
        FileManager.default.fileExists(
            atPath: ((path as NSString).expandingTildeInPath as NSString)
                .appendingPathComponent(".git")
        )
    }

    /// Where `add` will put the worktree: `<repo>-<branch>`, a sibling of the
    /// checkout, so repo tooling that scans the repo itself never sees it.
    static func destination(repo: String, branch: String) -> String {
        let repoPath = (repo as NSString).expandingTildeInPath
        // Branch names may contain '/'; the directory name must not.
        let directoryName = ((repoPath as NSString).lastPathComponent)
            + "-" + branch.replacingOccurrences(of: "/", with: "-")
        return ((repoPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(directoryName)
    }

    /// A disposable, readable branch for the New Worktree sheet:
    /// `worktree/<adjective>-<noun>-<4 digits>`. The suffix keeps repeat
    /// creations from colliding; the user can always type their own.
    static func generatedBranch() -> String {
        let adjectives = [
            "calm", "brave", "quiet", "amber", "bright", "clever", "eager", "gentle",
            "lucid", "mellow", "noble", "rapid", "solid", "swift", "vivid", "warm",
        ]
        let nouns = [
            "stone", "river", "cedar", "comet", "ember", "falcon", "harbor", "lantern",
            "meadow", "otter", "pine", "quartz", "raven", "summit", "tide", "willow",
        ]
        let number = Int.random(in: 1000...9999)
        return "worktree/\(adjectives.randomElement()!)-\(nouns.randomElement()!)-\(number)"
    }

    struct Identity: Equatable {
        var repo: String
        var path: String
        var branch: String
        var base: String?
    }

    /// Folder containing this repository's registered linked worktrees. Git
    /// is authoritative because worktrees may live somewhere other than the
    /// primary checkout's parent. Falls back to that parent before the first
    /// linked worktree exists.
    static func importDirectory(repo: String) -> String {
        let canonicalRepo = URL(fileURLWithPath: (repo as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardized.path
        if let output = try? run(["-C", canonicalRepo, "worktree", "list", "--porcelain", "-z"]),
           let linked = output.components(separatedBy: "\0")
            .compactMap({ field -> String? in
                guard field.hasPrefix("worktree ") else { return nil }
                return String(field.dropFirst("worktree ".count))
            })
            .map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardized.path })
            .first(where: { $0 != canonicalRepo }) {
            return URL(fileURLWithPath: linked).deletingLastPathComponent().path
        }
        return URL(fileURLWithPath: canonicalRepo).deletingLastPathComponent().path
    }

    /// Canonical primary checkout for any checkout in a repository. Git's
    /// common directory is more reliable than filesystem spelling alone on
    /// macOS runners where temporary paths may have aliases.
    static func primaryCheckout(at path: String) throws -> String {
        let checkout = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardized.path
        let commonDir = try run([
            "-C", checkout, "rev-parse", "--path-format=absolute", "--git-common-dir",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: commonDir).deletingLastPathComponent()
            .resolvingSymlinksInPath().standardized.path
    }

    /// Read an existing linked worktree's primary checkout, branch, and best
    /// local base. A primary checkout is rejected because it belongs as a
    /// Space, not as a worktree Agent beneath itself.
    static func identity(at path: String) throws -> Identity {
        let checkout = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardized.path
        let commonDir = try run(["-C", checkout, "rev-parse", "--path-format=absolute", "--git-common-dir"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDir = try run(["-C", checkout, "rev-parse", "--path-format=absolute", "--git-dir"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard commonDir != gitDir else {
            throw Failure(message: "Choose a linked git worktree, not the primary checkout")
        }
        let branch = try run(["-C", checkout, "branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else {
            throw Failure(message: "Detached worktrees cannot be imported")
        }
        let repo = try primaryCheckout(at: checkout)
        let base = (try? run([
            "-C", checkout, "symbolic-ref", "--short", "refs/remotes/origin/HEAD",
        ]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Identity(repo: repo, path: checkout, branch: branch, base: base?.isEmpty == false ? base : nil)
    }

    /// `git worktree add [--no-track] -b <branch> <repo>-<branch> [<start>]`
    /// — see `destination`. With no `from`, git branches from HEAD (the
    /// primary checkout's current commit); an explicit start point also gets
    /// `--no-track`, because branching from `origin/<default>` would
    /// otherwise set *that* as upstream and a bare `git push` inside the
    /// worktree would aim at the default branch. Returns the new worktree's
    /// absolute path.
    static func add(repo: String, branch: String, from startPoint: String? = nil) throws -> String {
        let destination = destination(repo: repo, branch: branch)
        guard !FileManager.default.fileExists(atPath: destination) else {
            throw Failure(message: "\(destination) already exists")
        }
        var arguments = ["-C", (repo as NSString).expandingTildeInPath, "worktree", "add"]
        if let startPoint {
            arguments += ["--no-track", "-b", branch, destination, startPoint]
        } else {
            arguments += ["-b", branch, destination]
        }
        try run(arguments)
        return destination
    }

    /// The repo's default branch short name ("main"), from the local
    /// origin/HEAD symref, refreshing it from the network when missing
    /// (`git remote set-head origin --auto`). Nil when there is no origin.
    static func defaultBranch(repo: String) -> String? {
        let repoPath = (repo as NSString).expandingTildeInPath
        func read() -> String? {
            guard let out = try? run(["-C", repoPath, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) else {
                return nil
            }
            let short = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return short.hasPrefix("origin/") ? String(short.dropFirst("origin/".count)) : short
        }
        if let branch = read() { return branch }
        _ = try? run(["-C", repoPath, "remote", "set-head", "origin", "--auto"])
        return read()
    }

    /// `git fetch origin <branch>`; false on failure (offline, no remote).
    static func fetch(repo: String, branch: String) -> Bool {
        (try? run(["-C", (repo as NSString).expandingTildeInPath, "fetch", "--quiet", "origin", branch])) != nil
    }

    /// The current branch of the primary checkout ("feat/x"), or nil when
    /// detached.
    static func currentBranch(repo: String) -> String? {
        guard let out = try? run(["-C", (repo as NSString).expandingTildeInPath, "branch", "--show-current"]) else {
            return nil
        }
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The resolved start point for a new worktree, per the user's settings.
    struct BaseResolution: Equatable {
        /// Passed to `add(from:)`; nil = git's HEAD default.
        var startPoint: String?
        /// What the sheet's base field shows ("origin/main", "feat/x").
        var display: String
        /// Freshness/provenance note for the sheet ("fetched just now").
        var note: String
    }

    /// Resolve the base per Settings ▸ Worktrees. `fresh` wants the remote
    /// default branch (fetched first when enabled) and degrades gracefully:
    /// fetch failure falls back to the cached ref, a repo with no origin
    /// falls back to the current branch — always disclosed in `note`.
    /// Blocking (network); call off the main thread.
    static func resolveBase(repo: String, mode: WorktreeBaseMode, fetchFirst: Bool) -> BaseResolution {
        switch mode {
        case .head:
            let branch = currentBranch(repo: repo)
            return BaseResolution(
                startPoint: nil,
                display: branch ?? "HEAD",
                note: "current branch of the checkout"
            )
        case .fresh:
            guard let branch = defaultBranch(repo: repo) else {
                let current = currentBranch(repo: repo)
                return BaseResolution(
                    startPoint: nil,
                    display: current ?? "HEAD",
                    note: "no origin — using the current branch"
                )
            }
            let note: String
            if fetchFirst {
                note = fetch(repo: repo, branch: branch)
                    ? "fetched just now"
                    : "cached — fetch failed"
            } else {
                note = "cached — fetch disabled in settings"
            }
            return BaseResolution(startPoint: "origin/\(branch)", display: "origin/\(branch)", note: note)
        }
    }

    /// Work that would be lost with the worktree — uncommitted changes plus
    /// commits reachable from nowhere else — as a human warning ("2
    /// uncommitted changes and 1 commit only on this branch"), nil when the
    /// worktree is clean and fully reconciled (or unreadable: a missing
    /// directory has nothing to lose).
    static func unreconciledWork(worktree: String, branch: String) -> String? {
        guard let status = try? run(["-C", worktree, "status", "--porcelain"]) else { return nil }
        let dirty = status.split(separator: "\n").count
        // Commits on HEAD that no other local branch or remote ref reaches.
        let unpushed = (try? run([
            "-C", worktree, "rev-list", "--count", "HEAD",
            "--not", "--exclude=\(branch)", "--branches", "--remotes",
        ])).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        var parts: [String] = []
        if dirty > 0 { parts.append("\(dirty) uncommitted change\(dirty == 1 ? "" : "s")") }
        if unpushed > 0 { parts.append("\(unpushed) commit\(unpushed == 1 ? "" : "s") only on this branch") }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    /// Tear down what `add` created: `git worktree remove --force` on the
    /// derived destination, then delete the branch. Only the confirmed
    /// Delete Worktree Agent dialog calls this.
    static func remove(repo: String, branch: String, worktree: String? = nil) throws {
        let repoPath = (repo as NSString).expandingTildeInPath
        try run([
            "-C", repoPath, "worktree", "remove", "--force",
            worktree ?? destination(repo: repo, branch: branch),
        ])
        try run(["-C", repoPath, "branch", "-D", branch])
    }

    /// Run git, returning stdout; nonzero exit throws stderr as `Failure`.
    /// Prompting is disabled so network commands (fetch, set-head) fail fast
    /// instead of hanging a non-TTY child on a credential prompt.
    @discardableResult
    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw Failure(message: "git not available: \(error.localizedDescription)")
        }
        // Drain stdout before waiting so a chatty command cannot fill the
        // pipe and deadlock. ponytail: stderr is drained after exit — fine
        // for git's short diagnostics; stream both if that ever changes.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty ? "git \(arguments.joined(separator: " ")) failed" : detail)
        }
        return String(decoding: output, as: UTF8.self)
    }
}
