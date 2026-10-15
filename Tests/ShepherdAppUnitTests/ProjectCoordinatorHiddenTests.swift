import Foundation
import ShepherdCore
import Testing
@testable import ShepherdApp

/// A Project's coordinator is its conversation (a thread the Project owns), never an ordinary agent: it must
/// reach no producer that lists, pins, notifies about or completes ordinary threads.
@Suite("Project coordinators stay out of ordinary threads")
@MainActor
struct ProjectCoordinatorHiddenTests {
    private struct World {
        var state: ShepherdState
        var coordinator: Agent
        var ordinary: Agent
        var project: Project
    }

    private func world() -> World {
        let space = Fixture.space("work")
        var pair = Fixture.agent("Sample App conversation", in: space)
        let project = Project(name: "Sample App")
        pair.agent.coordinatorFor = project.id
        pair.agent.status = .blocked
        pair.agent.waitingOn = "Who organizes the list?"
        let worker = Fixture.agent("Fix the build", in: space, order: 1)
        var state = ShepherdState(spaces: [space], tabs: [pair.tab, worker.tab], agents: [pair.agent, worker.agent], projects: [project])
        state.projects[0].coordinatorAgentID = pair.agent.id
        return World(state: state, coordinator: pair.agent, ordinary: worker.agent, project: project)
    }

    @Test func thePredicateSeparatesTheConversationFromEveryOrdinaryThread() {
        let w = world()
        #expect(!w.state.isOrdinaryThread(w.coordinator))
        #expect(w.state.isOrdinaryThread(w.ordinary))
        #expect(!ShepherdViewModel.notifiesAsThread(w.coordinator.id, in: w.state), "no banner words a coordinator as a thread")
        #expect(ShepherdViewModel.notifiesAsThread(w.ordinary.id, in: w.state))
    }

    @Test func theActivitySidebarNeverListsTheCoordinatorEvenWhileItAsks() {
        let w = world()
        let lists = SidebarDerivation.lists(SidebarSource(local: w.state))
        #expect(lists.all.map(\.title) == ["Fix the build"])
        #expect(lists.needsYou.isEmpty, "a coordinator that is blocked is the Project's, not a Needs you thread")
        #expect(!lists.all.contains { $0.id == .local(w.coordinator.id) })
    }

    @Test func theSpacesTreeNeverListsTheCoordinator() {
        let w = world()
        let tree = SidebarDerivation.tree(SidebarSource(local: w.state), options: SidebarTreeOptions())
        let titles = tree.projects.flatMap(\.rows).map(\.title)
        #expect(titles == ["Fix the build"])
    }

    @Test func completionsAndNewThreadFallbacksIgnoreIt() {
        let w = world()
        var done = w.coordinator
        done.status = .done
        var state = w.state
        state.agents[0] = done
        var completions = SidebarCompletions()
        completions.reconcile(SidebarSource(local: state), endpoints: [:])
        #expect(completions.records[.local(done.id)] == nil, "its turns are not a Done thread")
    }

    /// The threads a Project starts live under the Project (its pane and conversation), never in the sidebar's own lists: the user's
    /// report was three scouts a Project ran filling Recents. They still notify and stay reachable like any thread.
    @Test func aProjectsWorkerThreadsLiveOnlyUnderTheProject() {
        let w = world()
        var state = w.state
        var worker = Fixture.agent("Reading scout: runtime flow", in: state.spaces[0], order: 2)
        worker.agent.status = .blocked
        worker.agent.waitingOn = "Which file first?"
        state.tabs.append(worker.tab); state.agents.append(worker.agent)
        state.projects[0].tasks.append(ProjectTask(operationID: UUID(), workerAgentID: worker.agent.id, spaceID: state.spaces[0].id,
                                                   title: "Reading scout", prompt: "Read", phase: .waiting))
        #expect(state.isOrdinaryThread(worker.agent) && !state.isSidebarThread(worker.agent))
        #expect(ShepherdViewModel.notifiesAsThread(worker.agent.id, in: state), "its question still posts a banner")
        let lists = SidebarDerivation.lists(SidebarSource(local: state))
        #expect(lists.all.map(\.title) == ["Fix the build"])
        #expect(lists.needsYou.isEmpty, "its question shows on its Project's row and pane, not as its own Needs you row")
        let tree = SidebarDerivation.tree(SidebarSource(local: state), options: SidebarTreeOptions())
        #expect(tree.projects.flatMap(\.rows).map(\.title) == ["Fix the build"])
        var done = worker.agent
        done.status = .done
        state.agents[state.agents.count - 1] = done
        var completions = SidebarCompletions()
        completions.reconcile(SidebarSource(local: state), endpoints: [:])
        #expect(completions.records[.local(done.id)] == nil, "its finish is the Project's, not a Done thread")
    }
}
