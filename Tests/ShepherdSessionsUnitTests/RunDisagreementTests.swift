import Testing
@testable import ShepherdSessions

/// The host's warning that a thread serves running against its agent's status.
@Suite("Run disagreement")
struct RunDisagreementTests {
    let start = ContinuousClock.now

    @Test func aDisagreementThatLastsWarnsOnce() {
        var d = RunDisagreement()
        let first = d.shouldWarn(disagrees: true, now: start)
        let later = d.shouldWarn(disagrees: true, now: start + .seconds(6))
        let again = d.shouldWarn(disagrees: true, now: start + .seconds(30))
        #expect([first, later, again] == [false, true, false])
    }

    /// Run A is caught before its Working report, polling pauses, then healthy run B is caught before its own: a long gap between
    /// samples is not a long disagreement, because A's report, its settle and B's start moved things in between.
    @Test func aSecondRunSampledAfterAGapDoesNotWarn() {
        var d = RunDisagreement()
        let a = d.shouldWarn(disagrees: true, now: start)
        d.reset()
        let b = d.shouldWarn(disagrees: true, now: start + .seconds(60))
        #expect([a, b] == [false, false])
    }

    @Test func agreeingEndsTheDisagreement() {
        var d = RunDisagreement()
        let first = d.shouldWarn(disagrees: true, now: start)
        let agreed = d.shouldWarn(disagrees: false, now: start + .seconds(3))
        let again = d.shouldWarn(disagrees: true, now: start + .seconds(7))
        #expect([first, agreed, again] == [false, false, false])
    }
}
