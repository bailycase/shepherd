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
        var pair = Fixture.agent("Gamecards conversation", in: space)
        let project = Project(name: "Gamecards")
        pair.agent.coordinatorFor = project.id
        pair.agent.status = .blocked
        pair.agent.waitingOn = "Who takes the payment?"
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
}
