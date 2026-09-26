import Testing
import ShepherdCore
@testable import ShepherdSessions

/// Which records `start()` purges from an older or crashed run: shells, which were removed from
/// Shepherd, and automation run agents, whose processes died with the previous app run; and where
/// design agents live.
@Suite("Startup purge rules")
struct StartupPurgeTests {
    private let space = Space(name: "repo", path: "/tmp/repo")

    private func tab(space: SpaceID?, inspectorFor: AgentID? = nil) -> Tab {
        Tab(spaceID: space, order: 0, layout: .leaf(LeafPane(cwd: "/tmp/repo")), inspectorFor: inspectorFor)
    }

    // MARK: - Shell layouts

    @Test func aGlobalShellIsAShellTab() {
        let global = tab(space: nil)
        #expect(SessionServer.shellTabIDs(in: ShepherdState(spaces: [space], tabs: [global])) == [global.id])
    }

    @Test func aSpaceLayoutNoAgentOwnsIsAShellTab() {
        let workspace = tab(space: space.id)
        #expect(SessionServer.shellTabIDs(in: ShepherdState(spaces: [space], tabs: [workspace])) == [workspace.id])
    }

    @Test func anAgentsLayoutIsKept() {
        let owned = tab(space: space.id)
        let agent = Agent(name: "a", spaceID: space.id, tabID: owned.id)
        #expect(SessionServer.shellTabIDs(in: ShepherdState(spaces: [space], tabs: [owned], agents: [agent])).isEmpty)
    }

    /// Utility terminals are purged by their own rule, never counted as shells.
    @Test func utilityTerminalsAreNotShellTabs() {
        let agentTab = tab(space: space.id)
        let agent = Agent(name: "a", spaceID: space.id, tabID: agentTab.id)
        let utilities = [tab(space: space.id, inspectorFor: agent.id), tab(space: nil, inspectorFor: agent.id)]
        let state = ShepherdState(spaces: [space], tabs: [agentTab] + utilities, agents: [agent])
        #expect(SessionServer.shellTabIDs(in: state).isEmpty)
    }

    @Test func aMixedWorkspaceYieldsExactlyItsShells() {
        let agentTab = tab(space: space.id)
        let agent = Agent(name: "a", spaceID: space.id, tabID: agentTab.id)
        let workspace = tab(space: space.id)
        let global = tab(space: nil)
        let state = ShepherdState(spaces: [space], tabs: [workspace, agentTab, global], agents: [agent])
        #expect(SessionServer.shellTabIDs(in: state) == [workspace.id, global.id])
    }

    // MARK: - Automation run agents

    @Test func agentsInAHiddenSpaceAreRunAgents() {
        let hidden = Space(name: "Automations", path: "~", hidden: true)
        let run = Agent(name: "watch CI", spaceID: hidden.id, tabID: TabID())
        let user = Agent(name: "user work", spaceID: space.id, tabID: TabID())
        let state = ShepherdState(spaces: [space, hidden], agents: [run, user])
        #expect(SessionServer.automationRunAgentIDs(in: state) == [run.id])
    }

    /// A run can live in a user space (the automation's cwd matched it); the link identifies it.
    @Test func anAutomationsLinkedAgentIsARunAgentWhereverItLives() {
        let run = Agent(name: "watch CI", spaceID: space.id, tabID: TabID())
        let user = Agent(name: "user work", spaceID: space.id, tabID: TabID())
        let automation = Automation(name: "watch CI", prompt: "watch", cwd: space.path, agentID: run.id)
        let state = ShepherdState(spaces: [space], agents: [run, user], automations: [automation])
        #expect(SessionServer.automationRunAgentIDs(in: state) == [run.id])
    }

    /// The designs space is hidden too, but its agents are no runs: they last across launches.
    @Test func agentsInTheDesignsSpaceAreNoRunAgents() {
        let designs = Space.designs()
        let drawer = Agent(name: "Checkout", spaceID: designs.id, tabID: TabID(), designID: DesignID())
        let state = ShepherdState(spaces: [space, designs], agents: [drawer])
        #expect(SessionServer.automationRunAgentIDs(in: state).isEmpty)
    }

    // MARK: - Design agents

    /// A design agent kept in a user space (an older state.json) moves into the designs space,
    /// made for it, with its layout; its folder stays the one it works in.
    @Test func aDesignAgentInAUserSpaceMovesToTheDesignsSpace() throws {
        let design = Design(name: "Checkout", createdAt: 1)
        let pane = LeafPane(cwd: space.path, agentID: AgentID())
        let layout = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let drawer = Agent(id: try #require(pane.agentID), name: "Checkout", spaceID: space.id, tabID: layout.id, paneID: pane.id,
                           designID: design.id)
        let worker = Agent(name: "user work", spaceID: space.id, tabID: TabID())
        var state = ShepherdState(spaces: [space], tabs: [layout], agents: [drawer, worker], designs: [design])
        #expect(SessionServer.designAgentsNeedSettling(in: state, missing: []))

        SessionServer.settleDesignAgents(&state)

        let designs = try #require(state.designsSpace)
        #expect(designs.hidden && state.spaces.count == 2)
        #expect(state.agents.first { $0.id == drawer.id }?.spaceID == designs.id)
        #expect(state.agents.first { $0.id == worker.id }?.spaceID == space.id)
        #expect(state.tabs.first?.spaceID == designs.id && state.tabs.first?.layout.firstLeaf.cwd == space.path)
        #expect(!SessionServer.designAgentsNeedSettling(in: state, missing: []), "settled once")
    }

    /// An agent the designs space holds for no live design goes; one drawing a design stays.
    @Test func anAgentTheDesignsSpaceHoldsForNoDesignIsDropped() {
        let designs = Space.designs()
        let kept = Design(name: "Kept", createdAt: 1)
        let lost = DesignID()
        let drawer = Agent(name: "Kept", spaceID: designs.id, tabID: TabID(), designID: kept.id)
        let orphan = Agent(name: "Lost", spaceID: designs.id, tabID: TabID(), designID: lost)
        let orphanTab = Tab(id: orphan.tabID, spaceID: designs.id, order: 0, layout: .leaf(LeafPane(cwd: "~")))
        var state = ShepherdState(spaces: [space, designs], tabs: [orphanTab], agents: [drawer, orphan], designs: [kept])
        #expect(SessionServer.designAgentsNeedSettling(in: state, missing: []))

        SessionServer.reconcileDesigns(&state, missing: [])
        SessionServer.settleDesignAgents(&state)

        #expect(state.agents.map(\.id) == [drawer.id])
        #expect(state.tabs.isEmpty)
        #expect(state.spaces.map(\.id) == [space.id, designs.id], "the space stays")
    }

    @Test func aWorkspaceWithoutDesignAgentsNeedsNoSettling() {
        let user = Agent(name: "user work", spaceID: space.id, tabID: TabID())
        let state = ShepherdState(spaces: [space], agents: [user], designs: [Design(name: "Idle", createdAt: 1)])
        #expect(!SessionServer.designAgentsNeedSettling(in: state, missing: []))
    }

    @Test func aWorkspaceWithoutAutomationsHasNoRunAgents() {
        let user = Agent(name: "user work", spaceID: space.id, tabID: TabID())
        let idle = Automation(name: "idle", prompt: "p", cwd: space.path)
        #expect(SessionServer.automationRunAgentIDs(in: ShepherdState(spaces: [space], agents: [user], automations: [idle])).isEmpty)
    }
}
