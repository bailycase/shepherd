import Foundation
import Testing
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport

/// Automation runs are ephemeral. A restart used to clear each automation's link to its run
/// agent but keep the agent, which relaunched its pi every start and piled up one per launch.
@Suite("Automation runs across a restart", .integrationTimeLimit)
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
        automation.deleteAfterRun = true
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
        #expect(state.automations.map(\.deleteAfterRun) == [true])
        #expect(!state.agents.contains { $0.id == orphan.id })
    }
}

/// Triggered runs are ordinary threads: a relaunch keeps them (even in the hidden space) and
/// their run stays linked, while a legacy watcher's agent still goes.
@Suite("Triggered runs across a restart", .integrationTimeLimit)
struct TriggeredRunRestartTests {
    @Test func restartKeepsTriggeredRunThreads() async throws {
        let first = try ScratchServer()
        let runSpace = Space(name: "Automations", path: "~", hidden: true)
        let automation = Automation(name: "loop", prompt: "p", cwd: first.dir.path,
                                    trigger: .schedule(AutomationSchedule(rrule: "FREQ=DAILY")))
        func agent(_ name: String, origin: AutomationOrigin?) -> (Agent, Tab) {
            let pane = LeafPane(cwd: first.dir.path)
            let tab = Tab(spaceID: runSpace.id, order: 0, layout: .leaf(pane))
            var agent = Agent(name: name, spaceID: runSpace.id, tabID: tab.id, paneID: pane.id)
            agent.automationOrigin = origin
            return (agent, tab)
        }
        let (run, runTab) = agent("#12 Fix login", origin: AutomationOrigin(automationID: automation.id, eventID: "a/b#12:opened",
                                                                             trigger: "#12 Fix login · issue opened"))
        let (watcher, watcherTab) = agent("old watcher", origin: nil)
        try await first.server.putState(ShepherdState(spaces: [runSpace], tabs: [runTab, watcherTab],
                                                      agents: [run, watcher], automations: [automation]))
        try await eventually("the run to open") { await first.server.automationRuns(automation.id).count == 1 }
        first.stop(keepFiles: true)

        let second = try ScratchServer(dir: first.dir)
        defer { second.stop() }
        #expect(second.server.state.agents.map(\.id) == [run.id])
        let runs = await second.server.automationRuns(automation.id)
        #expect(runs.count == 1 && runs[0].agentID == run.id && runs[0].trigger == "#12 Fix login · issue opened")
        #expect(runs[0].result == .interrupted)
    }
}
