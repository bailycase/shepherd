import Testing
@testable import ShepherdApp

/// A view made in the middle of a session, such as each new reply's live row, asks its parent
/// whether its first render is a catch-up. Its first render is not the thread's catch-up, so
/// without the parent's word it would lose its entrance (`ThreadMotionTests`).
@Suite("Catch-up gate")
@MainActor
struct CatchUpGateTests {
    @Test func aGateThatHasNotDrawnTakesItsParentsVerdict() {
        #expect(!CatchUpGate().catchingUp(caughtUpAt: 4, version: 9, parent: false), "the thread is caught up and moving")
        #expect(CatchUpGate().catchingUp(caughtUpAt: 4, version: 9, parent: true), "the thread is catching up")
        #expect(!CatchUpGate().catchingUp(caughtUpAt: nil, version: 9, parent: false), "the parent has the last word")
    }

    @Test func afterItsFirstRenderAGateCountsForItself() {
        let gate = CatchUpGate()
        #expect(!gate.catchingUp(caughtUpAt: 4, version: 9, parent: false))
        #expect(!gate.catchingUp(caughtUpAt: 4, version: 10, parent: true), "a parent's verdict no longer applies")
        #expect(gate.catchingUp(caughtUpAt: nil, version: 11, parent: false), "the thread left the screen")
        #expect(gate.catchingUp(caughtUpAt: 14, version: 14, parent: false), "the pull that caught the thread up")
        #expect(!gate.catchingUp(caughtUpAt: 14, version: 15, parent: false))
    }

    @Test func aFirstRenderRecordsTheVersionItDrew() {
        let gate = CatchUpGate()
        #expect(!gate.catchingUp(caughtUpAt: 4, version: 9, parent: false))
        #expect(!gate.catchingUp(caughtUpAt: 9, version: 9, parent: true), "nothing came after what it drew")
    }

    /// The views that pass no parent (the thread, the composer) are as they were.
    @Test func withoutAParentTheFirstRenderAfterACatchUpIsTheCatchUp() {
        #expect(CatchUpGate().catchingUp(caughtUpAt: 4, version: 9))
        #expect(CatchUpGate().catchingUp(caughtUpAt: nil, version: 9))
        let gate = CatchUpGate()
        #expect(gate.catchingUp(caughtUpAt: 4, version: 9))
        #expect(!gate.catchingUp(caughtUpAt: 4, version: 10))
    }
}
