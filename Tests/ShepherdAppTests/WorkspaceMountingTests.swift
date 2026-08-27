import Foundation
import Testing
import ShepherdCore
@testable import ShepherdApp

/// The workspace keeps every layout in every space mounted and only changes
/// which one is visible. Unmounting on switch destroyed the Ghostty
/// surfaces, forcing a re-attach and full replay each time — the visible
/// "flash" (and cross-space lag) when moving between agents.
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

        func selection(agent: Agent?) -> WorkspaceSelection {
            WorkspaceSelection(
                state: state,
                selectedSpaceID: space.id,
                selectedAgentID: agent?.id
            )
        }
    }

    @Test func everyLayoutInEverySpaceStaysMountedAcrossSwitches() {
        let f = Fixture()

        let onA = f.selection(agent: f.agentA)
        #expect(onA.mountedTabs.map(\.id) == [f.tabA.id, f.tabB.id, f.elsewhere.id])
        #expect(onA.isVisible(f.tabA))
        #expect(!onA.isVisible(f.tabB))
        #expect(!onA.isVisible(f.elsewhere))

        // Switching must not change what is mounted, nor its order: a
        // reordered ForEach would rebuild the very views we are preserving.
        let onB = f.selection(agent: f.agentB)
        #expect(onB.mountedTabs.map(\.id) == onA.mountedTabs.map(\.id))
        #expect(onB.isVisible(f.tabB))
        #expect(!onB.isVisible(f.tabA))
    }

    /// Cross-space switch: the other space's layout was already mounted, so
    /// selecting it is a pure visibility flip — same mounted set, same order.
    @Test func crossSpaceSwitchIsAVisibilityFlipNotARemount() {
        let f = Fixture()
        let before = f.selection(agent: f.agentA)

        let other = WorkspaceSelection(
            state: f.state,
            selectedSpaceID: f.other.id,
            selectedAgentID: nil
        )

        #expect(other.mountedTabs.map(\.id) == before.mountedTabs.map(\.id))
        #expect(other.isVisible(f.elsewhere))
        #expect(!other.isVisible(f.tabA))
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
        // Mounting order stays by (space, tab order) so ForEach identity is
        // stable even when tabs are stored out of order.
        #expect(selection.mountedTabs.map(\.id) == [first.id, second.id])
    }

    /// Exactly one layout is ever visible, across every mounted space.
    @Test func exactlyOneLayoutIsVisible() {
        let f = Fixture()
        let selection = f.selection(agent: f.agentA)

        #expect(selection.mountedTabs.count == 3)
        #expect(selection.mountedTabs.filter { selection.isVisible($0) }.count == 1)
    }

}
