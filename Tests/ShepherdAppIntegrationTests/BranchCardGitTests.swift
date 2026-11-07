import Foundation
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The branch card's git reads on real repositories: the base resolves through origin, the
/// branch counts what it is behind, and Changes counts lines since the branch left its base,
/// committed or not.
@Suite("Branch card git")
struct BranchCardGitTests {
    @Test func aBranchBehindOriginReadsItsLagAndItsOwnLines() throws {
        let origin = try makeScratchRepo(files: ["ledger.go": "a\nb\n"])
        let clone = try makeScratchDirectory("clone")
        defer { for url in [origin, clone] { try? FileManager.default.removeItem(at: url) } }
        try git(["clone", "-q", origin.path, clone.path], in: clone.deletingLastPathComponent())
        for args in [["config", "user.name", "T"], ["config", "user.email", "t@example.com"], ["switch", "-qc", "agent/refund-events"]] {
            try git(args, in: clone)
        }
        // origin/main moves on twice.
        for n in 1...2 {
            try "\(n)\n".write(to: origin.appendingPathComponent("other\(n).txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: origin)
            try git(["commit", "-qm", "main \(n)"], in: origin)
        }
        try git(["fetch", "-q"], in: clone)
        // The branch commits one line changed and leaves one more uncommitted.
        try "a\nB\n".write(to: clone.appendingPathComponent("ledger.go"), atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "branch"], in: clone)
        try "a\nB\nc\n".write(to: clone.appendingPathComponent("ledger.go"), atomically: true, encoding: .utf8)

        let read = BranchCardGitReader.read(cwd: clone.path, base: nil)
        #expect(read == BranchCardGit(additions: 2, deletions: 1, base: "main", behind: 2))
        // A worktree's named base resolves the same way.
        #expect(BranchCardGitReader.read(cwd: clone.path, base: "main") == read)
    }

    @Test func aRepositoryWithoutOriginHasNoBase() throws {
        let repo = try makeScratchRepo(files: ["a.txt": "a\n"])
        defer { try? FileManager.default.removeItem(at: repo) }
        try "a\nb\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(BranchCardGitReader.read(cwd: repo.path, base: nil) == BranchCardGit(additions: 1, deletions: 0, base: nil, behind: 0))
    }
}

/// The branch card from the toolbar: what it lists for the selected thread, and its actions
/// landing on the existing flows.
@Suite("Branch card actions", .mainActorExclusive)
@MainActor
struct BranchCardActionTests {
    @Test func theCardListsTheSpaceAndCommitOpensTheChangesCommit() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try makeScratchRepo(files: ["file.txt": "before\n"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let space = Fixture.space("payments", path: repo.path)
        var mine = Fixture.agent("refunds", in: space)
        mine.agent.worktreeBranch = "agent/refund-events"
        var other = Fixture.agent("webhooks", in: space, order: 1, status: .blocked)
        other.agent.worktreeBranch = "agent/webhook-retries"
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [mine, other]))
        vm.selectAgent(mine.agent.id)

        let handle = vm.branchCardHandle(for: mine.agent.id)
        let card = try #require(handle.card())
        #expect(card.space == "payments" && card.branch == "agent/refund-events" && card.worktree)
        #expect(card.others == [BranchCardOther(id: other.agent.id, branch: "agent/webhook-retries", state: .attention, detail: "asked you")])

        handle.perform(.commit)
        #expect(vm.subagentInspector.open.contains(.local(mine.agent.id)) && vm.subagentInspector.tab(for: .local(mine.agent.id)) == .changes)
        #expect(vm.reviewSessions.values.first { $0.agentID == mine.agent.id }?.commitRequested == true)

        handle.perform(.select(other.agent.id))
        #expect(vm.selectedAgentID == other.agent.id)
    }

    /// The inline card's store reads the checkout and the space, and a turn ending asks it to read again.
    @Test func theCardReadsOnItsOwnAndAgainWhenATurnEnds() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try makeScratchRepo(files: ["file.txt": "a\n"])
        defer { try? FileManager.default.removeItem(at: repo) }
        try "a\nb\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let space = Fixture.space("payments", path: repo.path)
        var mine = Fixture.agent("refunds", in: space, status: .working)
        mine.agent.worktreeBranch = "main"
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [mine]))
        let store = vm.branchCardStore(for: mine.agent.id)
        #expect(vm.branchCardStore(for: mine.agent.id) === store, "one store per thread")

        await store.refresh()
        #expect(store.card?.branch == "main" && store.card?.space == "payments")
        #expect(store.status?.git.additions == 1)

        let before = store.refreshRequest
        vm.sessions.onAgentStatus?(mine.agent.id, .idle, nil)
        #expect(store.refreshRequest == before + 1)
        vm.sessions.onAgentStatus?(mine.agent.id, .idle, nil)
        #expect(store.refreshRequest == before + 1, "only a turn ending asks")
    }
}
