import ShepherdCore
import Testing
@testable import ShepherdApp

/// What the app takes as its own of the background host's workspace (`ShepherdViewModel.mirrored`):
/// the ordinary threads and designs with their agents (routed through the host, slice 2), never
/// what automations, Projects and missions own, which their pages still reach through the host.
@Suite struct LocalHostMirrorTests {
    @Test func theMirrorKeepsOrdinaryThreadsAndLeavesTheFeaturesTheirs() {
        let space = Space(name: "acme-web", path: "/tmp/acme-web")
        func agent(_ name: String, _ change: (inout Agent) -> Void = { _ in }) -> (Agent, ShepherdCore.Tab) {
            let pane = LeafPane(cwd: space.path)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
            var agent = Agent(name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id)
            change(&agent)
            return (agent, tab)
        }
        let thread = agent("Fix the login redirect")
        let watcher = agent("Nightly triage")
        let automation = Automation(name: "Nightly triage", prompt: "triage", cwd: space.path, agentID: watcher.0.id)
        let run = agent("Triage #12") { $0.automationOrigin = AutomationOrigin(automationID: automation.id) }
        let design = Design(name: "Dashboard", createdAt: 1)
        let drawer = agent("Dashboard") { $0.designID = design.id }
        let project = Project(name: "Release")
        let coordinator = agent("Release") { $0.coordinatorFor = project.id }
        let worker = agent("Release notes") { $0.projectWorkerFor = project.id }
        let all = [thread, watcher, run, drawer, coordinator, worker]
        let state = ShepherdState(spaces: [space], tabs: all.map(\.1), agents: all.map(\.0), automations: [automation],
                                  designs: [design], projects: [project])

        let mirrored = ShepherdViewModel.mirrored(state)
        #expect(mirrored.agents.map(\.id) == [thread.0.id, drawer.0.id])
        #expect(mirrored.tabs.map(\.id) == [thread.1.id, drawer.1.id])
        #expect(mirrored.spaces == [space])
        #expect(mirrored.designs == [design])
        #expect(mirrored.automations.isEmpty && mirrored.projects.isEmpty && mirrored.missions.isEmpty)
        #expect(ShepherdViewModel.mirrored(ShepherdState(spaces: [space], tabs: [thread.1], agents: [thread.0]))
            == ShepherdState(spaces: [space], tabs: [thread.1], agents: [thread.0]), "an ordinary workspace mirrors whole")
    }
}
