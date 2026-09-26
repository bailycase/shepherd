import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// A scratch repository the Changes engine reads, and what it looks like to git.
struct ChangesRepo {
    let url: URL

    init(files: [String: String] = ["README.md": "# scratch\n"]) throws {
        url = try makeScratchRepo(files: files)
    }

    var path: String { url.path }

    func write(_ path: String, _ text: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: url.appendingPathComponent(path))
    }

    func move(_ from: String, _ to: String) throws {
        try FileManager.default.moveItem(at: url.appendingPathComponent(from), to: url.appendingPathComponent(to))
    }

    @discardableResult
    func git(_ args: String...) throws -> String {
        try ShepherdTestSupport.git(args, in: url)
    }

    /// Everything a read must leave alone: the index (bytes and mtime), HEAD, every ref, the
    /// stash, the entries of `.git` other than its objects, and every working-tree file.
    struct State: Equatable {
        let index: Data
        let indexModified: Date?
        let head: String
        let refs: String
        let stash: String
        let gitEntries: [String]
        let files: [String: Data]
    }

    /// Expects `state()` to equal `before`, naming the parts that differ.
    func expectUnchanged(since before: State, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let now = try state()
        #expect(now.index == before.index, "the index's bytes", sourceLocation: sourceLocation)
        #expect(now.indexModified == before.indexModified, "the index's mtime", sourceLocation: sourceLocation)
        #expect(now.head == before.head, "HEAD", sourceLocation: sourceLocation)
        #expect(now.refs == before.refs, "refs: \(before.refs) → \(now.refs)", sourceLocation: sourceLocation)
        #expect(now.stash == before.stash, "the stash", sourceLocation: sourceLocation)
        #expect(now.gitEntries == before.gitEntries, ".git: \(before.gitEntries) → \(now.gitEntries)", sourceLocation: sourceLocation)
        #expect(now.files == before.files, "files: \(Set(before.files.keys).symmetricDifference(now.files.keys)) \(now.files.keys.filter { before.files[$0] != now.files[$0] })", sourceLocation: sourceLocation)
    }

    func state() throws -> State {
        let gitDir = url.appendingPathComponent(".git")
        let index = gitDir.appendingPathComponent("index")
        let modified = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        let entries = try FileManager.default.contentsOfDirectory(atPath: gitDir.path).filter { $0 != "objects" }.sorted()
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(atPath: url.path)
        while let relative = enumerator?.nextObject() as? String {
            if relative == ".git" { enumerator?.skipDescendants(); continue }
            if enumerator?.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
                files[relative] = try Data(contentsOf: url.appendingPathComponent(relative))
            }
        }
        return State(index: try Data(contentsOf: index), indexModified: modified,
                     head: try String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8),
                     refs: try git("for-each-ref", "--format=%(refname) %(objectname)"), stash: try git("stash", "list", "--format=%H"),
                     gitEntries: entries, files: files)
    }
}

/// The engine on its own: a scratch support directory, a scratch trash, and one agent working in
/// `repo`.
struct ChangesHarness {
    let service: ChangesService
    let directory: URL
    let agent = AgentID()

    init(repo: ChangesRepo, worktreeBase: String? = nil, isWorktree: Bool = false) throws {
        directory = try makeScratchDirectory("chg")
        let trash = directory.appendingPathComponent("Trash")
        service = ChangesService(directory: directory.appendingPathComponent("changes"), trash: { url in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        let agent = agent
        let context = ChangesService.AgentContext(cwd: repo.path, worktreeBase: worktreeBase, isWorktree: isWorktree)
        service.agentContext = { $0 == agent ? context : nil }
    }

    func list(_ scope: ChangesScope, _ options: ChangesOptions = ChangesOptions()) async throws -> ChangesList {
        try await service.list(agentID: agent, scope: scope, options: options)
    }
}

extension ChangesList {
    /// "M a.txt", "R c.txt→e.txt": each file as a status and path.
    var summary: [String] {
        files.map { file in "\(file.status.rawValue) " + (file.oldPath.map { "\($0)→" } ?? "") + file.path }.sorted()
    }
}

@Suite("Changes engine", .integrationTimeLimit)
struct ChangesEngineTests {
    /// Working tree, index and HEAD: each scope sees its own part of the changes, untracked files
    /// count, ignored ones don't — and reading them touches nothing the user owns (loose objects
    /// in `.git/objects` are the only trace).
    @Test func scopesSplitTheWorkingTreeAndLeaveTheRepositoryAlone() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "one\ntwo\n", "b.txt": "bee\n", "c.txt": "a file that moves\nwith its lines\n",
                                          "dir/d.txt": "dee\n", ".gitignore": "*.log\n"])
        // A stash entry, to prove it survives.
        try repo.write("a.txt", "stashed\n")
        try repo.git("stash")
        try repo.write("a.txt", "one\n2\n")
        try repo.remove("b.txt")
        try repo.move("c.txt", "e.txt")
        try repo.write("new.txt", "new\n")
        try repo.write("debug.log", "ignored\n")
        try repo.write("dir/d.txt", "dee staged\n")
        try repo.git("add", "dir/d.txt")
        let before = try repo.state()
        let h = try ChangesHarness(repo: repo)

        let uncommitted = try await h.list(.uncommitted)
        #expect(uncommitted.summary == ["A new.txt", "D b.txt", "M a.txt", "M dir/d.txt", "R c.txt→e.txt"])
        #expect(uncommitted.comparison.head == "Working tree" && uncommitted.comparison.base == "HEAD")
        #expect(uncommitted.files.first { $0.path == "a.txt" }.map { "+\($0.added) −\($0.removed)" } == "+1 −1")
        #expect(try await h.list(.staged).summary == ["M dir/d.txt"])
        #expect(try await h.list(.unstaged).summary == ["A new.txt", "D b.txt", "M a.txt", "R c.txt→e.txt"])

        let overview = try await h.service.overview(agentID: h.agent)
        #expect(overview.repository.map { ($0 as NSString).resolvingSymlinksInPath } == (repo.path as NSString).resolvingSymlinksInPath)
        #expect(overview.branch == "main" && overview.defaultScope == .uncommitted)
        #expect(overview.entries.first { $0.scope == .uncommitted }?.files == 5)
        #expect(overview.entries.first { $0.scope == .lastTurn }?.unavailable == "No turn yet.")
        #expect(overview.entries.first { $0.scope == .pullRequest }?.unavailable != nil, "no gh here")

        let a = try await h.service.file(agentID: h.agent, revision: uncommitted.revision, path: "a.txt")
        #expect(a.file.hunks.flatMap(\.lines).map { "\($0.kind.reviewMarker)\($0.text)" } == [" one", "-two", "+2"])
        _ = try await h.service.patch(agentID: h.agent, revision: uncommitted.revision)
        _ = try await h.service.diffs(agentID: h.agent, revision: uncommitted.revision)

        try repo.expectUnchanged(since: before)
    }

    /// A file's hunks come from the revision its list was made from, whatever changed since; the
    /// options hide whitespace changes and load the whole file.
    @Test func aFilesHunksBelongToItsListAndFollowTheOptions() async throws {
        let body = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let repo = try ChangesRepo(files: ["long.txt": body, "spaces.txt": "let x = 1\n"])
        try repo.write("long.txt", body.replacingOccurrences(of: "line 15\n", with: "line fifteen\n"))
        try repo.write("spaces.txt", "let  x = 1\n")
        let h = try ChangesHarness(repo: repo)
        let list = try await h.list(.uncommitted)

        try repo.write("long.txt", "rewritten\n")
        let long = try await h.service.file(agentID: h.agent, revision: list.revision, path: "long.txt")
        #expect(long.file.hunks.flatMap(\.lines).filter { $0.kind != .context }.map(\.text) == ["line 15", "line fifteen"])
        #expect(long.file.hunks.flatMap(\.lines).count == 8, "three lines of context either side")
        let full = try await h.service.file(agentID: h.agent, revision: list.revision, path: "long.txt", options: ChangesOptions(fullFiles: true))
        #expect(full.file.hunks.flatMap(\.lines).count == 31)

        let spaces = try await h.service.file(agentID: h.agent, revision: list.revision, path: "spaces.txt",
                                              options: ChangesOptions(ignoreWhitespace: true))
        #expect(spaces.file.hunks.isEmpty)
        // A file whose only changes are whitespace leaves the list while they are hidden.
        let hidden = try await h.list(.uncommitted, ChangesOptions(ignoreWhitespace: true))
        #expect(hidden.summary == ["M long.txt"])

        let words = DiffWords.changes(in: long.file)
        #expect(words.count == 2, "the changed line and its replacement pair")
    }

    /// Branch compares the working tree with its merge base; Commits takes one commit or a range;
    /// the overview lists the branch's commits and opens a worktree agent on Branch.
    @Test func branchAndCommitsCompareAgainstTheirBases() async throws {
        let repo = try ChangesRepo(files: ["shared.txt": "base\n"])
        try repo.git("checkout", "-q", "-b", "agent/refund-events")
        try repo.write("refund.go", "package ledger\n")
        try repo.git("add", "."); try repo.git("commit", "-qm", "Codec for outbox payloads")
        try repo.write("outbox.go", "package ledger\n")
        try repo.git("add", "."); try repo.git("commit", "-qm", "Emit refund events")
        try repo.git("checkout", "-q", "main")
        try repo.write("main-only.txt", "later on main\n")
        try repo.git("add", "."); try repo.git("commit", "-qm", "Main moves on")
        try repo.git("checkout", "-q", "agent/refund-events")
        try repo.write("draft.go", "package ledger // uncommitted\n")
        let h = try ChangesHarness(repo: repo, worktreeBase: "main", isWorktree: true)

        let branch = try await h.list(.branch(base: nil))
        #expect(branch.summary == ["A draft.go", "A outbox.go", "A refund.go"], "main's own commit is not the branch's")
        let mergeBase = try repo.git("merge-base", "main", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(branch.comparison.mergeBase == String(mergeBase.prefix(7)))
        #expect(branch.comparison.head == "agent/refund-events" && branch.title == "Branch · vs main")

        let overview = try await h.service.overview(agentID: h.agent)
        #expect(overview.defaultScope == .branch(base: nil) && overview.defaultBase == "main")
        #expect(overview.commits.map(\.subject) == ["Emit refund events", "Codec for outbox payloads"])
        #expect(overview.commitsBase == "main")
        let newest = try #require(overview.commits.first), oldest = try #require(overview.commits.last)
        #expect(try await h.list(.commits(first: newest.id, last: newest.id)).summary == ["A outbox.go"])
        #expect(try await h.list(.commits(first: oldest.id, last: newest.id)).summary == ["A outbox.go", "A refund.go"])

        await #expect(throws: ChangesError.self) { _ = try await h.list(.branch(base: "--output=/tmp/x")) }
        await #expect(throws: ChangesError.self) { _ = try await h.list(.commits(first: "nope", last: "nope")) }
    }

    /// The base picker: every branch, the default base, recents first once picked, and branches
    /// checked out in another worktree tagged with it.
    @Test func theBasePickerListsBranchesWorktreesAndRecents() async throws {
        let repo = try ChangesRepo()
        try repo.git("branch", "feat/ledger-v2")
        let worktree = try makeScratchDirectory("wt")
        try FileManager.default.removeItem(at: worktree)
        try repo.git("worktree", "add", "-q", "-b", "agent/retry-plan", worktree.path)
        try repo.git("checkout", "-q", "-b", "agent/refund-events")
        let h = try ChangesHarness(repo: repo)

        let branches = try await h.service.branches(agentID: h.agent)
        #expect(branches.defaultBase == "main")
        #expect(Set(branches.branches.map(\.name)) == ["main", "feat/ledger-v2", "agent/retry-plan", "agent/refund-events"])
        let retry = try #require(branches.branches.first { $0.name == "agent/retry-plan" })
        #expect(retry.worktree.map { ($0 as NSString).resolvingSymlinksInPath } == (worktree.path as NSString).resolvingSymlinksInPath)
        #expect(branches.branches.first { $0.isCurrent }?.name == "agent/refund-events")
        #expect(branches.recents.isEmpty)

        _ = try await h.list(.branch(base: "feat/ledger-v2"))
        #expect(try await h.service.branches(agentID: h.agent).recents == ["feat/ledger-v2"])
    }

    /// Copy as patch: what the engine hands out applies cleanly to the commit it was made against.
    @Test func aPatchAppliesToAClone() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "one\n", "gone.txt": "bye\n"])
        try repo.write("a.txt", "one\ntwo\n")
        try repo.remove("gone.txt")
        try repo.write("bin.dat", String(decoding: [0, 1, 2, 255, 0, 7].map { UInt8($0) }, as: UTF8.self))
        let h = try ChangesHarness(repo: repo)
        let list = try await h.list(.uncommitted)
        let patch = try await h.service.patch(agentID: h.agent, revision: list.revision)

        let clone = try makeScratchDirectory("clone")
        try FileManager.default.removeItem(at: clone)
        try ShepherdTestSupport.git(["clone", "-q", repo.path, clone.path], in: repo.url)
        let patchFile = clone.appendingPathComponent("changes.patch")
        try patch.write(to: patchFile, atomically: true, encoding: .utf8)
        try ShepherdTestSupport.git(["apply", "changes.patch"], in: clone)
        #expect(try String(contentsOf: clone.appendingPathComponent("a.txt"), encoding: .utf8) == "one\ntwo\n")
        #expect(!FileManager.default.fileExists(atPath: clone.appendingPathComponent("gone.txt").path))
        #expect(FileManager.default.fileExists(atPath: clone.appendingPathComponent("bin.dat").path))
    }

    @Test func aDirectoryOutsideGitHasNothingToCompare() async throws {
        let plain = try makeScratchDirectory("plain")
        let h = try ChangesHarness(repo: ChangesRepo())
        let overview = try await h.service.overview(agentID: nil, cwd: plain.path)
        #expect(overview.repository == nil && overview.reason?.contains("not a git repository") == true)
        let error = await #expect(throws: ChangesError.self) { _ = try await h.service.list(agentID: nil, scope: .uncommitted, cwd: plain.path) }
        #expect(error?.code == ChangesError.notARepository)
    }

    /// A file's hunks are cached by the objects they came from: asking again runs no git, and a
    /// list of an unchanged working tree runs only its snapshot, not the diff.
    @Test func repeatedRequestsForUnchangedObjectsRunNoDiffs() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "one\n"])
        try repo.write("a.txt", "one\ntwo\n")
        let h = try ChangesHarness(repo: repo)
        let root = try h.service.repository(repo.path).root
        func runs() -> Int { ChangesGit.runs.withValue { $0[root, default: 0] } }

        let list = try await h.list(.uncommitted)
        let beforeFile = runs()
        _ = try await h.service.file(agentID: h.agent, revision: list.revision, path: "a.txt")
        #expect(runs() - beforeFile == 1, "one git diff")
        let again = runs()
        _ = try await h.service.file(agentID: h.agent, revision: list.revision, path: "a.txt")
        #expect(runs() == again, "cached")

        let snapshot = runs()
        _ = try await h.service.snapshot(h.service.repository(repo.path))
        let snapshotRuns = runs() - snapshot
        let relist = runs()
        let second = try await h.list(.uncommitted)
        #expect(second.revision == list.revision)
        #expect(runs() - relist == snapshotRuns + 1, "the snapshot and HEAD, not the diff")
    }

    /// Untracked files too big to hash stay out of snapshots (and out of `.git/objects`).
    @Test func aHugeUntrackedFileStaysOutOfTheSnapshot() async throws {
        let repo = try ChangesRepo()
        let big = repo.url.appendingPathComponent("dump.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(ChangesLimits.untrackedFileBytes + 1))
        try handle.close()
        try repo.write("small.txt", "hi\n")
        let h = try ChangesHarness(repo: repo)
        let list = try await h.list(.uncommitted)
        #expect(list.summary == ["A small.txt"])
        #expect(list.skipped == ["dump.bin"])
    }
}
