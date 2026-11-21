import Testing
import ShepherdRemote

/// The owner's transitions: what moves it between following, pinned and jumping, what it asks the driver to do, and what it never does
/// while the reader moves. Pure values; no scroll view, no clocks.
@Suite("Thread scroll owner")
struct ThreadScrollOwnerTests {
    typealias Owner = ThreadScrollOwner
    typealias Anchor = ThreadScrollOwner.Anchor

    /// At the tail of 2000 pt of content in a 700 pt viewport with a 60 pt bar above and a 120 pt composer below.
    static func probe(content: Double = 2000, offset: Double = 1420, container: Double = 520, inset: Double = 120) -> NativeScrollProbe {
        NativeScrollProbe(content: content, offset: offset, container: container, insetTop: 60, insetBottom: inset)
    }

    /// Rows are 200 pt tall and the viewport starts at `offset`: `row-N` sits at `200 * N - offset`.
    static func reading(content: Double = 2000, offset: Double = 1420, shift: Double = 0, drop: Set<String> = []) -> ThreadScrollOwner.Reading {
        var rows: [String: Double] = [:]
        for n in 0..<10 where !drop.contains("row-\(n)") {
            let top = 200 * Double(n) - offset + shift
            if top > -200, top < 520 { rows["row-\(n)"] = top }
        }
        let first = rows.filter { $0.value > -200 }.min { $0.value < $1.value }?.key
        return .init(probe: probe(content: content, offset: offset), topRow: first, rows: rows)
    }

    static let order = (0..<10).map { "row-\($0)" }

    /// An owner that follows, read at the tail, then dragged up to `offset`: pinned there.
    static func pinned(at offset: Double = 700, ask interrupts: Bool = true) -> Owner {
        var owner = Owner(asksInterruptTouch: interrupts)
        _ = owner.rowsChanged(order)
        _ = owner.read(reading(), intent: .idle)
        _ = owner.read(reading(offset: offset), intent: .touching)
        _ = owner.read(reading(offset: offset), intent: .idle)
        return owner
    }

    // MARK: Following and pinned

    @Test func aDragUpDetachesAndPinsTheRowAtTheTop() {
        let owner = Self.pinned(at: 700)
        // 700 pt down: row-3 starts at -100, so it is the topmost row that intersects the viewport.
        #expect(owner.mode == .pinned(Anchor(row: "row-3", offset: -100)))
        #expect(!owner.follows)
    }

    @Test func comingBackInsideTheBandReAttaches() {
        var owner = Self.pinned()
        owner.contentArrived()
        #expect(owner.unseen)
        _ = owner.read(Self.reading(offset: 1380), intent: .touching)
        #expect(owner.follows && !owner.unseen)
    }

    @Test func layoutAloneNeverDetachesOrReAttaches() {
        var owner = Owner()
        _ = owner.read(Self.reading(), intent: .idle)
        _ = owner.read(Self.reading(content: 2400, offset: 1420), intent: .idle)
        #expect(owner.follows)
        var away = Self.pinned()
        _ = away.read(Self.reading(content: 2400, offset: 2000), intent: .idle)
        #expect(!away.follows)
    }

    @Test func aFollowerPastItsTailIsLandedOnItAtOnce() {
        var owner = Owner(nativeAnchor: false)
        _ = owner.read(Self.reading(), intent: .idle)
        #expect(owner.read(Self.reading(content: 1000, offset: 1420), intent: .idle) == .land)
    }

    @Test func aFollowerThatLayoutMovedOffTheTailIsLanded() {
        var owner = Owner()
        _ = owner.read(Self.reading(), intent: .idle)
        #expect(owner.read(Self.reading(content: 2400, offset: 1420), intent: .idle) == .land)
    }

    @Test func noLandingWhileTheReaderMoves() {
        for intent in [Owner.Intent.touching, .coasting] {
            var owner = Owner()
            _ = owner.read(Self.reading(), intent: .idle)
            #expect(owner.read(Self.reading(content: 2400, offset: 1420), intent: intent) == .none)
        }
    }

    // MARK: Pinned: layout compensation

    @Test func aLayoutShiftAboveAPinnedReaderIsHeldBack() {
        var owner = Self.pinned(at: 700)
        // A reply grows 340 pt above the viewport: every row below moves down, the offset does not.
        let decision = owner.read(Self.reading(content: 2340, offset: 700, shift: 340), intent: .idle)
        #expect(decision == .hold(Anchor(row: "row-3", offset: -100)))
    }

    @Test func aShiftWithinOnePointIsLeftAlone() {
        var owner = Self.pinned(at: 700)
        #expect(owner.read(Self.reading(content: 2001, offset: 700, shift: 1), intent: .idle) == .none)
        #expect(owner.read(Self.reading(content: 2002, offset: 700, shift: 1.5), intent: .idle) != .none)
    }

    @Test func nothingIsWrittenWhileTheReaderMovesAndTheAnchorFollowsTheirHand() {
        var owner = Self.pinned(at: 700)
        for intent in [Owner.Intent.touching, .coasting, .programmatic] {
            // Layout grew above while the hand is down: no write, and the place the reader is at is the new anchor.
            #expect(owner.read(Self.reading(content: 2340, offset: 700, shift: 340), intent: intent) == .none)
            #expect(owner.mode == .pinned(Anchor(row: "row-1", offset: -160)))
        }
        // They let go: where they are is where it is kept, so nothing is corrected.
        #expect(owner.read(Self.reading(content: 2340, offset: 700, shift: 340), intent: .idle) == .none)
    }

    @Test func aScrollNobodyReportedAsOneIsTheReaderNotALayoutShift() {
        // VoiceOver paging: the offset moved, the layout did not, and the intent says idle. It is not put back.
        var owner = Self.pinned(at: 700)
        #expect(owner.read(Self.reading(offset: 1100), intent: .idle) == .none)
        #expect(owner.mode == .pinned(Anchor(row: "row-5", offset: -100)))
        #expect(owner.read(Self.reading(offset: 1100), intent: .idle) == .none)
    }

    @Test func aVoiceOverPageAwayFromTheTailDetachesAFollower() {
        var owner = Owner()
        _ = owner.read(Self.reading(), intent: .idle)
        // Idle, layout unchanged, no command in flight: the reader paged up.
        #expect(owner.read(Self.reading(offset: 1100), intent: .idle) == .none)
        #expect(owner.mode == .pinned(Anchor(row: "row-5", offset: -100)))
        owner.contentArrived()
        #expect(owner.unseen)
    }

    @Test func aVoiceOverPageBackToTheTailReAttachesAPinnedReader() {
        var owner = Self.pinned(at: 700)
        owner.contentArrived()
        #expect(owner.read(Self.reading(offset: 1420), intent: .idle) == .none)
        #expect(owner.follows && !owner.unseen)
        // Within the slack counts, a little short of it does not.
        var near = Self.pinned(at: 700)
        _ = near.read(Self.reading(offset: 1420 - Owner.repinSlack), intent: .idle)
        #expect(near.follows)
        var short = Self.pinned(at: 700)
        _ = short.read(Self.reading(offset: 1420 - Owner.repinSlack - 1), intent: .idle)
        #expect(!short.follows)
    }

    @Test func anOffsetChangeTheDriverCausedIsNotTheReader() {
        var owner = Self.pinned(at: 700)
        // The owner held the row, and the next reading shows the view where the command put it: not a reader's page.
        #expect(owner.read(Self.reading(content: 2340, offset: 700, shift: 340), intent: .idle) == .hold(Anchor(row: "row-3", offset: -100)))
        #expect(owner.read(Self.reading(content: 2340, offset: 1040, shift: 340), intent: .idle) == .none)
        #expect(owner.mode == .pinned(Anchor(row: "row-3", offset: -100)))
    }

    // MARK: Jumps

    @Test func aTurnJumpDetachesAndItsFirstFramesAtTheTailDoNotReAttach() {
        var owner = Owner()
        _ = owner.read(Self.reading(), intent: .idle)
        #expect(owner.jumpToRow("row-2") == .scroll(toRow: "row-2", animated: true))
        _ = owner.read(Self.reading(offset: 1420), intent: .programmatic)
        _ = owner.read(Self.reading(offset: 1380), intent: .programmatic)
        #expect(owner.isJumping && !owner.follows)
        // It left the band: landed on the earlier row, and from here it is a pinned reader.
        _ = owner.read(Self.reading(offset: 400), intent: .programmatic)
        #expect(owner.mode == .pinned(Anchor(row: "row-2", offset: 0)))
    }

    @Test func aReaderScrollingEndsAJumpThatNeverLeftTheBand() {
        var owner = Owner()
        _ = owner.read(Self.reading(), intent: .idle)
        _ = owner.jumpToRow("row-2")
        _ = owner.read(Self.reading(offset: 1390), intent: .programmatic)
        #expect(owner.isJumping)
        _ = owner.read(Self.reading(offset: 1380), intent: .touching)
        #expect(owner.follows && !owner.isJumping)
    }

    @Test func layoutAloneNeverEndsAJump() {
        for intent in [Owner.Intent.programmatic, .idle] {
            var owner = Owner()
            _ = owner.read(Self.reading(), intent: .idle)
            _ = owner.jumpToRow("row-2")
            // The document grew 100 pt before the animation moved: 100 pt from the tail, the view where it was.
            _ = owner.read(Self.reading(content: 2100, offset: 1420), intent: intent)
            #expect(owner.mode == .jumping(row: "row-2"))
            // The animation then moves it, and that is where it landed.
            _ = owner.read(Self.reading(content: 2100, offset: 400), intent: .programmatic)
            #expect(owner.mode == .pinned(Anchor(row: "row-2", offset: 0)))
        }
    }

    @Test func aReaderMovingTheViewInEitherDirectionEndsAJump() {
        for intent in [Owner.Intent.touching, .coasting] {
            // Toward the tail, inside the band.
            var toward = Owner()
            _ = toward.read(Self.reading(), intent: .idle)
            _ = toward.jumpToRow("row-2")
            _ = toward.read(Self.reading(offset: 1380), intent: .programmatic)
            _ = toward.read(Self.reading(offset: 1400), intent: intent)
            #expect(toward.follows && !toward.isJumping)
            // Away from it, inside the band.
            var away = Owner()
            _ = away.read(Self.reading(), intent: .idle)
            _ = away.jumpToRow("row-2")
            _ = away.read(Self.reading(offset: 1400), intent: .programmatic)
            _ = away.read(Self.reading(offset: 1380), intent: intent)
            #expect(away.follows && !away.isJumping)
            // Away from it, beyond the band.
            var beyond = Owner()
            _ = beyond.read(Self.reading(), intent: .idle)
            _ = beyond.jumpToRow("row-2")
            _ = beyond.read(Self.reading(offset: 1000), intent: intent)
            #expect(beyond.mode == .pinned(Anchor(row: "row-5", offset: 0)) && !beyond.isJumping)
        }
    }

    @Test func rowsMeasuredAfterAJumpAreNothingNew() {
        var owner = Owner()
        _ = owner.read(Self.reading(), intent: .idle)
        _ = owner.jumpToRow("row-2")
        _ = owner.read(Self.reading(offset: 400), intent: .programmatic)
        _ = owner.read(Self.reading(content: 2300, offset: 400), intent: .idle)
        #expect(!owner.unseen && !owner.showsJump(running: false))
    }

    @Test func aTailRequestCancelsAJump() {
        var owner = Owner()
        _ = owner.read(Self.reading(), intent: .idle)
        _ = owner.jumpToRow("row-2")
        #expect(owner.jumpToLatest() == .land)
        #expect(owner.follows && !owner.isJumping)
    }

    // MARK: Asks

    @Test func theMacLandsAnAskWhileTheReaderTouches() {
        var owner = Self.pinned(ask: true)
        owner.setIntent(.touching)
        #expect(owner.jumpToLatest() == .land)
    }

    @Test func iOSHoldsAnAskUntilTheFingerLiftsAndLandsOverACoast() {
        var owner = Self.pinned(ask: false)
        owner.setIntent(.touching)
        #expect(owner.jumpToLatest() == .none)
        #expect(!owner.wantsTurn)
        owner.setIntent(.coasting)
        #expect(owner.wantsTurn)
        #expect(owner.turn() == .land)
        #expect(owner.turn() == .none)
    }

    @Test func onlyTheNewestRequestSurvivesAFingerOnIOS() {
        var owner = Self.pinned(ask: false)
        owner.setIntent(.touching)
        // Latest, then a row, while the finger is down: nothing is written.
        #expect(owner.jumpToLatest() == .none)
        #expect(owner.jumpToRow("row-2") == .none)
        #expect(!owner.wantsTurn)
        #expect(owner.turn() == .none)
        // The lift into a coast: one scroll to the row, not the landing the older ask wanted.
        owner.setIntent(.coasting)
        #expect(owner.wantsTurn)
        #expect(owner.turn() == .scroll(toRow: "row-2", animated: true))
        #expect(owner.isJumping)
        #expect(!owner.wantsTurn)
        #expect(owner.turn() == .none)
    }

    @Test func aTailAskAfterARowAskReplacesItOnIOS() {
        var owner = Self.pinned(ask: false)
        owner.setIntent(.touching)
        #expect(owner.jumpToRow("row-2") == .none)
        #expect(owner.jumpToLatest() == .none)
        owner.setIntent(.coasting)
        #expect(owner.turn() == .land)
        #expect(owner.turn() == .none)
        #expect(owner.follows && !owner.isJumping)
    }

    @Test func aRowAskWithNoFingerGoesAtOnceAndTakesTheTailAskWithIt() {
        var owner = Self.pinned(ask: false)
        owner.setIntent(.coasting)
        #expect(owner.jumpToRow("row-2") == .scroll(toRow: "row-2", animated: true))
        #expect(owner.turn() == .none)
        // The Mac does not wait for the finger either.
        var mac = Self.pinned(ask: true)
        mac.setIntent(.touching)
        #expect(mac.jumpToRow("row-2") == .scroll(toRow: "row-2", animated: true))
    }

    @Test func aSendThatGoesInNowReAttachesAndLandsOnItsTurnOnce() {
        var owner = Self.pinned()
        #expect(owner.sent(queued: false) == .land)
        #expect(owner.follows)
        #expect(owner.userTurnArrived() == .land)
        #expect(owner.userTurnArrived() == .none)
    }

    @Test func aSendWhileFollowingLeavesTheLandingToTheLayout() {
        var owner = Owner()
        _ = owner.read(Self.reading(), intent: .idle)
        #expect(owner.sent(queued: false) == .none)
        #expect(owner.userTurnArrived() == .land)
    }

    @Test func aQueuedSendLeavesTheReaderAlone() {
        var owner = Self.pinned()
        let before = owner
        #expect(owner.sent(queued: true) == .none)
        #expect(owner == before)
    }

    @Test func leavingTheTailBeforeTheSentTurnArrivesCancelsTheLanding() {
        var owner = Owner()
        _ = owner.read(Self.reading(), intent: .idle)
        _ = owner.sent(queued: false)
        _ = owner.read(Self.reading(offset: 1100), intent: .touching)
        #expect(!owner.follows)
        #expect(owner.userTurnArrived() == .none)
    }

    @Test func outputWhileDetachedShowsThePillAndOutputAtTheTailDoesNot() {
        var follower = Owner()
        follower.contentArrived()
        #expect(!follower.showsJump(running: false))
        var reader = Self.pinned()
        #expect(!reader.showsJump(running: false))
        reader.contentArrived()
        #expect(reader.showsJump(running: false))
        #expect(reader.showsJump(running: true))
    }

    // MARK: The landing budget

    @Test func aTailThatNeverSettlesStopsBeingChased() {
        var owner = Owner()
        var lands = 0
        _ = owner.read(Self.reading(), intent: .idle)
        // Each reading is a layout change that leaves the tail about as far off as the landing before it did.
        for n in 0..<30 {
            let content = 3000 + (n.isMultiple(of: 2) ? 0 : 150)
            if owner.read(Self.reading(content: Double(content), offset: 1420), intent: .idle) == .land { lands += 1 }
            while owner.wantsTurn, owner.turn() == .land { lands += 1 }
        }
        #expect(owner.landingStalled)
        #expect(lands < 30)
    }

    @Test func theReaderLettingGoGivesAStalledTailAFreshBudget() {
        var owner = Owner()
        _ = owner.read(Self.reading(), intent: .idle)
        for n in 0..<30 {
            _ = owner.read(Self.reading(content: Double(3000 + (n.isMultiple(of: 2) ? 0 : 150)), offset: 1420), intent: .idle)
            _ = owner.turn()
        }
        #expect(owner.landingStalled)
        owner.setIntent(.touching)
        owner.setIntent(.idle)
        #expect(!owner.landingStalled)
    }

    // MARK: Mount, session, kept place

    @Test func aMountLandsAFollowerAndReAttachesAReaderWithNothingKept() {
        var follower = Owner()
        #expect(follower.mount() == .land)
        var detached = Owner()
        _ = detached.read(Self.reading(), intent: .idle)
        _ = detached.read(Self.reading(offset: 1100), intent: .touching)
        detached.newSession()
        _ = detached.jumpToRow("row-1")
        #expect(detached.mount() == .land)
        #expect(detached.follows && !detached.unseen)
    }

    @Test func aMountGivesAReaderBackTheRowTheyKeptAndTheFirstReadingSettlesIt() {
        var owner = Self.pinned(at: 700)
        #expect(owner.kept == .pinned(Anchor(row: "row-3", offset: -100)))
        // Nothing is written by the mount itself: the view may already be there.
        var there = owner
        #expect(there.mount() == .none)
        #expect(there.read(Self.reading(offset: 700), intent: .idle) == .none)
        // The lazy stack has the row, off its place: put it back, though the offset moved since the last reading.
        #expect(owner.mount() == .none)
        #expect(owner.read(Self.reading(offset: 400), intent: .idle) == .hold(Anchor(row: "row-3", offset: -100)))
        // The row not built yet: ask for it, once.
        var missing = Self.pinned(at: 700)
        _ = missing.mount()
        #expect(missing.read(Self.reading(offset: 700, drop: ["row-3"]), intent: .idle) == .reveal("row-3"))
    }

    @Test func aJumpInFlightIsNotKept() {
        var owner = Owner()
        _ = owner.jumpToRow("row-1")
        #expect(owner.kept == .pinned(nil))
    }

    @Test func aNewSessionForgetsWhatTheOldOneKept() {
        var owner = Self.pinned()
        owner.newSession()
        #expect(owner.mode == .following && owner.order.isEmpty && !owner.unseen)
    }
}
