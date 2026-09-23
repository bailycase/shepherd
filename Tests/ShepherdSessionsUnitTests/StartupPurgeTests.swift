import Testing
import ShepherdCore
@testable import ShepherdSessions

/// Which records `start()` purges from an older or crashed run: shells, which were removed from
/// Shepherd, and automation run agents, whose processes died with the previous app run.
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

    @Test func aWorkspaceWithoutAutomationsHasNoRunAgents() {
        let user = Agent(name: "user work", spaceID: space.id, tabID: TabID())
        let idle = Automation(name: "idle", prompt: "p", cwd: space.path)
        #expect(SessionServer.automationRunAgentIDs(in: ShepherdState(spaces: [space], agents: [user], automations: [idle])).isEmpty)
    }
}
