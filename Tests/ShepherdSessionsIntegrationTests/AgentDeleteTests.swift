import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport

/// `SessionServer.deleteAgentRemovingWorktree`: a worktree agent deleted with its checkout, which
/// is removed only once its processes have stopped.
@Suite("Agent delete with its worktree", .mainActorExclusive)
@MainActor
struct AgentDeleteTests {
    private struct Fixture {
        let h: ScratchServer
        let repo: URL
        let path: String
        let agent: Agent
    }

    /// A repository with one commit, a worktree on `acme-feature`, and a live pi in the agent's pane.
    private func fixture() async throws -> Fixture {
        let h = try ScratchServer.fresh()
        let repo = h.dir.appendingPathComponent("acme-web")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "# acme\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Shepherd Tests"],
                     ["config", "user.email", "tests@example.com"], ["add", "."], ["commit", "-qm", "initial"]] {
            _ = try git(args, in: repo)
        }
        let path = try GitWorktree.add(repo: repo.path, branch: "acme-feature")
        let space = Space(name: "acme-web", path: repo.path)
        try await h.server.addSpace(space)
        let session = try await h.server.createSession(params: CreateSessionParams(cwd: path, command: StubPi.command, runtime: .rpc))
        let id = AgentID()
        let pane = LeafPane(sessionID: session.id, cwd: path, agentID: id)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: id, name: "feature", spaceID: space.id, tabID: tab.id, paneID: pane.id, worktreeBranch: "acme-feature")
        try await h.server.addAgent(agent, withTab: tab)
        return Fixture(h: h, repo: repo, path: path, agent: agent)
    }

    private func branches(_ f: Fixture) throws -> [String] {
        try git(["branch", "--format=%(refname:short)"], in: f.repo).split(separator: "\n").map(String.init)
    }

    @Test func deletingAWorktreeAgentStopsItsPiThenRemovesItsCheckoutAndBranch() async throws {
        let f = try await fixture()
        defer { f.h.stop() }
        try await f.h.server.deleteAgentRemovingWorktree(f.agent.id)
        #expect(!f.h.server.state.agents.contains { $0.id == f.agent.id })
        #expect(await f.h.server.listSessions().allSatisfy { !$0.isAlive })
        #expect(!FileManager.default.fileExists(atPath: f.path))
        #expect(try !branches(f).contains("acme-feature"))
    }

    @Test func aCheckoutStillInUseIsKeptAfterTheAgentIsRetired() async throws {
        let f = try await fixture()
        defer { f.h.stop() }
        struct InUse: Error {}
        await #expect(throws: InUse.self) {
            try await f.h.server.deleteAgentRemovingWorktree(f.agent.id, checkUnused: { throw InUse() })
        }
        #expect(!f.h.server.state.agents.contains { $0.id == f.agent.id })
        #expect(FileManager.default.fileExists(atPath: f.path))
        #expect(try branches(f).contains("acme-feature"))
    }

    @Test func aFolderThatIsNotTheAgentsWorktreeRetiresNothing() async throws {
        let f = try await fixture()
        defer { f.h.stop() }
        _ = try git(["worktree", "remove", "--force", f.path], in: f.repo)
        await #expect(throws: (any Error).self) { try await f.h.server.deleteAgentRemovingWorktree(f.agent.id) }
        #expect(f.h.server.state.agents.contains { $0.id == f.agent.id })
        #expect(try branches(f).contains("acme-feature"))
    }
}
