import Foundation
import ShepherdCore
import ShepherdUI
import ShepherdProtocol
import Testing
@testable import ShepherdApp

/// The branch card's pure reads: git's shortstat, the base's name, and which of the space's other
/// threads it lists, in what order.
@Suite("Branch card")
@MainActor
struct BranchCardTests {
    @Test(arguments: [
        (" 3 files changed, 71 insertions(+), 8 deletions(-)", 71, 8),
        (" 1 file changed, 1 insertion(+)", 1, 0),
        (" 1 file changed, 2 deletions(-)", 0, 2),
        ("", 0, 0),
    ])
    func shortstatReadsInsertionsAndDeletions(text: String, additions: Int, deletions: Int) {
        let read = BranchCardGitReader.shortstat(text)
        #expect(read.additions == additions && read.deletions == deletions)
    }

    @Test func originsBranchReadsByItsName() {
        #expect(BranchCardGitReader.baseName("origin/main") == "main")
        #expect(BranchCardGitReader.baseName("develop") == "develop")
    }

    @Test func otherBranchesListAskingThenRunningThenRecentOncePerBranch() {
        let space = SpaceID(), elsewhere = SpaceID(), tab = TabID()
        let now = Date(timeIntervalSince1970: 1_000_000)
        func agent(_ name: String, branch: String?, status: AgentStatus = .idle, daysAgo: Double = 0, in spaceID: SpaceID? = nil) -> Agent {
            Agent(name: name, spaceID: spaceID ?? space, tabID: tab, status: status, worktreeBranch: branch,
                  lastActiveAt: (now.timeIntervalSince1970 - daysAgo * 86_400) * 1000)
        }
        let me = agent("me", branch: "agent/refund-events")
        let agents = [
            me,
            agent("old", branch: "baily/ledger-refactor", daysAgo: 3),
            agent("asking", branch: "agent/webhook-retries", status: .blocked),
            agent("recent", branch: "agent/payout-ui", daysAgo: 1),
            agent("same branch", branch: "agent/refund-events", status: .working),
            agent("no branch", branch: nil, status: .working),
            agent("other space", branch: "agent/elsewhere", status: .blocked, in: elsewhere),
            agent("running", branch: "agent/fees", status: .working),
        ]
        let others = BranchCardModel.others(of: me, in: agents, now: now)
        #expect(others.map(\.branch) == ["agent/webhook-retries", "agent/fees", "agent/payout-ui", "baily/ledger-refactor"])
        #expect(others.map(\.detail) == ["asked you", "running", "1d", "3d"])
        #expect(others.map(\.state) == [.attention, .running, .idle, .idle])
    }

    @Test func thePickerListsLocalThenRemoteAndMarksBranchesInUse() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func at(_ days: Double) -> Double { now.timeIntervalSince1970 - days * 86_400 }
        let list = BranchPickerList(branches: ChangesBranches(defaultBase: "origin/main", branches: [
            ChangesBranch(name: "origin/sam/payout-ui", isRemote: true, committedAt: at(1)),
            ChangesBranch(name: "origin/main", isRemote: true, committedAt: at(0)),
            ChangesBranch(name: "origin/HEAD", isRemote: true, committedAt: at(0)),
            ChangesBranch(name: "baily/ledger-refactor", isRemote: false, committedAt: at(3)),
            ChangesBranch(name: "main", isRemote: false, isCurrent: true, committedAt: at(1)),
            ChangesBranch(name: "agent/refund-events", isRemote: false, worktree: "/tmp/payments-refund", committedAt: at(0.5)),
        ]), threads: ["/tmp/payments-refund": "Add refund events"])
        let rows = list.rows(now: now)
        #expect(rows.map(\.name) == ["agent/refund-events", "main", "baily/ledger-refactor", "origin/sam/payout-ui"])
        #expect(rows.map(\.detail) == ["in use · Add refund events", "1d", "3d", "remote · 1d"])
        #expect(rows.map(\.inUse) == [true, false, false, false] && rows[1].current)
        #expect(list.rows(query: "LEDGER", now: now).map(\.name) == ["baily/ledger-refactor"])
    }

    @Test func menuAndSheetWords() {
        #expect(BranchCardView.pushTitle(0) == "Push" && BranchCardView.pushTitle(1) == "Push 1 Commit" && BranchCardView.pushTitle(2) == "Push 2 Commits")
        #expect(BranchUpdateSheet.conflictTitle(.init(kind: .rebase, step: 2, steps: 4, files: ["a", "b"])) == "Stopped at commit 2 of 4: 2 files conflict")
        #expect(BranchUpdateSheet.conflictTitle(.init(kind: .merge, files: ["a"])) == "Stopped: 1 file conflict")
    }
}
