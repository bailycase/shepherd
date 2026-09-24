import Testing
@testable import ShepherdApp

/// Only turns that land at the tail of a thread already on screen make an entrance: opening a
/// thread, catching up after it was hidden, paging in older history, and swapping in another
/// session's window are instant.
@Suite("Thread arrivals")
@MainActor
struct ThreadArrivalsTests {
    /// A tracker that has seen `ids` load in session "s".
    private func loaded(_ ids: [String]) -> ThreadArrivals {
        let arrivals = ThreadArrivals()
        _ = arrivals.show(ids)
        return arrivals
    }

    @Test func aThreadsFirstLoadArrivesAtOnce() {
        let arrivals = ThreadArrivals()
        #expect(arrivals.show(["u1", "u1/reply"]).isEmpty)
        #expect(arrivals.armed)
    }

    @Test func turnsAppendedAtTheTailArrive() {
        let arrivals = loaded(["u1", "u1/reply"])
        #expect(arrivals.show(["u1", "u1/reply", "pending:op"]) == ["pending:op"])
        #expect(arrivals.show(["u1", "u1/reply", "pending:op", "pending:op/reply"]) == ["pending:op/reply"])
    }

    /// Streaming changes rows without changing which turns there are: the arrival stands, so a
    /// row the lazy stack creates a moment later still makes its entrance.
    @Test func theSameTurnsAnswerTheSameArrivals() {
        let arrivals = loaded(["u1", "u1/reply"])
        let next = ["u1", "u1/reply", "u2"]
        #expect(arrivals.show(next) == ["u2"])
        #expect(arrivals.show(next) == ["u2"])
    }

    @Test(arguments: [
        ["m0", "m0/reply", "u1", "u1/reply"],      // a page of older history
        ["w1", "w1/reply"],                          // another history window
        ["u1"],                                      // the tail rewound (a failed send's echo left)
    ])
    func turnsThatDoNotExtendTheTailArriveAtOnce(next: [String]) {
        let arrivals = loaded(["u1", "u1/reply"])
        #expect(arrivals.show(next).isEmpty)
    }

    @Test func aSlidingHistoryWindowStillBringsItsNewTurnsIn() {
        let arrivals = loaded(["u1", "u1/reply", "u2", "u2/reply"])
        #expect(arrivals.show(["u2", "u2/reply", "u3"]) == ["u3"])
    }

    @Test func anEmptyThreadsFirstTurnArrives() {
        let arrivals = loaded([])
        #expect(arrivals.show(["pending:op"]) == ["pending:op"])
    }

    /// `/resume` into an empty thread swaps in another session's history: it loads, all at once.
    @Test func anotherSessionsTurnsArriveAtOnce() {
        let arrivals = loaded([])
        #expect(arrivals.show(["r1", "r1/reply", "r2"], session: "t").isEmpty)
        #expect(arrivals.show(["r1", "r1/reply", "r2", "r3"], session: "t") == ["r3"])
    }

    /// Switching back to an agent: the pull that brings what it did while hidden is a load.
    @Test func aThreadBackOnScreenCatchesUpAtOnce() {
        let arrivals = loaded(["u1", "u1/reply"])
        #expect(arrivals.show(["u1", "u1/reply"], active: false).isEmpty)
        #expect(!arrivals.armed)
        // On screen again, still showing the last snapshot until the fresh pull lands.
        #expect(arrivals.show(["u1", "u1/reply"], active: true, catchingUp: true).isEmpty)
        #expect(arrivals.show(["u1", "u1/reply", "u2", "u2/reply"], active: true, catchingUp: true).isEmpty)
        #expect(arrivals.show(["u1", "u1/reply", "u2", "u2/reply", "u3"]) == ["u3"])
    }

    /// After a send the store re-pulls (not ready for a moment): the thread stays on screen and
    /// the reply that pull brings still arrives.
    @Test func aRefreshOnScreenKeepsArrivalsOn() {
        let arrivals = loaded(["u1", "u1/reply"])
        #expect(arrivals.show(["u1", "u1/reply", "pending:op"]) == ["pending:op"])
        #expect(arrivals.show(["u1", "u1/reply", "pending:op", "pending:op/reply"]) == ["pending:op/reply"])
    }

    /// History not known yet: nothing arrives until the thread has loaded once, and the empty state
    /// that then shows knows it.
    @Test func turnsBeforeTheFirstSnapshotDoNotArrive() {
        let arrivals = ThreadArrivals()
        #expect(arrivals.show([], session: nil, catchingUp: true).isEmpty)
        #expect(!arrivals.armed)
        #expect(arrivals.startedLoading)
        #expect(arrivals.show(["u1", "u1/reply"]).isEmpty)
        #expect(arrivals.armed)
    }

    @Test func aThreadOpenedLoadedDidNotStartLoading() {
        #expect(!loaded(["u1"]).startedLoading)
    }

    /// Back on screen with nothing new, the first turn after (a message sent at once) arrives.
    @Test func aThreadBackOnScreenUnchangedLetsTheNextTurnArrive() {
        let arrivals = loaded(["u1", "u1/reply"])
        #expect(arrivals.show(["u1", "u1/reply"], active: false).isEmpty)
        #expect(arrivals.show(["u1", "u1/reply"], catchingUp: true).isEmpty)
        #expect(arrivals.show(["u1", "u1/reply", "pending:op"]) == ["pending:op"])
    }

    // MARK: The catch-up gate

    /// Until the store has caught up, every render is the catch-up.
    @Test func aThreadThatHasNotCaughtUpIsCatchingUp() {
        let gate = CatchUpGate()
        #expect(gate.catchingUp(caughtUpAt: nil, version: 0))
        #expect(gate.catchingUp(caughtUpAt: nil, version: 3))
    }

    /// The render that draws what the catch-up changed is the catch-up; later ones are not.
    @Test func theRenderShowingTheCatchUpIsTheOnlyOne() {
        let gate = CatchUpGate()
        #expect(gate.catchingUp(caughtUpAt: nil, version: 4), "the flip, before the pull")
        #expect(gate.catchingUp(caughtUpAt: 7, version: 7), "the pull brought versions 5 to 7")
        #expect(!gate.catchingUp(caughtUpAt: 7, version: 8), "what came after")
        #expect(!gate.catchingUp(caughtUpAt: 7, version: 8), "a render for the view's own reasons")
    }

    /// A catch-up that changed nothing leaves nothing to land at once.
    @Test func aCatchUpThatChangedNothingIsDoneAtOnce() {
        let gate = CatchUpGate()
        #expect(gate.catchingUp(caughtUpAt: nil, version: 4))
        #expect(!gate.catchingUp(caughtUpAt: 4, version: 5))
    }

    /// A view created after the thread caught up (remounted) draws its first render at once.
    @Test func aViewsFirstRenderIsACatchUp() {
        #expect(CatchUpGate().catchingUp(caughtUpAt: 2, version: 9))
    }
}

extension ThreadArrivals {
    /// A thread on screen whose latest pull has landed, in session "s", unless told otherwise.
    fileprivate func show(_ ids: [String], session: String? = "s", active: Bool = true, catchingUp: Bool = false) -> Set<String> {
        update(ids, session: session, active: active, catchingUp: catchingUp)
    }
}
