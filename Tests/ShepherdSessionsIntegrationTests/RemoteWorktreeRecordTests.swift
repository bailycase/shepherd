import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// `RemoteAgentQuery.setWorktree`: a client (the branch card on This Mac) changed a worktree
/// thread's checkout itself and asks the host to record the branch or base, answered by the server.
@Suite("Remote worktree record", .integrationTimeLimit)
struct RemoteWorktreeRecordTests {
    @Test func theHostRecordsAWorktreeThreadsBranchAndBase() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let space = Space(name: "demo", path: r.host.dir.path)
        let thread = LeafPane(cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(thread))
        var agent = Agent(name: "agent", spaceID: space.id, tabID: tab.id, paneID: thread.id)
        agent.worktreeBranch = "agent/old"
        agent.worktreeBase = "main"
        var seeded = tab
        seeded.layout = seeded.layout.updatingLeaf(thread.id) { $0.agentID = agent.id }
        try await r.host.seed(ShepherdState(spaces: [space], tabs: [seeded], agents: [agent]))
        let client = try await r.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.worktreeRecordCapability))

        #expect(try await client.agentQuery(agentID: agent.id, query: .setWorktree(branch: "feat/card", base: nil)) == .ok)
        #expect(r.host.server.state.agents.first?.worktreeBranch == "feat/card")
        #expect(r.host.server.state.agents.first?.worktreeBase == "main")
        #expect(try await client.agentQuery(agentID: agent.id, query: .setWorktree(branch: nil, base: "release")) == .ok)
        #expect(r.host.server.state.agents.first?.worktreeBranch == "feat/card")
        #expect(r.host.server.state.agents.first?.worktreeBase == "release")
        #expect(try r.host.persisted().agents.first?.worktreeBase == "release")

        // An agent the host no longer lists is refused, and nothing changes.
        await #expect(throws: (any Error).self) {
            _ = try await client.agentQuery(agentID: AgentID(), query: .setWorktree(branch: "x", base: nil))
        }
    }
}
