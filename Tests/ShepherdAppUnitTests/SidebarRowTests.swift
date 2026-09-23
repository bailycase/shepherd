import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdUI
import Testing
@testable import ShepherdApp

/// A reorder lands exactly where the drop line was drawn, and drops that could not are refused
/// (so no line is drawn for them).
@Suite("Sidebar reorder")
@MainActor
struct SidebarReorderTests {
    private let one = Fixture.space("one", path: "/tmp/one")
    private let two = Fixture.space("two", path: "/tmp/two")

    private func agents() -> [Agent] {
        [Fixture.agent("a", in: one).agent, Fixture.agent("b", in: one).agent, Fixture.agent("c", in: one).agent,
         Fixture.agent("d", in: two).agent, Fixture.agent("wt", in: one, worktreeBranch: "worktree/wt").agent]
    }

    private func names(_ agents: [Agent]?) -> [String]? { agents?.map(\.name) }

    @Test(arguments: [
        ("c", "a", SidebarDropEdge.above, ["c", "a", "b", "d", "wt"]),
        ("a", "c", .above, ["b", "a", "c", "d", "wt"]),
        ("a", "c", .below, ["b", "c", "a", "d", "wt"]),
        ("c", "a", .below, ["a", "c", "b", "d", "wt"]),
    ])
    func anAgentLandsWhereTheDropLineIs(dragged: String, target: String, edge: SidebarDropEdge, order: [String]) {
        let agents = agents()
        let id = agents.first { $0.name == dragged }!.id, targetID = agents.first { $0.name == target }!.id
        #expect(names(ShepherdViewModel.reorderedAgents(agents, moving: id, beside: targetID, edge: edge)) == order)
    }

    /// Another space, the worktree/standard split (worktree agents always list first), the row
    /// itself, and a move that changes nothing.
    @Test(arguments: [("a", "d", SidebarDropEdge.above), ("a", "wt", .above), ("wt", "b", .below), ("a", "a", .above),
                      ("a", "b", .above), ("b", "a", .below)])
    func invalidOrNoOpDropsAreRefused(dragged: String, target: String, edge: SidebarDropEdge) {
        let agents = agents()
        let id = agents.first { $0.name == dragged }!.id, targetID = agents.first { $0.name == target }!.id
        #expect(ShepherdViewModel.reorderedAgents(agents, moving: id, beside: targetID, edge: edge) == nil)
    }

    @Test func spacesReorderAmongSiblingsOnly() {
        let root = Fixture.space("root", path: "/tmp/root")
        let child = Fixture.space("child", path: "/tmp/root/child")
        let other = Fixture.space("other", path: "/tmp/other")
        let spaces = [root, child, other]

        #expect(ShepherdViewModel.reorderedSpaces(spaces, moving: other.id, beside: root.id, edge: .above)?.map(\.name) == ["other", "root", "child"])
        #expect(ShepherdViewModel.reorderedSpaces(spaces, moving: root.id, beside: other.id, edge: .below)?.map(\.name) == ["child", "other", "root"])
        #expect(ShepherdViewModel.reorderedSpaces(spaces, moving: other.id, beside: child.id, edge: .above) == nil,
                "a root dropped on a nested project would land after its parent's subtree, not at the line")
        #expect(ShepherdViewModel.reorderedSpaces(spaces, moving: root.id, beside: other.id, edge: .above) == nil, "no-op")
    }

    @Test func forestParentsFollowPathContainment() {
        let root = Fixture.space("root", path: "/tmp/root")
        let child = Fixture.space("child", path: "/tmp/root/child")
        let deep = Fixture.space("deep", path: "/tmp/root/child/deep")
        let other = Fixture.space("other", path: "/tmp/other")
        let parents = ShepherdViewModel.forestParents([deep, other, child, root])
        #expect(parents[root.id] == .some(nil))
        #expect(parents[child.id] == .some(root.id))
        #expect(parents[deep.id] == .some(child.id))
        #expect(parents[other.id] == .some(nil))
    }

    @Test(arguments: [(3.0, true, SidebarDropEdge.above), (20.0, true, .below), (20.0, false, .above), (14.0, true, .above)])
    func theDropEdgeIsThePointersHalfOfTheRow(y: Double, allowsBelow: Bool, edge: SidebarDropEdge) {
        #expect(SidebarDropEdge.at(y: y, height: 28, allowsBelow: allowsBelow) == edge)
    }
}

@Suite("Sidebar rows")
struct SidebarRowModelTests {
    private let space = Fixture.space("s")

    private func model(_ status: AgentStatus, badge: Int? = nil, children: [ChildRun] = [], folded: Bool = false,
                       since: Date? = Date(timeIntervalSince1970: 10)) -> SidebarAgentRowModel {
        var agent = Fixture.agent("a", in: space).agent
        agent.status = status
        return SidebarAgentRowModel(agent: agent, selected: false, depth: 1, badge: badge, statusSince: since,
                                    children: children, folded: folded)
    }

    /// ⌘-digit hint, then needs you, then a folded subagent count, then elapsed while working.
    @Test func theTrailingSlotFollowsItsPriority() {
        let done = [Fixture.child("r1", state: "complete"), Fixture.child("r2", state: "complete")]
        #expect(model(.blocked, badge: 3).accessory == .shortcut("⌘3"))
        #expect(model(.blocked, children: done, folded: true).accessory == .ask)
        #expect(model(.working, children: done, folded: true).accessory == .text("2 sub"))
        #expect(model(.working).accessory == .elapsed(since: Date(timeIntervalSince1970: 10), tone: .running))
        #expect(model(.working, since: nil).accessory == .none)
        #expect(model(.done).accessory == .none)
        #expect(model(.idle).accessory == .none)
    }

    @Test func childRowsShowUnlessTheFinishedGroupIsFolded() {
        let live = [Fixture.child("r1")]
        #expect(model(.working, children: live).showsChildRows)
        #expect(!model(.working, children: live, folded: true).showsChildRows)
        #expect(!model(.working).showsChildRows)
    }

    @Test func theRowReadsAsOneElement() {
        var agent = Fixture.agent("Fix login", in: space, worktreeBranch: "worktree/login").agent
        agent.status = .blocked
        let model = SidebarAgentRowModel(agent: agent, selected: false, depth: 1)
        #expect(model.accessibilityLabel == "Fix login, worktree, needs you")
    }

    /// A run that needs you asks; a live one counts up from its start; a failed one shows its
    /// duration in the failed color.
    @Test func subagentRowsTrailWithTheirState() {
        #expect(SubagentStyle.accessory(Fixture.child("r", attention: true), state: .needsYou) == .ask)
        var live = Fixture.child("live")
        live.startedAt = 5_000
        #expect(SubagentStyle.accessory(live, state: .running) == .elapsed(since: Date(timeIntervalSince1970: 5), tone: .running))
        var failed = Fixture.child("failed", state: "failed")
        failed.startedAt = 0
        failed.endedAt = 14 * 60_000
        #expect(SubagentStyle.accessory(failed, state: .failed, now: Date(timeIntervalSince1970: 3600)) == .text("14m", tone: .failed))
    }
}
