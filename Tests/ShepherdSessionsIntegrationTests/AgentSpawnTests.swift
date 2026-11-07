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
        let id = AgentID()
        let pane = LeafPane(cwd: h.dir.path, agentID: id)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: id, name: "spawned", spaceID: space.id, tabID: tab.id, paneID: pane.id, model: "stub/model-a")
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

    private func paneSession(_ agent: Agent, on h: ScratchServer) -> SessionID? {
        h.server.state.tabs.first { $0.id == agent.tabID }?.layout.leaf(withID: agent.paneID!)?.sessionID
    }

    @Test func aRespawnBindsTheAgentsPiToItsPane() async throws {
        try StubPi.installAsEngine()
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let agent = try await agent(on: h)
        let info = try #require(try await h.server.respawnAgent(AgentSpawn(agent: agent, cwd: "/ignored", settings: AgentLaunchSettings())))
        #expect(info.isAlive)
        #expect(paneSession(agent, on: h) == info.id)
        try await eventuallyOnMain("the stub to record the launch") {
            StubPi.launches().contains { $0.env["SHEPHERD_AGENT_ID"] == agent.id.rawValue }
        }
        let launch = try #require(StubPi.launches().last { $0.env["SHEPHERD_AGENT_ID"] == agent.id.rawValue })
        #expect(PiHome.canonical(launch.cwd) == PiHome.canonical(h.dir.path), "the pane's folder, not the caller's")
        #expect(try await h.server.respawnAgent(AgentSpawn(agent: agent, cwd: "", settings: AgentLaunchSettings())) == nil,
                "a pane bound to a live pi is left alone")
        #expect(await h.server.listSessions().count == 1)
    }

    @Test nonisolated func theHostRespawnsOnlyAgentsWithWorkToRecover() async throws {
        try StubPi.installAsEngine()
        let h = try ScratchServer.fresh()
        let working = try await PiAgent.launch(on: h)
        let idle = try await PiAgent.launch(on: h)
        for pi in [working, idle] { // an agent's own pane, as the app makes it
            var tab = try #require(h.server.state.tabs.first { $0.id == pi.agent.tabID })
            tab.layout = tab.layout.updatingLeaf(pi.agent.paneID!) { $0.agentID = pi.agent.id }
            try await h.server.updateTab(tab)
        }
        _ = try await idle.ready()
        _ = try await working.send("slow", from: try await working.ready())
        _ = try await working.send("queued work", from: try await working.snapshot { $0.running && !$0.provisional.isEmpty })
        #expect(await h.server.agentsNeedingStartupRecovery() == [working.agent.id])
        h.stop(keepFiles: true)

        let restarted = try ScratchServer(dir: h.dir)
        defer { restarted.stop() }
        await restarted.server.respawnAgentsNeedingRecovery { AgentSpawn(agent: $0, cwd: "", settings: AgentLaunchSettings()) }
        let bound = try #require(await paneSession(working.agent, on: restarted))
        #expect(await restarted.server.sessionInfo(sessionID: bound)?.isAlive == true)
        #expect(await restarted.server.listSessions().count == 1, "an agent with nothing to recover waits for demand")
        try await eventually("the recovered turn to settle") { await restarted.server.agentsNeedingStartupRecovery().isEmpty }
    }
}
