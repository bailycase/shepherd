import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A branch action the person runs while an agent's turn is running rewrites the working tree under
/// it. The turn's card and Undo must not take that for the agent's work.
@Suite("Branch actions during a turn", .mainActorExclusive)
@MainActor
struct BranchActionTurnTests {
    /// `main` and `other` differ in x.txt and y.txt; the agent only ever names a.txt.
    private func repoWithOtherBranch() throws -> URL {
        let repo = try makeScratchRepo(files: ["a.txt": "a\n", "x.txt": "x on main\n", "y.txt": "y on main\n"])
        try git(["switch", "-q", "-c", "other"], in: repo)
        try "x on other\n".write(to: repo.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try "y on other\n".write(to: repo.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "other differs"], in: repo)
        try git(["switch", "-q", "main"], in: repo)
        return repo
    }

    private func read(_ repo: URL, _ path: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func aBranchSwitchDuringARunningTurnStaysOutOfItsUndo() async throws {
        let held = try await HeldTurn.start(in: try repoWithOtherBranch(), writes: ["a.txt"])
        defer { held.close() }
        let repo = held.repo
        try "a, edited\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        held.vm.performBranchCard(.switchBranch("other"), on: held.agentID)
        try await eventuallyOnMain("the checkout to move to other") {
            (try? git(["rev-parse", "--abbrev-ref", "HEAD"], in: repo))?.trimmingCharacters(in: .whitespacesAndNewlines) == "other"
        }
        let turn = try await held.release()

        #expect(turn.files.map(\.path) == ["a.txt"], "the switch rewrote x.txt and y.txt; they are not the agent's")
        #expect(await held.vm.undoTurn(.local(held.agentID), turnID: turn.id) == nil)
        #expect(try read(repo, "a.txt") == "a\n")
        #expect(try read(repo, "x.txt") == "x on other\n" && read(repo, "y.txt") == "y on other\n", "Undo leaves the files as the branch has them")
    }

    /// Commit from review runs the person's git hooks, and a hook can rewrite files under the turn.
    @Test func aCommitFromReviewDuringARunningTurnStaysOutOfItsUndo() async throws {
        let repo = try makeScratchRepo(files: ["a.txt": "a\n", "notes.txt": "notes\n", "fmt.txt": "raw\n"])
        let hook = repo.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nprintf 'formatted\\n' > fmt.txt\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try "notes, changed\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let held = try await HeldTurn.start(in: repo, writes: ["a.txt"])
        defer { held.close() }
        let vm = held.vm
        held.app.host?.worktrees?.commitRunner = ReviewCommitTests.Runner().closure
        try "a, edited\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        vm.selectAgent(held.agentID)
        vm.openUserReview()
        let session = try #require(vm.reviewSessions.values.first)
        try await eventuallyOnMain("the diff to load") { !session.isLoading }
        let store = try #require(vm.reviewCommitStore(for: session))
        await store.begin()
        store.toggle("a.txt")
        store.confirmedWhileWorking = true
        store.push = false
        await store.commit()
        try await eventuallyAsync("the commit to finish", timeout: .seconds(20)) { await store.pollOnce() }
        #expect(store.outcome == .succeeded(prURL: nil))
        let turn = try await held.release()

        #expect(turn.files.map(\.path) == ["a.txt"], "the hook's rewrite of fmt.txt is not the agent's")
        #expect(await vm.undoTurn(.local(held.agentID), turnID: turn.id) == nil)
        #expect(try read(repo, "a.txt") == "a\n")
        #expect(try read(repo, "fmt.txt") == "formatted\n")
    }
}
