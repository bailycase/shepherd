import Testing
import ShepherdRemote

/// Round 5: every event sequence over a small alphabet, up to `depth` events, checked against a spec model that never reads the
/// owner's `mode`, `follows` or `outstanding`. Random scripts missed two bugs that are three to five events long, and the
/// invariants beside them lean on the owner's own state; this walks all of them, and the oracle is only what an observer sees.
///
/// The spec (`Spec`) tracks: the reader's intent, the last reading, the reader's open request (none, the tail, `row-2`), the row a
/// request is guarding, and whether the reader is "following" by an observer's definition (at the tail, and has not scrolled up out
/// of the band since). Six rules over the owner's returned decisions:
/// - a. nothing automatic while the intent is not `idle`; a delivered ask is the exception (on iOS not under a finger);
/// - b. after the reader asks for a row, until they act again, the view is never moved to any other row, and never landed;
/// - c. a request is delivered at most once, a row ask only to the row asked for;
/// - d. an observer-following thread the layout grew off its tail is landed by one more turn at idle (a cancelled row request
///   must not lose this);
/// - e. after a jump to the tail lands, nothing reveals or holds a row;
/// - f. after the reader scrolls up out of the band, nothing lands them unless they ask or come back.
@Suite("Thread scroll owner: exhaustive small scope")
struct ThreadScrollOwnerExhaustiveTests {
    typealias Owner = ThreadScrollOwner
    typealias Fixture = ThreadScrollOwnerTests
    typealias Intent = ThreadScrollOwner.Intent

    /// Longest sequence walked. 17 events at depth 6 is about 24 million sequences.
    static let depth = 6
    static let row = "row-2"

    enum Rule: String, CaseIterable { case a, b, c, d, e, f }

    enum Event: CustomStringConvertible {
        case setIntent(Intent), read(Int), askLatest, askRow, removeRow, output, turn, jumpCompleted, mount

        var description: String {
            switch self {
            case .setIntent(let intent): "intent(\(intent))"
            case .read(let g): "read(\(geometryNames[g]))"
            case .askLatest: "askLatest"
            case .askRow: "askRow"
            case .removeRow: "removeRow"
            case .output: "output"
            case .turn: "turn"
            case .jumpCompleted: "jumpCompleted"
            case .mount: "mount"
            }
        }
    }

    // MARK: Geometries (the standard fixture: 520 pt viewport, rows 200 pt)

    static let geometryNames = ["tail", "band", "far", "grown", "top", "mid"]
    /// At the tail; 20 pt up, inside the band; far up; content grew under the reader at the tail's offset; `row-2` at the top of
    /// the view (content grown too); an offset on the way to a jump.
    static let shapes: [(content: Double, offset: Double)] = [(2000, 1420), (2000, 1400), (2000, 700), (2400, 1420), (2100, 400), (2000, 1200)]
    /// `[removed][shape]`: after `row-2` leaves the order the lazy stack no longer shows it.
    static let readings: [[Owner.Reading]] = [[], ["row-2"]].map { drop in
        shapes.map { Fixture.reading(content: $0.content, offset: $0.offset, drop: Set(drop)) }
    }
    static let order = Fixture.order
    static let orderWithoutRow = Fixture.order.filter { $0 != row }

    static let alphabet: [Event] = [.setIntent(.idle), .setIntent(.touching), .setIntent(.coasting), .setIntent(.programmatic)]
        + (0..<shapes.count).map { .read($0) } + [.askLatest, .askRow, .removeRow, .output, .turn, .jumpCompleted, .mount]

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
        /// The view moved and nothing explains how; rules d and f wait for the reader or a landing to say where they are.
        var lost = false
        var afterLanding = false
        var owed = false
        var lands = 0
        var commanded = false
        var removed = false
        /// A mount that may have kept the reader's place: the next reading is where the view is put back, not a move to learn from.
        var skipNext = false
        /// A delivered jump has not arrived, been completed or been taken over.
        var jumping = false
        var arrived = false
        /// A jump's row left the order mid-flight: nothing is kept, the next reading anchors the reader.
        var noPlace = false

        var rowOpen: Bool { if case .row = request { true } else { false } }
        var gesture: Bool { intent == .touching || intent == .coasting }
        var following: Bool { atTail && !rowOpen }

        /// What the owner decided for `event`, given everything an observer saw. Returns the rules it broke and the rules whose
        /// premise held (the sequence was a real test of them).
        mutating func step(_ event: Event, _ decision: Owner.Decision, owner: Owner) -> (fails: [Rule], premises: [Rule]) {
            var fails = [Rule](), premises = [Rule]()
            var canDecide = true
            var mountLanded = false
            switch event {
            case .setIntent(let next): intent = next; canDecide = false
            case .output: canDecide = false
            case .askLatest: request = .latest; guarded = nil; jumping = false; afterLanding = false
            case .askRow: request = .row(row); guarded = row; afterLanding = false
            case .mount:
                // A mount re-sticks a reader with nothing kept (the design in `mount()`): it may land them, or leave the observer unsure.
                request = .none
                guarded = nil
                afterLanding = false
                let restick = jumping || noPlace
                jumping = false
                noPlace = false
                if decision == .land || restick {
                    atTail = true
                    scrolledUp = false
                    lost = false
                    owed = false
                    if decision == .land {
                        lands += 1
                        mountLanded = true
                    }
                } else if !atTail || lost {
                    lost = true
                    owed = false
                    skipNext = true
                }
            case .removeRow:
                if rowOpen { request = .none }
                guarded = nil
                noPlace = jumping
                // The animation to a row that is gone is cancelled where it is: a view that never left the band is still at the tail.
                if jumping, view.probe.distance <= NativeScrollFollower.threshold { atTail = true; noPlace = false }
                jumping = false
                removed = true
            case .jumpCompleted:
                canDecide = false
                // Before any reading since a mount, nobody knows where the animation stopped.
                if jumping, skipNext { lost = true; owed = false }
                else if jumping, view.probe.distance <= NativeScrollFollower.threshold { atTail = true; lost = false }
                guarded = nil
                jumping = false
            case .turn: break
            case .read(let g): reading(readings[removed ? 1 : 0][g])
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
            // c and f. A request is delivered once, to what was asked; a landing nobody asked for needs a reader at the tail.
            if decision != .none { premises.append(.c) }
            switch decision {
            case .scroll(let r, _):
                if request == .row(r) {
                    request = .none
                    jumping = true
                    arrived = false
                    atTail = false
                    owed = false
                } else {
                    fails.append(.c)
                }
            case .land where request == .latest:
                request = .none
                atTail = true
                scrolledUp = false
                lost = false
                afterLanding = true
                owed = false
                lands += 1
            case .land where mountLanded: break
            case .land:
                if !lost, !rowOpen, !following { fails.append(scrolledUp ? .f : .c) }
                if scrolledUp, !lost { premises.append(.f) }
                owed = false
                lands += 1
            default: break
            }
            if scrolledUp, !lost, canDecide { premises.append(.f) }
            // e. After a jump to the tail, the row just left is not put back.
            if afterLanding, canDecide {
                premises.append(.e)
                switch decision {
                case .reveal, .hold: fails.append(.e)
                default: break
                }
            }
            if decision != .none { commanded = true }
            if case .read(let g) = event { view = readings[removed ? 1 : 0][g] }
            // d. Owed a landing: one more turn at idle delivers it.
            if owed, atTail, !rowOpen, !lost, lands <= 2 {
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
                return
            }
            let layoutChanged = next.probe.layoutDiffers(from: previous.probe)
            let moved = next.probe.offset != previous.probe.offset
            let explained = commanded || intent == .programmatic || (guarded != nil && !rowOpen)
            commanded = false
            noPlace = false
            // A row at the top of the view is the jump's arrival; the view moving off it afterwards is not the jump's doing.
            if arrived, moved { guarded = nil; arrived = false; jumping = false }
            if let guarded, abs(next.rows[guarded] ?? 1000) <= Owner.pinTolerance { arrived = true; jumping = false }
            // The view moved away from the tail with nothing changed around it: someone other than the landing did it.
            if moved, !layoutChanged, next.probe.distance > NativeScrollFollower.repinSlack { afterLanding = false }
            if gesture, moved {
                // The reader acted: what a delivered ask guarded is theirs again; an ask still waiting for the finger stays.
                if !rowOpen { guarded = nil }
                jumping = false
                afterLanding = false
                if next.probe.distance <= NativeScrollFollower.threshold {
                    if layoutChanged, next.probe.offset <= previous.probe.offset {
                        // Not down, in the band, and the layout changed: the band may have come to the reader.
                        lost = true
                        owed = false
                    } else {
                        atTail = true
                        scrolledUp = false
                        lost = false
                    }
                } else if next.probe.offset < previous.probe.offset {
                    // Up and out of the band. With the layout changed in the same reading the owner cannot tell, and neither can this.
                    if layoutChanged { lost = true } else { scrolledUp = true }
                    atTail = false
                    owed = false
                }
            } else if intent == .idle, moved, !layoutChanged, !explained {
                // Nobody asked and nothing was commanded: the reader moved the view some other way (VoiceOver paging).
                if next.probe.distance > NativeScrollFollower.threshold {
                    scrolledUp = true
                    atTail = false
                    owed = false
                } else {
                    lost = true
                    owed = false
                }
            }
            if next.probe.distance <= NativeScrollFollower.repinSlack {
                owed = false
            } else if atTail, !lost, next.probe.content > previous.probe.content {
                owed = true
            }
        }
    }

    // MARK: The walk

    struct Walk {
        let iOS: Bool
        var nodes = 0
        var premises = [Rule: Int]()
        var failures = [Rule: [String]]()
        var failureCounts = [Rule: Int]()

        mutating func walk(_ owner: Owner, _ spec: Spec, path: inout [Event], depth: Int) {
            for event in alphabet {
                switch event {
                case .setIntent(let next) where next == spec.intent: continue
                case .removeRow where spec.removed: continue
                case .askRow where spec.removed: continue
                default: break
                }
                var owner = owner
                var spec = spec
                let decision: Owner.Decision
                switch event {
                case .setIntent(let next):
                    owner.setIntent(next)
                    decision = .none
                case .read(let g): decision = owner.read(readings[spec.removed ? 1 : 0][g], intent: spec.intent)
                case .askLatest: decision = owner.jumpToLatest()
                case .askRow: decision = owner.jumpToRow(row)
                case .removeRow: decision = owner.rowsChanged(orderWithoutRow)
                case .output:
                    owner.contentArrived()
                    decision = .none
                case .turn: decision = owner.turn()
                case .jumpCompleted:
                    owner.jumpCompleted()
                    decision = .none
                case .mount: decision = owner.mount()
                }
                let result = spec.step(event, decision, owner: owner)
                nodes += 1
                for rule in result.premises { premises[rule, default: 0] += 1 }
                path.append(event)
                if result.fails.isEmpty {
                    if depth + 1 < ThreadScrollOwnerExhaustiveTests.depth { walk(owner, spec, path: &path, depth: depth + 1) }
                } else {
                    // The first failing prefix is the sequence; its extensions are the same failure.
                    for rule in Set(result.fails) {
                        failureCounts[rule, default: 0] += 1
                        // Keep the six shortest.
                        var kept = failures[rule, default: []]
                        kept.append("\(path.count) events: " + path.map(\.description).joined(separator: ", ") + " -> \(decision)")
                        kept.sort { Int($0.prefix { $0 != " " })! < Int($1.prefix { $0 != " " })! }
                        failures[rule] = Array(kept.prefix(6))
                    }
                }
                path.removeLast()
            }
        }
    }

    static func run(iOS: Bool) -> Walk {
        var owner = Owner(asksInterruptTouch: !iOS)
        _ = owner.rowsChanged(order)
        _ = owner.read(readings[0][0], intent: .idle)
        var walk = Walk(iOS: iOS)
        var path = [Event]()
        walk.walk(owner, Spec(iOS: iOS), path: &path, depth: 0)
        return walk
    }

    @Test(arguments: [false, true])
    func everySequenceKeepsTheSixRules(iOS: Bool) {
        let walk = Self.run(iOS: iOS)
        let name = iOS ? "iOS" : "Mac"
        print("EXHAUSTIVE \(name): alphabet \(Self.alphabet.count), depth \(Self.depth), sequences \(walk.nodes)")
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
