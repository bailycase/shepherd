import Foundation
import CryptoKit
import ShepherdCore
import ShepherdProtocol

/// The Changes pane's engine, owned by the host's `SessionServer` (docs/changes.md): every scope
/// resolves to two git objects — a tree or commit on each side — and a diff runs between them.
/// The working tree becomes a tree through a snapshot: `git add -A` and `git write-tree` on an
/// index file of Shepherd's own, in the support directory, never the user's. Its only effect on
/// the repository is loose objects in `.git/objects` (AGENTS.md › Only these paths mutate
/// repositories).
///
/// Everything here blocks on git, so it runs on the engine's own queues: never the server
/// queue, never the main thread. Diffs are cached by the objects they ran between, so a
/// repeated request costs nothing while the working tree is unchanged.
public final class ChangesService: @unchecked Sendable {
    /// Moves a file to the Trash. Tests pass their own, which never reaches the user's Trash.
    public typealias Trash = @Sendable (URL) throws -> Void

    public static let systemTrash: Trash = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// What the engine needs to know about an agent: where it works and what its branch is based on.
    public struct AgentContext: Sendable {
        public var cwd: String
        public var worktreeBase: String?
        public var isWorktree: Bool

        public init(cwd: String, worktreeBase: String? = nil, isWorktree: Bool = false) {
            self.cwd = cwd
            self.worktreeBase = worktreeBase
            self.isWorktree = isWorktree
        }
    }

    let directory: URL
    let trash: Trash
    /// Installed by the server: an agent's directory and branch base, from the committed state.
    var agentContext: @Sendable (AgentID) -> AgentContext? = { _ in nil }
    /// Installed by the server: an agent's turns changed (a capture finished, an Undo). Called on
    /// an engine queue.
    var onTurnsChanged: (@Sendable (AgentID, [ChangesTurn]) -> Void)?

    let work = DispatchQueue(label: "shepherd.changes", qos: .userInitiated, attributes: .concurrent)
    private let repositories = ChangesLocked<[String: Repository]>([:])
    private let indexLocks = ChangesLocked<[String: NSLock]>([:])
    private let emptyTrees = ChangesLocked<[String: String]>([:])
    private let lists = ChangesCache<[ChangesFile]>(capacity: 64)
    private let diffs = ChangesCache<DiffFile>(capacity: 512)
    private let pullRequests = ChangesLocked<[String: (at: Date, value: ChangesPullRequest?)]>([:])
    private let recents: ChangesRecents
    let turnStore: TurnStore
    let captureQueues = ChangesLocked<[AgentID: DispatchQueue]>([:])

    /// How long a pull request lookup (gh, over the network) is reused.
    static let pullRequestTTL: TimeInterval = 60

    public init(directory: URL, trash: @escaping Trash = ChangesService.systemTrash) {
        self.directory = directory
        self.trash = trash
        recents = ChangesRecents(url: directory.appendingPathComponent("bases.json"))
        turnStore = TurnStore(url: directory.appendingPathComponent("turns.json"))
    }

    var indexDirectory: URL { directory.appendingPathComponent("index", isDirectory: true) }

    // MARK: Repository

    struct Repository: Hashable, Sendable {
        /// The working tree's top level: every path the engine reports is relative to it.
        let root: String
        /// The user's index file (per worktree).
        let index: String
        let commonDir: String
        let gitDir: String

        /// Names Shepherd's index files for this working tree.
        var key: String {
            SHA256.hash(data: Data(index.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        }

        /// A linked worktree (`git worktree add`), not the main checkout.
        var isLinkedWorktree: Bool { gitDir != commonDir }
    }

    func repository(_ cwd: String) throws -> Repository {
        if let known = repositories.withValue({ $0[cwd] }) { return known }
        guard FileManager.default.fileExists(atPath: cwd) else {
            throw ChangesError(ChangesError.notARepository, "\(cwd) no longer exists.")
        }
        let result = try ChangesGit.run(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-path", "index",
                                         "--git-common-dir", "--absolute-git-dir"], in: cwd)
        let lines = result.text.split(separator: "\n").map(String.init)
        guard result.status == 0, lines.count == 4 else {
            throw ChangesError(ChangesError.notARepository, "\((cwd as NSString).lastPathComponent) is not a git repository.")
        }
        let repository = Repository(root: lines[0], index: lines[1], commonDir: (lines[2] as NSString).standardizingPath,
                                    gitDir: (lines[3] as NSString).standardizingPath)
        repositories.withValue { $0[cwd] = repository }
        return repository
    }

    private func lock(for repository: Repository) -> NSLock {
        indexLocks.withValue { locks in
            if let lock = locks[repository.key] { return lock }
            let lock = NSLock()
            locks[repository.key] = lock
            return lock
        }
    }

    // MARK: Snapshots

    /// The working tree as a tree object, untracked files included and ignored ones not: `git add
    /// -A` then `git write-tree` against Shepherd's own index for this working tree. That index
    /// starts as a copy of the user's (so tracked but ignored files stay, and git's stat cache
    /// makes the next snapshot re-read only what changed) and lives on in the support
    /// directory. Untracked files over `ChangesLimits.untrackedFileBytes` stay out.
    func snapshot(_ repository: Repository) throws -> (tree: String, skipped: [String]) {
        let lock = lock(for: repository)
        lock.lock()
        defer { lock.unlock() }
        let index = try snapshotIndex(repository)
        let untracked = try ChangesGit.checked(["ls-files", "-z", "--others", "--exclude-standard"], in: repository.root, index: index)
        let root = URL(fileURLWithPath: repository.root, isDirectory: true)
        let skipped = untracked.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { path in
            let size = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.size] as? NSNumber)?.intValue ?? 0
            return size > ChangesLimits.untrackedFileBytes
        }
        let pathspecs = ["."] + skipped.map { ":(exclude,literal)\($0)" }
        let input = Data(pathspecs.joined(separator: "\0").utf8)
        // A file git cannot read (exit 1 with --ignore-errors) stays as the index had it.
        _ = try ChangesGit.checked(["add", "-A", "--ignore-errors", "--pathspec-from-file=-", "--pathspec-file-nul"],
                                   in: repository.root, index: index, input: input, allowed: [0, 1])
        let tree = try ChangesGit.checked(["write-tree"], in: repository.root, index: index).trimmed
        return (tree, skipped)
    }

    /// Shepherd's index for this working tree, seeded from the user's the first time.
    private func snapshotIndex(_ repository: Repository) throws -> String {
        let url = indexDirectory.appendingPathComponent(repository.key)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: repository.index) {
                try? fm.removeItem(at: url)
                try fm.copyItem(atPath: repository.index, toPath: url.path)
            }
        }
        return url.path
    }

    /// The index as a tree (Staged, Unstaged): `git write-tree` on a copy of the user's index,
    /// since write-tree also writes the index file it reads.
    func indexTree(_ repository: Repository) throws -> String {
        guard FileManager.default.fileExists(atPath: repository.index) else { return try emptyTree(repository) }
        let lock = lock(for: repository)
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        let copy = indexDirectory.appendingPathComponent(repository.key + ".staged")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(atPath: repository.index, toPath: copy.path)
        defer { try? FileManager.default.removeItem(at: copy) }
        let result = try ChangesGit.run(["write-tree"], in: repository.root, index: copy.path)
        guard result.status == 0 else {
            throw ChangesError(ChangesError.unavailable, "The index has unresolved conflicts.")
        }
        return result.trimmed
    }

    func emptyTree(_ repository: Repository) throws -> String {
        if let tree = emptyTrees.withValue({ $0[repository.commonDir] }) { return tree }
        let tree = try ChangesGit.checked(["hash-object", "-t", "tree", "/dev/null"], in: repository.root).trimmed
        emptyTrees.withValue { $0[repository.commonDir] = tree }
        return tree
    }

    /// A commit's full id; nil when `name` names none (or is unsafe to pass to git).
    func commit(_ name: String, in repository: Repository) -> String? {
        guard Self.isSafeName(name),
              let result = try? ChangesGit.run(["rev-parse", "-q", "--verify", "\(name)^{commit}"], in: repository.root),
              result.status == 0 else { return nil }
        let id = result.trimmed
        return id.isEmpty ? nil : id
    }

    /// An object's existence (a turn's trees survive only until git prunes them).
    func exists(_ object: String, in repository: Repository) -> Bool {
        (try? ChangesGit.run(["cat-file", "-e", object], in: repository.root))?.status == 0
    }

    /// Refs and ids a client may name: never an option, a range, or anything with spaces.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 256 && !name.hasPrefix("-") && !name.contains("..")
            && !name.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 0x20 || $0 == "\u{7F}" }
    }

    func shortID(_ id: String) -> String { String(id.prefix(7)) }

    func currentBranch(_ repository: Repository) -> String? {
        let result = try? ChangesGit.run(["symbolic-ref", "-q", "--short", "HEAD"], in: repository.root)
        guard let result, result.status == 0, !result.trimmed.isEmpty else { return nil }
        return result.trimmed
    }

    func remotes(_ repository: Repository) -> Set<String> {
        guard let result = try? ChangesGit.run(["remote"], in: repository.root), result.status == 0 else { return [] }
        return Set(result.text.split(separator: "\n").map(String.init))
    }

    /// What Branch compares against: the agent's own base, the remote's default branch, or
    /// main or master.
    func defaultBase(_ repository: Repository, agentBase: String?) -> String? {
        let current = currentBranch(repository)
        if let agentBase, commit(agentBase, in: repository) != nil { return agentBase }
        if let result = try? ChangesGit.run(["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"], in: repository.root),
           result.status == 0, !result.trimmed.isEmpty, commit(result.trimmed, in: repository) != nil {
            return result.trimmed
        }
        return ["origin/main", "origin/master", "main", "master"].first { $0 != current && commit($0, in: repository) != nil }
    }

    // MARK: Resolution

    struct Resolution {
        let revision: ChangesRevision
        let comparison: ChangesComparison
        var skipped: [String] = []
    }

    /// The two objects a scope compares, and its compare row.
    func resolve(_ scope: ChangesScope, agentID: AgentID?, context: AgentContext, repository: Repository) throws -> Resolution {
        let head = commit("HEAD", in: repository)
        func headOrEmpty() throws -> String { try head ?? emptyTree(repository) }
        func needHead() throws -> String {
            guard let head else { throw ChangesError(ChangesError.unavailable, "The repository has no commits yet.") }
            return head
        }
        func headName() -> String { currentBranch(repository) ?? head.map(shortID) ?? "HEAD" }
        switch scope {
        case .uncommitted:
            let snapshot = try snapshot(repository)
            return Resolution(revision: .init(old: try headOrEmpty(), new: snapshot.tree),
                              comparison: .init(head: "Working tree", base: "HEAD"), skipped: snapshot.skipped)
        case .unstaged:
            let index = try indexTree(repository)
            let snapshot = try snapshot(repository)
            return Resolution(revision: .init(old: index, new: snapshot.tree),
                              comparison: .init(head: "Working tree", base: "Index"), skipped: snapshot.skipped)
        case .staged:
            return Resolution(revision: .init(old: try headOrEmpty(), new: try indexTree(repository)),
                              comparison: .init(head: "Index", base: "HEAD"))
        case .commits(let first, let last):
            guard let firstID = commit(first, in: repository), let lastID = commit(last, in: repository) else {
                throw ChangesError(ChangesError.invalid, "No such commit.")
            }
            let parent = commit("\(firstID)^", in: repository)
            return Resolution(revision: .init(old: try parent ?? emptyTree(repository), new: lastID),
                              comparison: .init(head: shortID(lastID), base: parent.map(shortID) ?? "(root)"))
        case .branch(let requested):
            let head = try needHead()
            guard let base = requested ?? defaultBase(repository, agentBase: context.worktreeBase) else {
                throw ChangesError(ChangesError.unavailable, "No base branch to compare against.")
            }
            guard let baseID = commit(base, in: repository) else {
                throw ChangesError(ChangesError.invalid, "\(base) is not a branch or commit here.")
            }
            guard let mergeBase = try? ChangesGit.checked(["merge-base", baseID, head], in: repository.root).trimmed, !mergeBase.isEmpty else {
                throw ChangesError(ChangesError.unavailable, "\(headName()) and \(base) share no history.")
            }
            if let requested { recents.note(requested, repository: repository.commonDir) }
            let snapshot = try snapshot(repository)
            return Resolution(revision: .init(old: mergeBase, new: snapshot.tree),
                              comparison: .init(head: headName(), base: base, baseName: ChangesParse.baseName(base, remotes: remotes(repository)),
                                                mergeBase: shortID(mergeBase)),
                              skipped: snapshot.skipped)
        case .pullRequest:
            let head = try needHead()
            guard let pull = pullRequest(repository, branch: currentBranch(repository)) else {
                throw ChangesError(ChangesError.unavailable, "This branch has no pull request.")
            }
            guard let base = pullRequestBase(pull, repository: repository), let baseID = commit(base, in: repository) else {
                throw ChangesError(ChangesError.unavailable, "The pull request’s base, \(pull.base), is not here. Fetch it first.")
            }
            guard let mergeBase = try? ChangesGit.checked(["merge-base", baseID, head], in: repository.root).trimmed, !mergeBase.isEmpty else {
                throw ChangesError(ChangesError.unavailable, "\(headName()) and \(base) share no history.")
            }
            return Resolution(revision: .init(old: mergeBase, new: head),
                              comparison: .init(head: pull.head, base: base, baseName: pull.base, mergeBase: shortID(mergeBase)))
        case .lastTurn, .turn:
            guard let agentID else { throw ChangesError(ChangesError.unavailable, "Only an agent has turns.") }
            let record: TurnRecord?
            if case .turn(let id) = scope { record = turnStore.record(agentID, id) } else { record = turnStore.latest(agentID) }
            guard let record else { throw ChangesError(ChangesError.unavailable, "No turn yet.") }
            guard let start = record.startTree, exists(start, in: repository) else {
                throw ChangesError(ChangesError.unavailable, record.turn.reason ?? "The turn’s starting point is no longer available.")
            }
            let end: String
            var skipped: [String] = []
            if let tree = record.endTree {
                end = tree
            } else {
                let snapshot = try snapshot(repository)
                end = snapshot.tree
                skipped = snapshot.skipped
            }
            return Resolution(revision: .init(old: start, new: end),
                              comparison: .init(head: record.endTree == nil ? "Working tree" : "End of turn", base: "Start of turn",
                                                turn: turnStore.published(agentID).first { $0.id == record.turn.id } ?? record.turn),
                              skipped: skipped)
        }
    }

    // MARK: Diffs

    private func diffArguments(_ options: ChangesOptions) -> [String] {
        var arguments = ["diff", "--no-color", "--no-ext-diff", "-M", "--src-prefix=a/", "--dst-prefix=b/"]
        if options.ignoreWhitespace { arguments.append("-w") }
        if options.fullFiles { arguments.append("-U1000000") }
        return arguments
    }

    private func cacheKey(_ repository: Repository, _ revision: ChangesRevision, _ options: ChangesOptions, _ path: String = "") -> String {
        "\(repository.root)\u{0}\(revision.old)\u{0}\(revision.new)\u{0}\(options.ignoreWhitespace)\u{0}\(options.fullFiles)\u{0}\(path)"
    }

    /// The files that differ between a revision's objects, with statuses and counts.
    func files(_ repository: Repository, _ revision: ChangesRevision, _ options: ChangesOptions) throws -> [ChangesFile] {
        guard revision.isWellFormed else { throw ChangesError(ChangesError.invalid, "Not a revision.") }
        let key = cacheKey(repository, revision, ChangesOptions(ignoreWhitespace: options.ignoreWhitespace))
        if let cached = lists.value(key) { return cached }
        var arguments = ["diff", "--no-color", "--no-ext-diff", "-M", "--raw", "--numstat", "-z"]
        if options.ignoreWhitespace { arguments.append("-w") }
        let result = try ChangesGit.checked(arguments + [revision.old, revision.new], in: repository.root)
        let files = ChangesParse.files(rawNumstat: result.stdout, ignoringWhitespace: options.ignoreWhitespace)
        lists.insert(files, key)
        return files
    }

    /// One file's hunks, cut at `ChangesLimits.fileLines`.
    func fileDiff(_ repository: Repository, _ revision: ChangesRevision, path: String, oldPath: String?, options: ChangesOptions) throws -> ChangesFileDiff {
        guard revision.isWellFormed else { throw ChangesError(ChangesError.invalid, "Not a revision.") }
        let key = cacheKey(repository, revision, options, (oldPath ?? "") + "\u{0}" + path)
        let file: DiffFile
        if let cached = diffs.value(key) {
            file = cached
        } else {
            let paths = [oldPath, path].compactMap { $0 }
            let result = try ChangesGit.checked(diffArguments(options) + [revision.old, revision.new, "--"] + paths,
                                                in: repository.root, literalPaths: true)
            let parsed = DiffFile.parse(result.text)
            file = parsed.first { $0.displayPath == path } ?? parsed.first
                ?? DiffFile(oldPath: oldPath ?? path, newPath: path, displayPath: path, isNew: false, isDeleted: false,
                            isRenamed: oldPath != nil, isBinary: false, hunks: [])
            diffs.insert(file, key)
        }
        return Self.truncated(file, lines: ChangesLimits.fileLines)
    }

    /// Every file's hunks at once (the Mac's pane, which is not bound by the remote frame cap).
    func allDiffs(_ repository: Repository, _ revision: ChangesRevision, options: ChangesOptions) throws -> [DiffFile] {
        guard revision.isWellFormed else { throw ChangesError(ChangesError.invalid, "Not a revision.") }
        let result = try ChangesGit.checked(diffArguments(options) + [revision.old, revision.new], in: repository.root)
        return DiffFile.parse(result.text).map { Self.truncated($0, lines: ChangesLimits.fileLines).file }
    }

    /// A revision's diff as a patch `git apply` takes (binary files included).
    func patch(_ repository: Repository, _ revision: ChangesRevision, options: ChangesOptions) throws -> String {
        guard revision.isWellFormed else { throw ChangesError(ChangesError.invalid, "Not a revision.") }
        var arguments = ["diff", "--no-color", "--no-ext-diff", "-M", "--binary", "--src-prefix=a/", "--dst-prefix=b/"]
        if options.ignoreWhitespace { arguments.append("-w") }
        return try ChangesGit.checked(arguments + [revision.old, revision.new], in: repository.root).text
    }

    /// `file` with at most `lines` diff lines.
    static func truncated(_ file: DiffFile, lines limit: Int) -> ChangesFileDiff {
        var remaining = limit
        var hunks: [DiffHunk] = []
        for hunk in file.hunks {
            guard remaining > 0 else { break }
            if hunk.lines.count <= remaining {
                hunks.append(hunk)
                remaining -= hunk.lines.count
            } else {
                hunks.append(DiffHunk(header: hunk.header, lines: Array(hunk.lines.prefix(remaining))))
                remaining = 0
            }
        }
        guard hunks != file.hunks else { return ChangesFileDiff(file: file) }
        return ChangesFileDiff(file: DiffFile(oldPath: file.oldPath, newPath: file.newPath, displayPath: file.displayPath, isNew: file.isNew,
                                              isDeleted: file.isDeleted, isRenamed: file.isRenamed, isBinary: file.isBinary, hunks: hunks),
                               truncated: true)
    }

    // MARK: Pull requests

    /// The checkout's pull request, from gh through a login shell (gh lives on the user's PATH);
    /// nil without gh, a GitHub remote, or a pull request. Reused for `pullRequestTTL`.
    func pullRequest(_ repository: Repository, branch: String?) -> ChangesPullRequest? {
        guard let branch else { return nil }
        let key = repository.root + "\u{0}" + branch
        if let cached = pullRequests.withValue({ $0[key] }), Date().timeIntervalSince(cached.at) < Self.pullRequestTTL {
            return cached.value
        }
        let value = Self.lookUpPullRequest(root: repository.root)
        pullRequests.withValue { $0[key] = (Date(), value) }
        return value
    }

    private static func lookUpPullRequest(root: String) -> ChangesPullRequest? {
        struct View: Decodable {
            let number: Int
            let title: String
            let isDraft: Bool
            let state: String
            let baseRefName: String
            let headRefName: String
            let url: String
        }
        guard let output = runLoginShell("gh pr view --json number,title,isDraft,state,baseRefName,headRefName,url", in: root, timeout: 10),
              let view = try? JSONDecoder().decode(View.self, from: output) else { return nil }
        return ChangesPullRequest(number: view.number, title: view.title, isDraft: view.isDraft, state: view.state,
                                  base: view.baseRefName, head: view.headRefName, url: view.url)
    }

    /// The pull request's base as a ref here: the remote's copy first.
    func pullRequestBase(_ pull: ChangesPullRequest, repository: Repository) -> String? {
        let candidates = remotes(repository).sorted { a, _ in a == "origin" }.map { "\($0)/\(pull.base)" } + [pull.base]
        return candidates.first { commit($0, in: repository) != nil }
    }

    /// stdout of `command` in a login shell, or nil when it fails or outlasts `timeout`.
    static func runLoginShell(_ command: String, in directory: String, timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        let output = ChangesLocked(Data())
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            output.withValue { $0 = data }
            read.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        read.wait()
        return process.terminationStatus == 0 ? output.withValue { $0 } : nil
    }

    // MARK: Branches and commits

    func branches(_ repository: Repository, context: AgentContext) throws -> ChangesBranches {
        let current = currentBranch(repository)
        let result = try ChangesGit.checked(["for-each-ref", "--sort=-committerdate", "--count=500",
                                             "--format=%(refname)%00%(refname:short)%00%(committerdate:unix)%00%(worktreepath)",
                                             "refs/heads", "refs/remotes"], in: repository.root)
        let pull = pullRequest(repository, branch: current)
        return ChangesBranches(defaultBase: defaultBase(repository, agentBase: context.worktreeBase),
                               pullRequestBase: pull.flatMap { pullRequestBase($0, repository: repository) },
                               recents: recents.list(repository.commonDir).filter { commit($0, in: repository) != nil },
                               branches: ChangesParse.branches(result.text, current: current))
    }

    /// The branch's commits against `base`, newest first; HEAD's recent history without one.
    func commits(_ repository: Repository, base: String?) -> (commits: [ChangesCommit], base: String?) {
        let format = "--format=%H%x1f%h%x1f%s%x1f%ct%x1e"
        if let base, let baseID = commit(base, in: repository),
           let result = try? ChangesGit.run(["log", format, "-n", "100", "\(baseID)..HEAD"], in: repository.root), result.status == 0 {
            let commits = ChangesParse.commits(result.text)
            if !commits.isEmpty { return (commits, base) }
        }
        guard let result = try? ChangesGit.run(["log", format, "-n", "30", "HEAD"], in: repository.root), result.status == 0 else { return ([], nil) }
        return (ChangesParse.commits(result.text), nil)
    }
}

// MARK: - Cache

/// A small least-recently-used cache, keyed by the objects a result came from (so an entry is
/// never stale, only evicted).
final class ChangesCache<Value>: @unchecked Sendable {
    private var values: [String: Value] = [:]
    private var order: [String] = []
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) { self.capacity = capacity }

    func value(_ key: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[key] else { return nil }
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
        return value
    }

    func insert(_ value: Value, _ key: String) {
        lock.lock()
        defer { lock.unlock() }
        if values.updateValue(value, forKey: key) == nil {
            order.append(key)
            if order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
        }
    }
}

// MARK: - Recent bases

/// Bases picked in each repository, most recent first (the base picker's recents).
final class ChangesRecents: @unchecked Sendable {
    private let url: URL
    private let state: ChangesLocked<[String: [String]]?> = ChangesLocked(nil)
    static let limit = 5

    init(url: URL) { self.url = url }

    private func load(_ value: inout [String: [String]]?) -> [String: [String]] {
        if let value { return value }
        let loaded = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))) ?? [:]
        value = loaded
        return loaded
    }

    func list(_ repository: String) -> [String] {
        state.withValue { load(&$0)[repository] ?? [] }
    }

    func note(_ base: String, repository: String) {
        let snapshot: [String: [String]] = state.withValue { value in
            var all = load(&value)
            var list = all[repository] ?? []
            list.removeAll { $0 == base }
            list.insert(base, at: 0)
            all[repository] = Array(list.prefix(Self.limit))
            value = all
            return all
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
