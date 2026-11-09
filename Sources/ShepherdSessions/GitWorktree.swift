import Foundation
import CryptoKit
import ShepherdProtocol

/// The New Agent sheet's "worktree" option and the space context menu's
/// "New Worktree…": create a git worktree beside the checkout and start an
/// agent there. This is the one deliberate exception to "Shepherd does not
/// mutate repository state" — explicit, user-initiated, and additive (a new
/// branch + directory). The single subtractive counterpart is `remove`,
/// reachable only through the confirmed Delete Worktree Agent dialog.
public enum GitWorktree {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// Cheap probe for showing the sheet row. `.git` may be a directory (a
    /// primary checkout) or a file (an existing worktree).
    public static func isRepo(_ path: String) -> Bool {
        FileManager.default.fileExists(
            atPath: ((path as NSString).expandingTildeInPath as NSString)
                .appendingPathComponent(".git")
        )
    }

    /// Where `add` will put the worktree: Shepherd's own
    /// `<support>/worktrees/<repo>-<hash>/<branch>`, so projects' parent folders
    /// stay clean. The hash of the repo path keeps same-named repos apart.
    public static func destination(repo: String, branch: String) -> String {
        let repoPath = (repo as NSString).expandingTildeInPath
        let hash = SHA256.hash(data: Data(repoPath.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return ShepherdPaths.supportDirectory()
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("\((repoPath as NSString).lastPathComponent)-\(hash)", isDirectory: true)
            // Branch names may contain '/'; the directory name must not.
            .appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-")).path
    }

    /// The pre-support-folder sibling `<repo>-<branch>`, for agents created before
    /// worktrees moved that never recorded `worktreePath`.
    public static func existingDestination(repo: String, branch: String) -> String {
        let repoPath = (repo as NSString).expandingTildeInPath
        let legacy = ((repoPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent((repoPath as NSString).lastPathComponent + "-" + branch.replacingOccurrences(of: "/", with: "-"))
        let current = destination(repo: repo, branch: branch)
        return !FileManager.default.fileExists(atPath: current) && FileManager.default.fileExists(atPath: legacy) ? legacy : current
    }

    /// A disposable, readable branch for the New Worktree sheet:
    /// `agent/<adjective>-<noun>-<4 digits>`. The suffix keeps repeat
    /// creations from colliding; the user can always type their own.
    public static func generatedBranch() -> String {
        let adjectives = [
            "calm", "brave", "quiet", "amber", "bright", "clever", "eager", "gentle",
            "lucid", "mellow", "noble", "rapid", "solid", "swift", "vivid", "warm",
        ]
        let nouns = [
            "stone", "river", "cedar", "comet", "ember", "falcon", "harbor", "lantern",
            "meadow", "otter", "pine", "quartz", "raven", "summit", "tide", "willow",
        ]
        let number = Int.random(in: 1000...9999)
        return "agent/\(adjectives.randomElement()!)-\(nouns.randomElement()!)-\(number)"
    }

    public struct Identity: Equatable {
        public var repo: String
        public var path: String
        public var branch: String
        public var base: String?
        public init(repo: String, path: String, branch: String, base: String?) {
            self.repo = repo
            self.path = path
            self.branch = branch
            self.base = base
        }
    }

    /// Folder containing this repository's registered linked worktrees. Git
    /// is authoritative because worktrees may live somewhere other than the
    /// primary checkout's parent. Falls back to that parent before the first
    /// linked worktree exists.
    public static func importDirectory(repo: String) -> String {
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

    /// Exact registered checkout membership, not a caller-controlled `.git` pointer or folder name.
    public static func containsCheckout(repo: String, checkout: String) throws -> Bool {
        let wanted = PiHome.canonical(checkout)
        let output = try run(["-C", PiHome.canonical(repo), "worktree", "list", "--porcelain", "-z"])
        return output.components(separatedBy: "\0").contains { field in
            field.hasPrefix("worktree ") && PiHome.canonical(String(field.dropFirst("worktree ".count))) == wanted
        }
    }

    /// Canonical primary checkout for any checkout in a repository. Git's
    /// common directory is more reliable than filesystem spelling alone on
    /// macOS runners where temporary paths may have aliases.
    public static func primaryCheckout(at path: String) throws -> String {
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
    public static func identity(at path: String) throws -> Identity {
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
    public static func add(repo: String, branch: String, from startPoint: String? = nil) throws -> String {
        let destination = destination(repo: repo, branch: branch)
        guard !FileManager.default.fileExists(atPath: destination) else {
            throw Failure(message: "\(destination) already exists")
        }
        var arguments = ["-C", (repo as NSString).expandingTildeInPath, "worktree", "add"]
        if let startPoint {
            // Worktree forwards the base to `git branch`, which needs an option-like local ref qualified too.
            let startPoint = startPoint.hasPrefix("-") ? "refs/heads/\(startPoint)" : startPoint
            arguments += ["--no-track", "-b", branch, "--", destination, startPoint]
        } else {
            arguments += ["-b", branch, "--", destination]
        }
        try run(arguments)
        return destination
    }

    /// A new worktree on a branch that already exists (the new thread's Branch picker):
    /// `git worktree add <dest> <branch>`; a remote branch ("origin/x") with no local copy gets one
    /// tracking it (`--track -b x <dest> origin/x`). git refuses a branch another worktree has.
    /// Returns the worktree's path and its local branch.
    public static func addExisting(repo: String, branch: String) throws -> (path: String, branch: String) {
        let repoPath = (repo as NSString).expandingTildeInPath
        let remote = branch.hasPrefix("origin/")
        let local = remote ? String(branch.dropFirst("origin/".count)) : branch
        guard !local.hasPrefix("-"), (try? run(["-C", repoPath, "check-ref-format", "--branch", local])) != nil else {
            throw Failure(message: "“\(branch)” isn’t a valid branch name.")
        }
        let destination = destination(repo: repo, branch: local)
        guard !FileManager.default.fileExists(atPath: destination) else { throw Failure(message: "\(destination) already exists") }
        let hasLocal = (try? run(["-C", repoPath, "rev-parse", "--verify", "--quiet", "refs/heads/\(local)"])) != nil
        if remote, !hasLocal {
            try run(["-C", repoPath, "worktree", "add", "--track", "-b", local, "--", destination, "refs/remotes/\(branch)"])
        } else {
            try run(["-C", repoPath, "worktree", "add", "--", destination, local])
        }
        return (destination, local)
    }

    /// Network git commands (fetch, set-head) give up after this long rather than hanging the
    /// worktree sheet on a dead network or a stalled remote.
    public static let networkTimeout: TimeInterval = 20

    /// The repo's default branch short name ("main"), from the local origin/HEAD symref. When
    /// that is missing it asks the remote (`git remote set-head origin --auto`) only if `network`
    /// is allowed, and otherwise falls back to a local origin/main or origin/master. Nil when
    /// there is no origin.
    public static func defaultBranch(repo: String, network: Bool = true) -> String? {
        let repoPath = (repo as NSString).expandingTildeInPath
        func read() -> String? {
            guard let out = try? run(["-C", repoPath, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) else {
                return nil
            }
            let short = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return short.hasPrefix("origin/") ? String(short.dropFirst("origin/".count)) : short
        }
        if let branch = read() { return branch }
        if network {
            _ = try? run(["-C", repoPath, "remote", "set-head", "origin", "--auto"], timeout: networkTimeout)
            if let branch = read() { return branch }
        }
        return ["main", "master"].first { name in
            (try? run(["-C", repoPath, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(name)"])) != nil
        }
    }

    /// Fetch a literal branch, never an option or a refspec; false on failure (offline, no remote).
    public static func fetch(repo: String, branch: String) -> Bool {
        let repoPath = (repo as NSString).expandingTildeInPath
        let ref = "refs/heads/\(branch)"
        guard (try? run(["-C", repoPath, "check-ref-format", ref])) != nil else { return false }
        return (try? run(["-C", repoPath, "fetch", "--quiet", "--", "origin", ref], timeout: networkTimeout)) != nil
    }

    /// A branch the user picked as the base honours Settings ▸ Worktrees ▸ Fetch before creating
    /// as the default does: `origin/<branch>` is fetched first, and a failed fetch leaves the cached
    /// ref. A local branch has nothing to fetch. Blocking (network); call off the main thread.
    public static func fetchPicked(repo: String, base: String, fetchFirst: Bool) {
        guard fetchFirst, base.hasPrefix("origin/") else { return }
        _ = fetch(repo: repo, branch: String(base.dropFirst("origin/".count)))
    }

    /// The current branch of the primary checkout ("feat/x"), or nil when
    /// detached.
    public static func currentBranch(repo: String) -> String? {
        guard let out = try? run(["-C", (repo as NSString).expandingTildeInPath, "branch", "--show-current"]) else {
            return nil
        }
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The resolved start point for a new worktree, per the user's settings.
    public struct BaseResolution: Equatable {
        /// Passed to `add(from:)`; nil = git's HEAD default.
        public var startPoint: String?
        /// What the sheet's base field shows ("origin/main", "feat/x").
        public var display: String
        /// Freshness/provenance note for the sheet ("fetched just now").
        public var note: String
        public init(startPoint: String?, display: String, note: String) {
            self.startPoint = startPoint
            self.display = display
            self.note = note
        }
    }

    /// Resolve the base per Settings ▸ Worktrees. `fresh` wants the remote
    /// default branch (fetched first when enabled) and degrades gracefully:
    /// fetch failure falls back to the cached ref, a repo with no origin
    /// falls back to the current branch — always disclosed in `note`.
    /// A project's default base (`Space.worktreeBase`) outranks the mode: it is the start point
    /// as it is, fetched first like a picked branch. A branch that no longer exists is not
    /// replaced: `add` fails on it, so the thread never quietly starts somewhere else.
    /// Blocking (network); call off the main thread.
    public static func resolveBase(repo: String, mode: WorktreeBaseMode, fetchFirst: Bool, projectBase: String?) -> BaseResolution {
        if let projectBase {
            let note = !projectBase.hasPrefix("origin/") ? "project default"
                : !fetchFirst ? "project default · cached"
                : fetch(repo: repo, branch: String(projectBase.dropFirst("origin/".count))) ? "project default · fetched just now"
                : "project default · cached — fetch failed"
            return BaseResolution(startPoint: projectBase, display: projectBase, note: note)
        }
        switch mode {
        case .head:
            let branch = currentBranch(repo: repo)
            return BaseResolution(
                startPoint: nil,
                display: branch ?? "HEAD",
                note: "current branch of the checkout"
            )
        case .fresh:
            // With fetching off, never touch the network to find the default branch either.
            guard let branch = defaultBranch(repo: repo, network: fetchFirst) else {
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
    public static func unreconciledWork(worktree: String, branch: String) -> String? {
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

    /// Destructive remote operations must not treat a failed probe as a clean checkout. A paired
    /// Mac counts every commit no remote has; `otherBranchesKeep` (this Mac's own app, as the
    /// background host's client) spares commits another local branch reaches too, the
    /// in-process rule (`unreconciledWork`), in its words.
    public static func checkedUnreconciledWork(worktree: String, branch: String, otherBranchesKeep: Bool = false) throws -> String? {
        let status = try run(["-C", worktree, "status", "--porcelain"])
        let kept = otherBranchesKeep ? ["--exclude=\(branch)", "--branches", "--remotes"] : ["--remotes"]
        let count = try run(["-C", worktree, "rev-list", "--count", "HEAD", "--not"] + kept)
        guard let unpushed = Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure(message: "Could not verify commits on the remote")
        }
        var parts: [String] = []
        let dirty = status.split(separator: "\n").count
        if dirty > 0 { parts.append("\(dirty) uncommitted change\(dirty == 1 ? "" : "s")") }
        if unpushed > 0 { parts.append("\(unpushed) commit\(unpushed == 1 ? "" : "s") \(otherBranchesKeep ? "only on this branch" : "not on a remote")") }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    /// Why closing a merged pull request's worktree would lose work: uncommitted changes, or
    /// commits no remote has when HEAD isn't the pull request's head (`pushedHead`). Nil when safe.
    public static func closeBlocker(worktree: String, pushedHead: String) throws -> String? {
        let dirty = try run(["-C", worktree, "status", "--porcelain"]).split(separator: "\n").count
        if dirty > 0 { return "\(dirty) uncommitted change\(dirty == 1 ? "" : "s")" }
        let head = try run(["-C", worktree, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard head != pushedHead else { return nil }
        // A squash merge leaves the branch's commits off main; the remote branch (or GitHub's head) still has them.
        let count = try run(["-C", worktree, "rev-list", "--count", "HEAD", "--not", "--remotes"])
        guard let unpushed = Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure(message: "Could not verify commits on the remote")
        }
        return unpushed > 0 ? "\(unpushed) unpushed commit\(unpushed == 1 ? "" : "s")" : nil
    }

    public static func deletionFingerprint(worktree: String) throws -> String {
        let identity = try identity(at: worktree)
        var digest = SHA256()
        func add(_ value: String) { digest.update(data: Data((value + "\0").utf8)) }
        add(identity.repo); add(identity.path); add(identity.branch)
        add(try run(["-C", worktree, "rev-parse", "HEAD"]))
        add(try run(["-C", worktree, "ls-files", "--stage", "-z"]))
        add(try run(["-C", worktree, "status", "--porcelain=v1", "-z", "--untracked-files=all"]))
        // Match status's ignore rules; tracked files are still included.
        let files = try run(["-C", worktree, "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
        for file in Set(files.split(separator: "\0").map(String.init)).sorted() {
            add(file)
            let path = URL(fileURLWithPath: worktree).appendingPathComponent(file)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: path.path) }
            catch CocoaError.fileReadNoSuchFile { add("deleted"); continue }
            guard let type = attributes[.type] as? FileAttributeType else { throw Failure(message: "Cannot inspect checkout file") }
            add(type.rawValue)
            add(String(describing: attributes[.posixPermissions]))
            if type == .typeSymbolicLink {
                add(try FileManager.default.destinationOfSymbolicLink(atPath: path.path))
            } else if type == .typeRegular {
                let handle = try FileHandle(forReadingFrom: path)
                defer { try? handle.close() }
                while let bytes = try handle.read(upToCount: 256 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
            } else {
                throw Failure(message: "Cannot safely fingerprint nested repository or special file: \(file)")
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verifyIdentity(worktree: String, repo: String, branch: String) throws {
        let current = try identity(at: worktree)
        let expectedRepo = try primaryCheckout(at: repo)
        guard current.repo == expectedRepo, current.branch == branch else {
            throw Failure(message: "Checkout repository or branch changed. Checkout was kept.")
        }
    }

    /// Remove the confirmed checkout and its original branch, if it still exists.
    /// A checkout switched after merging keeps its new branch.
    public static func remove(repo: String, branch: String, worktree: String? = nil, fingerprint: String? = nil, checkoutBranch: String? = nil) throws {
        let path = worktree ?? existingDestination(repo: repo, branch: branch)
        try verifyIdentity(worktree: path, repo: repo, branch: checkoutBranch ?? branch)
        if let fingerprint, try deletionFingerprint(worktree: path) != fingerprint {
            throw Failure(message: "Checkout contents changed. Checkout was kept.")
        }
        let repoPath = (repo as NSString).expandingTildeInPath
        try run([
            "-C", repoPath, "worktree", "remove", "--force",
            path,
        ])
        let branches = try run(["-C", repoPath, "for-each-ref", "--format=%(refname)", "refs/heads/"])
        if branches.split(separator: "\n").contains(Substring("refs/heads/\(branch)")) {
            try run(["-C", repoPath, "branch", "-D", "--", branch])
        }
    }

    /// Run git, returning stdout; nonzero exit throws stderr as `Failure`.
    /// Prompting is disabled so network commands (fetch, set-head) fail fast
    /// instead of hanging a non-TTY child on a credential prompt; `timeout`
    /// terminates a command that still hangs (a stalled connection).
    @discardableResult
    private static func run(_ arguments: [String], timeout: TimeInterval? = nil) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result: BoundedCommand.Result
        do {
            // Bounded so a cancelled mission or app quit can stop it; generous because a big repository's
            // `worktree add` or status legitimately takes minutes and was never cut short before.
            result = try BoundedCommand.run(["/usr/bin/git"] + arguments, environment: environment, timeout: timeout ?? 600)
        } catch {
            throw Failure(message: "git stopped: \(error)")
        }
        guard result.status == 0 else {
            let detail = String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty ? "git \(arguments.joined(separator: " ")) failed" : detail)
        }
        return String(decoding: result.output, as: UTF8.self)
    }
}

/// What a new worktree branches from (Settings ▸ Worktrees).
public enum WorktreeBaseMode: String, CaseIterable, Sendable {
    /// The remote default branch (origin/<default>), fetched first when
    /// enabled — a clean start matching the remote.
    case fresh
    /// The primary checkout's current branch — stacks on in-progress work.
    case head
}
