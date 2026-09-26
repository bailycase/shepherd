import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Designs stand alone (the user's decision, 2026-09-26): a design belongs to no space, and its
/// agent lives in the reserved hidden designs space, working in the design's own folder. Spaces
/// never touch designs, design agents last across launches, and startup moves a design agent an
/// older state.json kept in a user space.
@Suite("Standalone designs", .integrationTimeLimit)
struct DesignStandaloneTests {
    /// A design agent in `space`, working in `cwd`.
    private static func designAgent(_ design: DesignID, in space: Space, cwd: String) -> (agent: Agent, tab: ShepherdCore.Tab) {
        let agentID = AgentID()
        let pane = LeafPane(cwd: cwd, agentID: agentID)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: agentID, name: "Checkout", spaceID: space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true,
                          designID: design)
        return (agent, tab)
    }

    /// A server holding a user space with one agent, a design, and the design's agent in the
    /// reserved designs space.
    private func serverWithDesignAgent() async throws
        -> (h: ScratchServer, user: Space, worker: Agent, design: Design, drawer: Agent) {
        let h = try ScratchServer.fresh()
        let user = Fixture.space("web")
        let worker = Fixture.agent(in: user)
        try await h.seed(Fixture.workspace([worker], space: user))
        let design = Design(name: "Checkout", createdAt: 1_000)
        _ = try await h.server.createDesign(design)
        let designsID = try await h.server.designsSpaceID()
        let designs = try #require(h.server.state.spaces.first { $0.id == designsID })
        let folder = try #require(h.server.designs.folder(for: design.id)).path
        let drawer = Self.designAgent(design.id, in: designs, cwd: folder)
        try await h.server.addAgent(drawer.agent, withTab: drawer.tab)
        try await h.server.setDesignAgent(design.id, agentID: drawer.agent.id)
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        return (h, user, worker.agent, try #require(h.server.state.designs.first), drawer.agent)
    }

    @Test func creatingADesignChangesNoSpace() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([worker], space: space))
        let before = h.server.state

        _ = try await h.server.createDesign(Design(name: "Checkout", createdAt: 1_000))

        let after = h.server.state
        #expect(after.spaces == before.spaces && after.tabs == before.tabs && after.agents == before.agents)
        #expect(after.designs.count == 1)
    }

    /// The reserved space is made once, hidden and marked, and is never a project.
    @Test func theDesignsSpaceIsMadeOnceAndHidden() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(ShepherdState(spaces: [space]))

        let id = try await h.server.designsSpaceID()

        await drainMainQueue()
        let state = h.server.state
        let designs = try #require(state.spaces.first { $0.id == id })
        #expect(designs.hidden && designs.holdsDesigns && !designs.holdsAutomations)
        #expect(state.spaces.filter { !$0.hidden } == [space], "the user's projects are unchanged")
        #expect(try h.persisted() == state.persisted)
        #expect(h.broadcasts.current == [state], "one broadcast")
        h.broadcasts.withValue { $0.removeAll() }

        #expect(try await h.server.designsSpaceID() == id)
        await drainMainQueue()
        #expect(h.server.state.spaces.count == 2 && h.broadcasts.current.isEmpty, "asking again changes nothing")
    }

    @Test func deletingASpaceKeepsDesignsAndTheirAgents() async throws {
        let (h, user, _, design, drawer) = try await serverWithDesignAgent()
        defer { h.stop() }

        try await h.server.deleteSpace(user.id)

        await drainMainQueue()
        let state = h.server.state
        #expect(!state.spaces.contains { $0.id == user.id })
        #expect(state.designs.map(\.id) == [design.id] && state.designs.first?.agentID == drawer.id)
        #expect(state.agents.map(\.id) == [drawer.id], "only the space's own agent went")
        #expect(state.tabs.map(\.id) == [drawer.tabID])
        #expect(try h.persisted() == state.persisted)
    }

    /// Deleting a design takes its agent along: it lives where nothing else reaches it.
    @Test func deletingADesignRemovesItsAgentFromTheDesignsSpace() async throws {
        let (h, _, worker, design, drawer) = try await serverWithDesignAgent()
        defer { h.stop() }

        try await h.server.deleteDesign(design.id)

        await drainMainQueue()
        let state = h.server.state
        #expect(state.designs.isEmpty)
        #expect(state.agents.map(\.id) == [worker.id])
        #expect(!state.tabs.contains { $0.id == drawer.tabID })
        #expect(state.designsSpace != nil, "the reserved space stays for the next design")
        #expect(h.broadcasts.current == [state], "one broadcast")
    }

    /// Design agents last across launches, in the designs space, unlike automation runs.
    @Test func aRelaunchKeepsDesignAgentsInTheDesignsSpace() async throws {
        let (first, _, worker, design, drawer) = try await serverWithDesignAgent()
        // An automation run in the automations space, which a relaunch drops.
        let automations = Space(name: "Automations", path: "~", hidden: true)
        try await first.server.addSpace(automations)
        let run = Fixture.agent(in: automations, name: "run")
        try await first.server.addAgent(run.agent, withTab: run.tab)
        first.stop(keepFiles: true)

        let h = try ScratchServer(dir: first.dir)
        defer { h.stop() }
        let state = h.server.state
        #expect(Set(state.agents.map(\.id)) == [worker.id, drawer.id])
        let kept = try #require(state.agents.first { $0.id == drawer.id })
        #expect(kept.spaceID == state.designsSpace?.id && kept.designID == design.id)
        #expect(state.designs.first?.agentID == drawer.id)
        #expect(state.tabs.contains { $0.id == drawer.tabID && $0.spaceID == kept.spaceID })
    }

    /// A design agent an older state.json kept in its project moves into the designs space on
    /// start, with its layout, keeping the folder it works in (its pi session is filed under it).
    @Test func anOlderDesignAgentInAUserSpaceMovesOnStart() async throws {
        let first = try ScratchServer.fresh()
        let user = Fixture.space("web")
        let design = Design(name: "Checkout", createdAt: 1_000)
        _ = try await first.server.createDesign(design)
        let drawer = Self.designAgent(design.id, in: user, cwd: user.path)
        var state = Fixture.workspace([drawer], space: user)
        state.designs = first.server.state.designs
        state.designs[0].agentID = drawer.agent.id
        try await first.server.putState(state)
        first.stop(keepFiles: true)

        let h = try ScratchServer(dir: first.dir)
        defer { h.stop() }
        let restored = h.server.state
        let designs = try #require(restored.designsSpace)
        #expect(designs.hidden)
        #expect(restored.spaces.filter { !$0.hidden } == [user], "the project stays, without the design's agent")
        let moved = try #require(restored.agents.first { $0.id == drawer.agent.id })
        #expect(moved.spaceID == designs.id && moved.designID == design.id)
        let tab = try #require(restored.tabs.first { $0.id == drawer.tab.id })
        #expect(tab.spaceID == designs.id && tab.layout.firstLeaf.cwd == user.path)
        #expect(restored.designs.first?.agentID == drawer.agent.id)
        #expect(try h.persisted() == restored.persisted, "the move is written")
    }

    /// An agent the designs space holds for a design that is gone has nothing to draw and no
    /// row: startup drops it with its layout.
    @Test func startupDropsAnAgentTheDesignsSpaceHoldsForNoDesign() async throws {
        let (first, _, worker, design, drawer) = try await serverWithDesignAgent()
        try FileManager.default.removeItem(at: try #require(first.server.designs.folder(for: design.id)))
        first.stop(keepFiles: true)

        let h = try ScratchServer(dir: first.dir)
        defer { h.stop() }
        let state = h.server.state
        #expect(state.designs.isEmpty)
        #expect(state.agents.map(\.id) == [worker.id])
        #expect(!state.tabs.contains { $0.id == drawer.tabID })
    }

    /// A system build still reads its project: its record names it, and the project must exist.
    @Test func aSystemBuildKeepsItsProject() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space("dashboard-web")
        try await h.seed(ShepherdState(spaces: [space]))
        let build = Design(name: "dashboard-web", createdAt: 1, buildsSystem: true, sourceSpaceID: space.id)

        _ = try await h.server.createDesign(build)

        #expect(h.server.state.designs.first?.sourceSpaceID == space.id)
        #expect(try h.persisted().designs.first?.sourceSpaceID == space.id)
    }
}
