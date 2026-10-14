import Foundation
import ShepherdCore
import ShepherdProtocol

// Git sharing for designs (docs/designs.md › Sharing with Git; boards GitDesignPublish … GitDesignMergeReview).
// A shared design is a Git working tree whose repository lives outside it, beside the designs:
// `<designs>/.git/<id>` holds it, so nothing in the design's folder (the design agent's working
// folder) leads to the repository, its remote or its config. Only `project/`, `assets/` and
// `comments.json` are tracked; Shepherd's own files (`revision`, `versions/`, `pins/`,
// `checkpoints/`, the merge copy) are excluded. Every call blocks: callers run it off the
// server's queue.

/// One git run against a design's private repository, or with no repository (clone, ls-remote).
struct DesignGitRunner: Sendable {
    let folder: URL
    /// `<designs>/.git/<id>`: outside the design's folder, where its agent works.
    let gitDirectory: URL

    /// The folder beside the designs that holds every shared design's repository, by id.
    static let repositoriesName = ".git"

    init(folder: URL) {
        self.init(folder: folder, gitDirectory: Self.repository(of: folder))
    }

    init(folder: URL, gitDirectory: URL) {
        self.folder = folder
        self.gitDirectory = gitDirectory
    }

    /// The repository of the design whose folder is `folder`.
    static func repository(of folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(repositoriesName, isDirectory: true)
            .appendingPathComponent(folder.lastPathComponent, isDirectory: true)
    }
    /// A network step (clone, fetch, push) longer than this has stalled.
    static let networkTimeout: TimeInterval = 150
    static let localTimeout: TimeInterval = 60

    var isShared: Bool { FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent("HEAD").path) }

    /// Runs git on this design's repository and working tree.
    @discardableResult
    func run(_ arguments: [String], input: Data? = nil, network: Bool = false,
             environment: [String: String] = [:]) throws -> Data {
        try Self.run(["--git-dir=" + gitDirectory.path, "--work-tree=" + folder.path] + arguments, in: folder,
                     input: input, network: network, environment: environment)
    }

    func text(_ arguments: [String]) throws -> String {
        String(decoding: try run(arguments), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What every design git run sets: no hooks, no symlinks checked out, bytes as they are, no
    /// file-system monitor, and no transport helpers (`ext::`).
    static let safety = ["-c", "core.hooksPath=/dev/null", "-c", "core.symlinks=false", "-c", "core.autocrlf=false",
                         "-c", "core.fsmonitor=false", "-c", "protocol.ext.allow=never", "-c", "advice.detachedHead=false",
                         // No attributes but these, so no filter, diff or merge driver runs a command.
                         "-c", "core.attributesFile=/dev/null", "-c", "core.ignoreCase=true", "-c", "core.protectHFS=true",
                         "-c", "core.protectNTFS=true", "-c", "submodule.recurse=false"]

    /// Git as Shepherd runs it for designs: never prompting (a repository that needs credentials
    /// it has none for fails), never reading hooks, and never following a symlink in a tree.
    @discardableResult
    static func run(_ arguments: [String], in directory: URL?, input: Data? = nil, network: Bool = false,
                    environment: [String: String] = [:]) throws -> Data {
        do {
            return try SkillsGit.run(safety + arguments, in: directory, input: input,
                                     timeout: network ? networkTimeout : localTimeout, environment: environment)
        } catch let failure as SkillsGit.Failure {
            throw DesignGitError.git(DesignGit.redacted(failure.message))
        }
    }

    /// Like `run`, but answers git's output and exit status rather than throwing on a non-zero
    /// exit (`merge-tree` exits 1 when it leaves conflicts).
    static func runStatus(_ arguments: [String], in directory: URL?, environment: [String: String] = [:]) throws -> (output: Data, status: Int32) {
        var env = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/true"
        env["SSH_ASKPASS"] = "/usr/bin/true"
        let result: BoundedCommand.Result
        do {
            result = try BoundedCommand.run([SkillsGit.executable.path] + safety + arguments, directory: directory,
                                            environment: env, timeout: localTimeout)
        } catch {
            throw DesignGitError.git("Couldn't run git: \(error)")
        }
        return (result.output, result.status)
    }
}

/// Why a Git action on a design was refused or failed. `message` is what the app shows.
public enum DesignGitError: Error, Equatable, Sendable, CustomStringConvertible {
    case notShared
    case alreadyShared
    case invalidURL
    case remoteNotEmpty
    case unavailable(String)
    case notADesign(String)
    case dirty
    case nothingToCommit
    case diverged
    case agentWorking
    case merging
    case noMerge
    case noIdentity
    /// The design was written while the merge waited (a Tweak, a comment, a turn): taking the
    /// merge now would lose it.
    case changedDuringMerge
    case git(String)

    public var description: String { message }

    public var message: String {
        switch self {
        case .notShared: "This design isn't shared through Git."
        case .alreadyShared: "This design is already shared through Git."
        case .invalidURL: "Enter an SSH or HTTPS Git URL."
        case .remoteNotEmpty: "That repository already has commits. Use an empty repository, or open it with Open from Git."
        case .unavailable(let why): "Check the repository URL and your Git access, then try again. Nothing was cloned. (\(why))"
        case .notADesign(let why): "That repository doesn't hold a Shepherd design: \(why)"
        case .dirty: "Commit local changes before pulling."
        case .nothingToCommit: "There's nothing to commit."
        case .diverged: "Your branch and the remote each have new commits. Pull to merge them first."
        case .agentWorking: "Wait for the design agent to finish this turn."
        case .merging: "A merge is in progress. Finish or stop it first."
        case .noMerge: "There's no merge to commit."
        case .noIdentity: "Git doesn't know who you are. Set user.name and user.email in your Git config, then try again."
        case .changedDuringMerge: "The design changed after the pull, so the merge would lose those changes. "
            + "Keep working locally, commit them, then pull again."
        case .git(let message): message
        }
    }

    /// The board's error box title for a failed open or share.
    public var title: String {
        switch self {
        case .unavailable, .invalidURL: "Repository unavailable"
        case .remoteNotEmpty: "Repository isn't empty"
        case .notADesign: "Not a Shepherd design"
        default: "Git couldn't finish"
        }
    }
}

// MARK: - What a shared design's Git status is

/// A shared design's Git state as the chip and the panel draw it (GitDesignChanges).
public struct DesignGitStatus: Equatable, Sendable, Codable {
    public struct File: Equatable, Sendable, Codable, Identifiable {
        /// The path in the repository: `project/A.dc.html` shows as `A.dc.html`.
        public var path: String
        /// M, A or D.
        public var letter: String
        public var id: String { path }
        public init(path: String, letter: String) {
            self.path = path
            self.letter = letter
        }
    }

    public struct Commit: Equatable, Sendable, Codable {
        public var hash: String
        public var subject: String
        public var author: String
        public var files: [String]
        public init(hash: String, subject: String, author: String, files: [String]) {
            self.hash = hash
            self.subject = subject
            self.author = author
            self.files = files
        }
    }

    public var branch: String
    /// The remote's URL as the user gave it.
    public var remoteURL: String
    /// The upstream's name ("origin/main").
    public var upstream: String
    /// Commits the branch has that the remote doesn't, and the reverse, as of the last fetch.
    public var ahead: Int
    public var behind: Int
    /// The working copy's changes against the last commit.
    public var files: [File]
    /// When the remote was last reached (ms since 1970); nil when the last fetch failed.
    public var fetchedAt: Double?
    /// The last fetch failed: Offline.
    public var offline: Bool
    /// The newest incoming commit, when the remote is ahead.
    public var incoming: Commit?
    /// The last push failed, and why.
    public var pushFailed: String?

    public init(branch: String, remoteURL: String, upstream: String, ahead: Int = 0, behind: Int = 0, files: [File] = [],
                fetchedAt: Double? = nil, offline: Bool = false, incoming: Commit? = nil, pushFailed: String? = nil) {
        self.branch = branch
        self.remoteURL = remoteURL
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.files = files
        self.fetchedAt = fetchedAt
        self.offline = offline
        self.incoming = incoming
        self.pushFailed = pushFailed
    }

    public var isClean: Bool { files.isEmpty }
}

/// A pull that needs a merge (GitDesignConflict): the two commits, and the merge copy's state.
public struct DesignGitMerge: Equatable, Sendable, Codable {
    public enum Phase: String, Equatable, Sendable, Codable {
        /// Waiting on the user: Keep working locally or Resolve with agent.
        case conflict
        /// The design agent is combining the two in the merge copy.
        case running
        /// The agent finished and the merge copy passes the checks: Review merge.
        case ready
        case stopped
        case failed
    }

    public var phase: Phase
    public var ours: DesignGitStatus.Commit
    public var theirs: DesignGitStatus.Commit
    /// The commits the merge joins.
    public var oursHash: String
    public var theirsHash: String
    /// Why the attempt failed, when it did.
    public var reason: String?
    /// The merge copy's tree when it became ready to review: Commit merge commits exactly this,
    /// and refuses a copy that changed since.
    public var reviewedTree: String?

    public init(phase: Phase, ours: DesignGitStatus.Commit, theirs: DesignGitStatus.Commit, oursHash: String, theirsHash: String,
                reason: String? = nil, reviewedTree: String? = nil) {
        self.phase = phase
        self.ours = ours
        self.theirs = theirs
        self.oursHash = oursHash
        self.theirsHash = theirsHash
        self.reason = reason
        self.reviewedTree = reviewedTree
    }
}

// MARK: - The engine

/// The Git side of a design: share, open, status, commit, push, pull and the merge copy.
/// Stateless; every function blocks and runs git.
enum DesignGit {
    /// What a shared design tracks, relative to its folder.
    static let tracked = ["project", "assets", "comments.json"]

    /// `info/exclude` for a design's repository: everything but the tracked paths, and hidden
    /// files anywhere (`.DS_Store`).
    static let exclude = "/*\n!/project/\n!/assets/\n!/comments.json\n.*\n"

    /// The merge copy beside the design (never served, never a board).
    static let mergeCopyName = ".git-merge"

    // MARK: URLs

    /// Whether `url` reads as a Git remote: an SSH form (`git@host:path`, `ssh://`), HTTPS, or
    /// (for tests and local mirrors) `file://` or an absolute path. Never a `-` option, and no
    /// `ext::` or other transport helper.
    static func isRemoteURL(_ raw: String) -> Bool {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, url.utf8.count <= 2048, !url.hasPrefix("-"),
              !url.contains(where: { $0.isWhitespace || $0.isNewline }), !url.contains("::") else { return false }
        // A password or token in the URL would be kept in the repository's config: git's own
        // credential helper holds those instead.
        if hasPassword(url) { return false }
        if url.hasPrefix("https://") || url.hasPrefix("ssh://") || url.hasPrefix("file://") { return true }
        if url.hasPrefix("/") { return true }
        // scp-like: user@host:path
        if let colon = url.firstIndex(of: ":"), let at = url.firstIndex(of: "@"), at < colon,
           url.distance(from: url.startIndex, to: at) > 0, url.index(after: colon) < url.endIndex { return true }
        return false
    }

    /// `https://user:secret@host/…`: a URL that carries a password.
    static func hasPassword(_ url: String) -> Bool {
        guard let scheme = url.range(of: "://") else { return false }
        let rest = url[scheme.upperBound...]
        let authority = rest.prefix { $0 != "/" }
        guard let at = authority.lastIndex(of: "@") else { return false }
        return authority[..<at].contains(":")
    }

    /// Git's words with any credentials in a URL taken out (`https://user:token@host` →
    /// `https://host`), before they reach the UI or a log.
    static func redacted(_ text: String) -> String {
        text.replacingOccurrences(of: #"([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@\s]+@"#, with: "$1", options: .regularExpression)
    }

    /// "acme/checkout-design" from `git@github.com:acme/checkout-design.git` or its HTTPS form.
    static func repositoryName(_ url: String) -> String {
        var path = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = path.range(of: "://") { path = String(path[range.upperBound...]) ; path = String(path.drop { $0 != "/" }.dropFirst()) }
        else if let colon = path.firstIndex(of: ":"), !path.hasPrefix("/") { path = String(path[path.index(after: colon)...]) }
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let parts = path.split(separator: "/").suffix(2)
        return parts.joined(separator: "/")
    }

    // MARK: Identity

    /// Whether git knows who commits: the user's own Git config, as for any commit they make.
    /// Shepherd never invents an identity.
    static func hasIdentity(_ git: DesignGitRunner) -> Bool {
        (try? git.text(["var", "GIT_COMMITTER_IDENT"])).map { !$0.isEmpty } ?? false
    }

    // MARK: Sharing

    /// Share with Git: makes the design's repository, commits what is tracked with `message`,
    /// and pushes it to `url`'s default branch, which must have no commits. A failure removes
    /// the repository again, so the design is as it was.
    static func share(_ folder: URL, url: String, message: String) throws -> DesignGitStatus {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRemoteURL(url) else { throw DesignGitError.invalidURL }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw DesignGitError.nothingToCommit }
        let git = DesignGitRunner(folder: folder)
        guard !git.isShared else { throw DesignGitError.alreadyShared }
        // Refuse a repository that has commits before anything is written here.
        let heads: Data
        do { heads = try DesignGitRunner.run(["ls-remote", "--heads", "--", url], in: nil, network: true) } catch DesignGitError.git(let why) {
            throw DesignGitError.unavailable(why)
        }
        guard heads.isEmpty else { throw DesignGitError.remoteNotEmpty }
        do {
            try FileManager.default.createDirectory(at: git.gitDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DesignGitRunner.run(["init", "-q", "-b", "main", "--bare", "--", git.gitDirectory.path], in: nil)
            try git.run(["config", "core.bare", "false"])
            try writeExclude(git)
            try git.run(["remote", "add", "origin", url])
            try git.run(["add", "-A", "--"] + tracked.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) })
            guard hasIdentity(git) else { throw DesignGitError.noIdentity }
            try git.run(["commit", "-q", "--no-verify", "-m", message])
            do { try git.run(["push", "-q", "-u", "origin", "main"], network: true) } catch DesignGitError.git(let why) {
                throw DesignGitError.unavailable(why)
            }
        } catch {
            try? FileManager.default.removeItem(at: git.gitDirectory)
            throw error
        }
        return try status(folder, fetch: false)
    }

    /// Open from Git: clones `url` as the design `folder` (which doesn't exist yet), checked
    /// out into `staging` and moved into place only once it holds a design: `project/canvas.json`
    /// that reads as a canvas, every file within the import's rules, no links. Its repository is
    /// the design's own (`gitDirectory`), outside both folders. A failure removes everything.
    static func clone(_ url: String, as folder: URL, staging: URL) throws -> DesignIndex {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRemoteURL(url) else { throw DesignGitError.invalidURL }
        let manager = FileManager.default
        try? manager.removeItem(at: staging)
        let repository = DesignGitRunner.repository(of: folder)
        guard !manager.fileExists(atPath: folder.path), !manager.fileExists(atPath: repository.path) else {
            throw DesignGitError.git("A design with that id already exists.")
        }
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            try manager.createDirectory(at: repository.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Checked out into staging; the repository is already where the design will live.
            let git = DesignGitRunner(folder: staging, gitDirectory: repository)
            // A bare clone is only the repository: nothing is checked out until the tree is checked.
            do {
                try DesignGitRunner.run(["clone", "-q", "--bare", "--no-tags", "--", url, git.gitDirectory.path], in: nil, network: true)
            } catch DesignGitError.git(let why) {
                throw DesignGitError.unavailable(why)
            }
            try git.run(["config", "core.bare", "false"])
            try git.run(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
            try writeExclude(git)
            guard let head = try? git.text(["symbolic-ref", "--short", "-q", "HEAD"]),
                  (try? git.text(["rev-parse", "--verify", "-q", "HEAD^{commit}"])) != nil else {
                throw DesignGitError.notADesign("the repository is empty")
            }
            // The bare clone's branches become the remote's; the default branch tracks its own.
            try git.run(["fetch", "-q", "--no-tags", "origin"], network: true)
            try git.run(["branch", "-q", "--set-upstream-to=origin/\(head)", head])
            let entries = try tree(git, "HEAD")
            try checkTree(entries)
            try git.run(["reset", "-q", "--hard", "HEAD"])
            // Check what landed on disk too (no links followed, sizes within the import's caps).
            let canvas = staging.appendingPathComponent("project/canvas.json")
            guard let data = try? Data(contentsOf: canvas) else { throw DesignGitError.notADesign("there's no project/canvas.json") }
            let index: DesignIndex
            do { index = try DesignIndex.decode(data) } catch { throw DesignGitError.notADesign("canvas.json isn't a canvas Shepherd reads") }
            try Data("0\n".utf8).write(to: staging.appendingPathComponent("revision"))
            try manager.moveItem(at: staging, to: folder)
            return index
        } catch {
            try? manager.removeItem(at: staging)
            try? manager.removeItem(at: repository)
            throw error
        }
    }

    /// A design that goes (deleted for good): its repository goes with it.
    static func removeRepository(of folder: URL) {
        try? FileManager.default.removeItem(at: DesignGitRunner.repository(of: folder))
    }

    /// One entry of `ls-tree -r`.
    struct Entry: Equatable {
        var mode: String
        var type: String
        var size: Int
        var path: String
    }

    static func tree(_ git: DesignGitRunner, _ commit: String) throws -> [Entry] {
        let output = try git.run(["ls-tree", "-r", "-z", "-l", "--full-tree", commit])
        return output.split(separator: 0).compactMap { record in
            guard let line = String(data: Data(record), encoding: .utf8), let tab = line.firstIndex(of: "\t") else { return nil }
            let fields = line[..<tab].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count == 4 else { return nil }
            return Entry(mode: fields[0], type: fields[1], size: Int(fields[3]) ?? 0, path: String(line[line.index(after: tab)...]))
        }
    }

    /// What a design's repository may hold: regular files only (no links or submodules), each a
    /// path a design keeps, within the import's file count and sizes, and a canvas.
    static func checkTree(_ entries: [Entry]) throws {
        guard entries.contains(where: { $0.path == "project/canvas.json" }) else {
            throw DesignGitError.notADesign("there's no project/canvas.json")
        }
        guard entries.count <= DesignImport.maxFiles else { throw DesignGitError.notADesign("it holds more than \(DesignImport.maxFiles) files") }
        var total = 0
        // APFS is case-insensitive: two paths that differ only by case would write one file.
        var folded = Set<String>()
        for entry in entries {
            guard entry.type == "blob", entry.mode == "100644" || entry.mode == "100755" else {
                throw DesignGitError.notADesign("\(entry.path) is a link or a submodule")
            }
            guard isTrackedPath(entry.path) else { throw DesignGitError.notADesign("\(entry.path) isn't part of a design") }
            // Git reads these from the tree it checks out (filters, hooks' config): never from a design.
            let name = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
            guard ![".gitattributes", ".gitmodules", ".gitignore", ".git"].contains(name.lowercased()) else {
                throw DesignGitError.notADesign("\(entry.path) is a Git file, not part of a design")
            }
            guard folded.insert(entry.path.lowercased()).inserted else {
                throw DesignGitError.notADesign("\(entry.path) differs from another file only by case")
            }
            guard entry.size <= DesignImport.maxFileBytes else { throw DesignGitError.notADesign("\(entry.path) is too large") }
            total += entry.size
            guard Int64(total) <= DesignImport.maxProjectBytes else { throw DesignGitError.notADesign("it's too large") }
        }
    }

    /// `project/…`, `assets/<name>` or `comments.json`, each segment a name a design keeps.
    static func isTrackedPath(_ path: String) -> Bool {
        if path == "comments.json" { return true }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 2, segments.count <= DesignImport.maxDepth,
              segments.allSatisfy(DesignImport.isSegment) else { return false }
        switch segments[0] {
        case "project": return true
        case "assets": return segments.count == 2 && DesignBundle.isAssetName(segments[1])
        default: return false
        }
    }

    private static func writeExclude(_ git: DesignGitRunner) throws {
        let info = git.gitDirectory.appendingPathComponent("info", isDirectory: true)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try Data(exclude.utf8).write(to: info.appendingPathComponent("exclude"), options: .atomic)
    }

    // MARK: Status

    /// The design's branch, remote and changes; with `fetch`, after asking the remote what's new
    /// (a failure marks it offline rather than throwing).
    static func status(_ folder: URL, fetch: Bool, pushFailed: String? = nil) throws -> DesignGitStatus {
        let git = DesignGitRunner(folder: folder)
        guard git.isShared else { throw DesignGitError.notShared }
        var fetchedAt: Double?
        var offline = false
        if fetch {
            do {
                try git.run(["fetch", "-q", "--no-tags", "--prune", "origin"], network: true)
                fetchedAt = Date().timeIntervalSince1970 * 1000
            } catch {
                offline = true
            }
        }
        let branch = (try? git.text(["symbolic-ref", "--short", "-q", "HEAD"])) ?? "main"
        let remoteURL = (try? git.text(["remote", "get-url", "origin"])) ?? ""
        let upstreamRef = "refs/remotes/origin/\(branch)"
        let hasUpstream = (try? git.text(["rev-parse", "--verify", "-q", upstreamRef])) != nil
        var ahead = 0, behind = 0
        if hasUpstream, let counts = try? git.text(["rev-list", "--left-right", "--count", "HEAD...\(upstreamRef)"]) {
            let parts = counts.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
            if parts.count == 2 { ahead = parts[0]; behind = parts[1] }
        } else if !hasUpstream {
            ahead = Int((try? git.text(["rev-list", "--count", "HEAD"])) ?? "0") ?? 0
        }
        let incoming = behind > 0 ? try? commit(git, upstreamRef) : nil
        return DesignGitStatus(branch: branch, remoteURL: remoteURL, upstream: "origin/\(branch)", ahead: ahead, behind: behind,
                               files: try changes(git), fetchedAt: fetchedAt, offline: offline, incoming: incoming,
                               pushFailed: pushFailed)
    }

    /// The working copy's changes against HEAD: modified, added (untracked included) and deleted.
    static func changes(_ git: DesignGitRunner) throws -> [DesignGitStatus.File] {
        let output = try git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames", "--"] + tracked)
        var files: [DesignGitStatus.File] = []
        for record in output.split(separator: 0) {
            guard record.count > 3, let line = String(data: Data(record), encoding: .utf8) else { continue }
            let code = line.prefix(2)
            let path = String(line.dropFirst(3))
            let letter: String
            if code == "??" || code.contains("A") { letter = "A" } else if code.contains("D") { letter = "D" } else { letter = "M" }
            files.append(DesignGitStatus.File(path: path, letter: letter))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// A commit's subject, author, short hash and the files it changed.
    static func commit(_ git: DesignGitRunner, _ ref: String) throws -> DesignGitStatus.Commit {
        let fields = String(decoding: try git.run(["log", "-1", "--format=%s%x00%an%x00%h", ref]), as: UTF8.self)
            .trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        let files = String(decoding: try git.run(["diff-tree", "--no-commit-id", "--name-only", "-r", "-z", "--root", ref]), as: UTF8.self)
            .split(separator: "\0").map { String($0) }
        return DesignGitStatus.Commit(hash: fields.count > 2 ? fields[2] : "", subject: fields.first ?? "",
                                      author: fields.count > 1 ? fields[1] : "", files: files)
    }

    /// A file's content at HEAD, or nil when HEAD doesn't have it.
    static func committed(_ git: DesignGitRunner, _ path: String, at ref: String = "HEAD") -> Data? {
        try? git.run(["show", "\(ref):\(path)"])
    }

    // MARK: Committing and pushing

    /// Commits every change to the tracked paths with `message`, then pushes when `push`.
    /// A push that fails keeps the commit: the error says so and the status shows it.
    static func commit(_ folder: URL, message: String, push: Bool) throws -> (status: DesignGitStatus, pushError: String?) {
        let git = DesignGitRunner(folder: folder)
        guard git.isShared else { throw DesignGitError.notShared }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw DesignGitError.nothingToCommit }
        guard !(try changes(git)).isEmpty else { throw DesignGitError.nothingToCommit }
        guard hasIdentity(git) else { throw DesignGitError.noIdentity }
        try git.run(["add", "-A", "--"] + tracked.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
                    + deletedTrackedRoots(git, folder))
        try git.run(["commit", "-q", "--no-verify", "-m", message])
        guard push else { return (try status(folder, fetch: false), nil) }
        let error = pushBranch(git)
        return (try status(folder, fetch: false, pushFailed: error), error)
    }

    /// A tracked root that is gone from disk (a design with no uploads left), so `add -A` records it.
    private static func deletedTrackedRoots(_ git: DesignGitRunner, _ folder: URL) -> [String] {
        tracked.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            .filter { (try? git.run(["ls-files", "--error-unmatch", "--", $0])) != nil }
    }

    /// Pushes the branch to its upstream, never forced. Nil when it went, else why not.
    static func pushBranch(_ git: DesignGitRunner) -> String? {
        let branch = (try? git.text(["symbolic-ref", "--short", "-q", "HEAD"])) ?? "main"
        do {
            try git.run(["push", "-q", "origin", "HEAD:refs/heads/\(branch)"], network: true)
            try? git.run(["branch", "-q", "--set-upstream-to=origin/\(branch)"])
            return nil
        } catch let error as DesignGitError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    // MARK: Pulling

    enum PullOutcome: Equatable {
        /// Already up to date, or fast-forwarded: the design's files may have changed.
        case updated(changed: Bool)
        /// Both sides have commits: the merge copy waits on the user.
        case needsMerge(DesignGitMerge)
    }

    /// Pull's network half: fetch the remote. Runs on the Git queue, never under the design
    /// store's, so a slow remote stalls no canvas or agent.
    static func fetch(_ folder: URL) throws {
        let git = DesignGitRunner(folder: folder)
        guard git.isShared else { throw DesignGitError.notShared }
        guard try changes(git).isEmpty else { throw DesignGitError.dirty }
        do { try git.run(["fetch", "-q", "--no-tags", "--prune", "origin"], network: true) } catch DesignGitError.git(let why) {
            throw DesignGitError.unavailable(why)
        }
    }

    /// Pull's local half, after `fetch`: fast-forward a clean working copy to what was fetched.
    /// Diverged history is never merged here: it answers the two commits for the merge dialog,
    /// and the design's files stay as they were. Local only, so it may run under the store's queue.
    static func pull(_ folder: URL) throws -> PullOutcome {
        let git = DesignGitRunner(folder: folder)
        guard git.isShared else { throw DesignGitError.notShared }
        // Checked again here: a write may have landed since the fetch.
        guard try changes(git).isEmpty else { throw DesignGitError.dirty }
        let branch = (try? git.text(["symbolic-ref", "--short", "-q", "HEAD"])) ?? "main"
        let upstream = "refs/remotes/origin/\(branch)"
        guard let theirs = try? git.text(["rev-parse", "--verify", "-q", upstream]) else { return .updated(changed: false) }
        let ours = try git.text(["rev-parse", "HEAD"])
        if ours == theirs { return .updated(changed: false) }
        if (try? git.run(["merge-base", "--is-ancestor", theirs, ours])) != nil { return .updated(changed: false) }
        if (try? git.run(["merge-base", "--is-ancestor", ours, theirs])) != nil {
            // The incoming tree must be a design before anything is written.
            try checkTree(try tree(git, theirs))
            try git.run(["merge", "-q", "--ff-only", "--no-verify", theirs])
            return .updated(changed: true)
        }
        return .needsMerge(DesignGitMerge(phase: .conflict, ours: try commit(git, ours), theirs: try commit(git, theirs),
                                          oursHash: ours, theirsHash: theirs))
    }

    // MARK: The merge copy

    /// Makes the merge copy (`.git-merge` beside the design, never served): both commits merged
    /// by git where it can, with conflict markers where it can't. Answers the files git couldn't
    /// merge. The design's own files stay as they are.
    static func prepareMergeCopy(_ folder: URL, merge: DesignGitMerge) throws -> (copy: URL, conflicts: [String]) {
        let git = DesignGitRunner(folder: folder)
        let copy = folder.appendingPathComponent(mergeCopyName, isDirectory: true)
        try? FileManager.default.removeItem(at: copy)
        try checkTree(try tree(git, merge.theirsHash))
        // merge-tree exits 1 with conflicts (0 clean); its first record is the tree either way.
        let (output, status) = try DesignGitRunner.runStatus(["--git-dir=" + git.gitDirectory.path, "merge-tree", "--write-tree", "-z",
                                                               "--name-only", merge.oursHash, merge.theirsHash], in: folder)
        guard status == 0 || status == 1 else { throw DesignGitError.git("Git couldn't prepare the merge.") }
        let records = output.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard let treeID = records.first, treeID.count >= 40 else { throw DesignGitError.git("Git couldn't prepare the merge.") }
        var conflicts: [String] = []
        for record in records.dropFirst() {
            if record.isEmpty { break }
            if !conflicts.contains(record) { conflicts.append(record) }
        }
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let index = folder.appendingPathComponent(".git-merge.index")
        defer { try? FileManager.default.removeItem(at: index) }
        try DesignGitRunner.run(["--git-dir=" + git.gitDirectory.path, "--work-tree=" + copy.path, "read-tree", treeID], in: folder,
                                environment: ["GIT_INDEX_FILE": index.path])
        try DesignGitRunner.run(["--git-dir=" + git.gitDirectory.path, "--work-tree=" + copy.path, "checkout-index", "-a", "-f"],
                                in: folder, environment: ["GIT_INDEX_FILE": index.path])
        return (copy, conflicts.filter(isTrackedPath))
    }

    /// The merge copy's problems: conflict markers left, a canvas that doesn't read, a board the
    /// checks refuse, a listed board with no file. Empty when it's ready to review.
    static func checkMergeCopy(_ copy: URL) -> [String] {
        var problems: [String] = []
        let manager = FileManager.default
        let project = copy.appendingPathComponent("project", isDirectory: true)
        let canvasURL = project.appendingPathComponent("canvas.json")
        var index: DesignIndex?
        if let data = try? Data(contentsOf: canvasURL) {
            if String(decoding: data, as: UTF8.self).contains("<<<<<<<") { problems.append("canvas.json still has conflict markers") }
            index = try? DesignIndex.decode(data)
            if index == nil { problems.append("canvas.json isn't a canvas Shepherd reads") }
        } else {
            problems.append("there's no canvas.json")
        }
        let walker = manager.enumerator(at: copy, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let relative = relativePath(url, in: copy)
            if values?.isSymbolicLink == true { problems.append("\(relative) is a link"); continue }
            guard values?.isRegularFile == true else { continue }
            guard isTrackedPath(relative) else { problems.append("\(relative) isn't part of a design"); continue }
            guard relative.hasSuffix(DesignPath.fileExtension) || relative == "comments.json" else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            if text.contains("\n<<<<<<< ") || text.hasPrefix("<<<<<<< ") || text.contains("\n>>>>>>> ") {
                problems.append("\(relative) still has conflict markers")
                continue
            }
            if relative == "comments.json" {
                if (try? JSONDecoder().decode(DesignComments.self, from: data)) == nil { problems.append("comments.json doesn't read") }
                continue
            }
            let board = String(relative.dropFirst("project/".count))
            if DesignPath(board) != nil {
                do { _ = try DesignBoardCheck.check(text) } catch { problems.append("\(board): \(error.description)") }
            }
        }
        if let index {
            for path in index.boards.keys where !manager.fileExists(atPath: project.appendingPathComponent(path.rawValue).path) {
                problems.append("canvas.json lists \(path), which has no file")
            }
        }
        return problems
    }

    /// The files the merge copy changes against the design's HEAD, for the review: by content,
    /// file by file.
    static func mergeChanges(_ folder: URL) throws -> [DesignGitStatus.File] {
        let git = DesignGitRunner(folder: folder)
        let copy = folder.appendingPathComponent(mergeCopyName, isDirectory: true)
        var files: [DesignGitStatus.File] = []
        let manager = FileManager.default
        var seen = Set<String>()
        let walker = manager.enumerator(at: copy, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = relativePath(url, in: copy)
            guard isTrackedPath(relative) else { continue }
            seen.insert(relative)
            let now = try? Data(contentsOf: url)
            let before = committed(git, relative)
            if before == nil { files.append(.init(path: relative, letter: "A")) } else if before != now { files.append(.init(path: relative, letter: "M")) }
        }
        for entry in (try? tree(git, "HEAD")) ?? [] where !seen.contains(entry.path) {
            files.append(.init(path: entry.path, letter: "D"))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Commit merge: writes the merge copy's tree as a commit with both parents, moves the branch
    /// to it, and answers the files the design's working copy must take. The working copy itself
    /// is replaced by the caller (through the design store), then `finishMerge` resets the index.
    static func commitMerge(_ folder: URL, merge: DesignGitMerge, message: String) throws -> String {
        let git = DesignGitRunner(folder: folder)
        let copy = folder.appendingPathComponent(mergeCopyName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: copy.path) else { throw DesignGitError.noMerge }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw DesignGitError.nothingToCommit }
        guard hasIdentity(git) else { throw DesignGitError.noIdentity }
        let head = try git.text(["rev-parse", "HEAD"])
        guard head == merge.oursHash else { throw DesignGitError.git("The branch moved since the merge started. Pull again.") }
        // The design must still be what the merge started from: anything written since (a
        // Tweak, a comment, a turn) would be lost when the design takes the merge.
        guard try changes(git).isEmpty else { throw DesignGitError.changedDuringMerge }
        let index = folder.appendingPathComponent(".git-merge.index")
        defer { try? FileManager.default.removeItem(at: index) }
        let environment = ["GIT_INDEX_FILE": index.path]
        let copyGit = ["--git-dir=" + git.gitDirectory.path, "--work-tree=" + copy.path, "-c", "core.excludesFile=/dev/null"]
        try DesignGitRunner.run(copyGit + ["read-tree", "--empty"], in: folder, environment: environment)
        try DesignGitRunner.run(copyGit + ["add", "-A", "--", "."], in: folder, environment: environment)
        let tree = try String(decoding: DesignGitRunner.run(copyGit + ["write-tree"], in: folder, environment: environment), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // What was reviewed is what is committed: the copy's tree when the merge became ready.
        if let reviewed = merge.reviewedTree, reviewed != tree {
            throw DesignGitError.git("The merge changed after you reviewed it. Review it again.")
        }
        // The merged tree must be a design (files, sizes, names) before the branch moves.
        try checkTree(try Self.tree(git, tree))
        let commit = try String(decoding: git.run(["commit-tree", tree, "-p", merge.oursHash, "-p", merge.theirsHash, "-m", message]),
                                as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = (try? git.text(["symbolic-ref", "--short", "-q", "HEAD"])) ?? "main"
        try git.run(["update-ref", "-m", "shepherd: merge", "refs/heads/\(branch)", commit, head])
        return commit
    }

    /// The merge copy's tree as git would commit it, without moving anything: what the review
    /// shows, kept so Commit merge commits exactly that.
    static func mergeCopyTree(_ folder: URL) throws -> String {
        let git = DesignGitRunner(folder: folder)
        let copy = folder.appendingPathComponent(mergeCopyName, isDirectory: true)
        let index = folder.appendingPathComponent(".git-merge.review-index")
        defer { try? FileManager.default.removeItem(at: index) }
        let environment = ["GIT_INDEX_FILE": index.path]
        let copyGit = ["--git-dir=" + git.gitDirectory.path, "--work-tree=" + copy.path, "-c", "core.excludesFile=/dev/null"]
        try DesignGitRunner.run(copyGit + ["read-tree", "--empty"], in: folder, environment: environment)
        try DesignGitRunner.run(copyGit + ["add", "-A", "--", "."], in: folder, environment: environment)
        return try String(decoding: DesignGitRunner.run(copyGit + ["write-tree"], in: folder, environment: environment), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Puts the branch back where it was (a merge commit whose checkout failed).
    static func restoreBranch(_ folder: URL, to head: String) {
        let git = DesignGitRunner(folder: folder)
        let branch = (try? git.text(["symbolic-ref", "--short", "-q", "HEAD"])) ?? "main"
        _ = try? git.run(["update-ref", "-m", "shepherd: merge undone", "refs/heads/\(branch)", head])
    }

    /// The design's tracked files take HEAD's (a merge commit's): changed and new files written,
    /// files HEAD no longer has removed. Only tracked paths; Shepherd's own files stay.
    static func checkoutHead(_ folder: URL) throws {
        let git = DesignGitRunner(folder: folder)
        let before = Set(((try? git.run(["ls-files", "-z", "--"] + tracked)) ?? Data())
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        try checkTree(try tree(git, "HEAD"))
        try git.run(["read-tree", "-u", "--reset", "HEAD"])
        let after = Set(try tree(git, "HEAD").map(\.path))
        for path in before.subtracting(after) where isTrackedPath(path) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(path))
        }
    }

    /// At launch: a merge copy a quit or crash left behind goes. A restart never resumes a merge.
    static func dropLeftoverMergeCopies(in designs: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: designs.path)) ?? []
        for name in names where !name.hasPrefix(".") {
            discardMergeCopy(designs.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// After the design's files were replaced with the merge's: the index follows HEAD, and the
    /// merge copy goes.
    static func finishMerge(_ folder: URL) {
        let git = DesignGitRunner(folder: folder)
        _ = try? git.run(["reset", "-q", "--mixed", "HEAD"])
        discardMergeCopy(folder)
    }

    /// `url`'s path inside `root`, both with their links resolved (/tmp is /private/tmp).
    static func relativePath(_ url: URL, in root: URL) -> String {
        let base = root.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    static func discardMergeCopy(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(mergeCopyName, isDirectory: true))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(".git-merge.index"))
    }
}

