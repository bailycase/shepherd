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

    /// Stopping a selected automation run leaves no agent selected in the hidden automations
    /// space; the workspace moves to a visible space rather than offering New agent out of sight.
    @Test func withNoAgentSelectedTheWorkspaceNeverStandsInAHiddenSpace() {
        let w = Workspace()
        let runs = Space(name: "Automations", path: "~", hidden: true)
        var state = w.state
        state.spaces.insert(runs, at: 0)
        #expect(WorkspaceSelection.standingSpace(runs.id, agentSelected: false, in: state) == w.home.id)
        // A run's agent on screen keeps its space.
        #expect(WorkspaceSelection.standingSpace(runs.id, agentSelected: true, in: state) == runs.id)
        // Only the hidden space left: the no-spaces state, never the hidden one.
        let onlyRuns = ShepherdState(spaces: [runs])
        #expect(WorkspaceSelection.standingSpace(runs.id, agentSelected: false, in: onlyRuns) == nil)
        #expect(WorkspaceSelection.standingSpace(nil, agentSelected: false, in: onlyRuns) == nil)
    }

    /// A visible space stays put, with or without an agent; one that is gone gives way to the
    /// first visible space.
    @Test(arguments: [false, true])
    func aVisibleSelectedSpaceStandsUntilItIsGone(agentSelected: Bool) {
        let w = Workspace()
        #expect(WorkspaceSelection.standingSpace(w.other.id, agentSelected: agentSelected, in: w.state) == w.other.id)
        #expect(WorkspaceSelection.standingSpace(SpaceID(), agentSelected: agentSelected, in: w.state) == w.home.id)
        #expect(WorkspaceSelection.standingSpace(nil, agentSelected: agentSelected, in: w.state) == w.home.id)
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

        let candidates = WorkspaceSelection.coldParkCandidates(hiddenSince: hidden, activeTabID: ids[7], terminalTabs: Set(ids), now: now)

        // Hot set: ids[6], ids[5], ids[4], ids[3].
        #expect(candidates == [ids[0], ids[1], ids[2]])
    }

    @Test func nothingParksWithinTheDelay() {
        let now = Date(timeIntervalSince1970: 10_000)
        let hidden = Dictionary(uniqueKeysWithValues: (0..<10).map { _ in (TabID(), now.addingTimeInterval(-29)) })
        #expect(WorkspaceSelection.coldParkCandidates(hiddenSince: hidden, activeTabID: nil, terminalTabs: Set(hidden.keys), now: now).isEmpty)
    }

    /// Only a layout holding a terminal pane parks: a thread alone has no surface to release.
    @Test func layoutsWithoutATerminalPaneAreNeverParkCandidates() {
        let w = Workspace()
        let now = Date(timeIntervalSince1970: 10_000)
        let ids = (0..<6).map { _ in TabID() }
        var hidden: [TabID: Date] = [:]
        // All hidden an hour, ids[0] most recently: the hot four are ids[0...3].
        for (index, id) in ids.enumerated() { hidden[id] = now.addingTimeInterval(-3_600 - Double(index)) }

        let candidates = WorkspaceSelection.coldParkCandidates(hiddenSince: hidden, activeTabID: nil,
                                                               terminalTabs: [ids[1], ids[5]], now: now)

        #expect(candidates == [ids[5]], "ids[4] is past the delay and outside the hot four, but only a thread")
        #expect(WorkspaceSelection.terminalTabs(in: w.state).isEmpty, "these agents' layouts are only their threads")
    }

    @Test func aLayoutWithASplitTerminalHoldsATerminalPane() {
        let w = Workspace()
        var state = w.state
        let terminal = LeafPane(cwd: w.home.path)
        let index = state.tabs.firstIndex { $0.id == w.b.tab.id }!
        state.tabs[index].layout = .split(axis: .vertical, ratio: 0.5, first: state.tabs[index].layout, second: .leaf(terminal))
        #expect(WorkspaceSelection.terminalTabs(in: state) == [w.b.tab.id])
    }

    // MARK: Mounting at launch

    @Test func pendingLayoutsWaitToMount() {
        let w = Workspace()
        var selection = w.selecting(w.a.agent)
        selection.pendingMountTabIDs = [w.b.tab.id, w.c.tab.id]
        #expect(selection.mountedTabs.map(\.id) == [w.a.tab.id])
    }

    /// An agent selected before its turn to mount mounts at once.
    @Test func theActiveLayoutMountsEvenWhilePending() {
        let w = Workspace()
        var selection = w.selecting(w.b.agent)
        selection.pendingMountTabIDs = Set(w.stableOrder)
        #expect(selection.mountedTabs.map(\.id) == [w.b.tab.id])
    }

    @Test func theVisibleSpaceMountsFirst() {
        let w = Workspace()
        var inOther = w.selecting(w.c.agent, in: w.other)
        inOther.pendingMountTabIDs = [w.a.tab.id, w.b.tab.id]
        #expect(inOther.mountOrder == [w.a.tab.id, w.b.tab.id])
        var inHome = w.selecting(w.a.agent)
        inHome.pendingMountTabIDs = [w.b.tab.id, w.c.tab.id]
        #expect(inHome.mountOrder == [w.b.tab.id, w.c.tab.id])
        var otherFirst = w.selecting(w.c.agent, in: w.other)
        otherFirst.pendingMountTabIDs = [w.a.tab.id]
        #expect(otherFirst.mountOrder == [w.a.tab.id])
    }

    /// Mounting in any order never moves a layout already mounted: each lands in its place in
    /// the stable order.
    @Test(arguments: [[0, 1, 2], [2, 0, 1], [1, 2, 0]])
    func draininglayoutsKeepsTheStableOrder(drain: [Int]) {
        let w = Workspace()
        var selection = w.selecting(nil)
        selection.pendingMountTabIDs = Set(w.stableOrder)
        for index in drain {
            selection.pendingMountTabIDs.remove(w.stableOrder[index])
            let mounted = selection.mountedTabs.map(\.id)
            #expect(mounted == w.stableOrder.filter(mounted.contains))
        }
        #expect(selection.mountedTabs.map(\.id) == w.stableOrder)
    }

    @Test func theFourMostRecentlyShownLayoutsNeverPark() {
        let now = Date(timeIntervalSince1970: 10_000)
        let hidden = Dictionary(uniqueKeysWithValues: (0..<4).map { _ in (TabID(), now.addingTimeInterval(-3_600)) })
        #expect(WorkspaceSelection.coldParkCandidates(hiddenSince: hidden, activeTabID: nil, terminalTabs: Set(hidden.keys), now: now).isEmpty)
        #expect(WorkspaceSelection.hotRetainLimit == 4)
        #expect(WorkspaceSelection.parkDelay == .seconds(30))
    }
}

/// What the workspace says with no agent on screen.
@Suite("Empty workspace")
@MainActor
struct EmptyWorkspaceTests {
    nonisolated static let home = Fixture.space("home")
    nonisolated static let runs = Space(name: "Automations", path: "~", hidden: true)

    /// "No spaces yet" only when there are none anywhere: the hidden automations space is not
    /// one, and a connected host's spaces are there in the sidebar to pick from.
    @Test(arguments: [
        ([Space](), 0, EmptyWorkspace.Variant.noSpaces),
        ([runs], 0, .noSpaces),
        ([], 3, .noSelection),
        ([runs], 1, .noSelection),
        ([home], 0, .noSelection),
    ])
    func noSpacesMeansNoneOnThisMacOrAnyHost(local: [Space], remote: Int, variant: EmptyWorkspace.Variant) {
        #expect(EmptyWorkspace.variant(selected: nil, agents: [], localSpaces: local, remoteSpaces: remote) == variant)
    }

    @Test func aSelectedSpaceSaysWhetherItHasAgents() {
        let agent = Fixture.agent("a", in: Self.home).agent
        #expect(EmptyWorkspace.variant(selected: Self.home, agents: [], localSpaces: [Self.home], remoteSpaces: 2)
            == .space(Self.home.id, hasAgents: false))
        #expect(EmptyWorkspace.variant(selected: Self.home, agents: [agent], localSpaces: [Self.home], remoteSpaces: 0)
            == .space(Self.home.id, hasAgents: true))
    }
}
