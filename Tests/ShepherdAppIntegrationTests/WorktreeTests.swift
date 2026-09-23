import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A repository at `<root>/proj` with one commit on `main`. Worktrees `GitWorktree.add`
/// creates land beside it, inside `root`, so one removal cleans everything. With `origin`, a
/// local bare repository stands in for the remote (no network).
struct WorktreeSandbox {
    let root: URL
    let repo: URL
    var origin: URL { root.appendingPathComponent("origin.git") }

    init(origin: Bool = false) throws {
        root = try makeScratchDirectory("wt")
        repo = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "# proj\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Shepherd Tests"],
                     ["config", "user.email", "tests@example.com"], ["add", "."], ["commit", "-qm", "initial"]] {
            try git(args, in: repo)
        }
        if origin {
            try git(["init", "-q", "--bare", "--initial-branch=main", self.origin.path], in: root)
            try git(["remote", "add", "origin", self.origin.path], in: repo)
            try git(["push", "-q", "-u", "origin", "main"], in: repo)
            try git(["remote", "set-head", "origin", "main"], in: repo)
        }
    }

    func path(_ branch: String) -> String { GitWorktree.destination(repo: repo.path, branch: branch) }

    func branches() throws -> [String] {
        try git(["branch", "--format=%(refname:short)"], in: repo).split(separator: "\n").map(String.init)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// Creating, inspecting, and removing git worktrees on real scratch repositories.
@Suite("Git worktrees")
struct GitWorktreeTests {
    @Test func addingAWorktreeChecksOutANewBranchBesideTheRepo() throws {
        let sandbox = try WorktreeSandbox()
        defer { sandbox.remove() }

        let path = try GitWorktree.add(repo: sandbox.repo.path, branch: "agent/fix-thing")

        #expect(path == sandbox.root.appendingPathComponent("proj-agent-fix-thing").path)
        #expect(GitWorktree.isRepo(path))
        #expect(GitWorktree.currentBranch(repo: path) == "agent/fix-thing")
        #expect(throws: (any Error).self, "the branch already exists") {
            try GitWorktree.add(repo: sandbox.repo.path, branch: "agent/fix-thing")
        }
    }

    @Test func unreconciledWorkNamesUncommittedChangesThenBranchOnlyCommits() throws {
        let sandbox = try WorktreeSandbox()
        defer { sandbox.remove() }
        let path = try GitWorktree.add(repo: sandbox.repo.path, branch: "agent/work")
        #expect(GitWorktree.unreconciledWork(worktree: path, branch: "agent/work") == nil)

        try "x".write(toFile: path + "/f.txt", atomically: true, encoding: .utf8)
        #expect(GitWorktree.unreconciledWork(worktree: path, branch: "agent/work") == "1 uncommitted change")

        try git(["add", "f.txt"], in: URL(fileURLWithPath: path))
        try git(["commit", "-qm", "wip"], in: URL(fileURLWithPath: path))
        #expect(GitWorktree.unreconciledWork(worktree: path, branch: "agent/work") == "1 commit only on this branch")
    }

    /// A commit another *local* branch reaches is still not on any remote: the remote-cleanup
    /// probe must not treat it as safe.
    @Test func commitsOnlyOnLocalBranchesAreNotSafeForRemoteCleanup() throws {
        let sandbox = try WorktreeSandbox()
        defer { sandbox.remove() }
        try git(["branch", "another-local"], in: sandbox.repo)

        #expect(try GitWorktree.checkedUnreconciledWork(worktree: sandbox.repo.path, branch: "main") != nil)
        #expect(throws: GitWorktree.Failure.self) {
            try GitWorktree.checkedUnreconciledWork(worktree: sandbox.root.appendingPathComponent("missing").path, branch: "main")
        }
    }

    @Test func removingAWorktreeDeletesTheCheckoutAndItsBranch() throws {
        let sandbox = try WorktreeSandbox()
        defer { sandbox.remove() }
        let path = try GitWorktree.add(repo: sandbox.repo.path, branch: "agent/done")

        try GitWorktree.remove(repo: sandbox.repo.path, branch: "agent/done")

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try sandbox.branches() == ["main"])
    }

    @Test func removalRefusesACheckoutThatChangedSinceItWasConfirmed() throws {
        let sandbox = try WorktreeSandbox()
        defer { sandbox.remove() }
        let path = try GitWorktree.add(repo: sandbox.repo.path, branch: "agent/moving")
        let fingerprint = try GitWorktree.deletionFingerprint(worktree: path)
        try "late edit".write(toFile: path + "/late.txt", atomically: true, encoding: .utf8)

        #expect(throws: GitWorktree.Failure.self) {
            try GitWorktree.remove(repo: sandbox.repo.path, branch: "agent/moving", worktree: path, fingerprint: fingerprint)
        }
        #expect(FileManager.default.fileExists(atPath: path + "/late.txt"))
    }

    /// The primary checkout wandered onto a feature branch; a worktree based on
    /// `origin/<default>` carries none of that work and does not track the default branch.
    @Test func aWorktreeFromTheRemoteDefaultCarriesNoCheckoutWorkAndTracksNothing() throws {
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        try git(["checkout", "-qb", "feat/other"], in: sandbox.repo)
        try git(["commit", "-q", "--allow-empty", "-m", "unrelated"], in: sandbox.repo)
        #expect(GitWorktree.defaultBranch(repo: sandbox.repo.path) == "main")

        let fresh = GitWorktree.resolveBase(repo: sandbox.repo.path, mode: .fresh, fetchFirst: false)
        let path = try GitWorktree.add(repo: sandbox.repo.path, branch: "wt/clean", from: fresh.startPoint)

        #expect(fresh.startPoint == "origin/main" && fresh.note == "cached — fetch disabled in settings")
        #expect(try git(["rev-list", "--count", "origin/main..wt/clean"], in: sandbox.repo).trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        #expect(throws: (any Error).self, "no upstream is configured") {
            try git(["config", "--get", "branch.wt/clean.merge"], in: sandbox.repo)
        }
        #expect(GitWorktree.isRepo(path))
        let head = GitWorktree.resolveBase(repo: sandbox.repo.path, mode: .head, fetchFirst: false)
        #expect(head.startPoint == nil && head.display == "feat/other")
    }

    @Test func aLinkedWorktreeReportsItsRepositoryPathAndBranch() throws {
        let sandbox = try WorktreeSandbox()
        defer { sandbox.remove() }
        let linked = sandbox.root.appendingPathComponent("linked/any-name")
        try git(["worktree", "add", "-q", "-b", "worktree/imported", linked.path], in: sandbox.repo)

        let identity = try GitWorktree.identity(at: linked.path)

        #expect(identity.repo == canonical(sandbox.repo))
        #expect(identity.path == canonical(linked))
        #expect(identity.branch == "worktree/imported")
        #expect(GitWorktree.importDirectory(repo: sandbox.repo.path) == canonical(sandbox.root.appendingPathComponent("linked")))
        #expect(throws: (any Error).self, "the primary checkout is not a linked worktree") {
            try GitWorktree.identity(at: sandbox.repo.path)
        }
    }
}

/// Worktree agents through the view model: the import picker, deleting an agent together
/// with its checkout, and refusing work that would lose data.
@Suite("Worktree agents")
@MainActor
struct WorktreeAgentTests {
    private func worktreeAgent(in sandbox: WorktreeSandbox, branch: String) throws -> AgentFixture {
        let path = try GitWorktree.add(repo: sandbox.repo.path, branch: branch)
        let space = Fixture.space("proj", path: sandbox.repo.path)
        var agent = Fixture.agent(branch, in: space, cwd: path)
        agent.agent.worktreeBranch = branch
        agent.agent.worktreePath = path
        return agent
    }

    @Test func theImportPickerOpensInTheReposWorktreeFolderEachTime() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let sandbox = try WorktreeSandbox()
        defer { sandbox.remove() }
        try git(["worktree", "add", "-q", "-b", "worktree/feature", sandbox.root.appendingPathComponent("linked/feature").path], in: sandbox.repo)
        let vm = try await app.start()
        let spaceID = try #require(await vm.addSpace(at: sandbox.repo, createInitialAgent: false))

        vm.importExistingWorktreeFromPanel(in: spaceID)
        guard case .importWorktree(let first) = vm.spacePickerTarget else { Issue.record("no import picker"); return }
        vm.spacePickerTarget = nil
        vm.importExistingWorktreeFromPanel(in: spaceID)
        guard case .importWorktree(let second) = vm.spacePickerTarget else { Issue.record("no import picker"); return }

        #expect(first.spaceID == spaceID)
        #expect(first.startPath == canonical(sandbox.root.appendingPathComponent("linked")))
        #expect(second.id != first.id, "reopening is a new request")
    }

    @Test func importingAWorktreeOfAnotherRepositoryIntoASpaceIsRefused() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let first = try WorktreeSandbox(), second = try WorktreeSandbox()
        defer { first.remove(); second.remove() }
        let foreign = second.root.appendingPathComponent("foreign")
        try git(["worktree", "add", "-q", "-b", "worktree/wrong-space", foreign.path], in: second.repo)
        let vm = try await app.start()
        let spaceID = try #require(await vm.addSpace(at: first.repo, createInitialAgent: false))

        #expect(await vm.importExistingCheckout(at: foreign, into: spaceID) == nil)

        #expect(app.server.state.agents.isEmpty)
        #expect(app.server.state.spaces.count == 1)
    }

    @Test func deletingAWorktreeAgentWithItsCheckoutRemovesTheCheckoutAndBranch() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let sandbox = try WorktreeSandbox()
        defer { sandbox.remove() }
        let agent = try worktreeAgent(in: sandbox, branch: "worktree/finished")
        let vm = try await app.start(with: Fixture.state(spaces: [agent.space], agents: [agent]))

        vm.deleteWorktreeAgent(agent.agent.id, removeWorktree: true)

        let server = app.server
        try await eventuallyOnMain("the checkout and its branch to be removed") {
            !FileManager.default.fileExists(atPath: sandbox.path("worktree/finished")) && server.state.agents.isEmpty
                && (try? sandbox.branches()) == ["main"]
        }
        #expect(vm.remoteActionError == nil)
    }

    @Test func deletingAWorktreeAgentButKeepingTheCheckoutLeavesItsWork() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let sandbox = try WorktreeSandbox()
        defer { sandbox.remove() }
        let agent = try worktreeAgent(in: sandbox, branch: "worktree/keep")
        try "wip".write(toFile: sandbox.path("worktree/keep") + "/wip.txt", atomically: true, encoding: .utf8)
        let vm = try await app.start(with: Fixture.state(spaces: [agent.space], agents: [agent]))

        vm.deleteWorktreeAgent(agent.agent.id, removeWorktree: false)
        await app.settle()

        #expect(app.server.state.agents.isEmpty)
        #expect(FileManager.default.fileExists(atPath: sandbox.path("worktree/keep") + "/wip.txt"))
        #expect(try sandbox.branches().contains("worktree/keep"))
    }

    @Test func aWorktreeDeletionTheServerCannotPersistKeepsTheAgentAndCheckout() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let sandbox = try WorktreeSandbox()
        defer { sandbox.remove() }
        let agent = try worktreeAgent(in: sandbox, branch: "worktree/stuck")
        try "keep me".write(toFile: sandbox.path("worktree/stuck") + "/work.txt", atomically: true, encoding: .utf8)
        let vm = try await app.start(with: Fixture.state(spaces: [agent.space], agents: [agent]))
        let original = app.server.state
        try FileManager.default.removeItem(at: app.scratch.stateURL)
        try FileManager.default.createDirectory(at: app.scratch.stateURL, withIntermediateDirectories: true)

        vm.deleteWorktreeAgent(agent.agent.id, removeWorktree: true)

        try await eventuallyOnMain("the failure to be reported") { vm.remoteActionError != nil }
        #expect(app.server.state == original && vm.state == original)
        #expect(try String(contentsOfFile: sandbox.path("worktree/stuck") + "/work.txt", encoding: .utf8) == "keep me")
    }
}

/// Finalize Worktree's local steps on real repositories. `gh` is the only thing stubbed: a
/// local bare repository is the origin, so commit, push, the clean gate, worktree removal,
/// and branch deletion all run for real.
@Suite("Finalize worktree")
@MainActor
struct FinalizeWorktreeTests {
    private func finalizer(prURL: String = "https://github.com/o/r/pull/7", fakePush: Bool = false) -> WorktreeFinalizer {
        let finalizer = WorktreeFinalizer()
        finalizer.runner = { script, cwd in
            if script.hasPrefix("gh pr create") { return .init(status: 0, stdout: prURL + "\n", stderr: "") }
            if fakePush, script.hasPrefix("git push") { return .init(status: 0, stdout: "", stderr: "") }
            return Self.run(script, cwd: cwd)
        }
        return finalizer
    }

    private static func run(_ script: String, cwd: String?) -> LoginShell.Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return .init(status: 127, stdout: "", stderr: "\(error)") }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return .init(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }

    private func context(_ sandbox: WorktreeSandbox, branch: String) -> WorktreeFinalizer.Context {
        WorktreeFinalizer.Context(repo: sandbox.repo.path, worktree: sandbox.path(branch), branch: branch,
                                  base: "main", title: "Fix the 'thing'", body: "")
    }

    @Test func finalizeCommitsPushesThenRemovesTheWorktreeAndLocalBranch() async throws {
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        let path = try GitWorktree.add(repo: sandbox.repo.path, branch: "worktree/ship")
        try "done\n".write(toFile: path + "/feature.txt", atomically: true, encoding: .utf8)
        let finalizer = finalizer()

        await finalizer.run(context(sandbox, branch: "worktree/ship"))

        #expect(finalizer.phase == .succeeded)
        #expect(finalizer.prURL == "https://github.com/o/r/pull/7")
        #expect(finalizer.states[.commit] == .done("committed") && finalizer.states[.verifyClean] == .done("clean"))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try sandbox.branches() == ["main"])
        let pushed = try git(["log", "-1", "--format=%s", "worktree/ship"], in: sandbox.origin)
        #expect(pushed.trimmingCharacters(in: .whitespacesAndNewlines) == "Fix the 'thing'")
    }

    @Test func aFailedPushStopsBeforeAnythingIsDestroyed() async throws {
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        let path = try GitWorktree.add(repo: sandbox.repo.path, branch: "worktree/offline")
        try "work\n".write(toFile: path + "/work.txt", atomically: true, encoding: .utf8)
        try git(["remote", "set-url", "origin", sandbox.root.appendingPathComponent("gone.git").path], in: sandbox.repo)
        let finalizer = finalizer()

        await finalizer.run(context(sandbox, branch: "worktree/offline"))

        #expect(finalizer.phase == .failed)
        guard case .failed? = finalizer.states[.push] else { Issue.record("push should fail"); return }
        #expect(finalizer.states[.pullRequest] == .pending && finalizer.states[.removeWorktree] == .pending)
        #expect(FileManager.default.fileExists(atPath: path + "/work.txt"))
        #expect(try sandbox.branches().contains("worktree/offline"))
    }

    /// Even when every earlier step reports success, work that is not actually on the
    /// remote blocks all cleanup.
    @Test func theCleanGateBlocksCleanupWhenCommitsNeverReachedTheRemote() async throws {
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        let path = try GitWorktree.add(repo: sandbox.repo.path, branch: "worktree/unpushed")
        try "work\n".write(toFile: path + "/work.txt", atomically: true, encoding: .utf8)
        let finalizer = finalizer(fakePush: true)

        await finalizer.run(context(sandbox, branch: "worktree/unpushed"))

        #expect(finalizer.phase == .failed)
        #expect(finalizer.states[.verifyClean] == .failed("1 commit only on this branch — aborting before any cleanup"))
        #expect(FileManager.default.fileExists(atPath: path + "/work.txt"))
        #expect(try sandbox.branches().contains("worktree/unpushed"))
    }

    @Test func withAutoCommitOffADirtyWorktreeStopsBeforePushing() async throws {
        let sandbox = try WorktreeSandbox(origin: true)
        defer { sandbox.remove() }
        let path = try GitWorktree.add(repo: sandbox.repo.path, branch: "worktree/dirty")
        try "work\n".write(toFile: path + "/work.txt", atomically: true, encoding: .utf8)
        let finalizer = finalizer()
        var ctx = context(sandbox, branch: "worktree/dirty")
        ctx.autoCommit = false

        await finalizer.run(ctx)

        #expect(finalizer.phase == .failed)
        #expect(finalizer.states[.push] == .pending)
        #expect(try git(["status", "--porcelain"], in: URL(fileURLWithPath: path)).contains("work.txt"))
    }
}
