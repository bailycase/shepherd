import Foundation
import ShepherdCore
import Testing
@testable import ShepherdApp

/// Switching agents is a visibility flip, never a remount: every mounted layout stays in the
/// view tree in a stable order and exactly one is visible. Reordering `mountedTabs` would
/// change ForEach identity and rebuild the very surfaces this exists to preserve.
@Suite("Workspace selection")
struct WorkspaceSelectionTests {
    private struct Workspace {
        let home = Fixture.space("home")
        let other = Fixture.space("other")
        let a: (agent: Agent, tab: Tab)
        let b: (agent: Agent, tab: Tab)
        let c: (agent: Agent, tab: Tab)
        let state: ShepherdState

        init() {
            a = Fixture.agent("a", in: home, order: 0)
            b = Fixture.agent("b", in: home, order: 1)
            c = Fixture.agent("c", in: other, order: 0)
            // Tabs declared out of order: mounting must sort by (space, order), not declaration.
            state = ShepherdState(spaces: [home, other], tabs: [c.tab, b.tab, a.tab], agents: [a.agent, b.agent, c.agent])
        }

        var stableOrder: [TabID] { [a.tab.id, b.tab.id, c.tab.id] }

        func selecting(_ agent: Agent?, in space: Space? = nil) -> WorkspaceSelection {
            WorkspaceSelection(state: state, selectedSpaceID: (space ?? home).id, selectedAgentID: agent?.id)
        }
    }

    @Test func theSelectedAgentsLayoutIsTheOnlyVisibleOne() {
        let w = Workspace()
        let selection = w.selecting(w.b.agent)
        #expect(selection.activeTabID == w.b.tab.id)
        #expect(selection.activeTab?.id == w.b.tab.id)
        #expect(selection.mountedTabs.filter(selection.isVisible).map(\.id) == [w.b.tab.id])
    }

    @Test func everyLayoutMountsInStableSpaceThenTabOrder() {
        let w = Workspace()
        #expect(w.selecting(w.a.agent).mountedTabs.map(\.id) == w.stableOrder)
    }

    /// Switching — within a space or across spaces — never changes what is mounted or its order.
    @Test func switchingAgentsNeverChangesTheMountedOrder() {
        let w = Workspace()
        let orders = [
            w.selecting(w.a.agent), w.selecting(w.b.agent), w.selecting(w.c.agent, in: w.other), w.selecting(nil),
        ].map { $0.mountedTabs.map(\.id) }
        #expect(orders.allSatisfy { $0 == w.stableOrder })
    }

    @Test func noAgentSelectedShowsAnEmptyWorkspace() {
        let w = Workspace()
        let selection = w.selecting(nil)
        #expect(selection.activeTabID == nil)
        #expect(selection.activeTab == nil)
        #expect(!selection.mountedTabs.contains(where: selection.isVisible))
    }

    @Test func anAgentOutsideTheSelectedSpaceIsNotShown() {
        let w = Workspace()
        #expect(w.selecting(w.a.agent, in: w.other).activeTabID == nil)
    }

    @Test func anAgentWhoseLayoutIsGoneShowsNothing() {
        let w = Workspace()
        var state = w.state
        state.tabs.removeAll { $0.id == w.a.tab.id }
        let selection = WorkspaceSelection(state: state, selectedSpaceID: w.home.id, selectedAgentID: w.a.agent.id)
        #expect(selection.activeTabID == nil)
    }

    /// A remote agent owns the workspace; local layouts stay mounted but none is visible.
    @Test func aRemoteSelectionHidesEveryLocalLayoutButKeepsThemMounted() {
        let w = Workspace()
        var selection = w.selecting(w.a.agent)
        selection.remoteSelectionActive = true
        #expect(selection.activeTabID == nil)
        #expect(selection.mountedTabs.map(\.id) == w.stableOrder)
    }

    // MARK: Cold parking

    @Test func parkedLayoutsUnmount() {
        let w = Workspace()
        var selection = w.selecting(w.a.agent)
        selection.parkedTabIDs = [w.b.tab.id, w.c.tab.id]
        #expect(selection.mountedTabs.map(\.id) == [w.a.tab.id])
    }

    /// A selection that beat the park sweep must still mount.
    @Test func theActiveLayoutNeverParks() {
        let w = Workspace()
        var selection = w.selecting(w.a.agent)
        selection.parkedTabIDs = Set(w.stableOrder)
        #expect(selection.mountedTabs.map(\.id) == [w.a.tab.id])
        #expect(selection.isVisible(w.a.tab))
    }

    @Test func candidatesAreHiddenPastTheDelayAndOutsideTheHotSet() {
        let now = Date(timeIntervalSince1970: 10_000)
        let long = now.addingTimeInterval(-120)
        let ids = (0..<8).map { _ in TabID() }
        var hidden: [TabID: Date] = [:]
        // Six hidden long ago, staggered so the four most recent are deterministic.
        for (index, id) in ids.prefix(6).enumerated() { hidden[id] = long.addingTimeInterval(Double(index)) }
        hidden[ids[6]] = now.addingTimeInterval(-5)
        hidden[ids[7]] = long // the active layout: its stale entry is ignored

        let candidates = WorkspaceSelection.coldParkCandidates(hiddenSince: hidden, activeTabID: ids[7], now: now)

        // Hot set: ids[6], ids[5], ids[4], ids[3].
        #expect(candidates == [ids[0], ids[1], ids[2]])
    }

    @Test func nothingParksWithinTheDelay() {
        let now = Date(timeIntervalSince1970: 10_000)
        let hidden = Dictionary(uniqueKeysWithValues: (0..<10).map { _ in (TabID(), now.addingTimeInterval(-29)) })
        #expect(WorkspaceSelection.coldParkCandidates(hiddenSince: hidden, activeTabID: nil, now: now).isEmpty)
    }

    @Test func theFourMostRecentlyShownLayoutsNeverPark() {
        let now = Date(timeIntervalSince1970: 10_000)
        let hidden = Dictionary(uniqueKeysWithValues: (0..<4).map { _ in (TabID(), now.addingTimeInterval(-3_600)) })
        #expect(WorkspaceSelection.coldParkCandidates(hiddenSince: hidden, activeTabID: nil, now: now).isEmpty)
        #expect(WorkspaceSelection.hotRetainLimit == 4)
        #expect(WorkspaceSelection.parkDelay == .seconds(30))
    }
}
