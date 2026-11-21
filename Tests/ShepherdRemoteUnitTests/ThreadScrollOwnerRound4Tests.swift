import Testing
import ShepherdRemote

/// Round 3's four findings, each as the sequence the review gave. Written against the public surface the owner had before round 4,
/// so each one fails on the round 3 head.
@Suite("Thread scroll owner: round 3 findings")
struct ThreadScrollOwnerRound4Tests {
    typealias Owner = ThreadScrollOwner
    typealias Anchor = ThreadScrollOwner.Anchor
    typealias Fixture = ThreadScrollOwnerTests

    /// The offset that puts `content` on its tail in the fixture's viewport.
    static func tail(_ content: Double) -> Double { content - 580 }

    // MARK: 1. A completed Jump to Latest does not land a second time

    @Test func aTailAskThatAGrowthReadingLandedIsNotLandedAgainOnTheReadersNextCoast() {
        var owner = Fixture.pinned(at: 700, ask: false)
        owner.setIntent(.touching)
        #expect(owner.jumpToLatest() == .none)
        // The first idle event is a growth reading, before any turn: it lands the ask.
        #expect(owner.read(Fixture.reading(content: 2400, offset: 700), intent: .idle) == .land)
        #expect(owner.read(Fixture.reading(content: 2400, offset: Self.tail(2400)), intent: .idle) == .none)
        // The reader drags into history and lifts into a coast: nothing pulls them back.
        _ = owner.read(Fixture.reading(content: 2400, offset: 900), intent: .touching)
        #expect(!owner.follows)
        owner.setIntent(.coasting)
        #expect(!owner.wantsTurn)
        #expect(owner.turn() == .none)
        owner.setIntent(.idle)
        #expect(owner.turn() == .none)
        #expect(!owner.follows)
    }

    // MARK: 2. A pending Jump to Latest does not reveal the row it left

    @Test func aPendingTailAskHonoredAfterAFartherDragLeavesTheOwnerFollowingAndRevealsNothing() {
        var owner = Fixture.pinned(at: 700, ask: false)
        owner.setIntent(.touching)
        #expect(owner.jumpToLatest() == .none)
        _ = owner.read(Fixture.reading(offset: 300), intent: .touching)
        owner.setIntent(.idle)
        #expect(owner.turn() == .land)
        #expect(owner.follows)
        // The driver feeds back the tail: the row the reader left is not realized there, and nothing asks for it.
        #expect(owner.read(Fixture.reading(), intent: .idle) == .none)
        #expect(owner.follows)
    }

    // MARK: 3. A following thread does not stay off its tail

    @Test func contentThatGrewUnderTheReadersHandIsLandedAtTheFirstIdleTurn() {
        for intent in [Owner.Intent.touching, .coasting] {
            var owner = Owner()
            _ = owner.read(Fixture.reading(), intent: .idle)
            for content in [2100.0, 2200, 2300, 2400] {
                #expect(owner.read(Fixture.reading(content: content, offset: 1420), intent: intent) == .none)
            }
            #expect(owner.follows)
            owner.setIntent(.idle)
            #expect(owner.wantsTurn)
            #expect(owner.turn() == .land)
            #expect(owner.turn() == .none)
        }
    }

    @Test func aLandingTheReplacementBlockedIsOwedAtTheFirstIdleTurn() {
        // Within the slack of the tail, a reader's row is replaced with nothing surviving: they follow, and the landing waits.
        var owner = Owner(mode: .pinned(.init(row: "row-9", offset: 100)))
        _ = owner.rowsChanged(Fixture.order)
        _ = owner.read(Fixture.reading(), intent: .idle)
        owner.setIntent(.touching)
        #expect(owner.rowsChanged(["new-0"]) == .none)
        #expect(owner.follows)
        owner.setIntent(.idle)
        #expect(owner.turn() == .land)
    }

    @Test func aLandingOwedToAFollowerIsForgottenWhenTheReaderLeavesOrTheViewIsBackOnTheTail() {
        var left = Owner()
        _ = left.read(Fixture.reading(), intent: .idle)
        _ = left.read(Fixture.reading(content: 2400, offset: 1420), intent: .touching)
        _ = left.read(Fixture.reading(content: 2400, offset: 900), intent: .touching)
        #expect(!left.follows)
        left.setIntent(.idle)
        #expect(left.turn() == .none)
        var back = Owner()
        _ = back.read(Fixture.reading(), intent: .idle)
        _ = back.read(Fixture.reading(content: 2400, offset: 1420), intent: .touching)
        _ = back.read(Fixture.reading(content: 2400, offset: Self.tail(2400)), intent: .touching)
        back.setIntent(.idle)
        #expect(back.turn() == .none)
    }

    // MARK: 4. A jump ends

    @Test func aJumpDownToALaterRowEndsWhenTheRowArrivesAndPinnedCompensationApplies() {
        var owner = Owner()
        _ = owner.rowsChanged(Fixture.order)
        _ = owner.read(Fixture.reading(content: 3000, offset: Self.tail(3000)), intent: .idle)
        _ = owner.read(Fixture.reading(content: 3000, offset: 400), intent: .touching)
        _ = owner.read(Fixture.reading(content: 3000, offset: 400), intent: .idle)
        #expect(!owner.follows)
        #expect(owner.jumpToRow("row-6") == .scroll(toRow: "row-6", animated: true))
        // Every offset increases; the last stays where the animation left it, far from the tail band.
        for offset in [600.0, 800, 1000, 1200] {
            _ = owner.read(Fixture.reading(content: 3000, offset: offset), intent: .programmatic)
        }
        _ = owner.read(Fixture.reading(content: 3000, offset: 1200), intent: .idle)
        #expect(owner.mode == .pinned(Anchor(row: "row-6", offset: 0)))
        // Growth above the destination moves it away from the reader: it is put back.
        let grown = Fixture.reading(content: 3300, offset: 1200, shift: 300)
        #expect(owner.read(grown, intent: .idle) == .hold(Anchor(row: "row-6", offset: 0)))
    }

    @Test func anUpwardJumpWhoseEveryReadingCoincidesWithGrowthEndsWhenTheRowArrives() {
        var owner = Owner()
        _ = owner.rowsChanged(Fixture.order)
        _ = owner.read(Fixture.reading(content: 3000, offset: 1600), intent: .idle)
        _ = owner.read(Fixture.reading(content: 3000, offset: 1600), intent: .touching)
        _ = owner.read(Fixture.reading(content: 3000, offset: 1500), intent: .touching)
        _ = owner.read(Fixture.reading(content: 3000, offset: 1500), intent: .idle)
        #expect(!owner.follows)
        _ = owner.jumpToRow("row-2")
        for (n, offset) in [1000.0, 700, 400].enumerated() {
            _ = owner.read(Fixture.reading(content: 3010 + 10 * Double(n), offset: offset), intent: .programmatic)
        }
        #expect(owner.mode == .pinned(Anchor(row: "row-2", offset: 0)))
    }
}
