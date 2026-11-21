import Foundation
import Testing
import ShepherdRemote
import ShepherdTestKit

/// Every event sequence over a small alphabet, up to the walk's depth, checked against a spec model that never reads the
/// owner's `mode`, `follows` or `outstanding`. Random scripts missed two bugs that are three to five events long, and the
/// invariants beside them lean on the owner's own state; this walks all of them, and the oracle is only what an observer sees.
///
/// The spec (`Spec`) tracks: the reader's intent, the last reading, the reader's open request (none, the tail, `row-2`), the row a
/// request is guarding, and whether the reader is "following" by an observer's definition (at the tail, and has not scrolled up out
/// of the band since). Six rules over the owner's returned decisions:
/// - a. nothing automatic while the intent is not `idle`; a delivered ask is the exception (on iOS not under a finger);
/// - b. a waiting request is not passed by compensation; a delivered row ask keeps its row, and a hold restores the kept offset;
/// - c. a request is delivered at most once, a row ask only to the row asked for; an automatic landing needs unpaid debt;
/// - d. a waiting tail ask or a follower's unpaid layout landing is delivered by one more turn at idle;
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

    static let geometryNames = ["tail", "band", "far", "grown", "top", "mid", "fractional", "resized", "pastTail"]
    static let shapes: [(content: Double, offset: Double)] = [
        (2000, 1420), (2000, 1400), (2000, 700), (2400, 1420), (2100, 400), (2000, 1200), (2100, 399.5),
        (2000, 1420), (1800, 1420),
    ]
    // At a fractional arrival row-2 is 0.5 pt below the top, with the last 0.5 pt of row-1 still visible.
    static let drops: [Set<String>] = [[], [row], [historyRow], [row, historyRow]]
    static let readings = drops.map { drop in
        shapes.enumerated().map { index, shape in
            // The resize increases the gap; a shrink can leave the old offset briefly beyond the native tail.
            let resized = index == 7
            return Fixture.reading(content: shape.content, offset: shape.offset, drop: drop,
                                   container: resized ? 460 : 520, width: resized ? 500 : 640)
        }
    }
    static let orders = drops.map { drop in Fixture.order.filter { !drop.contains($0) } }

    static let requests: [Event] = [.askLatest, .askRow, .remove(row), .remove(historyRow), .turn]
    static let alphabet: [Event] = [.setIntent(.idle), .setIntent(.touching), .setIntent(.coasting), .setIntent(.programmatic)]
        + shapes.indices.map { .read($0) } + requests + [.output, .jumpCompleted, .mount, .newSession,
            .sent(queued: false, turnPresent: true), .sent(queued: false, turnPresent: false),
            .sent(queued: true, turnPresent: false), .userTurnArrived]
    static let requestAlphabet: [Event] = [.setIntent(.idle), .setIntent(.touching), .read(0), .read(2), .read(3)] + requests
        + [.sent(queued: false, turnPresent: true)]

    static func removalBit(_ row: String) -> Int { row == Self.row ? 1 : 2 }

    // MARK: The spec

    struct Spec {
        enum Request: Equatable { case none, latest, row(String) }

        // Contract values from the plan, not from the implementation under test.
        static let rowSlop = 1.0
        static let tailSlop = 4.0
        static let returnBand = 80.0

        let iOS: Bool
        var intent = Intent.idle
        var view = readings[0][0]
        var request = Request.none
        /// The row a request guards, from the ask until the reader acts or the driver says the animation is over.
        var guarded: String?
        /// The reader chose to follow the tail and has not navigated away. This does not deliver a pending request.
        var following = true
        var scrolledUp = false
        var afterLanding = false
        var owed = false
        var lands = 0
        var commanded = false
        var revealing: String?
        var removed = 0
        var awaitingEcho = false
        var followingSend = false
        /// The last observed place to preserve, when the trace establishes one.
        var kept: (row: String, offset: Double)?
        /// A mount that may have kept the reader's place: the next reading is where the view is put back, not a move to learn from.
        var skipNext = false
        /// A delivered jump has not arrived, been completed or been taken over.
        var jumping = false
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
                following = true
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
                if jumping || noPlace || following {
                    following = true
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
                    let detached = !following
                    request = detached || request == .latest ? .latest : .none
                    revealing = nil
                    guarded = nil
                    jumping = false
                    following = true
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
                let oldOrder = orders[removed]
                removed |= removalBit(removedRow)
                if let place = kept, place.row == removedRow, let index = oldOrder.firstIndex(of: removedRow) {
                    let replacement = oldOrder[..<index].last ?? oldOrder.dropFirst(index + 1).first
                    kept = replacement.map { ($0, place.offset) }
                }
                if revealing == removedRow { revealing = nil }
                if request == .row(removedRow) { request = .none }
                if guarded == removedRow {
                    guarded = nil
                    noPlace = jumping
                    if jumping { kept = nil }
                    // A cancelled animation that never left the band leaves a follower.
                    if jumping, !skipNext, view.probe.distance <= Self.returnBand {
                        following = true
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
                    } else if view.probe.distance <= Self.returnBand {
                        following = true
                        scrolledUp = false
                    } else if let guarded, let offset = view.rows[guarded] {
                        kept = (guarded, offset)
                    } else if let top = view.topRow, let offset = view.rows[top] {
                        // Prefer the old top row if it still exists. The clamped jump's final sample may predate a removal.
                        if orders[removed].contains(top) {
                            kept = (top, offset)
                        } else {
                            kept = view.rows.filter { orders[removed].contains($0.key) && $0.value >= offset }
                                .min { $0.value < $1.value }.map { ($0.key, $0.value) }
                            noPlace = kept == nil
                        }
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
            if case .hold(let anchor) = decision {
                if target == nil { premises.append(.b) }
                if request != .none || (kept.map { $0.row != anchor.row || $0.offset != anchor.offset } ?? false) {
                    if !fails.contains(.b) { fails.append(.b) }
                }
            } else if case .reveal = decision, request != .none {
                if target == nil { premises.append(.b) }
                if !fails.contains(.b) { fails.append(.b) }
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
                    kept = nil
                    arrived = false
                    following = false
                    owed = false
                } else {
                    fails.append(.c)
                }
            case .land:
                revealing = nil
                if request == .latest {
                    if case .read = event { fails.append(.c) }
                    request = .none
                    afterLanding = true
                } else if !rowOpen, !(following && owed) {
                    fails.append(.c)
                }
                following = true
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
            if case .read(let g) = event { view = readings[removed][g] }
            // d. A waiting tail ask or unpaid automatic debt must land on the next idle turn.
            if request == .latest || (owed && following && request == .none && lands <= 2) {
                premises.append(.d)
                var rest = owner
                rest.setIntent(.idle)
                if rest.turn() != .land { fails.append(.d) }
            }
            return (fails, premises)
        }

        private mutating func keepTop(of view: Owner.Reading) {
            kept = view.topRow.flatMap { row in view.rows[row].map { (row, $0) } }
        }

        private mutating func reading(_ next: Owner.Reading) {
            let previous = view
            if skipNext {
                skipNext = false
                commanded = false
                noPlace = false
                if jumping, let guarded, let top = next.rows[guarded], abs(top) <= Self.rowSlop {
                    jumping = false
                    arrived = true
                    kept = (guarded, top)
                } else if !following, !jumping, intent != .idle || kept == nil {
                    keepTop(of: next)
                }
                return
            }
            let layoutChanged = next.probe.content != previous.probe.content || next.probe.container != previous.probe.container
                || next.probe.inset != previous.probe.inset || next.probe.insetTop != previous.probe.insetTop
                || next.width != previous.width
            let moved = next.probe.offset != previous.probe.offset
            let explained = commanded || revealing != nil || intent == .programmatic || jumping
            commanded = false
            if let revealing, intent != .idle || next.rows[revealing] != nil { self.revealing = nil }
            noPlace = false
            // Fractional settling and layout changes alone do not undo arrival. Continued animation or an unexplained
            // offset change can move the view off the target after it arrives.
            if arrived, moved, (intent == .programmatic || (!explained && !layoutChanged)),
               let guarded, abs(next.rows[guarded] ?? 1000) > Self.rowSlop {
                self.guarded = nil
                arrived = false
            }
            if jumping, let guarded, let top = next.rows[guarded], abs(top) <= Self.rowSlop {
                arrived = true
                jumping = false
                kept = (guarded, top)
            }
            // The view moved away from the tail with nothing changed around it: someone other than the landing did it.
            if moved, !layoutChanged, next.probe.distance > Self.tailSlop { afterLanding = false }
            if gesture, moved {
                // The reader acted: what a delivered ask guarded is theirs again; an ask still waiting for the finger stays.
                if !rowOpen { guarded = nil }
                let interruptedJump = jumping
                jumping = false
                afterLanding = false
                if next.probe.distance <= Self.returnBand {
                    let closer = next.probe.offset > previous.probe.offset && next.probe.distance < previous.probe.distance
                    if interruptedJump || !layoutChanged || closer {
                        following = true
                        scrolledUp = false
                    }
                } else if next.probe.distance > previous.probe.distance, !layoutChanged {
                    // Moving up out of the band detaches only when no layout change can explain it.
                    scrolledUp = true
                    following = false
                    owed = false
                    awaitingEcho = false
                    followingSend = false
                }
            } else if intent == .idle, abs(next.probe.offset - previous.probe.offset) > Self.rowSlop, !layoutChanged, !explained {
                // Nobody asked and nothing was commanded: the reader moved the view some other way (VoiceOver paging).
                following = next.probe.distance <= Self.tailSlop
                scrolledUp = !following
                owed = false
                if !following {
                    keepTop(of: next)
                    awaitingEcho = false
                    followingSend = false
                }
            }
            // A gesture reading at the tail confirms where the reader is even if the previous reading already got there.
            if gesture, !layoutChanged, !jumping, next.probe.distance <= Self.returnBand {
                following = true
                scrolledUp = false
            }
            if following {
                kept = nil
            } else if !jumping, intent != .idle || kept == nil {
                // Preserve a row that arrived at the top, even if its neighbour is barely visible.
                let stillAtTop = kept.map { abs($0.offset) <= Self.rowSlop && abs(next.rows[$0.row] ?? 1000) <= Self.rowSlop } ?? false
                if !stillAtTop || (gesture && moved) { keepTop(of: next) }
            }
            // With native size anchoring, the first overrun during layout can be transient. When the sizes are
            // stable, a viewport beyond the maximum (including the top margin) needs a corrective landing.
            let overrun = min(0, next.probe.content - next.probe.container) - max(0, next.probe.insetTop)
            if following, !layoutChanged, next.probe.distance < overrun - Self.tailSlop {
                owed = true
            } else if next.probe.distance <= Self.tailSlop {
                owed = false
            } else if following, layoutChanged || (followingSend && next.probe.distance > previous.probe.distance) {
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

        mutating func walk(_ owner: Owner, _ spec: Spec, path: inout [Event], intent: Intent = .idle,
                           removed: Int = 0, animationSampled: Bool? = nil) {
            for event in alphabet {
                switch event {
                case .setIntent(let next) where next == intent: continue
                case .remove(let row) where removed & removalBit(row) != 0: continue
                case .askRow where removed & 1 != 0: continue
                // Only complete an animation we saw start, after at least one reading. Never prune on spec state.
                case .jumpCompleted where animationSampled != true: continue
                default: break
                }
                var owner = owner
                var spec = spec
                var intent = intent, removed = removed, animationSampled = animationSampled
                let decision: Owner.Decision
                switch event {
                case .setIntent(let next):
                    intent = next
                    owner.setIntent(next)
                    decision = .none
                case .read(let g):
                    decision = owner.read(readings[removed][g], intent: intent)
                    if animationSampled != nil { animationSampled = true }
                case .askLatest: decision = owner.jumpToLatest()
                case .askRow: decision = owner.jumpToRow(row)
                case .remove(let row):
                    removed |= removalBit(row)
                    if row == ThreadScrollOwnerExhaustiveTests.row { animationSampled = nil }
                    decision = owner.rowsChanged(orders[removed])
                case .output:
                    owner.contentArrived()
                    decision = .none
                case .turn: decision = owner.turn()
                case .jumpCompleted:
                    animationSampled = nil
                    owner.jumpCompleted()
                    decision = .none
                case .mount:
                    animationSampled = nil
                    decision = owner.mount()
                case .newSession:
                    removed = 0
                    animationSampled = nil
                    owner.newSession()
                    decision = owner.rowsChanged(orders[0])
                case .sent(let queued, let turnPresent): decision = owner.sent(queued: queued, turnPresent: turnPresent)
                case .userTurnArrived: decision = owner.userTurnArrived()
                }
                if case .scroll = decision { animationSampled = false }
                if decision == .land { animationSampled = nil }
                let result = spec.step(event, decision, owner: owner)
                nodes += 1
                for rule in result.premises { premises[rule, default: 0] += 1 }
                path.append(event)
                if result.fails.isEmpty {
                    if path.count < depth {
                        walk(owner, spec, path: &path, intent: intent, removed: removed, animationSampled: animationSampled)
                    }
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

    @Test func theSpecRejectsAnAutomaticLandingDuringACoast() {
        var spec = Spec(iOS: false)
        let owner = Owner()
        #expect(spec.step(.setIntent(.coasting), .none, owner: owner).fails.isEmpty)
        #expect(spec.step(.read(3), .land, owner: owner).fails.contains(.a))
    }

    @Test func theSpecRejectsAHoldWithTheWrongOffsetAfterArrival() {
        var spec = Spec(iOS: false)
        let owner = Owner()
        #expect(spec.step(.askRow, .scroll(toRow: Self.row, animated: true), owner: owner).fails.isEmpty)
        #expect(spec.step(.read(6), .none, owner: owner).fails.isEmpty)
        #expect(spec.step(.read(4), .hold(.init(row: Self.row, offset: 0)), owner: owner).fails.contains(.b))
    }

    @Test func theSpecRejectsForgettingATailAskAfterAnAttachedSend() {
        var spec = Spec(iOS: true)
        var owner = Owner(asksInterruptTouch: false)
        owner.setIntent(.touching)
        #expect(spec.step(.setIntent(.touching), .none, owner: owner).fails.isEmpty)
        #expect(spec.step(.read(2), .none, owner: owner).fails.isEmpty)
        #expect(spec.step(.askLatest, owner.jumpToLatest(), owner: owner).fails.isEmpty)
        // Inject the wrong state: send did not land and the next idle turn can no longer deliver the ask.
        let lost = Owner(asksInterruptTouch: false)
        #expect(spec.step(.sent(queued: false, turnPresent: true), .none, owner: lost).fails.contains(.d))
    }

    @Test func theSpecRejectsRevealingHistoryAfterLandingAtTheTail() {
        var spec = Spec(iOS: false)
        let owner = Owner()
        #expect(spec.step(.askLatest, .land, owner: owner).fails.isEmpty)
        #expect(spec.step(.turn, .reveal(Self.row), owner: owner).fails.contains(.e))
    }

    @Test(arguments: [false, true])
    func shallowSequencesKeepTheSixRules(iOS: Bool) {
        _ = checkWalk(iOS: iOS, focused: false, depth: 3, minimum: 0)
    }

    static let completion = "all four full-depth owner walks passed"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_SCROLL_OWNER_FULL"] == "1",
                   "SHEPHERD_SCROLL_OWNER_FULL=1 enables the full-depth walks"))
    func fullDepthSequencesKeepTheSixRules() async throws {
        let passed = await withTaskGroup(of: Bool.self) { group in
            for iOS in [false, true] {
                for focused in [false, true] {
                    group.addTask {
                        let result = checkWalk(iOS: iOS, focused: focused, depth: focused ? 7 : 6, minimum: 1000)
                        do {
                            try ValidationEvidence.record(in: ValidationEvidence.directory, step: result.name,
                                                          status: result.passed ? "passed" : "failed",
                                                          expected: "all six rules exercised and no failures", actual: result.summary,
                                                          evidence: ["mac/run.log"])
                            return result.passed
                        } catch {
                            Issue.record(error)
                            return false
                        }
                    }
                }
            }
            var allPassed = true
            for await passed in group { allPassed = passed && allPassed }
            return allPassed
        }
        if passed {
            try ValidationEvidence.record(in: ValidationEvidence.directory, step: "complete", status: "passed",
                                          expected: Self.completion, actual: Self.completion)
        }
    }

    private func checkWalk(iOS: Bool, focused: Bool, depth: Int, minimum: Int) -> (name: String, passed: Bool, summary: String) {
        var owner = Owner(asksInterruptTouch: !iOS)
        _ = owner.rowsChanged(Self.orders[0])
        _ = owner.read(Self.readings[0][0], intent: .idle)
        var walk = Walk(alphabet: focused ? Self.requestAlphabet : Self.alphabet, depth: depth)
        var path = [Event]()
        walk.walk(owner, Spec(iOS: iOS), path: &path)
        let name = "\(iOS ? "ios" : "mac")-\(focused ? "requests" : "broad")"
        var passed = true
        var summary = ["alphabet \(walk.alphabet.count), depth \(walk.depth), sequences \(walk.nodes)"]
        print("EXHAUSTIVE \(name): \(summary[0])")
        for rule in Rule.allCases {
            let premises = walk.premises[rule] ?? 0, failures = walk.failureCounts[rule] ?? 0
            let count = "rule \(rule): premise held in \(premises) sequences, \(failures) minimal failing sequences"
            summary.append(count)
            print("EXHAUSTIVE \(name) \(count)")
            for line in walk.failures[rule] ?? [] { print("EXHAUSTIVE \(name) rule \(rule) FAIL: \(line)") }
            #expect(premises > minimum, "\(name) \(count)")
            #expect(failures == 0, "\(name) rule \(rule) failed, first: \(walk.failures[rule]?.first ?? "")")
            passed = passed && premises > minimum && failures == 0
        }
        return (name, passed, summary.joined(separator: "\n"))
    }
}
