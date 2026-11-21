import Testing
import ShepherdRemote

/// The floor: what `NativeScrollFollower`, `NativeTailRepin` and `NativeTranscriptPlace` do today, which the owner must reproduce.
/// The follower and the repin are still in the tree, so the strongest check is to drive them and the owner through the same
/// readings and compare. The place's marker hand-back is SwiftUI mechanics the owner replaces with a measured anchor; what it kept
/// for the reader (follow, unseen, mount, send, jump to latest) is checked below.
@Suite("Thread scroll owner: follower and place floor")
struct ThreadScrollOwnerFloorTests {
    typealias Fixture = ScrollFollowerLayoutTests

    /// The probes the follower's own layout suite uses, plus an offset-only move each way and two taller ones.
    static let probes: [NativeScrollProbe] = [
        Fixture.tail,
        Fixture.probe(content: 2400),
        Fixture.probe(container: 300, inset: 340),
        Fixture.probe(content: 1000),
        Fixture.probe(offset: 1120),
        Fixture.probe(offset: 1370),
        Fixture.probe(offset: 2300),
        Fixture.probe(content: 2159, offset: 1370),
        Fixture.probe(content: 300, offset: -60),
        Fixture.probe(content: 1020, offset: 430),
    ]

    /// Every three-reading script over the probes, with and without a finger on each reading, with and without a native anchor.
    @Test("the owner follows, detaches, re-attaches, lands and sees output exactly as the follower does")
    func ownerMatchesFollower() {
        var mismatches: [String] = []
        var scripts = 0, landings = 0, detached = 0
        for native in [true, false] {
            for a in Self.probes.indices { for b in Self.probes.indices { for c in Self.probes.indices { for mask in 0..<8 {
                scripts += 1
                var follower = NativeScrollFollower()
                var owner = ThreadScrollOwner(nativeAnchor: native)
                _ = owner.read(.init(probe: Self.probes[0]), intent: .idle)
                var previous = Self.probes[0]
                var commanded = false
                for (n, index) in [a, b, c].enumerated() {
                    let touching = mask & (1 << n) != 0
                    let probe = Self.probes[index]
                    // An offset change with the layout as it was and no finger is the reader paging (VoiceOver), which the follower
                    // cannot see: the owner takes the view's place as the reader's (the plan's `repinSlack` rule), and the follower
                    // is told the same, so the scripts go on comparing everything else.
                    // (A reading right after a landing is the landing's doing.)
                    let displaced = !commanded && !touching && !probe.layoutDiffers(from: previous) && probe.offset != previous.offset
                    if displaced {
                        follower.sticky = probe.distance <= NativeScrollFollower.repinSlack
                        if follower.sticky { follower.unseen = false }
                    }
                    let lands = follower.observe(from: previous, to: probe, gesture: touching, nativeAnchor: native)
                    let decision = owner.read(.init(probe: probe), intent: touching ? .touching : .idle)
                    // Rowless scripts have one answer: a landing or nothing, never a hold, reveal or scroll.
                    let expected: ThreadScrollOwner.Decision = lands ? .land : .none
                    if decision != expected || owner.follows != follower.sticky || owner.unseen != follower.unseen {
                        mismatches.append("native \(native) probes \([a, b, c]) touching \(mask) step \(n): owner \(decision) follows \(owner.follows) unseen \(owner.unseen), "
                            + "follower lands \(lands) sticky \(follower.sticky) unseen \(follower.unseen)")
                    }
                    commanded = decision != .none
                    // Output while detached is what shows the pill: deliver it every step, to both.
                    follower.contentArrived()
                    owner.contentArrived()
                    landings += lands ? 1 : 0
                    detached += follower.sticky ? 0 : 1
                    previous = probe
                }
            } } } }
        }
        #expect(scripts == 2 * 1000 * 8)
        // Not vacuous: scripts that land the tail and scripts that detach are both well represented.
        #expect(landings > 1000 && detached > 1000, "landings \(landings), detached steps \(detached)")
        #expect(mismatches.isEmpty, "\(mismatches.count) differ, first: \(mismatches.prefix(5))")
    }

    // MARK: The follower's sends and jumps

    /// The same events through a live follower and the owner: where they end, what the user turn asks and the pill agree with each
    /// other and with the case's expectations.
    @Test(arguments: ScrollFollowerSendTests.cases)
    func sendsAndArrivalsMatchTheFollowersExpectations(_ c: ScrollFollowerSendTests.Case) {
        var owner = ThreadScrollOwner()
        var follower = NativeScrollFollower()
        var lands = false, followerLands = false
        _ = owner.read(.init(probe: Fixture.tail), intent: .idle)
        for event in c.events {
            switch event {
            case .dragUp:
                _ = owner.read(.init(probe: Fixture.probe(offset: 820)), intent: .touching)
                follower.observe(distanceFromBottom: 600, userIntent: true)
            case .jumpUp:
                _ = owner.jumpToRow("earlier")
                _ = owner.read(.init(probe: Fixture.probe(offset: 820)), intent: .programmatic)
                follower.beginJump()
                follower.observe(distanceFromBottom: 600)
            case .send(let queued):
                _ = owner.sent(queued: queued)
                follower.sent(queued: queued)
            case .userTurn:
                lands = owner.userTurnArrived() == .land
                followerLands = follower.userTurnArrived()
            case .output:
                owner.contentArrived()
                follower.contentArrived()
            }
            #expect(owner.follows == follower.sticky && owner.unseen == follower.unseen)
        }
        #expect(owner.follows == c.sticky)
        #expect(lands == c.lands && lands == followerLands)
        #expect(owner.showsJump(running: false) == c.pill)
        #expect(owner.showsJump(running: false) == NativeScrollFollower.showsJump(sticky: follower.sticky, unseen: follower.unseen, running: false))
    }

    // MARK: The place's reader

    @Test func whatTheTranscriptDrawsOfTheOwner() {
        var owner = ThreadScrollOwner()
        #expect(owner.follows && !owner.unseen)
        _ = owner.read(.init(probe: Fixture.tail), intent: .idle)
        _ = owner.read(.init(probe: Fixture.probe(offset: 820)), intent: .touching)
        owner.contentArrived()
        #expect(!owner.follows && owner.unseen)
        _ = owner.jumpToLatest()
        #expect(owner.follows && !owner.unseen)
    }

    @Test func aMountReSticksAReaderWithNothingKeptTheWayTheJumpPillDoes() {
        var owner = ThreadScrollOwner()
        _ = owner.read(.init(probe: Fixture.tail), intent: .idle)
        _ = owner.read(.init(probe: Fixture.probe(offset: 820)), intent: .touching)
        owner.contentArrived()
        #expect(owner.mount() == .land)
        #expect(owner.follows && !owner.unseen)
    }

    @Test func jumpToLatestDropsTheKeptRowSoNothingFeedsHistoryBackDuringTheJump() {
        var owner = ThreadScrollOwnerTests.pinned(at: 700)
        #expect(owner.kept != .following)
        _ = owner.jumpToLatest()
        #expect(owner.kept == .following)
        // The lazy stack reports rows while measuring the jump: with no hold on any, none is put back.
        let measuring = ThreadScrollOwnerTests.reading(content: 2400, offset: 700, shift: 300)
        #expect(owner.read(measuring, intent: .idle) != .hold(.init(row: "row-3", offset: -100)))
        // A reader who then leaves the tail keeps the place they are at.
        _ = owner.read(ThreadScrollOwnerTests.reading(content: 2400, offset: 500), intent: .touching)
        #expect(owner.kept != .following)
    }

    @Test func aSendFromHistoryReleasesTheKeptRowWhileFollowingKeepsFollowing() {
        var history = ThreadScrollOwnerTests.pinned(at: 700)
        #expect(history.sent(queued: false) == .land)
        #expect(history.follows && history.kept == .following)
        var follower = ThreadScrollOwner()
        _ = follower.read(.init(probe: Fixture.tail), intent: .idle)
        _ = follower.sent(queued: false)
        #expect(follower.follows)
    }
}
