import ShepherdCore
import Testing
@testable import ShepherdApp

/// What the app takes as its own of the background host's workspace (`ShepherdViewModel.mirrored`):
/// the whole workspace: ordinary threads, designs with their agents (slice 2), automations and their
/// runs (slice 3), Projects and missions with their threads (slice 4), all through the host.
@Suite struct LocalHostMirrorTests {
    @Test func theMirrorIsTheWholeWorkspace() {
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
        #expect(mirrored.agents.map(\.id) == [thread.0.id, watcher.0.id, run.0.id, drawer.0.id, coordinator.0.id, worker.0.id])
        #expect(mirrored.tabs.map(\.id) == [thread.1.id, watcher.1.id, run.1.id, drawer.1.id, coordinator.1.id, worker.1.id])
        #expect(mirrored.spaces == [space])
        #expect(mirrored.automations == [automation] && mirrored.designs == [design])
        #expect(mirrored.projects == [project], "Projects run on the host and draw as the app's own")
        #expect(ShepherdViewModel.mirrored(ShepherdState(spaces: [space], tabs: [thread.1], agents: [thread.0]))
            == ShepherdState(spaces: [space], tabs: [thread.1], agents: [thread.0]), "an ordinary workspace mirrors whole")
    }
}
