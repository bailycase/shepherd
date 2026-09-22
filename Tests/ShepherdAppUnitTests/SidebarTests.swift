import Foundation
import ShepherdCore
import Testing
@testable import ShepherdApp

/// Spaces nest by path containment, derived at render time: adding `~/mono/sub` after `~/mono`
/// shows it under MONO without any stored parent.
@Suite("Sidebar space forest")
@MainActor
struct SpaceForestTests {
    @Test func spacesNestUnderTheNearestContainingPathRegardlessOfDeclarationOrder() {
        let mono = Fixture.space("mono", path: "/Users/x/mono")
        let sub = Fixture.space("sub", path: "/Users/x/mono/sub")
        let deep = Fixture.space("svc", path: "/Users/x/mono/sub/svc")
        let web = Fixture.space("web", path: "/Users/x/web")

        let forest = ShepherdViewModel.spaceForest([web, deep, mono, sub])

        #expect(forest.map(\.space.name) == ["web", "mono", "sub", "svc"])
        #expect(forest.map(\.depth) == [0, 0, 1, 2])
    }

    /// /tmp/app2 is a sibling of /tmp/app, not a child.
    @Test func aSharedPrefixWithoutASeparatorDoesNotNest() {
        let forest = ShepherdViewModel.spaceForest([Fixture.space("app", path: "/tmp/app"), Fixture.space("app2", path: "/tmp/app2")])
        #expect(forest.map(\.depth) == [0, 0])
    }

    @Test func trailingSlashesAndTildesNormalizeBeforeNesting() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let parent = Fixture.space("parent", path: "~/shepherd-unit-forest/")
        let child = Fixture.space("child", path: "\(home)/shepherd-unit-forest/child")
        #expect(ShepherdViewModel.spaceForest([child, parent]).map(\.depth) == [0, 1])
    }

    @Test func collapsingASpaceHidesItsDescendantsButNotItsSiblings() {
        let root = Fixture.space("root", path: "/tmp/r")
        let child = Fixture.space("child", path: "/tmp/r/c")
        let grandchild = Fixture.space("grandchild", path: "/tmp/r/c/g")
        let sibling = Fixture.space("sibling", path: "/tmp/s")

        let visible = ShepherdViewModel.visibleSpaceForest([root, child, grandchild, sibling], collapsed: [child.id])

        #expect(visible.map(\.space.name) == ["root", "child", "sibling"])
    }

    @Test func ancestorsAreListedNearestFirst() {
        let root = Fixture.space("root", path: "/tmp/root")
        let child = Fixture.space("child", path: "/tmp/root/child")
        let deep = Fixture.space("deep", path: "/tmp/root/child/deep")
        let spaces = [root, child, deep]

        #expect(ShepherdViewModel.ancestorSpaceIDs(of: deep.id, in: spaces) == [child.id, root.id])
        #expect(ShepherdViewModel.ancestorSpaceIDs(of: child.id, in: spaces) == [root.id])
        #expect(ShepherdViewModel.ancestorSpaceIDs(of: root.id, in: spaces).isEmpty)
        #expect(ShepherdViewModel.ancestorSpaceIDs(of: SpaceID(), in: spaces).isEmpty)
    }
}

/// ⌘1–9, the palette, and the tree must agree on one agent order.
@Suite("Sidebar agent order")
@MainActor
struct SidebarAgentOrderTests {
    /// Worktree agents read as part of the space's checkout tree, directly under its header.
    @Test func worktreeAgentsSortFirstThenDeclarationOrder() {
        let space = Fixture.space("s")
        let agents = [
            Fixture.agent("one", in: space).agent,
            Fixture.agent("wt-1", in: space, worktreeBranch: "worktree/wt-1").agent,
            Fixture.agent("two", in: space).agent,
            Fixture.agent("wt-2", in: space, worktreeBranch: "worktree/wt-2").agent,
            Fixture.agent("elsewhere", in: Fixture.space("x")).agent,
        ]
        #expect(ShepherdViewModel.sidebarAgents(of: space.id, in: agents).map(\.name) == ["wt-1", "wt-2", "one", "two"])
    }

    @Test func orderedAgentsFollowTheForestAndSkipCollapsedAndHiddenSpaces() {
        let root = Fixture.space("root", path: "/tmp/root")
        let child = Fixture.space("child", path: "/tmp/root/child")
        let other = Fixture.space("other", path: "/tmp/other")
        let automations = Fixture.space("automations", path: "/tmp/auto", hidden: true)
        let agents = [
            Fixture.agent("other-agent", in: other).agent,
            Fixture.agent("child-agent", in: child).agent,
            Fixture.agent("root-agent", in: root).agent,
            Fixture.agent("watcher", in: automations).agent,
        ]
        let state = ShepherdState(spaces: [root, other, child, automations], agents: agents)

        #expect(ShepherdViewModel.orderedAgents(in: state).map(\.name) == ["root-agent", "child-agent", "other-agent"])
        #expect(ShepherdViewModel.orderedAgents(in: state, collapsed: [root.id]).map(\.name) == ["other-agent"])
        #expect(ShepherdViewModel.orderedAgents(in: state, collapsed: [child.id]).map(\.name) == ["root-agent", "other-agent"])
    }

    @Test func eachSpaceListsOnlyItsOwnAgents() {
        let a = Fixture.space("a")
        let b = Fixture.space("b")
        let state = ShepherdState(spaces: [a, b], agents: [
            Fixture.agent("one", in: a).agent, Fixture.agent("two", in: b).agent, Fixture.agent("three", in: a).agent,
        ])
        #expect(ShepherdViewModel.agents(in: state, space: a.id).map(\.name) == ["one", "three"])
        #expect(ShepherdViewModel.agents(in: state, space: SpaceID()).isEmpty)
    }

    @Test func dragPayloadsNameTheirKind() {
        let agent = AgentID(rawValue: "a1")
        let space = SpaceID(rawValue: "s1")
        #expect(ShepherdViewModel.dragPayload(agent: agent) == "agent:a1")
        #expect(ShepherdViewModel.dragPayload(space: space) == "space:s1")
    }
}

/// Keyboard navigation scrolls the sidebar to this target; a wrong one scrolls to nothing or
/// yanks the tree while a remote agent owns the workspace.
@Suite("Sidebar reveal target")
@MainActor
struct SidebarRevealTargetTests {
    private let root = Fixture.space("root", path: "/tmp/root")
    private let child = Fixture.space("child", path: "/tmp/root/child")
    private let hidden = Fixture.space("automations", path: "/tmp/auto", hidden: true)

    private func target(agent: AgentID? = nil, space: SpaceID?, remote: Bool = false,
                        collapsed: Set<SpaceID> = []) -> AnyHashable? {
        ShepherdViewModel.sidebarRevealTarget(selectedAgentID: agent, selectedSpaceID: space, remoteSelected: remote,
                                              spaces: [root, child, hidden], collapsed: collapsed)
    }

    @Test func theSelectedAgentsRowIsTheTarget() {
        let agent = AgentID()
        #expect(target(agent: agent, space: child.id) == AnyHashable(agent))
    }

    @Test func aSpaceWithoutASelectedAgentTargetsItsHeader() {
        #expect(target(space: root.id) == AnyHashable(root.id))
    }

    /// A collapsed space hides its agent rows; its header is the row left to reveal.
    @Test func aCollapsedSpaceFallsBackToItsHeader() {
        #expect(target(agent: AgentID(), space: root.id, collapsed: [root.id]) == AnyHashable(root.id))
    }

    @Test func aSpaceUnderACollapsedParentHasNoRowToReveal() {
        #expect(target(agent: AgentID(), space: child.id, collapsed: [root.id]) == nil)
    }

    @Test func aRemoteSelectionNeverScrollsTheLocalTree() {
        #expect(target(agent: AgentID(), space: root.id, remote: true) == nil)
    }

    @Test func hiddenAndUnknownSpacesHaveNoTarget() {
        #expect(target(agent: AgentID(), space: hidden.id) == nil)
        #expect(target(space: SpaceID()) == nil)
        #expect(target(space: nil) == nil)
    }
}

@Suite("Sidebar rows")
@MainActor
struct SidebarRowTests {
    @Test(arguments: [
        (0.0, "0s"), (12, "12s"), (59, "59s"), (60, "1m"), (125, "2m"), (3_599, "59m"),
        (3_600, "1h"), (7_300, "2h"), (86_400, "1d"), (200_000, "2d"), (-5, "0s"),
    ])
    func elapsedTimeIsCoarse(seconds: Double, text: String) {
        let start = Date(timeIntervalSince1970: 0)
        #expect(SidebarTime.elapsed(since: start, now: start.addingTimeInterval(seconds)) == text)
    }

    /// Live groups are always expanded; a finished group folds for threads that are not
    /// selected unless the user unfolded it.
    @Test func finishedSubagentGroupsFoldOutsideTheSelectedThread() {
        let live = [Fixture.child("a", state: "complete"), Fixture.child("b")]
        let done = [Fixture.child("a", state: "complete"), Fixture.child("b", state: "failed")]
        #expect(!SubagentFolding.folded(children: live, selected: false, unfolded: false))
        #expect(SubagentFolding.folded(children: done, selected: false, unfolded: false))
        #expect(!SubagentFolding.folded(children: done, selected: true, unfolded: false))
        #expect(!SubagentFolding.folded(children: done, selected: false, unfolded: true))
        #expect(!SubagentFolding.folded(children: [], selected: false, unfolded: false))
    }

    @Test(arguments: [
        (AgentStatus.working, "running"), (.blocked, "needs you"), (.idle, "idle"), (.done, "done"),
    ])
    func statusWordsMatchTheStatusLanguage(status: AgentStatus, word: String) {
        #expect(AgentRow.statusWord(status) == word)
    }
}
