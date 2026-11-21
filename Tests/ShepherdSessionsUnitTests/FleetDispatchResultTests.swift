import Foundation
import ShepherdCore
import Testing
@testable import ShepherdSessions

@Suite("Fleet dispatch result")
struct FleetDispatchResultTests {
    @Test func theCheckoutNoticeIsSeparateFromCommittedWork() {
        let branch = "fleet/checkout-notes"
        let committed = "Branch fleet/checkout-notes: 1 commit ahead of the start, pushed to origin, 1 file changed (+2 -1)."
        let prefix = "[from: Checkout notes on Build Mac, an agent, not the user. Reply with agent_send only if this asks for a reply.] Result from Checkout notes on Build Mac:\nUpdated the notes.\n\n"
        var record = FleetDispatchRecord(parentHostID: UUID(), parentHostName: "Studio Mac", targetHostName: "Build Mac", title: "Checkout notes",
                                         task: "Update the notes.", repoKey: "github.com/acme/web", branch: branch, resultText: "Updated the notes.", createdAt: 1)
        let cases: [(Int?, Int?, Bool?, String)] = [
            (nil, nil, nil, ""), // Older receiver.
            (0, 0, nil, ""),
            (1, 0, nil, " Uncommitted in the checkout on Build Mac: 1 file (1 modified). Counts include any edits sent with the dispatch."),
            (0, 1, nil, " Uncommitted in the checkout on Build Mac: 1 file (1 untracked). Counts include any edits sent with the dispatch."),
            (2, 1, nil, " Uncommitted in the checkout on Build Mac: 3 files (2 modified, 1 untracked). Counts include any edits sent with the dispatch."),
            (nil, nil, true, " Could not check the checkout for uncommitted work."),
            (-1, 2, nil, ""),
            (Int.max, 1, nil, ""),
        ]
        for (modified, untracked, failed, notice) in cases {
            record.resultBranchFacts = FleetBranchFacts(branch: branch, head: "abc", ahead: 1, pushed: true, filesChanged: 1, insertions: 2, deletions: 1,
                                                       uncommittedModified: modified, uncommittedUntracked: untracked, uncommittedCheckFailed: failed)
            #expect(FleetDispatch.resultMessage(record) == prefix + committed + notice)
        }
        record.resultBranchFacts = FleetBranchFacts(branch: branch, uncommittedModified: 1, uncommittedUntracked: 0)
        #expect(FleetDispatch.resultMessage(record) == prefix + "Branch fleet/checkout-notes: branch work unavailable." + cases[2].3)
        record.resultBranchFacts = nil
        #expect(FleetDispatch.resultMessage(record) == prefix + "Branch fleet/checkout-notes: branch work unavailable.")
        record.branch = nil
        record.resultBranchFacts = FleetBranchFacts(branch: branch, uncommittedCheckFailed: true)
        #expect(FleetDispatch.resultMessage(record) == prefix + "Branch fleet/checkout-notes: branch work unavailable. Could not check the checkout for uncommitted work.")
    }

    @Test func closeDistinguishesACleanCheckoutFromAFailedCheck() {
        #expect(FleetDispatch.closeCheckoutReport(0) == "Kept the checkout, branches, and saved conversation; unverified output was left alone.")
        #expect(FleetDispatch.closeCheckoutReport(1).contains("including 1 uncommitted file in the checkout;"))
        #expect(FleetDispatch.closeCheckoutReport(nil).hasSuffix("Could not check the checkout for uncommitted work."))
    }
}
