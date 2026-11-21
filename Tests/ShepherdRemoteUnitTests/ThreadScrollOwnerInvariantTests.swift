import Testing
import ShepherdRemote

/// Round 4: outstanding work is one value, so what it promises is checked as invariants over random event sequences, not as cases.
/// Every run is `scripts` seeded scripts of `events` events each (the same on every run). The counters beside each invariant say how
/// often its premise was met, so a pass cannot come from scripts that never got there.
@Suite("Thread scroll owner: invariants over random scripts")
struct ThreadScrollOwnerInvariantTests {
    typealias Owner = ThreadScrollOwner
    typealias Fixture = ThreadScrollOwnerTests

    static let scripts = 16_000
    static let events = 40

    /// One owner driven by seeded random events, one call at a time.
    struct Sim {
        enum Call {
            case read(Owner.Reading), setIntent, turn, mount, contentArrived, quietPassed, rowsChanged([String]), newSession
            case jumpCompleted, jumpToLatest, jumpToRow(String), sent, userTurnArrived
        }

        struct Step {
            var call: Call
            var before: Owner
            /// The reading before this call's, if the owner had one.
            var previous: Owner.Reading?
            var decision: Owner.Decision
            var intent: Owner.Intent
        }

        var owner: Owner
        var intent = Owner.Intent.idle
        var previous: Owner.Reading?
        var generator: ThreadScrollOwnerGateTests.Generator
        let asks: Bool

        init(script: Int, seed: UInt64, asks: Bool) {
            generator = .init(state: seed &+ UInt64(script) &* 0x9E37_79B9)
            self.asks = asks
            let mode: Owner.Mode = [.following, .pinned(nil), .jumping(row: "row-2")][script % 3]
            owner = Owner(mode: mode, nativeAnchor: script % 2 == 0, asksInterruptTouch: script % 4 < 2)
            _ = owner.rowsChanged(Fixture.order)
        }

        mutating func reading() -> Owner.Reading {
            let offset = Double([1420, 1400, 1300, 1000, 700, 300, 1600][generator.next(7)])
            let content = Double([2000, 2000, 2100, 2400, 1800][generator.next(5)])
            let drop: Set<String> = generator.next(3) == 0 ? ["row-3", "row-4"] : []
            return Fixture.reading(content: content, offset: offset, shift: Double(generator.next(3) * 40), drop: drop)
        }

        mutating func randomIntent() -> Owner.Intent { [.idle, .touching, .coasting, .programmatic][generator.next(4)] }

        mutating func next() -> Step {
            let before = owner
            let call: Call
            switch generator.next(asks ? 20 : 14) {
            case 0, 1, 2, 3: call = .read(reading())
            case 4: call = .setIntent
            case 5, 6, 7: call = .turn
            case 8: call = .mount
            case 9: call = .contentArrived
            case 10: call = .quietPassed
            case 11:
                var rows = Fixture.order
                for _ in 0..<generator.next(4) { rows.remove(at: generator.next(rows.count)) }
                call = .rowsChanged(generator.next(4) == 0 ? ["new-0", "new-1"] : rows)
            case 12: call = generator.next(3) == 0 ? .newSession : .read(reading())
            case 13: call = .jumpCompleted
            case 14, 15: call = .jumpToLatest
            case 16: call = .sent
            case 17: call = .userTurnArrived
            default: call = .jumpToRow("row-\(generator.next(10))")
            }
            var decision = Owner.Decision.none
            let seen = previous
            switch call {
            case .read(let reading):
                intent = randomIntent()
                decision = owner.read(reading, intent: intent)
                previous = reading
            case .setIntent:
                intent = randomIntent()
                owner.setIntent(intent)
            case .turn: decision = owner.turn()
            case .mount:
                decision = owner.mount()
                if case .pinned(.some) = before.mode { previous = nil }
            case .contentArrived: owner.contentArrived()
            case .quietPassed: owner.quietPassed()
            case .rowsChanged(let rows): decision = owner.rowsChanged(rows)
            case .newSession:
                owner.newSession()
                previous = nil
            case .jumpCompleted: owner.jumpCompleted()
            case .jumpToLatest: decision = owner.jumpToLatest()
            case .jumpToRow(let row): decision = owner.jumpToRow(row)
            case .sent: decision = owner.sent(queued: false, turnPresent: generator.next(2) == 0)
            case .userTurnArrived: decision = owner.userTurnArrived()
            }
            return Step(call: call, before: before, previous: seen, decision: decision, intent: intent)
        }
    }

    static func tailOffset(_ content: Double) -> Double { content - 580 }

    /// The reading a driver feeds back after landing `content` on its tail.
    static func tailReading(_ content: Double) -> Owner.Reading { Fixture.reading(content: content, offset: content - 580) }

    // MARK: I1. Nothing automatic while the reader moves, turns included

    /// A reading, a mount, a rows change and a turn with only a landing the layout wanted never decide while the intent is not
    /// `idle`. A turn may decide only if what it delivers is the reader's own ask (`outstanding` says which).
    @Test(arguments: [false, true])
    func i1_noAutomaticDecisionWhileTheReaderMovesOrTheDriverAnimates(asks: Bool) {
        var moving = 0, turnsDelivering = 0, decisions = 0
        for script in 0..<Self.scripts {
            var sim = Sim(script: script, seed: 11, asks: asks)
            for _ in 0..<Self.events {
                let step = sim.next()
                if step.decision != .none { decisions += 1 }
                let automatic: Bool
                switch step.call {
                case .read, .mount, .rowsChanged: automatic = true
                case .turn:
                    switch step.before.outstanding {
                    case .readerLatest, .readerRow: automatic = false
                    case .none, .autoTail: automatic = true
                    }
                    if !automatic, step.decision != .none { turnsDelivering += 1 }
                default: automatic = false
                }
                if automatic, step.intent != .idle {
                    moving += 1
                    #expect(step.decision == .none, "script \(script): \(step.call) decided \(step.decision) with intent \(step.intent)")
                }
            }
        }
        #expect(moving > 20_000 && decisions > 5000, "moving \(moving), decisions \(decisions)")
        if asks { #expect(turnsDelivering > 100, "turns delivering an ask \(turnsDelivering)") }
        print("I1 asks=\(asks): scripts \(Self.scripts), automatic decisions checked under motion \(moving), turns that delivered a reader's ask \(turnsDelivering)")
    }

    // MARK: I2. Exactly once

    /// A turn that lands for a reader who is not following, or scrolls to a row, answers a request that is still open. The model
    /// opens a request when the reader asks and closes it at the first landing or scroll, a newer request, a mount, a new session.
    @Test func i2_eachRequestProducesAtMostOneDecision() {
        var delivered = 0, scriptsDelivering = 0, afterDelivery = 0
        for script in 0..<Self.scripts {
            var sim = Sim(script: script, seed: 7, asks: true)
            var latest = false
            var row: String?
            var any = false
            for _ in 0..<Self.events {
                let step = sim.next()
                let before = (latest, row)
                switch step.call {
                case .jumpToLatest, .sent:
                    latest = true
                    row = nil
                case .userTurnArrived:
                    // It asks only when a send awaits its turn: open permissively, close at the first landing.
                    latest = true
                case .jumpToRow(let next):
                    latest = false
                    row = next
                case .mount, .newSession:
                    latest = false
                    row = nil
                case .rowsChanged(let rows):
                    if let open = row, !rows.contains(open) { row = nil }
                default: break
                }
                if case .turn = step.call {
                    if step.decision == .land, !step.before.follows {
                        #expect(before.0, "script \(script): a turn landed a reader who was not following with no request open")
                        delivered += 1
                        any = true
                        if !before.0 { afterDelivery += 1 }
                    }
                    if case .scroll = step.decision {
                        #expect(before.1 != nil, "script \(script): a turn scrolled to a row with no request open")
                        delivered += 1
                        any = true
                    }
                }
                if step.decision == .land { latest = false }
                if case .scroll = step.decision { row = nil }
            }
            if any { scriptsDelivering += 1 }
        }
        #expect(delivered > 500 && afterDelivery == 0, "turns delivering a request \(delivered)")
        print("I2: scripts \(Self.scripts), scripts with a request delivered by a turn \(scriptsDelivering), deliveries \(delivered)")
    }

    // MARK: I3. Liveness

    /// A follower the layout left off its tail, with the reader's hands off, is landed by one more turn (unless the budget stalled
    /// it), and so is a request the reader made.
    @Test(arguments: [false, true])
    func i3_whatIsOwedIsDeliveredByOneMoreTurn(asks: Bool) {
        var owedChecks = 0, owedUnderMotion = 0, requestChecks = 0, scriptsOwed = 0
        for script in 0..<Self.scripts {
            var sim = Sim(script: script, seed: 3, asks: asks)
            var owed = false
            var counted = false
            for _ in 0..<Self.events {
                let step = sim.next()
                switch step.call {
                case .read(let reading):
                    let grew = step.previous.map { reading.probe.layoutDiffers(from: $0.probe) } ?? false
                    if sim.owner.follows, abs(reading.probe.distance) <= Owner.repinSlack {
                        owed = false
                    } else if sim.owner.follows, grew, reading.probe.distance > Owner.repinSlack {
                        owed = true
                    } else if !sim.owner.follows {
                        owed = false
                    }
                    if step.decision == .land { owed = false }
                case .setIntent, .contentArrived, .quietPassed: break
                case .turn: if step.decision == .land { owed = false }
                default: owed = false
                }
                // A row the reader asked for replaces a landing the layout owed.
                if !sim.owner.follows { owed = false }
                if case .readerRow = sim.owner.outstanding { owed = false }
                if owed {
                    var rest = sim.owner
                    rest.setIntent(.idle)
                    let decision = rest.turn()
                    #expect(decision == .land || rest.landingStalled, "script \(script): a follower off its tail was not landed at idle, got \(decision) after \(step.call)")
                    owedChecks += 1
                    if sim.intent != .idle { owedUnderMotion += 1 }
                    if !counted { scriptsOwed += 1; counted = true }
                }
                switch sim.owner.outstanding {
                case .readerLatest, .readerRow:
                    var rest = sim.owner
                    rest.setIntent(.idle)
                    #expect(rest.wantsTurn && rest.turn() != .none, "script \(script): a reader's request is not delivered at idle after \(step.call)")
                    requestChecks += 1
                case .none, .autoTail: break
                }
            }
        }
        #expect(owedChecks > 20_000 && owedUnderMotion > 2000, "owed \(owedChecks), under motion \(owedUnderMotion)")
        if asks { #expect(requestChecks > 2000, "request checks \(requestChecks)") }
        print("I3 asks=\(asks): scripts \(Self.scripts), scripts that owed a landing \(scriptsOwed), owed checks \(owedChecks) (\(owedUnderMotion) with the reader's hand down), reader's request checks \(requestChecks)")
    }

    // MARK: I4. A honored ask for the tail follows

    @Test func i4_aLandingPutsTheOwnerOnTheTailSoTheNextReadingRevealsNothing() {
        var landings = 0, fromHistory = 0
        for script in 0..<Self.scripts {
            var sim = Sim(script: script, seed: 5, asks: true)
            for _ in 0..<Self.events {
                let step = sim.next()
                guard step.decision == .land, let last = sim.previous else { continue }
                var next = sim.owner
                #expect(next.follows, "script \(script): landed but not following after \(step.call)")
                #expect(next.read(Self.tailReading(last.probe.content), intent: .idle) == .none, "script \(script): the tail reading after \(step.call) decided something")
                #expect(next.follows)
                landings += 1
                if !step.before.follows { fromHistory += 1 }
            }
        }
        #expect(landings > 3000 && fromHistory > 300, "landings \(landings), from a detached owner \(fromHistory)")
        print("I4: scripts \(Self.scripts), landings checked \(landings), of which the owner was detached before \(fromHistory)")
    }

    // MARK: I5. A jump ends

    @Test func i5_aJumpEndsWhenTheRowArrivesOrTheDriverSaysSoAndPinnedCompensationApplies() {
        var arrivals = 0, completions = 0, compensated = 0
        for script in 0..<Self.scripts {
            var sim = Sim(script: script, seed: 13, asks: true)
            for _ in 0..<Self.events {
                let step = sim.next()
                guard case .jumping(let row) = step.before.mode else { continue }
                var ended = false
                switch step.call {
                case .read(let reading) where step.previous != nil && abs(reading.rows[row] ?? 1000) <= Owner.pinTolerance:
                    ended = true
                    arrivals += 1
                case .jumpCompleted:
                    ended = true
                    completions += 1
                default: break
                }
                guard ended else { continue }
                #expect(!sim.owner.isJumping, "script \(script): still jumping after \(step.call)")
                guard case .pinned(let anchor?) = sim.owner.mode, let last = sim.previous else { continue }
                // A reader's ask still waiting for the finger wins: the row they are leaving is not held on the way.
                guard !ThreadScrollOwnerGateTests.isReadersAsk(sim.owner.outstanding) else { continue }
                // Growth above the reader moves the row 40 pt: it is held where it was kept.
                var next = sim.owner
                var probe = last.probe
                probe.content += 40
                probe.distance += 40
                let shifted = Owner.Reading(probe: probe, topRow: anchor.row, rows: [anchor.row: anchor.offset + 40])
                #expect(next.read(shifted, intent: .idle) == .hold(anchor), "script \(script): no compensation after the jump ended by \(step.call)")
                compensated += 1
            }
        }
        #expect(arrivals > 100 && completions > 100 && compensated > 100, "arrivals \(arrivals), completions \(completions), compensated \(compensated)")
        print("I5: scripts \(Self.scripts), jumps ended by arrival \(arrivals), by jumpCompleted \(completions), compensation checked \(compensated)")
    }

    @Test func aJumpTheDriverCompletedWhereverItStoppedIsNoLongerAJump() {
        var owner = Owner()
        _ = owner.rowsChanged(Fixture.order)
        _ = owner.read(Fixture.reading(content: 3000, offset: Self.tailOffset(3000)), intent: .idle)
        _ = owner.read(Fixture.reading(content: 3000, offset: 400), intent: .touching)
        _ = owner.read(Fixture.reading(content: 3000, offset: 400), intent: .idle)
        _ = owner.jumpToRow("row-6")
        // The animation stops with the row 40 pt below the top (a bar above it): the row never reads as arrived.
        _ = owner.read(Fixture.reading(content: 3000, offset: 1160), intent: .programmatic)
        _ = owner.read(Fixture.reading(content: 3000, offset: 1160), intent: .idle)
        #expect(owner.isJumping)
        owner.jumpCompleted()
        #expect(owner.mode == .pinned(.init(row: "row-6", offset: 40)))
        let grown = Fixture.reading(content: 3300, offset: 1160, shift: 300)
        #expect(owner.read(grown, intent: .idle) == .hold(.init(row: "row-6", offset: 40)))
    }

    // MARK: I6. The reader wins

    /// From a follower, with whatever the layout and the reader's hands did before, a drag up out of the band detaches. Nothing after
    /// that lands them, whatever the layout, the intent or the turns do, until they ask or come back to the tail.
    @Test func i6_afterTheReaderLeavesTheTailNoTurnLandsThemUnlessTheyAskAgain() {
        var generator = ThreadScrollOwnerGateTests.Generator(state: 17)
        var detached = 0, hadWork = 0, turnsAfter = 0
        for script in 0..<Self.scripts {
            var owner = Owner(asksInterruptTouch: script % 2 == 0)
            _ = owner.rowsChanged(Fixture.order)
            var content = 2000.0
            _ = owner.read(Fixture.reading(content: content, offset: content - 580), intent: .idle)
            for _ in 0..<generator.next(8) {
                switch generator.next(5) {
                case 0, 1:
                    content = [2000.0, 2100, 2400, 3000][generator.next(4)]
                    _ = owner.read(Fixture.reading(content: content, offset: [1420.0, 1500][generator.next(2)]), intent: [.idle, .touching, .coasting, .programmatic][generator.next(4)])
                case 2: owner.setIntent([.idle, .touching, .coasting, .programmatic][generator.next(4)])
                case 3: _ = owner.turn()
                default: owner.contentArrived()
                }
            }
            guard owner.follows else { continue }
            if owner.outstanding == .autoTail { hadWork += 1 }
            // The reader drags up out of the band, the layout as it was.
            _ = owner.read(Fixture.reading(content: content, offset: 700), intent: [.touching, .coasting][generator.next(2)])
            guard !owner.follows else { continue }
            detached += 1
            for _ in 0..<30 {
                var decision = Owner.Decision.none
                switch generator.next(7) {
                case 0, 1, 2:
                    let grown = content + Double(generator.next(3) * 100)
                    let offset = Double([700, 300, 1000, 500][generator.next(4)])
                    decision = owner.read(Fixture.reading(content: grown, offset: offset, shift: Double(generator.next(3) * 40)), intent: [.idle, .touching, .coasting, .programmatic][generator.next(4)])
                case 3: owner.setIntent([.idle, .touching, .coasting, .programmatic][generator.next(4)])
                case 4:
                    decision = owner.turn()
                    turnsAfter += 1
                case 5: owner.contentArrived()
                default:
                    owner.quietPassed()
                    owner.jumpCompleted()
                }
                #expect(decision != .land, "script \(script): landed a reader who left the tail")
                if generator.next(5) == 0 {
                    owner.setIntent(.idle)
                    #expect(owner.turn() != .land, "script \(script): landed a reader who left the tail at idle")
                }
            }
        }
        #expect(detached > 10_000 && hadWork > 1000 && turnsAfter > 10_000, "detached \(detached), with work owed before \(hadWork), turns after \(turnsAfter)")
        print("I6: scripts \(Self.scripts), readers detached \(detached), of which a landing was owed to the follower \(hadWork), turns after the detach \(turnsAfter)")
    }
}
