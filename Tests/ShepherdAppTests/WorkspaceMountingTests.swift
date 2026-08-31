import Foundation
import Testing
import ShepherdCore
@testable import ShepherdApp

/// The workspace keeps every *mounted* layout in the view tree and only
/// changes which one is visible. Unmounting on switch destroyed the Ghostty
/// surfaces, forcing a re-attach and full replay each time — the visible
/// "flash" (and cross-space lag) when moving between agents.
///
/// Agent layouts, global shells, and inspector tabs always mount. A space's
/// shell workspace mounts lazily — on first visit — so a large space tree
/// does not spawn a login shell + surface per space at launch. Once visited
/// it stays mounted, so switching remains a pure visibility flip.
///
/// These cover the selection logic itself (`WorkspaceSelection`), which the
/// view model delegates `mountedTabs`/`isVisibleTab` to without constructing a
/// session server.
@Suite("Workspace mounting")
struct WorkspaceMountingTests {
    private struct Fixture {
        let space = Space(name: "Shepherd", path: "/tmp/Shepherd")
        let other = Space(name: "Other", path: "/tmp/Other")
        let tabA: Tab
        let tabB: Tab
        let elsewhere: Tab
        let agentA: Agent
        let agentB: Agent
        let state: ShepherdState

        init() {
            tabA = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: "/tmp")))
            tabB = Tab(spaceID: space.id, order: 1, layout: .leaf(LeafPane(cwd: "/tmp")))
            elsewhere = Tab(spaceID: other.id, order: 0, layout: .leaf(LeafPane(cwd: "/tmp")))
            agentA = Agent(name: "a", spaceID: space.id, tabID: tabA.id)
            agentB = Agent(name: "b", spaceID: space.id, tabID: tabB.id)
            state = ShepherdState(
                spaces: [space, other],
                tabs: [tabA, tabB, elsewhere],
                agents: [agentA, agentB]
            )
        }

        func selection(agent: Agent?, visited: Set<TabID> = []) -> WorkspaceSelection {
            WorkspaceSelection(
                state: state,
                selectedSpaceID: space.id,
                selectedAgentID: agent?.id,
                visitedTabIDs: visited
            )
        }
    }

    @Test func agentLayoutsStayMountedAcrossSwitches() {
        let f = Fixture()

        let onA = f.selection(agent: f.agentA)
        #expect(onA.mountedTabs.map(\.id) == [f.tabA.id, f.tabB.id])
        #expect(onA.isVisible(f.tabA))
        #expect(!onA.isVisible(f.tabB))

        // Switching must not change what is mounted, nor its order: a
        // reordered ForEach would rebuild the very views we are preserving.
        let onB = f.selection(agent: f.agentB)
        #expect(onB.mountedTabs.map(\.id) == onA.mountedTabs.map(\.id))
        #expect(onB.isVisible(f.tabB))
        #expect(!onB.isVisible(f.tabA))
    }

    /// A never-visited space's shell workspace is not mounted: mounting
    /// would spawn its login shell and surface for a space never opened.
    @Test func unvisitedSpaceShellIsNotMounted() {
        let f = Fixture()
        let selection = f.selection(agent: f.agentA)
        #expect(!selection.mountedTabs.map(\.id).contains(f.elsewhere.id))
    }

    /// Selecting a space mounts its shell immediately (active wins even
    /// before the view model records the visit), so a first visit renders.
    @Test func activeSpaceShellMountsEvenBeforeVisited() {
        let f = Fixture()
        let onOther = WorkspaceSelection(
            state: f.state,
            selectedSpaceID: f.other.id,
            selectedAgentID: nil
        )
        #expect(onOther.mountedTabs.map(\.id) == [f.tabA.id, f.tabB.id, f.elsewhere.id])
        #expect(onOther.isVisible(f.elsewhere))
    }

    /// Cross-space switch after a visit: the other space's layout stays
    /// mounted, so returning to it is a pure visibility flip — same mounted
    /// set, same order.
    @Test func visitedSpaceShellStaysMountedAfterSwitchingAway() {
        let f = Fixture()
        let visited: Set<TabID> = [f.elsewhere.id]

        let backOnA = f.selection(agent: f.agentA, visited: visited)
        #expect(backOnA.mountedTabs.map(\.id) == [f.tabA.id, f.tabB.id, f.elsewhere.id])
        #expect(backOnA.isVisible(f.tabA))
        #expect(!backOnA.isVisible(f.elsewhere))

        let onOther = WorkspaceSelection(
            state: f.state,
            selectedSpaceID: f.other.id,
            selectedAgentID: nil,
            visitedTabIDs: visited
        )
        #expect(onOther.mountedTabs.map(\.id) == backOnA.mountedTabs.map(\.id))
        #expect(onOther.isVisible(f.elsewhere))
    }

    /// Global shells (spaceID == nil) always mount: they are few,
    /// user-created, and replay a remembered command at launch.
    @Test func globalShellsAlwaysMount() {
        let f = Fixture()
        let shell = Tab(spaceID: nil, order: 0, layout: .leaf(LeafPane(cwd: "/tmp")))
        let state = ShepherdState(
            spaces: f.state.spaces,
            tabs: f.state.tabs + [shell],
            agents: f.state.agents
        )
        let selection = WorkspaceSelection(
            state: state,
            selectedSpaceID: f.space.id,
            selectedAgentID: f.agentA.id
        )
        #expect(selection.mountedTabs.map(\.id).contains(shell.id))
    }

    /// With no agent selected the space falls back to its main layout: the
    /// lowest-order tab, regardless of the order they appear in state.
    @Test func fallsBackToTheSpacesLowestOrderLayout() {
        let space = Space(name: "s", path: "/tmp")
        let second = Tab(spaceID: space.id, order: 5, layout: .leaf(LeafPane(cwd: "/tmp")))
        let first = Tab(spaceID: space.id, order: 1, layout: .leaf(LeafPane(cwd: "/tmp")))
        // Deliberately stored out of order.
        let state = ShepherdState(spaces: [space], tabs: [second, first], agents: [])

        let selection = WorkspaceSelection(
            state: state, selectedSpaceID: space.id, selectedAgentID: nil
        )

        #expect(selection.activeTabID == first.id)
        #expect(selection.isVisible(first))
        #expect(!selection.isVisible(second))
        // Only the active shell mounts before a visit; a visited sibling
        // mounts in stable (space, tab order) position.
        #expect(selection.mountedTabs.map(\.id) == [first.id])
        let bothVisited = WorkspaceSelection(
            state: state, selectedSpaceID: space.id, selectedAgentID: nil,
            visitedTabIDs: [first.id, second.id]
        )
        #expect(bothVisited.mountedTabs.map(\.id) == [first.id, second.id])
    }

    /// Exactly one layout is ever visible, across every mounted space.
    @Test func exactlyOneLayoutIsVisible() {
        let f = Fixture()
        let selection = f.selection(agent: f.agentA, visited: [f.elsewhere.id])

        #expect(selection.mountedTabs.count == 3)
        #expect(selection.mountedTabs.filter { selection.isVisible($0) }.count == 1)
    }

}
