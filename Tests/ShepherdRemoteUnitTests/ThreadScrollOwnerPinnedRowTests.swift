import Testing
import ShepherdRemote

/// `docs/plans/thread-scroll.md` D3: a pinned row the owner cannot hold. Not realized, replaced, or gone with everything around it.
@Suite("Thread scroll owner: pinned row that cannot be held")
struct ThreadScrollOwnerPinnedRowTests {
    typealias Owner = ThreadScrollOwner
    typealias Anchor = ThreadScrollOwner.Anchor
    typealias Fixture = ThreadScrollOwnerTests

    // MARK: 1. Not realized

    @Test func aRowTheLazyStackDroppedIsRevealedOnceThenHeld() {
        var owner = Fixture.pinned(at: 700)
        // The stack unrealized row-3 and the rows around it; the order still has it.
        let gone = Fixture.reading(offset: 700, drop: ["row-2", "row-3", "row-4"])
        #expect(owner.read(.init(probe: gone.probe, topRow: nil, rows: gone.rows), intent: .idle) == .reveal("row-3"))
        // Asked once: further readings with the row still missing wait for it.
        #expect(owner.read(.init(probe: Fixture.probe(content: 2100, offset: 700), rows: gone.rows), intent: .idle) == .none)
        #expect(owner.read(.init(probe: Fixture.probe(content: 2200, offset: 700), rows: gone.rows), intent: .idle) == .none)
        // It shows up 140 pt off where it was kept (the reveal landed it, or the estimate was wrong): held, not re-anchored.
        let back = Fixture.reading(content: 2200, offset: 560)
        #expect(owner.read(back, intent: .idle) == .hold(Anchor(row: "row-3", offset: -100)))
    }

    @Test func aRevealedRowThatNeverShowsIsNotAskedForAgainByLayoutAlone() {
        var owner = Fixture.pinned(at: 700)
        let gone = Fixture.reading(offset: 700, drop: ["row-3"])
        var reveals = 0
        for n in 0..<5 {
            let reading = ThreadScrollOwner.Reading(probe: Fixture.probe(content: 2000 + Double(n) * 30, offset: 700), rows: gone.rows)
            if owner.read(reading, intent: .idle) == .reveal("row-3") { reveals += 1 }
        }
        #expect(reveals == 1)
    }

    @Test func aStructureChangeThatKeepsTheRowAsksForNothingByItself() {
        // A history page joins above: the pinned row is still in the order, and the next reading shows how far it moved.
        var owner = Fixture.pinned(at: 700)
        let paged = (0..<4).map { "older-\($0)" } + Fixture.order
        #expect(owner.rowsChanged(paged) == .none)
        #expect(owner.mode == .pinned(Anchor(row: "row-3", offset: -100)))
        let shifted = Fixture.reading(content: 2300, offset: 700, shift: 300)
        #expect(owner.read(shifted, intent: .idle) == .hold(Anchor(row: "row-3", offset: -100)))
    }

    // MARK: 2. Replaced

    @Test func aReplacedRowFallsBackToTheNearestSurvivorAboveBeforeBelow() {
        var owner = Fixture.pinned(at: 700)
        let next = Fixture.order.filter { $0 != "row-3" }
        #expect(owner.rowsChanged(next) == .reveal("row-2"))
        #expect(owner.mode == .pinned(Anchor(row: "row-2", offset: -100)))
    }

    @Test func whenTheRowsAboveAreGoneTooTheNearestBelowIsUsed() {
        var owner = Fixture.pinned(at: 700)
        let next = Fixture.order.filter { !["row-1", "row-2", "row-3"].contains($0) }
        #expect(owner.rowsChanged(next) == .reveal("row-4"))
        #expect(owner.mode == .pinned(Anchor(row: "row-4", offset: -100)))
    }

    @Test func theSubstituteIsThenHeldLikeAnyPinnedRow() {
        var owner = Fixture.pinned(at: 700)
        _ = owner.rowsChanged(Fixture.order.filter { $0 != "row-3" })
        // row-2 shows 50 pt from where it is kept: put there.
        let reading = Fixture.reading(content: 2000, offset: 450)
        #expect(owner.read(reading, intent: .idle) == .hold(Anchor(row: "row-2", offset: -100)))
    }

    @Test func aReplacedRowDecidesNothingWhileTheReaderMovesOrTheDriverAnimates() {
        for intent in [Owner.Intent.touching, .coasting, .programmatic] {
            var owner = Fixture.pinned(at: 700)
            // The motion is already under way when the structure changes: the event itself must not write.
            owner.setIntent(intent)
            #expect(owner.rowsChanged(Fixture.order.filter { $0 != "row-3" }) == .none)
            // The reader's place is what the view shows, not the row the store lost.
            let reading = Fixture.reading(content: 2000, offset: 710, drop: ["row-3"])
            #expect(owner.read(reading, intent: intent) == .none)
            #expect(owner.mode == .pinned(Anchor(row: "row-4", offset: 90)))
        }
    }

    @Test func aReplacedRowIsRevealedOnceTheReaderLetsGo() {
        var owner = Fixture.pinned(at: 700)
        owner.setIntent(.touching)
        _ = owner.rowsChanged(Fixture.order.filter { $0 != "row-3" })
        owner.setIntent(.idle)
        // No reading re-anchored them while moving, so the substitute is still what is kept.
        #expect(owner.read(Fixture.reading(offset: 700, drop: ["row-2"]), intent: .idle) == .reveal("row-2"))
    }

    @Test func aMountedPinnedRowDecidesNothingOnItsFirstReadingWhileTheReaderMoves() {
        for intent in [Owner.Intent.touching, .coasting, .programmatic] {
            for gone: Set<String> in [[], ["row-3"]] {
                var owner = Fixture.pinned(at: 700)
                #expect(owner.mount() == .none)
                // Off its place, or not built: at rest that is a hold or a reveal; under the reader's hand it is neither.
                let reading = Fixture.reading(offset: 400, drop: gone)
                #expect(owner.read(reading, intent: intent) == .none)
                #expect(owner.mode == .pinned(Anchor(row: "row-2", offset: 0)))
            }
        }
    }

    // MARK: 3. Nothing survives

    @Test func ifNothingSurvivesAReaderNearTheTailFollowsAndLands() {
        var owner = Fixture.pinned(at: 700)
        // The reader had come within the slack of the tail (a layout clamp left them detached: paging there would re-attach): the whole transcript is replaced.
        _ = owner.read(Fixture.reading(content: 1999, offset: 1418), intent: .idle)
        #expect(!owner.follows)
        #expect(owner.rowsChanged(["new-0", "new-1"]) == .land)
        #expect(owner.follows)
    }

    @Test func nothingSurvivingLandsNobodyWhoseHandIsOnTheThread() {
        for intent in [Owner.Intent.touching, .coasting, .programmatic] {
            var owner = Fixture.pinned(at: 700)
            _ = owner.read(Fixture.reading(content: 1999, offset: 1418), intent: .idle)
            owner.setIntent(intent)
            #expect(owner.rowsChanged(["new-0", "new-1"]) == .none)
            #expect(owner.follows)
            #expect(owner.turn() == .none)
        }
    }

    @Test func ifNothingSurvivesAReaderFarFromTheTailKeepsNothingAndIsAnchoredWhereTheyAre() {
        var owner = Fixture.pinned(at: 700)
        #expect(owner.rowsChanged(["new-0", "new-1"]) == .none)
        #expect(owner.mode == .pinned(nil))
        let reading = ThreadScrollOwner.Reading(probe: Fixture.probe(offset: 700), topRow: "new-0", rows: ["new-0": -40, "new-1": 160])
        #expect(owner.read(reading, intent: .idle) == .none)
        #expect(owner.mode == .pinned(Anchor(row: "new-0", offset: -40)))
    }
}
