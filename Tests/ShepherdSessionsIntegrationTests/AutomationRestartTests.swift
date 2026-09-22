import Foundation
import Testing
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport

/// Automation runs are ephemeral. A restart used to clear each automation's link to its run
/// agent but keep the agent, which relaunched its pi every start and piled up one per launch.
@Suite("Automation runs across a restart")
struct AutomationRestartTests {
    @Test func restartDropsRunAgentsIncludingOnesAlreadyOrphaned() async throws {
        let first = try ScratchServer()
        let userSpace = Space(name: "proj", path: first.dir.path)
        let runSpace = Space(name: "Automations", path: "~", hidden: true)
        func agent(_ name: String, in space: Space) -> (Agent, Tab) {
            let pane = LeafPane(cwd: first.dir.path)
            let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
            return (Agent(name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id), tab)
        }
        let (user, userTab) = agent("user work", in: userSpace)
        let (current, currentTab) = agent("watch CI", in: runSpace)      // linked run
        let (orphan, orphanTab) = agent("watch CI", in: runSpace)        // leaked by an older build
        var automation = Automation(name: "watch CI", prompt: "watch", cwd: first.dir.path, enabled: true)
        automation.agentID = current.id
        try await first.server.putState(ShepherdState(
            spaces: [userSpace, runSpace], tabs: [userTab, currentTab, orphanTab],
            agents: [user, current, orphan], automations: [automation]))
        first.stop(keepFiles: true)

        let second = try ScratchServer(dir: first.dir)
        defer { second.stop() }
        let state = second.server.state
        #expect(state.agents.map(\.id) == [user.id])
        #expect(state.tabs.map(\.id) == [userTab.id])
        #expect(state.automations.map(\.agentID) == [nil])
        #expect(state.automations.map(\.enabled) == [true])
        #expect(!state.agents.contains { $0.id == orphan.id })
    }
}
