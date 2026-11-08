import Testing
import ShepherdRemote

/// The bound on landing a stuck thread on its tail again (ios-duo-1): a layout that never settles
/// stops being chased after a few landings that do not help, while streaming, the composer, the
/// keyboard and the side pane's width animation are followed for as long as they last. Every turn
/// is one run-loop turn as the iOS pin sees it: its readings and events, then `take()`.
@Suite("Scroll follower: landing after layout")
struct ScrollFollowerRepinTests {
    /// What one turn brought: where the reading left the tail, and what moved it.
    struct Turn {
        var gap: Double
        var wants = true
        var resized = false
        var output = false
    }

    /// Replays `turns` and counts the landings the repin allowed.
    @discardableResult
    static func replay(_ repin: inout NativeTailRepin, _ turns: [Turn]) -> Int {
        var landings = 0
        for turn in turns {
            if turn.output { repin.outputArrived() }
            repin.reading(distance: turn.gap, wants: turn.wants, resized: turn.resized)
            if repin.take() { landings += 1 }
        }
        return landings
    }

    /// A tail that bounces between two heights without ever resting, until the repin gives up.
    static func stalled() -> NativeTailRepin {
        var repin = NativeTailRepin()
        replay(&repin, [Turn(gap: 16_000)] + (0..<20).map { Turn(gap: $0.isMultiple(of: 2) ? 3_000 : 3_200) })
        return repin
    }

    // MARK: A layout that does not settle

    @Test func aTailThatNeverSettlesStopsLanding() {
        var repin = NativeTailRepin()
        let landings = Self.replay(&repin, [Turn(gap: 16_000)] + (0..<60).map { Turn(gap: $0.isMultiple(of: 2) ? 3_000 : 3_200) })
        #expect(landings <= 2 * NativeTailRepin.limit + 1)
        #expect(repin.stalled)
        #expect(repin.misses == NativeTailRepin.limit)
    }

    /// Without the bound, the follower asks again on every one of those readings.
    @Test func theFollowerAloneAsksOnAllSixty() {
        let container = 520.0, insetTop = 60.0
        func probe(content: Double, distance: Double) -> NativeScrollProbe {
            NativeScrollProbe(content: content, offset: content - distance - container - insetTop, container: container,
                              insetTop: insetTop, insetBottom: 120)
        }
        var follower = NativeScrollFollower()
        var old = probe(content: 26_000, distance: 16_000)
        var asks = 0
        for i in 0..<60 {
            let new = probe(content: i.isMultiple(of: 2) ? 24_000 : 24_200, distance: i.isMultiple(of: 2) ? 3_000 : 3_200)
            if follower.observe(from: old, to: new, gesture: false, nativeAnchor: false) { asks += 1 }
            old = new
        }
        #expect(asks == 60)
    }

    @Test func pastTheTailCountsLikeAboveIt() {
        var repin = NativeTailRepin()
        func take() -> Bool { repin.take() }
        let landings = Self.replay(&repin, [Turn(gap: -16_000)] + (0..<60).map { Turn(gap: $0.isMultiple(of: 2) ? -3_000 : 3_200) })
        #expect(landings <= 2 * NativeTailRepin.limit + 1)
        #expect(repin.stalled)
        repin.reading(distance: -2, wants: true, resized: false)
        #expect(!take())
        #expect(!repin.stalled)
    }

    // MARK: A layout that settles, or keeps changing for a reason

    @Test func aConvergingTailLandsUntilItRests() {
        var repin = NativeTailRepin()
        let landings = Self.replay(&repin, [800, 400, 200, 100, 50, 20, 8, 2].map { Turn(gap: $0) })
        #expect(landings == 7)
        #expect(!repin.stalled)
        #expect(repin.misses == 0)
        #expect(!repin.pending)
    }

    @Test func aStreamingReplyIsFollowedEveryTurn() {
        var repin = NativeTailRepin()
        let landings = Self.replay(&repin, Array(repeating: Turn(gap: 40, output: true), count: 300))
        #expect(landings == 300)
        #expect(!repin.stalled)
        #expect(repin.misses == 0)
    }

    @Test func aTailThatRestsBetweenChangesNeverStops() {
        var repin = NativeTailRepin()
        let landings = Self.replay(&repin, (0..<100).flatMap { _ in [Turn(gap: 600), Turn(gap: 650), Turn(gap: 0, wants: false)] })
        #expect(landings == 200)
        #expect(!repin.stalled)
        #expect(repin.misses == 0)
    }

    @Test func aWidthAnimationNeverStalls() {
        // The side pane's 0.18 s ease at 120 Hz: the rows re-wrap every frame, the gap rises and falls.
        let gaps: [Double] = [40, 150, 330, 560, 800, 1_000, 1_150, 1_230, 1_260, 1_250, 1_200, 1_100,
                              950, 780, 600, 440, 300, 190, 110, 60, 30, 12]
        #expect(gaps.count == 22)
        var repin = NativeTailRepin()
        let landings = Self.replay(&repin, gaps.map { Turn(gap: $0, resized: true) })
        #expect(landings == 22)
        #expect(!repin.stalled)
        #expect(repin.misses == 0)
    }

    @Test func aResizeThatNeverEndsStopsAtTheCeiling() {
        var repin = NativeTailRepin()
        let landings = Self.replay(&repin, Array(repeating: Turn(gap: 500, resized: true), count: 200))
        #expect(landings == NativeTailRepin.maxRun)
        #expect(repin.stalled)
        #expect(repin.misses == 0)
    }

    @Test func outputRestartsTheRun() {
        var repin = NativeTailRepin()
        let resized = Turn(gap: 500, resized: true)
        let before = Self.replay(&repin, Array(repeating: resized, count: NativeTailRepin.maxRun - 1))
        let streamed = Self.replay(&repin, [Turn(gap: 500, resized: true, output: true)])
        let after = Self.replay(&repin, Array(repeating: resized, count: NativeTailRepin.maxRun - 1))
        #expect(before + streamed + after == 2 * NativeTailRepin.maxRun - 1)
        #expect(!repin.stalled)
    }

    // MARK: The distance a landing is measured from

    private static func probe(content: Double, distance: Double) -> NativeScrollProbe {
        NativeScrollProbe(content: content, offset: content - distance - 540 - 60, container: 540, insetTop: 60, insetBottom: 120)
    }

    @Test func aLandedViewReadsZeroFromTheMarker() {
        let landed = Self.probe(content: 20_000, distance: 16)
        #expect(NativeTailRepin.distance(of: landed, belowMarker: 16) == 0)
        #expect(NativeTailRepin.distance(of: Self.probe(content: 20_000, distance: 616), belowMarker: 16) == 600)
        #expect(NativeTailRepin.distance(of: Self.probe(content: 20_000, distance: -8), belowMarker: 16) == -24)
    }

    /// Content that overflows by less than the padding lands at its top, short of the marker.
    @Test func aThreadThatOverflowsByLessThanItsPaddingRests() {
        for overflow in [6.0, 10, 14] {
            let landed = Self.probe(content: 540 + overflow, distance: overflow)
            #expect(NativeTailRepin.distance(of: landed, belowMarker: 16) == 0)
            var repin = NativeTailRepin()
            let landings = Self.replay(&repin, Array(repeating: Turn(gap: NativeTailRepin.distance(of: landed, belowMarker: 16)), count: 20))
            #expect(landings == 0)
            #expect(!repin.pending)
            #expect(!repin.stalled)
        }
    }

    @Test func aThreadThatFitsReadsNegative() {
        #expect(NativeTailRepin.distance(of: Self.probe(content: 400, distance: -140), belowMarker: 16) == -140)
    }

    // MARK: Turns

    @Test func readingsInOneTurnLandOnce() {
        var repin = NativeTailRepin()
        func take() -> Bool { repin.take() }
        for gap in [900.0, 700, 650, 640, 640] { repin.reading(distance: gap, wants: true, resized: false) }
        #expect(repin.pending)
        #expect(take())
        #expect(!repin.pending)
        #expect(!take())
    }

    @Test func aReadingBackOnTheTailCancelsTheLanding() {
        var repin = NativeTailRepin()
        func take() -> Bool { repin.take() }
        repin.reading(distance: 600, wants: true, resized: false)
        repin.reading(distance: 0, wants: false, resized: false)
        #expect(!repin.pending)
        #expect(!take())
    }

    @Test func aReadingThatDoesNotAskLandsNothing() {
        var repin = NativeTailRepin()
        func take() -> Bool { repin.take() }
        repin.reading(distance: 600, wants: false, resized: false)
        #expect(!take())
    }

    // MARK: The reader

    @Test func noLandingWhileTheReaderScrolls() {
        var repin = NativeTailRepin()
        func take() -> Bool { repin.take() }
        repin.reading(distance: 600, wants: true, resized: false)
        repin.reader(scrolling: true, touching: true)
        #expect(!take())
        #expect(repin.pending)
        repin.reader(scrolling: false, touching: false)
        #expect(take())
    }

    /// The flick was let go: the thread coasts on its own, and no landing of its own pulls it back.
    @Test func anAutomaticLandingStillWaitsForTheCoast() {
        var repin = NativeTailRepin()
        func take() -> Bool { repin.take() }
        repin.reader(scrolling: true, touching: true)
        repin.reader(scrolling: true, touching: false)
        repin.reading(distance: 600, wants: true, resized: false)
        repin.outputArrived()
        #expect(!repin.wantsTurn)
        #expect(!take())
        #expect(repin.pending)
        repin.reader(scrolling: false, touching: false)
        #expect(repin.wantsTurn)
        #expect(take())
    }

    @Test func theReaderLettingGoStartsAFreshBudget() {
        var repin = Self.stalled()
        #expect(repin.stalled)
        repin.reader(scrolling: true, touching: true)
        #expect(repin.stalled)
        repin.reader(scrolling: false, touching: false)
        #expect(!repin.stalled)
        #expect(repin.misses == 0)
        #expect(repin.quietWait == NativeTailRepin.quiet)
    }

    @Test func theReaderAskingLandsAtOnceWithAFreshBudget() {
        var repin = Self.stalled()
        func take() -> Bool { repin.take() }
        repin.reading(distance: 3_200, wants: true, resized: false)
        #expect(!take())
        repin.asked()
        #expect(take())
        #expect(!repin.stalled)
        #expect(repin.misses == 0)
        // Whatever the gap: asking lands even where the tail already rests.
        repin.reading(distance: 0, wants: false, resized: false)
        repin.asked()
        #expect(take())
    }

    @Test func askingWhileTheReaderScrollsWaitsForTheFingerToLift() {
        var repin = NativeTailRepin()
        func take() -> Bool { repin.take() }
        // A finger down but not yet moving holds it back too, and so does a drag.
        repin.reader(scrolling: true, touching: true)
        repin.asked()
        #expect(!repin.wantsTurn)
        #expect(!take())
        // Let go of a drag and the thread coasts: the ask lands.
        repin.reader(scrolling: true, touching: false)
        #expect(repin.wantsTurn)
        #expect(take())
        #expect(!take())

        // Let go without a coast (a tap): the same.
        repin.reader(scrolling: false, touching: false)
        repin.reader(scrolling: true, touching: true)
        repin.asked()
        #expect(!take())
        repin.reader(scrolling: false, touching: false)
        #expect(repin.wantsTurn)
        #expect(take())
    }

    /// The jump pill and a send are not the reader's flick coming back: landing is what stops the
    /// coast, and holding the ask until the coast ends loses it, since the coast's end reads a
    /// thread far from the tail and detaches again.
    @Test func askingWhileTheThreadCoastsLandsAtOnce() {
        var repin = NativeTailRepin()
        func take() -> Bool { repin.take() }
        repin.reader(scrolling: true, touching: true)
        repin.reader(scrolling: true, touching: false)
        repin.reading(distance: 2_200, wants: false, resized: false)
        repin.asked()
        #expect(repin.wantsTurn)
        #expect(take())
        #expect(!repin.wantsTurn)
        #expect(!take())
    }

    @Test func askingWhileTheThreadCoastsOverMovingRowsLandsOnce() {
        var repin = Self.stalled()
        func take() -> Bool { repin.take() }
        repin.reader(scrolling: true, touching: false)
        repin.reading(distance: 3_200, wants: true, resized: true)
        repin.outputArrived()
        repin.asked()
        #expect(take())
        // The ask took the turn's output and resize with it, and gave a fresh budget.
        #expect(!repin.stalled)
        #expect(repin.misses == 0)
        #expect(!repin.pending)
        #expect(!take())
    }

    // MARK: Turns wanted

    @Test func aTurnIsWantedOnlyWhereItCouldLand() {
        var repin = NativeTailRepin()
        #expect(!repin.wantsTurn)
        repin.reading(distance: 600, wants: false, resized: false)
        #expect(!repin.wantsTurn)
        repin.reading(distance: 600, wants: true, resized: false)
        #expect(repin.wantsTurn)
        _ = repin.take()
        #expect(!repin.wantsTurn)
        repin.outputArrived()
        #expect(repin.wantsTurn)
        _ = repin.take()
        repin.asked()
        #expect(repin.wantsTurn)
        _ = repin.take()
        #expect(!repin.wantsTurn)
    }

    // MARK: A stall

    @Test func outputWhileStalledGetsOneTry() {
        var repin = Self.stalled()
        func take() -> Bool { repin.take() }
        repin.reading(distance: 3_200, wants: true, resized: false)
        #expect(!take())
        repin.outputArrived()
        repin.reading(distance: 3_000, wants: true, resized: false)
        #expect(take())
        repin.reading(distance: 3_200, wants: true, resized: false)
        #expect(!take())
        #expect(repin.stalled)
    }

    @Test func restingEndsAStall() {
        var repin = Self.stalled()
        func take() -> Bool { repin.take() }
        repin.reading(distance: 0, wants: false, resized: false)
        #expect(!repin.stalled)
        #expect(repin.misses == 0)
        repin.reading(distance: 700, wants: true, resized: false)
        #expect(take())
    }

    @Test func quietGivesOneTryAndBacksOff() {
        var repin = Self.stalled()
        func take() -> Bool { repin.take() }
        var waits: [Duration] = []
        for _ in 0..<NativeTailRepin.maxQuietTries {
            waits.append(repin.quietWait)
            repin.quietPassed()
            #expect(take())
            // The layout still moves, and the try is not repeated until the next quiet.
            repin.reading(distance: 3_200, wants: true, resized: false)
            #expect(!take())
        }
        #expect(waits == [.milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800), .milliseconds(1_600)])
        repin.quietPassed()
        #expect(!take())
    }

    @Test func aQuietTryOnlyHappensWhileStalled() {
        var repin = NativeTailRepin()
        func take() -> Bool { repin.take() }
        repin.reading(distance: 600, wants: true, resized: false)
        repin.quietPassed()
        #expect(repin.quietWait == NativeTailRepin.quiet)
        #expect(take())
        repin.reading(distance: 3_000, wants: true, resized: false)
        #expect(take())
    }

    // MARK: The first landings, in the layout pass

    @Test func aFreshPinLandsInThePassThatAsks() {
        var repin = NativeTailRepin()
        func takeInPass() -> Bool { repin.takeInPass() }
        func take() -> Bool { repin.take() }
        repin.reading(distance: 27_400, wants: true, resized: false)
        #expect(takeInPass())
        #expect(repin.landings == 1)
        #expect(!repin.pending)
        #expect(!take())
    }

    /// A follower that asks at the tail moves nothing, but while a mount settles its landing keeps the
    /// tail anchored; it counts against the pin's limit all the same.
    @Test func anAskAtRestLandsInThePassAndCounts() {
        var repin = NativeTailRepin()
        func takeInPass() -> Bool { repin.takeInPass() }
        repin.reading(distance: 0, wants: true, resized: false)
        #expect(takeInPass())
        #expect(repin.landings == 1)
        #expect(!takeInPass())
    }

    /// The P0's layout asked again inside every pass it caused. Whatever it asks, passes land `inPassLimit` times.
    @Test func aLayoutThatKeepsAskingLandsInItsPassesLimitedTimes() {
        var repin = NativeTailRepin()
        var inPass = 0, deferred = 0
        for i in 0..<200 {
            repin.reading(distance: i.isMultiple(of: 2) ? 3_000 : 3_200, wants: true, resized: true)
            if repin.takeInPass() { inPass += 1 }
            if repin.take() { deferred += 1 }
        }
        #expect(inPass == NativeTailRepin.inPassLimit)
        #expect(deferred > 0)
        #expect(repin.landings == inPass + deferred)
    }

    /// A pass that gets the tail no nearer is a miss like a turn's, and stalls the pin before the limit.
    @Test func passesThatMakeNoHeadwayStall() {
        var repin = NativeTailRepin()
        var inPass = 0
        for i in 0..<200 {
            repin.reading(distance: i.isMultiple(of: 2) ? 3_000 : 3_200, wants: true, resized: false)
            if repin.takeInPass() { inPass += 1 }
        }
        #expect(repin.stalled)
        #expect(inPass == 2 * NativeTailRepin.limit - 1)
        #expect(inPass < NativeTailRepin.inPassLimit)
    }

    /// The pin reports a stall by comparing `stalled` around the call that can set it. A stall in a pass
    /// is seen there and nowhere else: readings that follow ask for no turn (`pending` with `stalled`
    /// takes none) and a turn finds the pin stalled already.
    @Test func aStallInsideAPassChangesTheStateTheCallReturnsWith() {
        var repin = NativeTailRepin()
        func take() -> Bool { repin.take() }
        var seenInPass = 0
        for i in 0..<20 {
            repin.reading(distance: i.isMultiple(of: 2) ? 3_000 : 3_200, wants: true, resized: false)
            let stalled = repin.stalled
            _ = repin.takeInPass()
            if repin.stalled, !stalled { seenInPass += 1 }
        }
        #expect(seenInPass == 1)
        repin.reading(distance: 3_100, wants: true, resized: false)
        #expect(repin.stalled)
        #expect(!take())
        #expect(repin.stalled)
    }

    /// The same pin that stalls in a pass is not stalled by one that makes headway.
    @Test func passesThatMakeHeadwayDoNotChangeTheStall() {
        var repin = NativeTailRepin()
        func takeInPass() -> Bool { repin.takeInPass() }
        for gap in [3_000.0, 2_000, 1_000, 500, 200, 100] {
            repin.reading(distance: gap, wants: true, resized: false)
            #expect(takeInPass())
            #expect(!repin.stalled)
        }
    }

    @Test func aPinThatHasLandedEnoughTakesNoPassAfterwards() {
        var repin = NativeTailRepin()
        func takeInPass() -> Bool { repin.takeInPass() }
        func take() -> Bool { repin.take() }
        for _ in 0..<NativeTailRepin.inPassLimit {
            repin.asked()
            #expect(take())
        }
        repin.reading(distance: 600, wants: true, resized: false)
        #expect(!takeInPass())
        #expect(repin.pending)
        #expect(take())
    }

    @Test func aReadingThatAsksNothingTakesNoPass() {
        var repin = NativeTailRepin()
        func takeInPass() -> Bool { repin.takeInPass() }
        repin.reading(distance: 600, wants: false, resized: false)
        #expect(!takeInPass())
        repin.reading(distance: 0, wants: false, resized: false)
        #expect(!takeInPass())
        repin.reading(distance: 600, wants: true, resized: false)
        #expect(takeInPass())
    }

    @Test func noLandingInThePassWhileTheReaderScrolls() {
        var repin = NativeTailRepin()
        func takeInPass() -> Bool { repin.takeInPass() }
        repin.reader(scrolling: true, touching: true)
        repin.reading(distance: 600, wants: true, resized: false)
        #expect(!takeInPass())
        repin.reader(scrolling: false, touching: false)
        repin.reading(distance: 600, wants: true, resized: false)
        #expect(takeInPass())
    }

    // MARK: A new thread under the pin

    @Test func aNewThreadForgetsTheOldOnesStall() {
        var repin = Self.stalled()
        func take() -> Bool { repin.take() }
        #expect(repin.stalled)
        let landed = repin.landings
        repin.newThread(refillingPass: false)
        #expect(!repin.stalled)
        #expect(repin.misses == 0)
        #expect(!repin.pending)
        #expect(repin.quietTries == 0)
        #expect(repin.quietWait == NativeTailRepin.quiet)
        #expect(repin.landings == landed)
        repin.reading(distance: 700, wants: true, resized: false)
        #expect(take())
        #expect(repin.landings == landed + 1)
    }

    @Test func aNewThreadForgetsAReadingNotYetLanded() {
        var repin = NativeTailRepin()
        func takeInPass() -> Bool { repin.takeInPass() }
        repin.reading(distance: 600, wants: true, resized: false)
        repin.newThread(refillingPass: true)
        #expect(!repin.pending)
        #expect(!takeInPass())
        repin.reading(distance: 600, wants: true, resized: false)
        #expect(takeInPass())
    }

    /// A reused view's next thread draws its first frame like a mount's: at the tail.
    @Test func aNewThreadRefillsThePass() {
        var repin = NativeTailRepin()
        func takeInPass() -> Bool { repin.takeInPass() }
        for _ in 0..<NativeTailRepin.inPassLimit {
            repin.reading(distance: 0, wants: true, resized: false)
            #expect(takeInPass())
        }
        repin.reading(distance: 600, wants: true, resized: false)
        #expect(!takeInPass())
        repin.newThread(refillingPass: true)
        #expect(repin.landings == 0)
        repin.reading(distance: 600, wants: true, resized: false)
        #expect(takeInPass())
    }

    /// A view that leaves the screen and comes back is not a new thread: a layout may be what moves it.
    @Test func leavingTheScreenDoesNotRefillThePass() {
        var repin = NativeTailRepin()
        func takeInPass() -> Bool { repin.takeInPass() }
        for _ in 0..<NativeTailRepin.inPassLimit {
            repin.reading(distance: 0, wants: true, resized: false)
            #expect(takeInPass())
        }
        repin.newThread(refillingPass: false)
        #expect(repin.landings == NativeTailRepin.inPassLimit)
        repin.reading(distance: 600, wants: true, resized: false)
        #expect(!takeInPass())
    }

    /// The bound is `inPassLimit` per thread: a layout that keeps asking while threads change only by
    /// events lands in its passes that many times for each, never more.
    @Test func aLayoutThatKeepsAskingStaysBoundedPerThread() {
        var repin = NativeTailRepin()
        var inPass = 0
        let threads = 3
        for thread in 0..<threads {
            if thread > 0 { repin.newThread(refillingPass: true) }
            for i in 0..<200 {
                repin.reading(distance: i.isMultiple(of: 2) ? 3_000 : 3_200, wants: true, resized: true)
                if repin.takeInPass() { inPass += 1 }
                _ = repin.take()
            }
        }
        #expect(inPass == threads * NativeTailRepin.inPassLimit)
    }

    @Test func aNewThreadLeavesTheReadersScrollAlone() {
        var repin = NativeTailRepin()
        func take() -> Bool { repin.take() }
        repin.reader(scrolling: true, touching: false)
        repin.newThread(refillingPass: true)
        repin.reading(distance: 600, wants: true, resized: false)
        #expect(!take())
        #expect(!repin.wantsTurn)
        repin.reader(scrolling: false, touching: false)
        #expect(take())
    }
}
