import Foundation
import Testing
@testable import ShepherdRemote

/// Where the @ picker's read of this Mac's designs stands (`DesignMentionLoad`): it says it is
/// loading before there are rows, a read that failed says so with a way back, a read belongs to
/// the opening that asked for it, and rows already read stay through the next read.
@Suite("Design mention load")
struct DesignMentionLoadTests {
    @Test func aPickerThatHasReadNothingSaysItIsLoading() {
        var load = DesignMentionLoad()
        #expect(load.stage == .loading, "idle: the read is about to start")
        load.begin()
        #expect(load.phase == .loading && load.stage == .loading)
    }

    @Test func aReadThatComesBackLeavesItsRows() {
        var load = DesignMentionLoad()
        let request = load.begin()
        let accepted = load.finish(request)
        #expect(accepted)
        #expect(load.phase == .loaded && load.stage == .rows)
    }

    @Test func aReadThatFailsSaysWhyUntilItIsRetried() {
        var load = DesignMentionLoad()
        let first = load.begin()
        let failed = load.fail(first, reason: "took too long")
        #expect(failed)
        #expect(load.stage == .failed(reason: "took too long"))

        let retry = load.begin()
        #expect(load.stage == .loading, "Retry reads again: the failure is gone while it does")
        let accepted = load.finish(retry)
        #expect(accepted && load.stage == .rows)
    }

    @Test func anAnswerToAnOlderReadIsDropped() {
        var load = DesignMentionLoad()
        let slow = load.begin()
        let second = load.begin()

        let lateRows = load.finish(slow)
        #expect(!lateRows, "the first opening's answer comes after the second began")
        #expect(load.stage == .loading)
        let lateFailure = load.fail(slow, reason: "late")
        #expect(!lateFailure)
        #expect(load.stage == .loading)

        let accepted = load.finish(second)
        #expect(accepted)
        let laterStill = load.fail(slow, reason: "later still")
        #expect(!laterStill, "and never undoes the answer that landed")
        #expect(load.stage == .rows)
    }

    @Test func rowsAlreadyReadStayThroughALaterReadAndItsFailure() {
        var load = DesignMentionLoad()
        load.finish(load.begin())

        let again = load.begin()
        #expect(load.stage == .rows, "reading again keeps the rows on screen")
        let failed = load.fail(again, reason: "took too long")
        #expect(failed)
        #expect(load.phase == .loaded && load.stage == .rows, "a read nobody needed is no failure")
    }

    @Test func aFailureOfTheFirstReadIsNotRememberedOnceAnotherSucceeds() {
        var load = DesignMentionLoad()
        load.fail(load.begin(), reason: "took too long")
        load.finish(load.begin())
        #expect(load.stage == .rows)
    }
}
