import Foundation
import Testing
import ShepherdCore
@testable import ShepherdApp

/// The workspace keeps every *mounted* layout in the view tree and only
/// changes which one is visible. Unmounting on switch destroyed the Ghostty
/// surfaces, forcing a re-attach and full replay each time — the visible
/// "flash" (and cross-space lag) when moving between agents.
///
/// Every agent layout stays mounted (unless cold-parked), so switching is a pure visibility
/// flip. With no agent selected nothing is visible: the workspace shows its empty state.
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
        let agentElsewhere: Agent
        let state: ShepherdState

        init() {
            tabA = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: "/tmp")))
            tabB = Tab(spaceID: space.id, order: 1, layout: .leaf(LeafPane(cwd: "/tmp")))
            elsewhere = Tab(spaceID: other.id, order: 0, layout: .leaf(LeafPane(cwd: "/tmp")))
            agentA = Agent(name: "a", spaceID: space.id, tabID: tabA.id)
            agentB = Agent(name: "b", spaceID: space.id, tabID: tabB.id)
            agentElsewhere = Agent(name: "c", spaceID: other.id, tabID: elsewhere.id)
            state = ShepherdState(
                spaces: [space, other],
                tabs: [tabA, tabB, elsewhere],
                agents: [agentA, agentB, agentElsewhere]
            )
        }

        func selection(agent: Agent?) -> WorkspaceSelection {
            WorkspaceSelection(state: state, selectedSpaceID: space.id, selectedAgentID: agent?.id)
        }
    }

    @Test func agentLayoutsStayMountedAcrossSwitches() {
        let f = Fixture()

        let onA = f.selection(agent: f.agentA)
        #expect(onA.mountedTabs.map(\.id) == [f.tabA.id, f.tabB.id, f.elsewhere.id])
        #expect(onA.isVisible(f.tabA))
        #expect(!onA.isVisible(f.tabB))

        // Switching must not change what is mounted, nor its order: a
        // reordered ForEach would rebuild the very views we are preserving.
        let onB = f.selection(agent: f.agentB)
        #expect(onB.mountedTabs.map(\.id) == onA.mountedTabs.map(\.id))
        #expect(onB.isVisible(f.tabB))
        #expect(!onB.isVisible(f.tabA))
    }

    /// Every agent's layout mounts, in every space, in stable (space, order) position.
    @Test func everyAgentLayoutMountsAcrossSpaces() {
        let f = Fixture()
        let selection = WorkspaceSelection(state: f.state, selectedSpaceID: f.space.id, selectedAgentID: f.agentA.id)
        #expect(selection.mountedTabs.map(\.id) == [f.tabA.id, f.tabB.id, f.elsewhere.id])
        #expect(selection.isVisible(f.tabA))
        #expect(!selection.isVisible(f.elsewhere))
    }

    /// Space shell workspaces are gone: with no agent selected nothing is visible.
    @Test func noAgentSelectedShowsNoLayout() {
        let f = Fixture()
        let selection = WorkspaceSelection(state: f.state, selectedSpaceID: f.other.id, selectedAgentID: nil)
        #expect(selection.activeTabID == nil)
        #expect(!selection.mountedTabs.contains { selection.isVisible($0) })
    }

    /// An agent selected in another space than the selected one is not shown.
    @Test func agentOutsideTheSelectedSpaceIsNotShown() {
        let f = Fixture()
        let selection = WorkspaceSelection(state: f.state, selectedSpaceID: f.other.id, selectedAgentID: f.agentA.id)
        #expect(selection.activeTabID == nil)
    }

    /// A parked layout leaves the mounted set; the active one never parks,
    /// even if it is in `parkedTabIDs` (a selection that beat the sweep).
    @Test func parkedLayoutsUnmountExceptTheActiveOne() {
        let f = Fixture()
        var selection = f.selection(agent: f.agentA)
        selection.parkedTabIDs = [f.tabB.id, f.elsewhere.id]
        #expect(selection.mountedTabs.map(\.id) == [f.tabA.id])

        selection.parkedTabIDs = [f.tabA.id, f.tabB.id, f.elsewhere.id]
        #expect(selection.mountedTabs.map(\.id) == [f.tabA.id])
        #expect(selection.isVisible(f.tabA))
    }

    /// Candidates: hidden past the delay and outside the hot set of the
    /// most recently hidden layouts. The active layout is never a candidate.
    @Test func coldParkCandidatesRespectDelayAndHotSet() {
        let now = Date(timeIntervalSince1970: 10_000)
        let old = now.addingTimeInterval(-120)
        let recent = now.addingTimeInterval(-5)
        let ids = (0..<8).map { _ in TabID() }
        var hidden: [TabID: Date] = [:]
        // Six hidden long ago, staggered so the hot set is deterministic.
        for (i, id) in ids.prefix(6).enumerated() {
            hidden[id] = old.addingTimeInterval(Double(i))
        }
        hidden[ids[6]] = recent
        hidden[ids[7]] = old  // the active tab: stale entry must be ignored

        let candidates = WorkspaceSelection.coldParkCandidates(
            hiddenSince: hidden, activeTabID: ids[7], now: now
        )
        // Hot set (4 most recent, excluding active): ids[6], ids[5], ids[4], ids[3].
        #expect(candidates == Set([ids[0], ids[1], ids[2]]))

        // Within the delay nothing parks, hot or not.
        let fresh = Dictionary(uniqueKeysWithValues: ids.map { ($0, recent) })
        #expect(WorkspaceSelection.coldParkCandidates(hiddenSince: fresh, activeTabID: nil, now: now).isEmpty)
    }

    /// Exactly one layout is ever visible, across every mounted space.
    @Test func exactlyOneLayoutIsVisible() {
        let f = Fixture()
        let selection = f.selection(agent: f.agentA)

        #expect(selection.mountedTabs.count == 3)
        #expect(selection.mountedTabs.filter { selection.isVisible($0) }.count == 1)
    }

}
