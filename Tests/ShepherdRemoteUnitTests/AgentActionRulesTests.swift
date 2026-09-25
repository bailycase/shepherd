import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// A client's agent actions: moving within a group, renaming, and deleting a worktree agent.
@Suite("Agent action rules")
struct AgentActionRulesTests {
    static let shepherd = SpaceID(rawValue: "shepherd")
    static let horizon = SpaceID(rawValue: "horizon")

    static func agent(_ id: String, space: SpaceID = shepherd, worktree: String? = nil) -> Agent {
        Agent(id: AgentID(rawValue: id), name: id, spaceID: space, tabID: TabID(rawValue: "tab-" + id), nameIsFinal: true,
              worktreeBranch: worktree)
    }

    /// a, b, c plain in Shepherd; w1, w2 its worktrees; h in horizon, between them in the host's order.
    static let agents = [
        agent("a"), agent("w1", worktree: "worktree/one"), agent("h", space: horizon), agent("b"),
        agent("w2", worktree: "worktree/two"), agent("c"),
    ]

    static func move(_ agent: String, before: String) -> AgentReorder.Move {
        AgentReorder.Move(agent: AgentID(rawValue: agent), before: AgentID(rawValue: before))
    }

    @Test func aGroupIsASpacesPlainOrWorktreeAgentsInTheHostsOrder() {
        #expect(AgentReorder.group(Self.agents, of: AgentID(rawValue: "b")).map(\.rawValue) == ["a", "b", "c"])
        #expect(AgentReorder.group(Self.agents, of: AgentID(rawValue: "w2")).map(\.rawValue) == ["w1", "w2"])
        #expect(AgentReorder.group(Self.agents, of: AgentID(rawValue: "missing")).isEmpty)
    }

    @Test(arguments: [
        ("b", AgentReorder.Direction.up, [("b", "a")]),
        ("a", .up, []),
        ("a", .down, [("a", "c")]),
        // Past the last agent: before it, then it before the one moving.
        ("b", .down, [("b", "c"), ("c", "b")]),
        ("c", .down, []),
        ("w1", .down, [("w1", "w2"), ("w2", "w1")]),
        ("h", .up, []),
        ("h", .down, []),
    ])
    func movingOnePlaceStaysInsideTheGroup(agent: String, direction: AgentReorder.Direction, moves: [(String, String)]) {
        let expected = moves.map { Self.move($0.0, before: $0.1) }
        #expect(AgentReorder.moves(Self.agents, moving: AgentID(rawValue: agent), direction) == expected)
    }

    @Test(arguments: [
        ("  New name ", "Old", "New name"),
        ("Old", "Old", nil),
        ("   ", "Old", nil),
        ("", "Old", nil),
    ] as [(String, String, String?)])
    func aRenameSendsOnlyANewNonEmptyName(text: String, current: String, sent: String?) {
        #expect(AgentRename.name(text, current: current) == sent)
    }

    static func info(warning: String?) -> RemoteWorktreeInfo {
        RemoteWorktreeInfo(path: "/repo/.worktrees/one", branch: "worktree/one", warning: warning,
                           defaults: RemoteFinalizeOptions(base: "main", title: "t", body: "", autoCommit: true,
                                                           deleteLocalBranch: true, autoMergePR: false, mergeMethod: "squash"),
                           fingerprint: "abc")
    }

    @Test(arguments: [
        (nil as String?, false, false, true),
        ("2 uncommitted files", false, false, false),
        ("2 uncommitted files", true, false, true),
        (nil, false, true, false),
    ])
    func unreconciledWorkMustBeAcknowledgedBeforeDeleting(warning: String?, acknowledged: Bool, submitting: Bool, allowed: Bool) {
        #expect(WorktreeDeletion.canDelete(Self.info(warning: warning), acknowledged: acknowledged, submitting: submitting) == allowed)
    }

    @Test func nothingIsDeletedBeforeTheHostDescribedTheCheckout() {
        #expect(!WorktreeDeletion.canDelete(nil, acknowledged: true, submitting: false))
    }

    @Test func theConfirmationCarriesTheWarningAndFingerprintItWasShown() {
        let id = UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!
        let query = WorktreeDeletion.query(Self.info(warning: "1 unpushed commit"), operationID: id)
        #expect(query == .deleteWorktree(operationID: id, confirmedWarning: "1 unpushed commit", fingerprint: "abc"))
    }

    @Test func aRefusalForgetsTheOperationButAnUnknownOutcomeKeepsCheckingIt() {
        let refused = WorktreeDeletion.startFailure(RemoteHostClientError.rejected(code: "x", message: "Checkout changed"))
        #expect(refused == .refused("Checkout changed"))
        guard case .unknown = WorktreeDeletion.startFailure(RemoteHostClientError.timeout) else {
            Issue.record("a timeout's outcome is unknown")
            return
        }
    }
}
