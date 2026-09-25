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
    private static let since = Date(timeIntervalSince1970: 10)

    private func model(_ status: AgentStatus, badge: Int? = nil, children: [ChildRun] = [],
                       since: Date? = since, turnFailed: Bool = false) -> SidebarAgentRowModel {
        var agent = Fixture.agent("a", in: space).agent
        agent.status = status
        return SidebarAgentRowModel(agent: agent, selected: false, depth: 1, badge: badge, statusSince: since,
                                    children: children, turnFailed: turnFailed)
    }

    /// The ⌘-digit hint, then needs you, then elapsed time while working.
    @Test func theTrailingSlotFollowsItsPriority() {
        #expect(model(.blocked, badge: 3).accessory == .shortcut("⌘3"))
        #expect(model(.blocked).accessory == .ask)
        #expect(model(.working).accessory == .elapsed(since: Self.since, tone: .running))
        #expect(model(.working, since: nil).accessory == .none)
        #expect(model(.done).accessory == .none)
        #expect(model(.idle).accessory == .none)
    }

    enum Children: Sendable {
        case waiting, live, finished

        var runs: [ChildRun] {
            switch self {
            case .waiting: [Fixture.child("live"), Fixture.child("asks", attention: true), Fixture.child("done", state: "complete")]
            case .live: [Fixture.child("live")]
            case .finished: [Fixture.child("done", state: "complete"), Fixture.child("failed", state: "failed")]
            }
        }
    }

    /// Subagents have no rows, and reach their agent's row only by asking: a waiting one makes
    /// it ask whatever the agent is doing, and live or finished ones leave it as the agent's own.
    @Test(arguments: [
        (AgentStatus.working, Children.waiting, NWSidebarRow.Accessory.ask, AgentState.attention, "needs you"),
        (.idle, .waiting, .ask, .attention, "needs you"),
        (.done, .waiting, .ask, .attention, "needs you"),
        (.working, .live, .elapsed(since: Date(timeIntervalSince1970: 10), tone: .running), .running, "running"),
        (.idle, .live, .none, .idle, "idle"),
        (.working, .finished, .elapsed(since: Date(timeIntervalSince1970: 10), tone: .running), .running, "running"),
        (.done, .finished, .none, .done, "done"),
    ])
    func subagentsReachTheirAgentsRowOnlyByAsking(status: AgentStatus, children: Children,
                                                 accessory: NWSidebarRow.Accessory, state: AgentState, word: String) {
        let row = model(status, children: children.runs)
        #expect(row.accessory == accessory)
        #expect(row.state == state)
        #expect(row.accessibilityLabel == "a, \(word)")
    }

    /// A finished agent whose turn ended in an error reads failed; a new turn, or a question
    /// from one of its subagents, reads as usual.
    @Test(arguments: [
        (AgentStatus.done, [ChildRun](), AgentState.failed, "failed"),
        (.working, [], .running, "running"),
        (.idle, [], .idle, "idle"),
        (.done, [Fixture.child("asks", attention: true)], .attention, "needs you"),
    ])
    func aFailedTurnReadsFailed(status: AgentStatus, children: [ChildRun], state: AgentState, word: String) {
        let row = model(status, children: children, turnFailed: true)
        #expect(row.state == state)
        #expect(row.accessibilityLabel == "a, \(word)")
    }

    /// Spaces and hosts count each blocked agent and each asking subagent of the agents given.
    @Test func needsYouCountsBlockedAgentsAndAskingSubagents() {
        var blocked = Fixture.agent("blocked", in: space).agent
        blocked.status = .blocked
        var working = Fixture.agent("working", in: space).agent
        working.status = .working
        let idle = Fixture.agent("idle", in: space).agent
        let elsewhere = Fixture.agent("elsewhere", in: space).agent
        let children: [AgentID: [ChildRun]] = [
            working.id: [Fixture.child("q1", attention: true), Fixture.child("q2", attention: true), Fixture.child("live")],
            idle.id: Children.finished.runs,
            elsewhere.id: [Fixture.child("q3", attention: true)],
        ]
        #expect(SidebarAttention.count([blocked, working, idle], children: children) == 3)
        #expect(SidebarAttention.count([idle], children: children) == 0)
    }

    @Test func theRowReadsAsOneElement() {
        var agent = Fixture.agent("Fix login", in: space, worktreeBranch: "worktree/login").agent
        agent.status = .blocked
        let model = SidebarAgentRowModel(agent: agent, selected: false, depth: 1)
        #expect(model.accessibilityLabel == "Fix login, worktree, needs you")
    }
}
