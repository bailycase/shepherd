import Testing
import ShepherdRemote

/// Round 3: one gate for automatic writes, takeover decided by intent, obsolete automatic work cancelled on detach.
@Suite("Thread scroll owner: the automatic gate")
struct ThreadScrollOwnerGateTests {
    typealias Owner = ThreadScrollOwner
    typealias Anchor = ThreadScrollOwner.Anchor
    typealias Fixture = ThreadScrollOwnerTests

    // MARK: A. A mount is automatic

    @Test func aMountDecidesNothingWhileTheReaderMovesOrTheDriverAnimatesAndLandsOnceAtRest() {
        for ask in [true, false] {
            for intent in [Owner.Intent.touching, .coasting, .programmatic] {
                let modes: [Owner.Mode] = [.following, .pinned(nil), .jumping(row: "row-2")]
                for mode in modes {
                    var owner = Owner(mode: mode, asksInterruptTouch: ask)
                    owner.setIntent(intent)
                    #expect(owner.mount() == .none, "\(mode) \(intent) asksInterruptTouch \(ask)")
                    #expect(owner.turn() == .none)
                    #expect(!owner.wantsTurn)
                    owner.setIntent(.idle)
                    #expect(owner.wantsTurn)
                    #expect(owner.turn() == .land)
                    #expect(owner.turn() == .none)
                }
            }
        }
    }

    @Test func aMountThatKeepsARowForgetsARowRequestFromBeforeIt() {
        var owner = Fixture.pinned(at: 700, ask: false)
        owner.setIntent(.touching)
        #expect(owner.jumpToRow("row-2") == .none)
        #expect(owner.mount() == .none)
        owner.setIntent(.idle)
        #expect(!owner.wantsTurn)
        #expect(owner.turn() == .none)
        #expect(owner.read(Fixture.reading(offset: 700), intent: .idle) == .none)
        #expect(!owner.isJumping)
    }

    // MARK: B. The reader takes over a jump by intent, not by offset deltas

    @Test func layoutThatMovesTheClipUpAndLeavesTheTailFarAwayDoesNotEndAJump() {
        for intent in [Owner.Intent.idle, .programmatic] {
            var owner = Owner()
            _ = owner.read(Fixture.reading(), intent: .idle)
            _ = owner.jumpToRow("row-2")
            // The clip moved up 10 pt by layout and growth put it 90 pt from the tail: nobody touched it.
            _ = owner.read(Fixture.reading(content: 2080, offset: 1410), intent: intent)
            #expect(owner.mode == .jumping(row: "row-2"), "\(intent)")
        }
    }

    @Test func aDragUpWhileContentGrowsInsideTheBandEndsAJump() {
        for intent in [Owner.Intent.touching, .coasting] {
            var owner = Owner()
            _ = owner.read(Fixture.reading(), intent: .idle)
            _ = owner.jumpToRow("row-2")
            _ = owner.read(Fixture.reading(offset: 1400), intent: .programmatic)
            #expect(owner.isJumping)
            // The reader moves it up 10 pt while the document grows 10 pt: still inside the band, and the reader's.
            _ = owner.read(Fixture.reading(content: 2010, offset: 1390), intent: intent)
            #expect(!owner.isJumping && owner.follows, "\(intent)")
        }
    }

    @Test func aDragDownWhileContentGrowsEndsAJumpToo() {
        var owner = Owner()
        _ = owner.read(Fixture.reading(), intent: .idle)
        _ = owner.jumpToRow("row-2")
        _ = owner.read(Fixture.reading(offset: 1380), intent: .programmatic)
        _ = owner.read(Fixture.reading(content: 2030, offset: 1400), intent: .touching)
        #expect(!owner.isJumping)
    }

    // MARK: C. Obsolete automatic work goes when the reader detaches

    @Test func aLandingPendingWhenTheReaderLeavesTheTailIsNotFiredWhenTheyStop() {
        var owner = Owner()
        _ = owner.read(Fixture.reading(), intent: .idle)
        // Layout keeps moving the tail: the in-pass budget is spent and a landing is left pending.
        for n in 1...12 { _ = owner.read(Fixture.reading(content: 2000 + 100 * Double(n), offset: 1420), intent: .idle) }
        #expect(owner.wantsTurn)
        // The reader drags into history before the turn runs.
        _ = owner.read(Fixture.reading(content: 3200, offset: 700), intent: .touching)
        #expect(!owner.follows)
        owner.setIntent(.idle)
        #expect(owner.turn() == .none)
        #expect(!owner.wantsTurn)
    }

    @Test func theReadersOwnAskForTheTailSurvivesTheirDetach() {
        var owner = Fixture.pinned(ask: false)
        owner.setIntent(.touching)
        #expect(owner.jumpToLatest() == .none)
        _ = owner.read(Fixture.reading(offset: 300), intent: .touching)
        owner.setIntent(.coasting)
        #expect(owner.turn() == .land)
    }

    // MARK: The property

    /// A small deterministic generator: the same scripts on every run.
    struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    static func isReadersAsk(_ outstanding: Owner.Outstanding) -> Bool {
        switch outstanding {
        case .readerLatest, .readerRow: true
        case .none, .autoTail: false
        }
    }

    /// Random event sequences: whatever the events, no decision comes out of an automatic one while the intent is not `idle`. With
    /// `asks` the reader's own requests are in the mix, and a `turn()` may decide under motion only when what it delivers is their
    /// ask (`outstanding`).
    @Test(arguments: [false, true])
    func noAutomaticDecisionWhileTheReaderMovesOrTheDriverAnimates(asks: Bool) {
        var generator = Generator(state: asks ? 7 : 11)
        var checked = 0, moving = 0, decisions = 0
        for script in 0..<400 {
            var owner = Owner(mode: [.following, .pinned(nil), .jumping(row: "row-2")][script % 3], nativeAnchor: script % 2 == 0, asksInterruptTouch: script % 4 < 2)
            var intent = Owner.Intent.idle
            _ = owner.rowsChanged(Fixture.order)
            for _ in 0..<40 {
                var decision = Owner.Decision.none
                var automatic = true
                switch generator.next(asks ? 14 : 11) {
                case 0, 1, 2:
                    intent = [.idle, .touching, .coasting, .programmatic][generator.next(4)]
                    let offset = Double([1420, 1400, 1300, 1000, 700, 300, 1600][generator.next(7)])
                    let content = Double([2000, 2000, 2100, 2400, 1800][generator.next(5)])
                    let drop: Set<String> = generator.next(3) == 0 ? ["row-3", "row-4"] : []
                    decision = owner.read(Fixture.reading(content: content, offset: offset, shift: Double(generator.next(3) * 40), drop: drop), intent: intent)
                case 3:
                    intent = [.idle, .touching, .coasting, .programmatic][generator.next(4)]
                    owner.setIntent(intent)
                case 4, 9:
                    automatic = !Self.isReadersAsk(owner.outstanding)
                    decision = owner.turn()
                case 5: decision = owner.mount()
                case 6: owner.contentArrived()
                case 7:
                    owner.quietPassed()
                    owner.jumpCompleted()
                case 8:
                    var next = Fixture.order
                    for _ in 0..<generator.next(4) { next.remove(at: generator.next(next.count)) }
                    if generator.next(4) == 0 { next = ["new-0", "new-1"] }
                    decision = owner.rowsChanged(next)
                case 10: owner.newSession()
                case 11: decision = owner.jumpToLatest(); automatic = false
                case 12: decision = owner.jumpToRow("row-\(generator.next(10))"); automatic = false
                default: decision = owner.sent(queued: false, turnPresent: generator.next(2) == 0); automatic = false
                }
                checked += 1
                if automatic, intent != .idle {
                    moving += 1
                    #expect(decision == .none, "script \(script): \(decision) with intent \(intent)")
                }
                if decision != .none { decisions += 1 }
            }
        }
        #expect(checked == 16_000)
        // Not vacuous: plenty of events under motion, and plenty of decisions at rest.
        #expect(moving > 3000 && decisions > 500, "moving \(moving), decisions \(decisions)")
    }
}
