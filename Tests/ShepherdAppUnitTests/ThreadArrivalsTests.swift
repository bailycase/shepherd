import Testing
@testable import ShepherdApp

/// Only turns that land at the tail of a thread already on screen make an entrance: opening a
/// thread, paging in older history, and swapping in another session's window are instant.
@Suite("Thread arrivals")
@MainActor
struct ThreadArrivalsTests {
    /// A tracker that has seen `ids` load.
    private func loaded(_ ids: [String]) -> ThreadArrivals {
        let arrivals = ThreadArrivals()
        _ = arrivals.update(ids, loaded: true)
        return arrivals
    }

    @Test func aThreadsFirstLoadArrivesAtOnce() {
        let arrivals = ThreadArrivals()
        #expect(arrivals.update(["u1", "u1/reply"], loaded: true).isEmpty)
        #expect(arrivals.armed)
    }

    @Test func turnsAppendedAtTheTailArrive() {
        let arrivals = loaded(["u1", "u1/reply"])
        #expect(arrivals.update(["u1", "u1/reply", "pending:op"], loaded: true) == ["pending:op"])
        #expect(arrivals.update(["u1", "u1/reply", "pending:op", "pending:op/reply"], loaded: true) == ["pending:op/reply"])
    }

    /// Streaming changes rows without changing which turns there are: the arrival stands, so a
    /// row the lazy stack creates a moment later still makes its entrance.
    @Test func theSameTurnsAnswerTheSameArrivals() {
        let arrivals = loaded(["u1", "u1/reply"])
        let next = ["u1", "u1/reply", "u2"]
        #expect(arrivals.update(next, loaded: true) == ["u2"])
        #expect(arrivals.update(next, loaded: true) == ["u2"])
    }

    @Test(arguments: [
        ["m0", "m0/reply", "u1", "u1/reply"],      // a page of older history
        ["w1", "w1/reply"],                          // another session or history window
        ["u1"],                                      // the tail rewound (a failed send's echo left)
    ])
    func turnsThatDoNotExtendTheTailArriveAtOnce(next: [String]) {
        let arrivals = loaded(["u1", "u1/reply"])
        #expect(arrivals.update(next, loaded: true).isEmpty)
    }

    @Test func aSlidingHistoryWindowStillBringsItsNewTurnsIn() {
        let arrivals = loaded(["u1", "u1/reply", "u2", "u2/reply"])
        #expect(arrivals.update(["u2", "u2/reply", "u3"], loaded: true) == ["u3"])
    }

    @Test func anEmptyThreadsFirstTurnArrives() {
        let arrivals = loaded([])
        #expect(arrivals.update(["pending:op"], loaded: true) == ["pending:op"])
    }

    /// "Starting pi…": nothing arrives until the thread has loaded once, and the empty state
    /// that replaces the spinner knows it.
    @Test func turnsBeforeTheFirstSnapshotDoNotArrive() {
        let arrivals = ThreadArrivals()
        #expect(arrivals.update([], loaded: false).isEmpty)
        #expect(!arrivals.armed)
        #expect(arrivals.startedLoading)
        #expect(arrivals.update(["u1", "u1/reply"], loaded: true).isEmpty)
        #expect(arrivals.armed)
    }

    @Test func aThreadOpenedLoadedDidNotStartLoading() {
        #expect(!loaded(["u1"]).startedLoading)
    }
}
