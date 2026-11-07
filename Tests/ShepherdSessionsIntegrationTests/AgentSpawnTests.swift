import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport

/// `SessionServer.spawnAgent`: an agent's pi started by the server from settings passed in as
/// values, for a new agent and a respawn alike. Binding it to its pane stays the caller's.
@Suite("Agent spawn", .mainActorExclusive)
@MainActor
struct AgentSpawnTests {
    private func agent(on h: ScratchServer) async throws -> Agent {
        let space = Space(name: "spawn", path: h.dir.path)
        try await h.server.addSpace(space)
        let pane = LeafPane(cwd: h.dir.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "spawned", spaceID: space.id, tabID: tab.id, paneID: pane.id, model: "stub/model-a")
        try await h.server.addAgent(agent, withTab: tab)
        return agent
    }

    @Test func aSpawnStartsTheAgentsPiWithItsLaunchLine() async throws {
        try StubPi.installAsEngine()
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let agent = try await agent(on: h)
        var released = false
        var spawn = AgentSpawn(agent: agent, cwd: h.dir.path, settings: AgentLaunchSettings())
        spawn.reserveCheckout = { _ in { released = true } }
        let info = try #require(try await h.server.spawnAgent(spawn))
        #expect(info.isAlive)
        #expect(released, "the checkout is held only while pi starts")
        try await eventuallyOnMain("the stub to record the launch") {
            StubPi.launches().contains { $0.env["SHEPHERD_AGENT_ID"] == agent.id.rawValue }
        }
        let launch = try #require(StubPi.launches().last { $0.env["SHEPHERD_AGENT_ID"] == agent.id.rawValue })
        #expect(launch.argv.contains("--mode"))
        #expect(launch.env["SHEPHERD_SOCKET"] != nil)
    }

    @Test func aPaneThatStoppedWantingItSpawnsNothing() async throws {
        try StubPi.installAsEngine()
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        var spawn = AgentSpawn(agent: try await agent(on: h), cwd: h.dir.path, settings: AgentLaunchSettings())
        spawn.stillWanted = { false }
        #expect(try await h.server.spawnAgent(spawn) == nil)
        #expect(await h.server.listSessions().isEmpty)
    }

    @Test func aFollowUpWithoutItsProvenConversationIsRefused() async throws {
        try StubPi.installAsEngine()
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        var spawn = AgentSpawn(agent: try await agent(on: h), cwd: h.dir.path, settings: AgentLaunchSettings())
        spawn.requiredHistoryEntryID = "missing-entry"
        await #expect(throws: AgentSpawnRefused.self) { try await h.server.spawnAgent(spawn) }
        #expect(await h.server.listSessions().isEmpty)
    }
}
