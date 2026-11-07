import ShepherdSessions
import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The branch card's git changes on real repositories (docs/rules.md "Only these paths mutate
/// repositories"): each does what it says, refuses what it must, and Abort restores a stopped
/// update exactly.
@Suite("Branch git")
struct BranchGitTests {
    /// An origin and a clone on `agent/refund-events`, with `ledger.go` the branch can conflict on.
    struct Clone {
        let origin: URL
        let clone: URL

        init() throws {
            origin = try makeScratchRepo(files: ["ledger.go": "a\nb\n"])
            clone = try makeScratchDirectory("clone")
            try git(["clone", "-q", origin.path, clone.path], in: clone.deletingLastPathComponent())
            for args in [["config", "user.name", "T"], ["config", "user.email", "t@example.com"], ["switch", "-qc", "agent/refund-events"]] {
                try git(args, in: clone)
            }
        }

        func commit(_ file: String, _ text: String, in dir: URL, _ message: String = "change") throws {
            try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
            try git(["add", "."], in: dir)
            try git(["commit", "-qm", message], in: dir)
        }

        func head(_ ref: String = "HEAD") throws -> String { try git(["rev-parse", ref], in: clone).trimmingCharacters(in: .whitespacesAndNewlines) }
        func branch() throws -> String { try git(["branch", "--show-current"], in: clone).trimmingCharacters(in: .whitespacesAndNewlines) }
        func remove() { for url in [origin, clone] { try? FileManager.default.removeItem(at: url) } }
    }

    @Test func pushSendsTheBranchAndSetsItsUpstream() throws {
        let repo = try Clone()
        defer { repo.remove() }
        try repo.commit("ledger.go", "a\nB\n", in: repo.clone)
        try repo.commit("ledger.go", "a\nB\nc\n", in: repo.clone)
        #expect(BranchGit.ahead(cwd: repo.clone.path) == nil, "no upstream before the first push")
        try BranchGit.push(cwd: repo.clone.path, branch: "agent/refund-events")
        #expect(try git(["rev-parse", "agent/refund-events"], in: repo.origin) == git(["rev-parse", "HEAD"], in: repo.clone))
        #expect(BranchGit.ahead(cwd: repo.clone.path) == 0)
        #expect(throws: BranchGit.Failure.self) { try BranchGit.push(cwd: repo.clone.path, branch: "--force") }
    }

    @Test func commitTakesOnlyTheTickedFiles() throws {
        let repo = try Clone()
        defer { repo.remove() }
        try "a\nB\n".write(to: repo.clone.appendingPathComponent("ledger.go"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.clone.appendingPathComponent("refund.go"), atomically: true, encoding: .utf8)
        try "scratch\n".write(to: repo.clone.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let id = try BranchGit.commit(cwd: repo.clone.path, paths: ["ledger.go", "refund.go"], message: "Emit refunds\n\nWith a codec.", amend: false)
        #expect(try repo.head().hasPrefix(id))
        #expect(try git(["show", "--name-only", "--format=%B", "HEAD"], in: repo.clone) == "Emit refunds\n\nWith a codec.\n\n\nledger.go\nrefund.go\n")
        #expect(try git(["status", "--porcelain"], in: repo.clone) == "?? notes.md\n", "the unticked file stays untracked")
        #expect(throws: BranchGit.Failure.self) { try BranchGit.commit(cwd: repo.clone.path, paths: [], message: "x", amend: false) }
    }

    @Test func amendReplacesAnUnpushedCommit() throws {
        let repo = try Clone()
        defer { repo.remove() }
        try BranchGit.push(cwd: repo.clone.path, branch: "agent/refund-events")
        try repo.commit("ledger.go", "a\nB\n", in: repo.clone, "Emit refunds")
        let parent = try repo.head("HEAD~1")
        #expect(BranchGit.amendBlocked(cwd: repo.clone.path) == nil)
        try "new\n".write(to: repo.clone.appendingPathComponent("refund.go"), atomically: true, encoding: .utf8)
        try BranchGit.commit(cwd: repo.clone.path, paths: ["refund.go"], message: "Emit refund events", amend: true)
        #expect(try repo.head("HEAD~1") == parent, "one commit, replaced")
        #expect(try git(["show", "--name-only", "--format=%s", "HEAD"], in: repo.clone) == "Emit refund events\n\nledger.go\nrefund.go\n")
        // No files: only the message changes. Then the amended commit pushes without force.
        try BranchGit.commit(cwd: repo.clone.path, paths: [], message: "Emit refund events from the outbox", amend: true)
        #expect(try repo.head("HEAD~1") == parent)
        try BranchGit.push(cwd: repo.clone.path, branch: "agent/refund-events")
        #expect(try git(["rev-parse", "agent/refund-events"], in: repo.origin) == git(["rev-parse", "HEAD"], in: repo.clone))
    }

    /// Amending a pushed commit is the person's call; Commit & push goes off, and the card's Push
    /// afterwards is refused (never forced) with what happened and how to replace it by hand.
    @MainActor
    @Test func amendingAPushedCommitTurnsPushOff() async throws {
        let repo = try Clone()
        defer { repo.remove() }
        try repo.commit("ledger.go", "a\nB\n", in: repo.clone)
        try BranchGit.push(cwd: repo.clone.path, branch: "agent/refund-events")
        let pushed = try repo.head()
        #expect(BranchGit.amendBlocked(cwd: repo.clone.path) == nil)
        #expect(BranchGit.pushedTo(cwd: repo.clone.path) == "origin/agent/refund-events")

        let info = try await ReviewCommitGit.info(cwd: repo.clone.path, agentWorking: false, draftsMessage: false) { await LoginShell.run($0, cwd: $1) }
        let form = BranchCommitSheet.Form(info: info, selected: [], title: "Emit refund events", details: "",
                                          amendBlocked: nil, pushedTo: BranchGit.pushedTo(cwd: repo.clone.path))
        #expect(BranchCommitSheet.pushProblem(form, amend: false) == nil)
        #expect(BranchCommitSheet.pushProblem(form, amend: true)
            == "Commit & push is off: the amended commit will differ from origin/agent/refund-events.")

        try BranchGit.commit(cwd: repo.clone.path, paths: [], message: "Emit refund events", amend: true)
        #expect(try repo.head() != pushed && repo.head("HEAD~1") == repo.head("\(pushed)~1"))
        #expect(throws: BranchGit.Failure(message: "agent/refund-events was amended after it was pushed; push with --force-with-lease in a terminal if you mean to replace it.")) {
            try BranchGit.push(cwd: repo.clone.path, branch: "agent/refund-events")
        }
        #expect(try git(["rev-parse", "agent/refund-events"], in: repo.origin).hasPrefix(pushed), "never forced")
    }

    @Test func amendRefusesDuringAMerge() throws {
        let repo = try Clone()
        defer { repo.remove() }
        try repo.commit("ledger.go", "a\nours\n", in: repo.clone)
        try repo.commit("ledger.go", "a\ntheirs\n", in: repo.origin)
        _ = try BranchGit.update(cwd: repo.clone.path, base: "main", rebase: false)
        let before = try repo.head()
        #expect(BranchGit.amendBlocked(cwd: repo.clone.path) == "A rebase or merge is in progress.")
        #expect(throws: BranchGit.Failure.self) {
            try BranchGit.commit(cwd: repo.clone.path, paths: [], message: "x", amend: true)
        }
        #expect(try repo.head() == before)
    }

    @Test func aRejectedPushIsNeverForced() throws {
        let repo = try Clone()
        defer { repo.remove() }
        try BranchGit.push(cwd: repo.clone.path, branch: "agent/refund-events")
        // Someone else moves the remote branch; ours diverges.
        try git(["switch", "-q", "agent/refund-events"], in: repo.origin)
        try repo.commit("other.txt", "theirs\n", in: repo.origin)
        try git(["switch", "-q", "main"], in: repo.origin)
        let theirs = try git(["rev-parse", "agent/refund-events"], in: repo.origin)
        try repo.commit("ledger.go", "ours\n", in: repo.clone)
        #expect(throws: BranchGit.Failure.self) { try BranchGit.push(cwd: repo.clone.path, branch: "agent/refund-events") }
        #expect(!BranchGit.rewrittenAfterPush(cwd: repo.clone.path, branch: "agent/refund-events"), "someone else's push isn't an amend")
        #expect(try git(["rev-parse", "agent/refund-events"], in: repo.origin) == theirs)
    }

    @Test func updateRebasesOntoTheFetchedBase() throws {
        let repo = try Clone()
        defer { repo.remove() }
        try repo.commit("ledger.go", "a\nB\n", in: repo.clone)
        try repo.commit("main.txt", "1\n", in: repo.origin)
        #expect(try BranchGit.update(cwd: repo.clone.path, base: "main", rebase: true) == .done)
        #expect(try git(["merge-base", "--is-ancestor", "origin/main", "HEAD"], in: repo.clone).isEmpty)
        #expect(try repo.head("HEAD~1") == repo.head("origin/main"), "the branch's commit replays on top")
    }

    @Test func aRebaseConflictStopsAndAbortRestoresTheBranch() throws {
        let repo = try Clone()
        defer { repo.remove() }
        try repo.commit("ledger.go", "a\nours\n", in: repo.clone)
        try repo.commit("notes.txt", "n\n", in: repo.clone)
        try repo.commit("ledger.go", "a\ntheirs\n", in: repo.origin)
        let before = try repo.head()

        let result = try BranchGit.update(cwd: repo.clone.path, base: "main", rebase: true)
        #expect(result == .conflict(BranchGit.Conflict(kind: .rebase, step: 1, steps: 2, files: ["ledger.go"])))
        #expect(BranchGit.conflict(cwd: repo.clone.path)?.files == ["ledger.go"])
        #expect(throws: BranchGit.Failure.self, "a second update refuses while one is stopped") {
            try BranchGit.update(cwd: repo.clone.path, base: "main", rebase: true)
        }

        try BranchGit.abort(cwd: repo.clone.path, .rebase)
        #expect(BranchGit.conflict(cwd: repo.clone.path) == nil)
        #expect(try repo.head() == before && repo.branch() == "agent/refund-events")
    }

    @Test func aMergeConflictStopsAndAbortRestoresTheBranch() throws {
        let repo = try Clone()
        defer { repo.remove() }
        try repo.commit("ledger.go", "a\nours\n", in: repo.clone)
        try repo.commit("ledger.go", "a\ntheirs\n", in: repo.origin)
        let before = try repo.head()
        #expect(try BranchGit.update(cwd: repo.clone.path, base: "main", rebase: false)
            == .conflict(BranchGit.Conflict(kind: .merge, files: ["ledger.go"])))
        try BranchGit.abort(cwd: repo.clone.path, .merge)
        #expect(try repo.head() == before)
        #expect(try git(["status", "--porcelain"], in: repo.clone).isEmpty)
    }

    @Test func updateRefusesUncommittedChanges() throws {
        let repo = try Clone()
        defer { repo.remove() }
        try repo.commit("main.txt", "1\n", in: repo.origin)
        try "dirty\n".write(to: repo.clone.appendingPathComponent("ledger.go"), atomically: true, encoding: .utf8)
        let before = try repo.head()
        #expect(throws: BranchGit.Failure(message: "Commit or revert the uncommitted changes first.")) {
            try BranchGit.update(cwd: repo.clone.path, base: "main", rebase: true)
        }
        #expect(try repo.head() == before)
    }

    @Test func switchCreateAndRenameBranches() throws {
        let repo = try Clone()
        defer { repo.remove() }
        // A remote branch with no local copy becomes one that tracks it.
        try git(["branch", "sam/payout-ui"], in: repo.origin)
        try BranchGit.fetchAll(cwd: repo.clone.path)
        #expect(try BranchGit.switchBranch(cwd: repo.clone.path, to: "origin/sam/payout-ui") == "sam/payout-ui")
        #expect(try repo.branch() == "sam/payout-ui")
        #expect(try git(["rev-parse", "--abbrev-ref", "@{upstream}"], in: repo.clone).hasPrefix("origin/sam/payout-ui"))
        #expect(try BranchGit.switchBranch(cwd: repo.clone.path, to: "agent/refund-events") == "agent/refund-events")

        try BranchGit.createBranch(cwd: repo.clone.path, name: "agent/refund-events-2")
        #expect(try repo.branch() == "agent/refund-events-2")
        #expect(BranchGit.invalidName("main", cwd: repo.clone.path) == "A branch named “main” already exists.")
        #expect(BranchGit.invalidName("bad..name", cwd: repo.clone.path) != nil)
        #expect(BranchGit.invalidName("-f", cwd: repo.clone.path) != nil)

        try BranchGit.renameBranch(cwd: repo.clone.path, from: "agent/refund-events-2", to: "agent/refunds")
        #expect(try repo.branch() == "agent/refunds")
        #expect(throws: BranchGit.Failure.self) { try BranchGit.renameBranch(cwd: repo.clone.path, from: "agent/refunds", to: "main") }
    }

    @Test func aNewWorktreeTakesAnExistingOrRemoteBranch() throws {
        let repo = try Clone()
        defer { repo.remove() }
        try git(["branch", "baily/ledger-refactor"], in: repo.clone)
        try git(["branch", "sam/payout-ui"], in: repo.origin)
        try BranchGit.fetchAll(cwd: repo.clone.path)

        let local = try GitWorktree.addExisting(repo: repo.clone.path, branch: "baily/ledger-refactor")
        defer { try? git(["worktree", "remove", "--force", local.path], in: repo.clone) }
        #expect(local.branch == "baily/ledger-refactor")
        #expect(try git(["branch", "--show-current"], in: URL(fileURLWithPath: local.path)).hasPrefix("baily/ledger-refactor"))

        let remote = try GitWorktree.addExisting(repo: repo.clone.path, branch: "origin/sam/payout-ui")
        defer { try? git(["worktree", "remove", "--force", remote.path], in: repo.clone) }
        #expect(remote.branch == "sam/payout-ui")
        #expect(try git(["rev-parse", "--abbrev-ref", "sam/payout-ui@{upstream}"], in: repo.clone).hasPrefix("origin/sam/payout-ui"))

        #expect(throws: (any Error).self, "a branch checked out elsewhere is refused") {
            try GitWorktree.addExisting(repo: repo.clone.path, branch: "agent/refund-events")
        }
    }
}
