import Foundation
import ShepherdCore
import ShepherdProtocol
import Testing
@testable import ShepherdApp

/// The dim context beside a palette row's title (NWComposer, CommandPalette).
@MainActor
@Suite("Palette context")
struct PaletteContextTests {
    @Test(arguments: [
        (nil as Int?, "working tree"),
        (1, "working tree · 1 file"),
        (4, "working tree · 4 files"),
        (0, "working tree · 0 files"),
    ])
    func reviewDiffCountsTheCheckoutsChangedFiles(files: Int?, expected: String) {
        #expect(ShepherdViewModel.reviewDiffContext(changedFiles: files) == expected)
    }

    @Test(arguments: [(false, "PR #24"), (true, "PR #24 draft")])
    func reviewPRNamesThePullRequest(draft: Bool, expected: String) {
        let pullRequest = ChangesPullRequest(number: 24, title: "Refunds", isDraft: draft, state: "OPEN",
                                             base: "main", head: "agent/refunds", url: "https://example.invalid/24")
        #expect(ShepherdViewModel.pullRequestContext(pullRequest) == expected)
    }

    @Test func newThreadNamesItsProject() {
        #expect(ShepherdViewModel.newThreadContext("Shepherd") == "in Shepherd/")
    }

    @Test(arguments: [
        (AgentStatus.working, false, 480.0 as Double?, "payments · running · 8m"),
        (.working, false, nil, "payments · running"),
        (.blocked, false, 480.0, "payments · needs you"),
        (.done, true, 480.0, "payments · failed"),
        (.idle, false, 480.0, "payments · idle"),
    ])
    func anAgentRowAddsAWorkingAgentsTime(status: AgentStatus, failed: Bool, elapsed: Double?, expected: String) {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let since = elapsed.map { now.addingTimeInterval(-$0) }
        #expect(ShepherdViewModel.agentContext(space: "payments", status: status, turnFailed: failed, since: since, now: now) == expected)
    }
}
