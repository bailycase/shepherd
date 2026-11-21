import Testing
import ShepherdRemote

/// Every event sequence over a small alphabet, up to the walk's depth, checked against a spec model that never reads the
/// owner's `mode`, `follows` or `outstanding`. Random scripts missed two bugs that are three to five events long, and the
/// invariants beside them lean on the owner's own state; this walks all of them, and the oracle is only what an observer sees.
///
/// The spec (`Spec`) tracks: the reader's intent, the last reading, the reader's open request (none, the tail, `row-2`), the row a
/// request is guarding, and whether the reader is "following" by an observer's definition (at the tail, and has not scrolled up out
/// of the band since). Six rules over the owner's returned decisions:
/// - a. nothing automatic while the intent is not `idle`; a delivered ask is the exception (on iOS not under a finger);
/// - b. after the reader asks for a row, until they act again, the view is never moved to any other row, and never landed;
/// - c. a request is delivered at most once, a row ask only to the row asked for; an automatic landing needs unpaid debt;
/// - d. an observer-following thread the layout grew off its tail is landed by one more turn at idle (a cancelled row request
///   must not lose this);
/// - e. after a jump to the tail lands, nothing reveals or holds a row;
/// - f. after the reader scrolls up out of the band, nothing lands them unless they ask or come back.
@Suite("Thread scroll owner: exhaustive small scope")
struct ThreadScrollOwnerExhaustiveTests {
    typealias Owner = ThreadScrollOwner
    typealias Fixture = ThreadScrollOwnerTests
    typealias Intent = ThreadScrollOwner.Intent

    static let row = "row-2"
    static let historyRow = "row-6"

    enum Rule: String, CaseIterable { case a, b, c, d, e, f }

    enum Event: CustomStringConvertible {
        case setIntent(Intent), read(Int), askLatest, askRow, remove(String), output, turn, jumpCompleted, mount
        case newSession, sent(queued: Bool, turnPresent: Bool), userTurnArrived

        var description: String {
            switch self {
            case .setIntent(let intent): "intent(\(intent))"
            case .read(let g): "read(\(geometryNames[g]))"
            case .askLatest: "askLatest"
            case .askRow: "askRow"
            case .remove(let row): "remove(\(row))"
            case .output: "output"
            case .turn: "turn"
            case .jumpCompleted: "jumpCompleted"
            case .mount: "mount"
            case .newSession: "newSession"
            case .sent(let queued, let turnPresent): "sent(queued:\(queued), turnPresent:\(turnPresent))"
            case .userTurnArrived: "userTurnArrived"
            }
        }
    }

    // MARK: Geometries (the standard fixture: 520 pt viewport, rows 200 pt)

    static let geometryNames = ["tail", "band", "far", "grown", "top", "mid", "fractional"]
    static let shapes: [(content: Double, offset: Double)] = [
        (2000, 1420), (2000, 1400), (2000, 700), (2400, 1420), (2100, 400), (2000, 1200), (2100, 399.5),
    ]
    // At a fractional arrival row-2 is 0.5 pt below the top, with the last 0.5 pt of row-1 still visible.
    static let drops: [Set<String>] = [[], [row], [historyRow], [row, historyRow]]
    static let readings = drops.map { drop in
        shapes.map { Fixture.reading(content: $0.content, offset: $0.offset, drop: drop) }
    }
    static let orders = drops.map { drop in Fixture.order.filter { !drop.contains($0) } }

    static let requests: [Event] = [.askLatest, .askRow, .remove(row), .remove(historyRow), .turn]
    static let alphabet: [Event] = [.setIntent(.idle), .setIntent(.touching), .setIntent(.coasting), .setIntent(.programmatic)]
        + shapes.indices.map { .read($0) } + requests + [.output, .jumpCompleted, .mount, .newSession,
            .sent(queued: false, turnPresent: true), .sent(queued: false, turnPresent: false),
            .sent(queued: true, turnPresent: false), .userTurnArrived]
    static let requestAlphabet: [Event] = [.setIntent(.idle), .setIntent(.touching), .read(0), .read(2), .read(3)] + requests

    // MARK: The spec

    struct Spec {
        enum Request: Equatable { case none, latest, row(String) }

        let iOS: Bool
        var intent = Intent.idle
        var view = readings[0][0]
        var request = Request.none
        /// The row a request guards, from the ask until the reader acts or the driver says the animation is over.
        var guarded: String?
        /// At the tail since the last tail arrival, not scrolled up out of the band since (before any open row request).
        var atTail = true
        var scrolledUp = false
        var afterLanding = false
        var owed = false
        var lands = 0
        var commanded = false
        var revealing: String?
        var removed = 0
        var awaitingEcho = false
        var followingSend = false

        func removalBit(_ row: String) -> Int { row == ThreadScrollOwnerExhaustiveTests.row ? 1 : 2 }
        /// A mount that may have kept the reader's place: the next reading is where the view is put back, not a move to learn from.
        var skipNext = false
        /// A delivered jump has not arrived, been completed or been taken over.
        var jumping = false
        var completionReady = false
        var arrived = false
        /// A jump's row left the order mid-flight: nothing is kept, the next reading anchors the reader.
        var noPlace = false

        var rowOpen: Bool { if case .row = request { true } else { false } }
        var gesture: Bool { intent == .touching || intent == .coasting }

        /// What the owner decided for `event`, given everything an observer saw. Returns the rules it broke and the rules whose
        /// premise held (the sequence was a real test of them).
        mutating func step(_ event: Event, _ decision: Owner.Decision, owner: Owner) -> (fails: [Rule], premises: [Rule]) {
            var fails = [Rule](), premises = [Rule]()
            var canDecide = true
            switch event {
            case .setIntent(let next): intent = next; canDecide = false
            case .output: canDecide = false
            case .askLatest:
                request = .latest
                revealing = nil
                guarded = nil
                jumping = false
                atTail = true
                scrolledUp = false
                afterLanding = false
            case .askRow:
                request = .row(row)
                revealing = nil
                guarded = row
                arrived = false
                afterLanding = false
                awaitingEcho = false
                followingSend = false
            case .mount:
                // Judge from what was kept before the mount, never from the decision it returned.
                if jumping || noPlace || atTail {
                    atTail = true
                    scrolledUp = false
                    owed = true
                } else {
                    owed = false
                    skipNext = true
                }
                revealing = nil
                request = .none
                guarded = nil
                afterLanding = false
                jumping = false
                noPlace = false
            case .newSession:
                let motion = intent
                self = Spec(iOS: iOS)
                intent = motion
                skipNext = true
                canDecide = false
            case .sent(let queued, let turnPresent):
                if !queued {
                    let detached = !atTail
                    request = detached ? .latest : .none
                    revealing = nil
                    guarded = nil
                    jumping = false
                    atTail = true
                    scrolledUp = false
                    // If attachment was uncertain, so was the send's immediate landing. The echo is an explicit ask.
                    afterLanding = false
                    awaitingEcho = !turnPresent
                    followingSend = true
                }
            case .userTurnArrived:
                if awaitingEcho {
                    awaitingEcho = false
                    request = .latest
                    guarded = nil
                    jumping = false
                }
            case .remove(let removedRow):
                removed |= removalBit(removedRow)
                completionReady = false
                if revealing == removedRow { revealing = nil }
                if request == .row(removedRow) { request = .none }
                if guarded == removedRow {
                    guarded = nil
                    noPlace = jumping
                    // A cancelled animation that never left the band leaves a follower.
                    if jumping, !skipNext, view.probe.distance <= NativeScrollFollower.threshold {
                        atTail = true
                        scrolledUp = false
                        noPlace = false
                    }
                    jumping = false
                }
            case .jumpCompleted:
                canDecide = false
                if jumping {
                    if skipNext {
                        noPlace = true
                    } else if view.probe.distance <= NativeScrollFollower.threshold {
                        atTail = true
                        scrolledUp = false
                    }
                    guarded = nil
                    jumping = false
                }
            case .turn: break
            case .read(let g): reading(readings[removed][g])
            }
            let target = guarded ?? { if case .row(let row) = request { row } else { nil } }()
            let landed = decision == .land

            // a. Nothing automatic while the reader moves or the driver animates.
            if canDecide, intent != .idle {
                premises.append(.a)
                if decision != .none {
                    let delivers = (request == .latest && landed) || { if case .scroll(let r, _) = decision { request == .row(r) } else { false } }()
                    if !delivers || (iOS && intent == .touching) { fails.append(.a) }
                }
            }
            // b. The reader's row wins: no other row, no landing.
            if canDecide, let target {
                premises.append(.b)
                switch decision {
                case .land: fails.append(.b)
                case .reveal(let r): if r != target { fails.append(.b) }
                case .hold(let anchor): if anchor.row != target { fails.append(.b) }
                case .scroll(let r, _): if r != target { fails.append(.b) }
                case .none: break
                }
            }
            // c and f. Judge the landing before consuming the request or debt or changing the observed position.
            if canDecide, scrolledUp {
                premises.append(.f)
                if landed, request != .latest { fails.append(.f) }
            }
            if decision != .none { premises.append(.c) }
            switch decision {
            case .scroll(let r, _):
                if request == .row(r) {
                    request = .none
                    jumping = true
                    completionReady = false
                    arrived = false
                    atTail = false
                    owed = false
                } else {
                    fails.append(.c)
                }
            case .land:
                revealing = nil
                if request == .latest {
                    request = .none
                    afterLanding = true
                } else if !rowOpen, !(atTail && owed) {
                    fails.append(.c)
                }
                atTail = true
                scrolledUp = false
                owed = false
                lands += 1
            case .reveal(let row): revealing = row
            default: break
            }
            // e. After a jump to the tail, the row just left is not put back.
            if afterLanding, canDecide {
                premises.append(.e)
                switch decision {
                case .reveal, .hold: fails.append(.e)
                default: break
                }
            }
            if decision != .none { commanded = true }
            if case .read(let g) = event {
                view = readings[removed][g]
                completionReady = jumping
            }
            // d. Owed a landing: one more turn at idle delivers it.
            if owed, atTail, request == .none, lands <= 2 {
                premises.append(.d)
                var rest = owner
                rest.setIntent(.idle)
                if rest.turn() != .land { fails.append(.d) }
            }
            return (fails, premises)
        }

        private mutating func reading(_ next: Owner.Reading) {
            let previous = view
            if skipNext {
                skipNext = false
                commanded = false
                noPlace = false
                if jumping, let guarded, abs(next.rows[guarded] ?? 1000) <= Owner.pinTolerance {
                    jumping = false
                    arrived = true
                }
                return
            }
            let layoutChanged = next.probe.layoutDiffers(from: previous.probe)
            let moved = next.probe.offset != previous.probe.offset
            let explained = commanded || revealing != nil || intent == .programmatic || jumping
            commanded = false
            if let revealing, intent != .idle || next.rows[revealing] != nil { self.revealing = nil }
            noPlace = false
            // Fractional settling and layout changes alone do not undo arrival. Continued animation or an unexplained
            // offset change can move the view off the target after it arrives.
            if arrived, moved, (intent == .programmatic || (!explained && !layoutChanged)),
               let guarded, abs(next.rows[guarded] ?? 1000) > Owner.pinTolerance {
                self.guarded = nil
                arrived = false
            }
            if jumping, let guarded, abs(next.rows[guarded] ?? 1000) <= Owner.pinTolerance { arrived = true; jumping = false }
            // The view moved away from the tail with nothing changed around it: someone other than the landing did it.
            if moved, !layoutChanged, next.probe.distance > NativeScrollFollower.repinSlack { afterLanding = false }
            if gesture, moved {
                // The reader acted: what a delivered ask guarded is theirs again; an ask still waiting for the finger stays.
                if !rowOpen { guarded = nil }
                let interruptedJump = jumping
                jumping = false
                afterLanding = false
                if next.probe.distance <= NativeScrollFollower.threshold {
                    if interruptedJump || !layoutChanged || next.probe.offset > previous.probe.offset {
                        atTail = true
                        scrolledUp = false
                    }
                } else if next.probe.distance > previous.probe.distance, !layoutChanged {
                    // Moving up out of the band detaches only when no layout change can explain it.
                    scrolledUp = true
                    atTail = false
                    owed = false
                    awaitingEcho = false
                    followingSend = false
                }
            } else if intent == .idle, abs(next.probe.offset - previous.probe.offset) > Owner.pinTolerance, !layoutChanged, !explained {
                // Nobody asked and nothing was commanded: the reader moved the view some other way (VoiceOver paging).
                atTail = next.probe.distance <= NativeScrollFollower.repinSlack
                scrolledUp = !atTail
                owed = false
                if !atTail {
                    awaitingEcho = false
                    followingSend = false
                }
            }
            // A gesture reading at the tail confirms where the reader is even if the previous reading already got there.
            if gesture, !layoutChanged, !jumping, next.probe.distance <= NativeScrollFollower.threshold {
                atTail = true
                scrolledUp = false
            }
            if next.probe.distance <= NativeScrollFollower.repinSlack {
                owed = false
            } else if atTail, layoutChanged || (followingSend && next.probe.distance > previous.probe.distance) {
                owed = true
            }
        }
    }

    // MARK: The walk

    struct Walk {
        let alphabet: [Event]
        let depth: Int
        var nodes = 0
        var premises = [Rule: Int]()
        var failures = [Rule: [String]]()
        var failureCounts = [Rule: Int]()

        mutating func walk(_ owner: Owner, _ spec: Spec, path: inout [Event]) {
            for event in alphabet {
                switch event {
                case .setIntent(let next) where next == spec.intent: continue
                case .remove(let row) where spec.removed & spec.removalBit(row) != 0: continue
                case .askRow where spec.removed & 1 != 0: continue
                // Completion is for a matching animation after its final reading, not a synthetic idle signal.
                case .jumpCompleted where !spec.completionReady: continue
                case .userTurnArrived where !spec.awaitingEcho: continue
                default: break
                }
                var owner = owner
                var spec = spec
                let decision: Owner.Decision
                switch event {
                case .setIntent(let next):
                    owner.setIntent(next)
                    decision = .none
                case .read(let g): decision = owner.read(readings[spec.removed][g], intent: spec.intent)
                case .askLatest: decision = owner.jumpToLatest()
                case .askRow: decision = owner.jumpToRow(row)
                case .remove(let row): decision = owner.rowsChanged(orders[spec.removed | spec.removalBit(row)])
                case .output:
                    owner.contentArrived()
                    decision = .none
                case .turn: decision = owner.turn()
                case .jumpCompleted:
                    owner.jumpCompleted()
                    decision = .none
                case .mount: decision = owner.mount()
                case .newSession:
                    owner.newSession()
                    decision = owner.rowsChanged(orders[0])
                case .sent(let queued, let turnPresent): decision = owner.sent(queued: queued, turnPresent: turnPresent)
                case .userTurnArrived: decision = owner.userTurnArrived()
                }
                let result = spec.step(event, decision, owner: owner)
                nodes += 1
                for rule in result.premises { premises[rule, default: 0] += 1 }
                path.append(event)
                if result.fails.isEmpty {
                    if path.count < depth { walk(owner, spec, path: &path) }
                } else {
                    // The first failing prefix is the sequence; its extensions are the same failure.
                    for rule in Set(result.fails) {
                        failureCounts[rule, default: 0] += 1
                        // Keep the six shortest.
                        var kept = failures[rule, default: []]
                        if kept.count < 6 || path.count < Int(kept.last!.prefix { $0 != " " })! {
                            let actual = rule == .d ? "next idle turn did not land (\(decision) at this event)" : "\(decision)"
                            kept.append("\(path.count) events: " + path.map(\.description).joined(separator: ", ") + " -> \(actual)")
                            kept.sort { Int($0.prefix { $0 != " " })! < Int($1.prefix { $0 != " " })! }
                            failures[rule] = Array(kept.prefix(6))
                        }
                    }
                }
                path.removeLast()
            }
        }
    }

    @Test func theSpecRejectsASecondLandingWithNothingOwed() {
        var spec = Spec(iOS: false)
        let owner = Owner()
        #expect(spec.step(.askLatest, .land, owner: owner).fails.isEmpty)
        #expect(spec.step(.turn, .land, owner: owner).fails.contains(.c))
    }

    @Test func theSpecRejectsAMountThatLandsAReaderWithAKeptRow() {
        var spec = Spec(iOS: false)
        let owner = Owner()
        _ = spec.step(.setIntent(.touching), .none, owner: owner)
        _ = spec.step(.read(2), .none, owner: owner)
        _ = spec.step(.setIntent(.idle), .none, owner: owner)
        #expect(spec.step(.mount, .land, owner: owner).fails.contains(.f))
    }

    @Test(arguments: [false, true], [false, true])
    func everySequenceKeepsTheSixRules(iOS: Bool, focused: Bool) {
        var owner = Owner(asksInterruptTouch: !iOS)
        _ = owner.rowsChanged(Self.orders[0])
        _ = owner.read(Self.readings[0][0], intent: .idle)
        var walk = Walk(alphabet: focused ? Self.requestAlphabet : Self.alphabet, depth: focused ? 7 : 6)
        var path = [Event]()
        walk.walk(owner, Spec(iOS: iOS), path: &path)
        let name = "\(iOS ? "iOS" : "Mac")/\(focused ? "requests" : "broad")"
        print("EXHAUSTIVE \(name): alphabet \(walk.alphabet.count), depth \(walk.depth), sequences \(walk.nodes)")
        for rule in Rule.allCases {
            let shortest = walk.failures[rule] ?? []
            print("EXHAUSTIVE \(name) rule \(rule): premise held in \(walk.premises[rule] ?? 0) sequences, \(walk.failureCounts[rule] ?? 0) minimal failing sequences")
            for line in shortest { print("EXHAUSTIVE \(name) rule \(rule) FAIL: \(line)") }
        }
        for rule in Rule.allCases {
            #expect((walk.premises[rule] ?? 0) > 1000, "rule \(rule) premise held in \(walk.premises[rule] ?? 0) sequences")
            #expect((walk.failureCounts[rule] ?? 0) == 0, "rule \(rule) failed, first: \(walk.failures[rule]?.first ?? "")")
        }
    }
}
