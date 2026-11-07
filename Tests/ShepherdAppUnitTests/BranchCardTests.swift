import Foundation
import ShepherdCore
import ShepherdUI
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
}
