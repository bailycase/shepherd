import Testing
import ShepherdRemote

/// Round 4's two findings, as the sequences the review gave, and what the exhaustive walk found beside them
/// (`ThreadScrollOwnerExhaustiveTests`).
@Suite("Thread scroll owner: round 4 findings")
struct ThreadScrollOwnerRound5Tests {
    typealias Owner = ThreadScrollOwner
    typealias Anchor = ThreadScrollOwner.Anchor
    typealias Fixture = ThreadScrollOwnerTests

    static func atTail(ask interrupts: Bool = true) -> Owner {
        var owner = Owner(asksInterruptTouch: interrupts)
        _ = owner.rowsChanged(Fixture.order)
        _ = owner.read(Fixture.reading(), intent: .idle)
        return owner
    }

    @Test func anUpwardJumpIsNotEndedByAnIntermediateOffsetAndTheArrivalIsNotUndone() {
        var owner = Self.atTail()
        #expect(owner.jumpToRow("row-2") == .scroll(toRow: "row-2", animated: true))
        #expect(owner.read(Fixture.reading(offset: 1200), intent: .programmatic) == .none)
        #expect(owner.isJumping)
        // The row arrives at the top, and the content grew in the same reading: nothing reveals the row the animation passed.
        #expect(owner.read(Fixture.reading(content: 2100, offset: 400), intent: .idle) == .none)
        #expect(owner.mode == .pinned(Anchor(row: "row-2", offset: 0)))
    }

    @Test(arguments: [true, false])
    func aFractionalArrivalKeepsTheRequestedRow(asksInterruptTouch: Bool) {
        var owner = Self.atTail(ask: asksInterruptTouch)
        #expect(owner.jumpToRow("row-2") == .scroll(toRow: "row-2", animated: true))
        #expect(owner.read(Fixture.reading(content: 2100, offset: 399.5), intent: .programmatic) == .none)
        #expect(owner.read(Fixture.reading(content: 2200, offset: 399.5, shift: -0.5), intent: .idle) == .none)
        #expect(owner.mode == .pinned(Anchor(row: "row-2", offset: 0.5)))
    }

    @Test func aReplacementDoesNotRevealTheFallbackAheadOfAWaitingAsk() {
        var owner = Self.atTail(ask: false)
        #expect(owner.read(Fixture.reading(offset: 1200), intent: .idle) == .none)
        owner.setIntent(.touching)
        #expect(owner.jumpToRow("row-2") == .none)
        owner.setIntent(.idle)
        #expect(owner.rowsChanged(Fixture.order.filter { $0 != "row-6" }) == .none)
        #expect(owner.mode == .pinned(Anchor(row: "row-5", offset: 0)))
        #expect(owner.turn() == .scroll(toRow: "row-2", animated: true))
        #expect(owner.turn() == .none)
    }

    @Test(arguments: [true, false])
    func aSendWithItsTurnAlreadyPresentDoesNotForgetAnOwedLanding(asksInterruptTouch: Bool) {
        var owner = Self.atTail(ask: asksInterruptTouch)
        owner.setIntent(.touching)
        #expect(owner.read(Fixture.reading(content: 2400), intent: .touching) == .none)
        #expect(owner.sent(queued: false, turnPresent: true) == .none)
        owner.setIntent(.idle)
        #expect(owner.turn() == .land)
        #expect(owner.turn() == .none)
    }

    @Test func aSendKeepsJumpToLatestWaitingForTheFinger() {
        var owner = Self.atTail(ask: false)
        owner.setIntent(.touching)
        #expect(owner.read(Fixture.reading(offset: 700), intent: .touching) == .none)
        #expect(owner.jumpToLatest() == .none)
        #expect(owner.sent(queued: false, turnPresent: true) == .none)
        owner.setIntent(.idle)
        #expect(owner.wantsTurn)
        #expect(owner.turn() == .land)
        #expect(owner.turn() == .none)
    }

    @Test func twoSendsUnderOneFingerFromHistoryLandOnceOnLift() {
        var owner = Fixture.pinned(ask: false)
        owner.setIntent(.touching)
        #expect(owner.sent(queued: false, turnPresent: true) == .none)
        #expect(owner.sent(queued: false, turnPresent: true) == .none)
        owner.setIntent(.idle)
        #expect(owner.wantsTurn)
        #expect(owner.turn() == .land)
        #expect(owner.turn() == .none)
    }

    @Test func anIdleResizeDoesNotLandAheadOfAWaitingTailAsk() {
        var owner = Self.atTail(ask: false)
        owner.setIntent(.touching)
        #expect(owner.jumpToLatest() == .none)
        #expect(owner.read(Fixture.reading(container: 460, width: 500), intent: .idle) == .none)
        #expect(owner.turn() == .land)
        #expect(owner.turn() == .none)
    }

    @Test func aWidthOnlyResizeIsLayoutRatherThanReaderMotion() {
        var owner = Self.atTail()
        #expect(owner.read(Fixture.reading(offset: 1400, width: 500), intent: .idle) == .land)
        #expect(owner.follows)
    }

    @Test func aNativeShrinkInvalidatesAnOlderLandingUntilTheOverrunIsStable() {
        var owner = Self.atTail()
        #expect(owner.read(Fixture.reading(content: 2400), intent: .touching) == .none)
        let shrunk = Fixture.reading(content: 1800)
        #expect(owner.read(shrunk, intent: .idle) == .none)
        #expect(owner.turn() == .none)
        #expect(owner.read(shrunk, intent: .idle) == .land)
        #expect(owner.turn() == .none)
    }

    @Test func aRevealedRowNoLongerMasksAnIdleReaderDisplacement() {
        var owner = Fixture.pinned(at: 1200)
        #expect(owner.read(Fixture.reading(content: 2400), intent: .idle) == .reveal("row-6"))
        #expect(owner.read(Fixture.reading(offset: 1200), intent: .programmatic) == .none)
        #expect(owner.read(Fixture.reading(offset: 1100), intent: .idle) == .none)
        #expect(owner.mode == .pinned(Anchor(row: "row-5", offset: -100)))
    }

    @Test func aClampedJumpKeepsAVisibleSurvivorWhenItsLastReadingNamesADeletedTopRow() {
        var owner = Self.atTail()
        #expect(owner.jumpToRow("row-2") == .scroll(toRow: "row-2", animated: true))
        #expect(owner.read(Fixture.reading(offset: 1200), intent: .idle) == .none)
        #expect(owner.rowsChanged(Fixture.order.filter { $0 != "row-6" }) == .none)
        owner.jumpCompleted()
        #expect(owner.kept == .pinned(Anchor(row: "row-7", offset: 200)))
        #expect(owner.rowsChanged(Fixture.order.filter { $0 != "row-6" && $0 != "row-2" }) == .none)
        #expect(owner.mount() == .none)
    }

    @Test func aJumpWhoseRowIsAtTheTopOfItsFirstReadingHasArrived() {
        var owner = Owner(mode: .jumping(row: "row-2"))
        _ = owner.rowsChanged(Fixture.order)
        #expect(owner.read(Fixture.reading(content: 2100, offset: 400), intent: .idle) == .none)
        #expect(owner.mode == .pinned(Anchor(row: "row-2", offset: 0)))
    }

    @Test func aRowAskCancelledByTheRowsRemovalOwesTheFollowerItsLanding() {
        var owner = Self.atTail(ask: false)
        owner.setIntent(.touching)
        #expect(owner.jumpToRow("row-2") == .none)
        #expect(owner.read(Fixture.reading(content: 2400, offset: 1420), intent: .touching) == .none)
        #expect(owner.rowsChanged(Fixture.order.filter { $0 != "row-2" }) == .none)
        owner.setIntent(.idle)
        #expect(owner.wantsTurn)
        #expect(owner.turn() == .land)
        #expect(owner.turn() == .none)
    }

    @Test func growthBeforeAnAskAndTheAsksRemovalAfterIt() {
        var owner = Self.atTail(ask: false)
        owner.setIntent(.touching)
        _ = owner.read(Fixture.reading(content: 2400, offset: 1420), intent: .touching)
        #expect(owner.jumpToRow("row-2") == .none)
        _ = owner.rowsChanged(Fixture.order.filter { $0 != "row-2" })
        owner.setIntent(.idle)
        #expect(owner.turn() == .land)
    }

    @Test func anIdleGrowthReadingDoesNotLandOverTheReadersRowAsk() {
        var owner = Self.atTail(ask: false)
        owner.setIntent(.touching)
        #expect(owner.jumpToRow("row-2") == .none)
        // The finger lifts and the layout grows before the turn: the reader's ask wins, and it is the only decision.
        #expect(owner.read(Fixture.reading(content: 2400, offset: 1420), intent: .idle) == .none)
        #expect(owner.turn() == .scroll(toRow: "row-2", animated: true))
        #expect(owner.turn() == .none)
    }

    @Test func aJumpWhoseRowLeavesWhileTheViewIsInTheBandLeavesAFollower() {
        var owner = Self.atTail()
        _ = owner.jumpToRow("row-2")
        _ = owner.rowsChanged(Fixture.order.filter { $0 != "row-2" })
        #expect(owner.follows)
        #expect(owner.read(Fixture.reading(content: 2400, offset: 1420), intent: .idle) == .land)
    }

    @Test func aRowAskWaitingForTheFingerIsNotPassedByTheRowTheMountKept() {
        var owner = Fixture.pinned(at: 700, ask: false)
        _ = owner.mount()
        owner.setIntent(.touching)
        #expect(owner.jumpToRow("row-2") == .none)
        // The first reading after the mount would put the kept row back; the ask goes instead.
        #expect(owner.read(Fixture.reading(offset: 1420), intent: .idle) == .none)
        #expect(owner.turn() == .scroll(toRow: "row-2", animated: true))
    }
}
