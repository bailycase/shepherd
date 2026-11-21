import Foundation

/// The one decision-maker for where a thread's transcript sits, as a value. A platform driver feeds it what it can see (a geometry
/// reading with the rows it measured, the reader's motion, the reader's requests) and carries out the `Decision` it returns; nothing
/// else decides a position. No view, scroll view or clock is involved: a test or a replay of a recorded run drives it the same way.
///
/// It holds one `Mode`. `following`: the reader is at the tail. `pinned`: the reader is elsewhere, and the owner keeps the row at the
/// top of the viewport and its distance from the viewport's top (`Anchor`), so a layout change above the reader is put back (`hold`)
/// instead of fought by a gate. `jumping`: an animated move to a row the reader asked for.
///
/// Rules, in the order the plan (`docs/plans/thread-scroll.md`, 4.1) gives them:
/// - Only the reader's motion changes the mode (`touching` or `coasting` moving it up with the layout unchanged detaches; coming
///   back inside `threshold` re-attaches). Layout never does.
/// - No automatic decision (`land`, `hold`, `reveal`) unless the intent is `idle`: not while the reader moves (`touching`,
///   `coasting`), not while the driver animates (`programmatic`). Mount, layout, row replacement, pending landings and a refreshed
///   budget are all automatic, and every one passes `automatic(_:)`, the single gate. The anchor is re-measured from the view every
///   reading, so the moment the reader stops it is where they are. Only the reader's own asks (`jumpToLatest`, `jumpToRow`, and the
///   send that asks) act at any intent: an ask lands at once on the Mac, and on iOS waits only for a finger (`asksInterruptTouch`).
/// - While `idle`, a pinned row that is not where it was kept is held there when layout moved it. An offset change beyond
///   `pinTolerance` nobody reported as the reader's (VoiceOver paging: idle, layout unchanged, no command in flight) is the reader
///   moving: where the view is, is the anchor, `following` if within `repinSlack` of the tail, else `pinned`.
/// - Outstanding work is one value, `Outstanding`: nothing, the reader's ask for the tail, the reader's ask for a row, or the tail
///   landing a follower is owed. The newest replaces the rest, and emitting a decision consumes its item in the same operation
///   (`issue`), whichever path emits it, so nothing can recreate it. Honoring the ask for the tail makes the owner follow in that
///   same operation.
/// - A `jumping` target survives layout, not the reader: the reader's intent (`touching` or `coasting` with the offset moving,
///   either way) ends it, whatever layout did in the same reading. So does arriving at the row (checked on the first reading too),
///   the row leaving the order, or the driver saying the animation is over (`jumpCompleted()`): no jump outlives its animation. Where
///   the view is on the way ends nothing.
/// - The reader's ask wins over what nobody asked for: while one waits (a row ask held by a finger on iOS, the tail), no landing,
///   hold or reveal goes out. Cancelling a row ask or superseding it with an attached send restores unpaid automatic debt.
/// - Automatic tail work is for a follower: it is recorded while the follower is off the tail, even when the reader's hand blocks
///   it, goes at the first idle turn, and is cancelled when the reader leaves the tail or the view is back on it.
/// - The tail landing keeps the budget `NativeTailRepin` has always given it: a layout that never settles stops being chased.
///
/// The three cases of a pinned row that cannot be held, as `docs/plans/thread-scroll.md` D3 specifies them:
/// 1. Not realized (the row is in the store's order, but the lazy stack has dropped it): `reveal(row)`, once; the next reading that
///    shows it is compensated with `hold`.
/// 2. Replaced (its ID left the order): the nearest surviving row of the old order, above before below, is pinned at the same
///    offset and revealed.
/// 3. Nothing survives: `following` and a `land` if the reader was within `repinSlack` of the tail before the change, else detached
///    with nothing to hold, which the next reading re-anchors where the reader is.
public struct ThreadScrollOwner: Equatable, Sendable {
    /// The reader's motion. Mirrors `ScrollIntent.State` (slice 2a) case for case; replace this with that type when both are on
    /// nightly and `ScrollIntent` is outside its `#if DEBUG` guard (slice 2a must move it before the swap), and the owner needs no
    /// other change.
    public enum Intent: Equatable, Sendable {
        case idle, touching, coasting, programmatic
    }

    public struct Anchor: Equatable, Sendable {
        public var row: String
        /// The row's top, from the viewport's top, in points.
        public var offset: Double
        public init(row: String, offset: Double) {
            self.row = row
            self.offset = offset
        }
    }

    /// The one thing the owner still owes. Each decision consumes its item; nothing else holds work.
    public enum Outstanding: Equatable, Sendable {
        case none
        /// The reader asked for the tail and it has not landed.
        case readerLatest
        /// The reader asked for a row while a finger was down (iOS); it goes at the lift.
        case readerRow(String)
        /// A follower is off its tail: a landing waits for the reader to stop (never the reader's ask).
        case autoTail
    }

    public enum Mode: Equatable, Sendable {
        case following
        /// Detached. Nil when no row was measured yet: there is nothing to hold, and the next reading anchors the reader.
        case pinned(Anchor?)
        case jumping(row: String)
    }

    /// What the driver saw: the tail probe, the width rows wrap to, the topmost row in the viewport and where each realized row's top
    /// sits from the viewport's top. Rows the lazy stack has not realized are absent.
    public struct Reading: Equatable, Sendable {
        public var probe: NativeScrollProbe
        public var width: Double
        public var topRow: String?
        public var rows: [String: Double]
        public init(probe: NativeScrollProbe, width: Double = 0, topRow: String? = nil, rows: [String: Double] = [:]) {
            self.probe = probe
            self.width = width
            self.topRow = topRow
            self.rows = rows
        }
    }

    /// What the driver carries out. At most one per call.
    public enum Decision: Equatable, Sendable {
        case none
        /// Put the view on the tail.
        case land
        /// Put this row where the anchor keeps it.
        case hold(Anchor)
        /// Make this row exist (scroll it into the lazy stack's window); the owner then compensates.
        case reveal(String)
        case scroll(toRow: String, animated: Bool)
    }

    /// Same band `NativeScrollFollower` re-attaches in.
    public static let threshold = NativeScrollFollower.threshold
    public static let repinSlack = NativeScrollFollower.repinSlack
    /// A pinned row this close to where it was kept is where it was kept (the plan's 1 pt displacement bound).
    public static let pinTolerance: Double = 1

    public private(set) var mode = Mode.following
    /// Output arrived while detached; cleared on re-attach.
    public private(set) var unseen = false
    /// The reader sent a message that goes in now: land on its turn once it is there (`userTurnArrived`).
    public private(set) var awaitingSentTurn = false
    /// A send owns the tail until the reader navigates away.
    public private(set) var followingSentTurn = false
    /// The store's row IDs in order, as last told (`rowsChanged`).
    public private(set) var order: [String] = []

    /// Whether the scroll view also keeps the tail itself (`NativeScrollFollower.observe`'s `nativeAnchor`).
    public var nativeAnchor: Bool
    /// What the thread keeps below its bottom marker (`NativeTailRepin.distance(of:belowMarker:)`).
    public let markerGap: Double
    /// Mac: an ask lands whatever the reader's hands are doing. iOS: an ask waits for a finger.
    public let asksInterruptTouch: Bool

    private var repin = NativeTailRepin()
    private var last: Reading?
    private var intent = Intent.idle
    /// A `reveal` was asked for the pinned row and it has not shown up since.
    private var revealing = false
    /// The driver was just told to move the view, so an offset change in the next reading is its doing, not the reader's.
    private var commanded = false
    /// A mount gave the reader back a kept row: the first reading puts it where it was kept, whatever else it differs in.
    private var placing = false
    /// Automatic debt survives a waiting reader request that is later cancelled or replaced without a landing.
    private enum TailDebt { case none, layout, mount }
    private var tailOwed = TailDebt.none
    /// What is owed, if anything. For a driver or a test to see; the owner is its only writer.
    public private(set) var outstanding = Outstanding.none

    /// `mode` is what a transcript kept (`kept`) when it was last shown, or where a replay of a recording starts.
    public init(mode: Mode = .following, nativeAnchor: Bool = true, markerGap: Double = 0, asksInterruptTouch: Bool = true) {
        self.mode = mode
        self.nativeAnchor = nativeAnchor
        self.markerGap = markerGap
        self.asksInterruptTouch = asksInterruptTouch
    }

    public var follows: Bool { mode == .following }
    public var isJumping: Bool {
        if case .jumping = mode { true } else { false }
    }

    /// What a later mount puts back: following, or the anchor. A jump in flight is not kept.
    public var kept: Mode {
        if case .jumping = mode { .pinned(nil) } else { mode }
    }

    public func showsJump(running: Bool) -> Bool { NativeScrollFollower.showsJump(sticky: follows, unseen: unseen, running: running) }

    private var readerMoves: Bool { intent == .touching || intent == .coasting }

    // MARK: Readings

    /// One geometry reading. Returns a landing for a following view that needs one now (inside the pass, within the pin's budget; the
    /// rest are `turn()`), a `hold` or `reveal` for a pinned one, or nothing.
    public mutating func read(_ reading: Reading, intent: Intent) -> Decision {
        setIntent(intent)
        let driverMoved = commanded || revealing
        commanded = false
        // The reveal explains this reading, not later navigation once the row has appeared.
        if revealing, case .pinned(let anchor?) = mode, reading.rows[anchor.row] != nil { revealing = false }
        defer { last = reading }
        guard let old = last else {
            // The first reading can already show the jump's arrival, including after a remount.
            if arrived(reading) {
                observe(reading, userIntent: false, endsJump: true)
                placing = false
                return .none
            }
            if placing {
                placing = false
                return settle(reading, reader: intent != .idle) ?? automatic { $0.place(reading) }
            }
            if case .pinned(nil) = mode { mode = .pinned(measured(reading)) }
            return .none
        }
        let layoutChanged = reading.width != old.width || reading.probe.layoutDiffers(from: old.probe)
        let gesture = readerMoves
        let displacement = abs(reading.probe.offset - old.probe.offset)
        let moved = displacement != 0
        let up = gesture && reading.probe.distance > old.probe.distance && !layoutChanged
        // What ends a jump: the reader (their intent with a scroll, in any direction, whatever layout did in the same reading), the row
        // arriving at the top of the view, the row leaving the order (`rowsChanged`), or the driver's `jumpCompleted()`. Where the view
        // is on the way (an offset that moves up, a layout that grows) is none of these: the reader asked for the row, and nothing
        // else puts them somewhere before it arrives.
        let reachesTarget = arrived(reading)
        let jumpEnds = (gesture && moved) || reachesTarget
        // Layout and recovery can clamp a detached viewport into the bottom band; a reader moving down may remeasure lazy rows, but
        // clamping a shrunken document moves up.
        let returning = gesture && reading.probe.offset > old.probe.offset && reading.probe.distance < old.probe.distance
        // The view moved, nobody said why, and nothing here explains it: the reader (VoiceOver paging). It is not a jump's doing either.
        let displaced = intent == .idle && !layoutChanged && !driverMoved && displacement > Self.pinTolerance && !isJumping
        if displaced {
            reanchor(reading)
        } else if follows || isJumping || (gesture && (!layoutChanged || returning)) {
            observe(reading, userIntent: up, endsJump: jumpEnds)
        }

        if follows {
            // With a native anchor, negative distances during layout are intermediate readings, not a settled position.
            let probe = reading.probe
            let beyondTail = probe.distance < min(0, probe.content - probe.container) - max(0, probe.insetTop) - Self.repinSlack
            let pastTail = beyondTail && (!layoutChanged || !nativeAnchor)
            // Shrinking past the tail invalidates older automatic debt. Give native anchoring the first chance to clamp;
            // a stable overrun can ask again. An explicit tail ask still goes on its turn.
            if beyondTail, !pastTail, tailOwed != .none { dropAutomaticTail() }
            // Wanted while the reader's hand blocks it too: it is owed, and goes at the first idle turn.
            let sentTurnMovedAway = followingSentTurn && probe.distance > old.probe.distance
            let wants = pastTail || ((layoutChanged || sentTurnMovedAway) && probe.distance > Self.repinSlack)
            let resized = Self.resized(reading, from: old)
            let distance = NativeTailRepin.distance(of: probe, belowMarker: markerGap)
            self.repin.reading(distance: distance, wants: wants, resized: resized)
            if abs(distance) <= Self.repinSlack {
                tailOwed = .none
                if outstanding == .autoTail { outstanding = .none }
            } else if wants {
                if tailOwed == .none { tailOwed = .layout }
                if outstanding == .none { outstanding = .autoTail }
            }
            return automatic { $0.repin.takeInPass() ? .land : .none }
        }
        repin.reading(distance: NativeTailRepin.distance(of: reading.probe, belowMarker: markerGap), wants: false, resized: false)
        // Detached: a landing the layout wanted of the follower is obsolete, and must not fire when the reader stops. Their own ask stays.
        dropAutomaticTail()

        guard case .pinned = mode else { return .none }
        // The arriving row is the anchor, even if a sliver of its neighbour is still visible above it.
        if !(gesture && moved), reachesTarget || (intent != .idle && keepsTop(reading)) { return .none }
        // The reader moves or the driver animates: where the view is, is where it is kept.
        if let done = settle(reading, reader: intent != .idle || displaced) { return done }
        return automatic { $0.place(reading) }
    }

    /// The reader's own ask (the tail or a row) has not been delivered.
    private var readerAsked: Bool {
        switch outstanding {
        case .readerLatest, .readerRow: true
        case .none, .autoTail: false
        }
    }

    /// A row kept at the top is still there even if a fraction of its neighbour is visible.
    private func keepsTop(_ reading: Reading) -> Bool {
        guard case .pinned(let anchor?) = mode, let top = reading.rows[anchor.row] else { return false }
        return abs(anchor.offset) <= Self.pinTolerance && abs(top) <= Self.pinTolerance
    }

    /// While the reader moves, the driver animates or a displacement was nobody's doing: keep what the view shows, decide nothing.
    private mutating func settle(_ reading: Reading, reader: Bool) -> Decision? {
        guard reader, case .pinned = mode else { return nil }
        if let place = measured(reading) { mode = .pinned(place) }
        revealing = false
        return Decision.none
    }

    /// An offset change nobody reported: the reader is where the view is. Within `repinSlack` of the tail they follow, else the row at
    /// the top is kept. Whatever was pending for the old place goes.
    private mutating func reanchor(_ reading: Reading) {
        revealing = false
        if reading.probe.distance <= Self.repinSlack {
            mode = .following
            unseen = false
        } else {
            mode = .pinned(measured(reading))
            awaitingSentTurn = false
            followingSentTurn = false
        }
    }

    /// Put the pinned row where it is kept (only through `automatic`): nothing to hold yet, ask for the row when it is not realized (case 1, once), or hold it.
    private mutating func place(_ reading: Reading) -> Decision {
        guard case .pinned(let anchor) = mode else { return .none }
        guard let anchor else {
            mode = .pinned(measured(reading))
            return .none
        }
        guard let top = reading.rows[anchor.row] else {
            guard !revealing else { return .none }
            revealing = true
            return .reveal(anchor.row)
        }
        revealing = false
        return abs(top - anchor.offset) > Self.pinTolerance ? .hold(anchor) : .none
    }

    /// The reader's motion changed with no reading (a scroll phase). Call `turn()` afterwards if `wantsTurn`.
    public mutating func setIntent(_ next: Intent) {
        intent = next
        repin.reader(scrolling: readerMoves, touching: next == .touching && !asksInterruptTouch)
    }

    /// The topmost row and where it sits; nil when the reading measured none.
    private func measured(_ reading: Reading) -> Anchor? {
        guard let row = reading.topRow, let offset = reading.rows[row] else { return nil }
        return Anchor(row: row, offset: offset)
    }

    /// `NativeScrollFollower.observe(distanceFromBottom:userIntent:)` over the modes. Only `userIntent` detaches.
    private mutating func observe(_ reading: Reading, userIntent: Bool, endsJump: Bool) {
        let distance = reading.probe.distance
        if isJumping {
            // Until it ends (`endsJump`), positions inside the band do not re-attach.
            guard endsJump, case .jumping(let row) = mode else { return }
            mode = .pinned(arrival(at: row, reading) ?? measured(reading))
        }
        if distance <= Self.threshold {
            mode = .following
            unseen = false
            revealing = false
            return
        }
        if userIntent {
            if follows { mode = .pinned(measured(reading)) }
            awaitingSentTurn = false
            followingSentTurn = false
        }
    }

    /// The jump's row where the view shows it, if it is at the top.
    private func arrival(at row: String, _ reading: Reading) -> Anchor? {
        guard let top = reading.rows[row], abs(top) <= Self.pinTolerance else { return nil }
        return Anchor(row: row, offset: top)
    }

    private func arrived(_ reading: Reading) -> Bool {
        guard case .jumping(let row) = mode else { return false }
        return arrival(at: row, reading) != nil
    }

    /// The driver's animation to the jump's row is over, wherever the view stopped: the mode is what the last reading shows (the row
    /// where it is, or following inside the band), and pinned compensation applies again. The driver must deliver the final
    /// geometry reading before calling this method: completion judges arrival from that reading, not the native stop position.
    public mutating func jumpCompleted() {
        guard case .jumping(let row) = mode else { return }
        guard let last else {
            mode = .pinned(nil)
            return
        }
        if last.probe.distance <= Self.threshold {
            mode = .following
            unseen = false
            revealing = false
        } else {
            var anchor = last.rows[row].map { Anchor(row: row, offset: $0) } ?? measured(last)
            // The last geometry may predate a row removal. Don't keep a row the driver can no longer reveal.
            if let stale = anchor, !order.isEmpty, !order.contains(stale.row) {
                anchor = order.lazy.compactMap { id in last.rows[id].map { Anchor(row: id, offset: $0) } }
                    .first { $0.offset >= stale.offset }
            }
            mode = .pinned(anchor)
        }
    }

    private static func resized(_ new: Reading, from old: Reading) -> Bool {
        abs(new.width - old.width) > repinSlack
            || abs(new.probe.container - old.probe.container) > repinSlack
            || abs(new.probe.inset - old.probe.inset) > repinSlack
            || abs(new.probe.insetTop - old.probe.insetTop) > repinSlack
    }

    // MARK: Landings that did not fit in a pass

    public var wantsTurn: Bool {
        switch outstanding {
        case .none: false
        case .readerRow: !fingerHolds
        // The reader's own ask does not wait for them to stop; a landing the layout wanted does.
        case .readerLatest: repin.wantsTurn
        case .autoTail: intent == .idle && repin.wantsTurn
        }
    }

    /// Once per run-loop turn, after its events: delivers what is outstanding. A jump that waited for the finger goes, then the
    /// reader's ask for the tail, else a landing the layout wanted, if the budget still allows and nothing moves.
    public mutating func turn() -> Decision {
        switch outstanding {
        case .none: return .none
        case .readerRow(let row): return fingerHolds ? .none : startJump(row)
        case .readerLatest: return repin.take() ? issue(.land) : .none
        case .autoTail: return automatic { $0.repin.take() ? .land : .none }
        }
    }

    /// iOS: an ask waits for a finger on the thread.
    private var fingerHolds: Bool { intent == .touching && !asksInterruptTouch }

    /// A newer request replaces what an older one still wanted of the tail.
    private mutating func dropOlderRequests() {
        outstanding = .none
        repin.hold()
        repin.release()
    }

    /// Landings the layout wanted of a follower, forgotten; the reader's ask for the tail, if one is waiting, is kept.
    private mutating func dropAutomaticTail() {
        repin.hold()
        repin.release()
        tailOwed = .none
        if outstanding == .autoTail { outstanding = .none }
        if outstanding == .readerLatest { repin.asked() }
    }

    /// Automatic work waits for idle and never passes a reader's request. Check before running `decide` so a blocked write
    /// spends no budget and sets no state. The reader's own asks use `issue` directly.
    private mutating func automatic(_ decide: (inout ThreadScrollOwner) -> Decision) -> Decision {
        guard intent == .idle, !readerAsked else { return .none }
        return issue(decide(&self))
    }

    /// Every decision leaves through here, and takes its item with it: a landing answers whatever waited for the tail and puts the
    /// owner on it (the reading that follows must not be read as the reader leaving history); a scroll answers a row.
    private mutating func issue(_ decision: Decision) -> Decision {
        switch decision {
        case .none: return .none
        case .land:
            if outstanding == .readerLatest || outstanding == .autoTail { outstanding = .none }
            tailOwed = .none
            mode = .following
            unseen = false
            revealing = false
        case .scroll:
            if case .readerRow = outstanding { outstanding = .none }
        case .hold, .reveal: break
        }
        commanded = true
        return decision
    }

    /// A stalled tail saw no reading for `NativeTailRepin.quiet`'s wait; it gets one try.
    public mutating func quietPassed() { repin.quietPassed() }

    public var landingStalled: Bool { repin.stalled }

    // MARK: Output

    /// The thread's tail changed: a row arrived, or the last one grew.
    public mutating func contentArrived() {
        if !follows { unseen = true }
        repin.outputArrived()
    }

    // MARK: The reader's asks

    private mutating func ask() -> Decision {
        dropOlderRequests()
        repin.asked()
        outstanding = .readerLatest
        return turn()
    }

    /// The jump pill. Stick, forget what was missed, drop a kept anchor, land.
    public mutating func jumpToLatest() -> Decision {
        mode = .following
        unseen = false
        revealing = false
        return ask()
    }

    /// The reader sent a message. One that goes in now re-attaches, and lands on its turn once it is there; one that waits in Up next
    /// (`queued`) leaves the reader's place alone. A send asks for the tail if detached or if that ask is already waiting.
    /// Otherwise an attached reader keeps any unpaid automatic landing and waits for the echo or its layout.
    public mutating func sent(queued: Bool, turnPresent: Bool = false) -> Decision {
        guard !queued else { return .none }
        let detached = !follows
        mode = .following
        unseen = false
        revealing = false
        awaitingSentTurn = !turnPresent
        followingSentTurn = true
        if detached || outstanding == .readerLatest { return ask() }
        if readerAsked {
            dropOlderRequests()
            resumeOwedTail()
        }
        return .none
    }

    /// The thread's last user turn changed. Lands when that is the reader's own send arriving.
    public mutating func userTurnArrived() -> Decision {
        guard awaitingSentTurn else { return .none }
        awaitingSentTurn = false
        return ask()
    }

    /// Previous or next turn, Find: detach and go to the row. The scroll's first frames, still at the tail, do not re-attach.
    /// On iOS a finger on the thread holds it until the lift (`turn()`), as it holds a landing.
    public mutating func jumpToRow(_ row: String) -> Decision {
        dropOlderRequests()
        awaitingSentTurn = false
        followingSentTurn = false
        revealing = false
        if fingerHolds {
            outstanding = .readerRow(row)
            return .none
        }
        return startJump(row)
    }

    private mutating func startJump(_ row: String) -> Decision {
        mode = .jumping(row: row)
        return issue(.scroll(toRow: row, animated: true))
    }

    // MARK: Structure

    /// The store's rows changed (a history page, a restore step, a rebuilt row). A pinned row that is gone gets the D3 answer.
    public mutating func rowsChanged(_ next: [String]) -> Decision {
        let previous = order
        order = next
        let survivors = Set(next)
        if case .readerRow(let row) = outstanding, !survivors.contains(row) {
            outstanding = .none
            resumeOwedTail()
        }
        // A structure change is not the reader's ask: it writes only through the gate.
        switch mode {
        case .jumping(let row) where !survivors.contains(row):
            // The animation is cancelled where the view is: still in the band, the reader is at the tail; anywhere else the next
            // reading anchors them.
            if let last, last.probe.distance <= Self.threshold {
                mode = .following
                unseen = false
            } else {
                mode = .pinned(nil)
            }
            return .none
        case .pinned(let anchor?) where !survivors.contains(anchor.row):
            revealing = false
            if let row = Self.nearest(to: anchor.row, in: previous, surviving: survivors) {
                // Case 2: replaced.
                mode = .pinned(Anchor(row: row, offset: anchor.offset))
                return automatic {
                    $0.revealing = true
                    return .reveal(row)
                }
            }
            // Case 3: nothing survives.
            if let distance = last?.probe.distance, distance <= Self.repinSlack {
                mode = .following
                unseen = false
                // Moving, the reader is not landed: the landing is owed, and goes at the first idle turn.
                guard outstanding == .none else { return .none }
                tailOwed = .mount
                outstanding = .autoTail
                repin.asked()
                return turn()
            }
            mode = .pinned(nil)
            return .none
        default:
            return .none
        }
    }

    /// A waiting request is gone. Restore any automatic landing that was owed before or while the request waited.
    private mutating func resumeOwedTail() {
        guard follows else { return }
        switch tailOwed {
        case .none: break
        case .mount:
            outstanding = .autoTail
            repin.asked()
        case .layout:
            guard let last else { return }
            repin.reading(distance: NativeTailRepin.distance(of: last.probe, belowMarker: markerGap), wants: true, resized: false)
            if repin.pending { outstanding = .autoTail }
        }
    }

    /// The row of `old` nearest to `row` that is still in `survivors`: above before below at the same distance.
    private static func nearest(to row: String, in old: [String], surviving survivors: Set<String>) -> String? {
        guard let index = old.firstIndex(of: row) else { return nil }
        for step in 1..<max(old.count, 1) {
            if index - step >= 0, survivors.contains(old[index - step]) { return old[index - step] }
            if index + step < old.count, survivors.contains(old[index + step]) { return old[index + step] }
        }
        return nil
    }

    // MARK: Mount and session

    /// The transcript mounts. A follower lands on the tail; a reader who kept a place gets that row back, which the first reading
    /// settles (nothing if it is already there, a `hold` if it is off, a `reveal` if the lazy stack has not built it); one detached
    /// with nothing kept re-attaches, as a mount re-sticks the follower the way the jump pill does.
    public mutating func mount() -> Decision {
        // Not the reader's ask (`docs/plans/thread-scroll.md`, 4.1): a request from before it is obsolete, and a landing waits for idle.
        dropOlderRequests()
        switch mode {
        case .pinned(.some):
            tailOwed = .none
            last = nil
            placing = true
            revealing = false
            return .none
        default:
            mode = .following
            unseen = false
            tailOwed = .mount
            outstanding = .autoTail
            repin.asked()
            return turn()
        }
    }

    /// Another session's turns replace this one's: nothing is kept, and the landing budget starts over.
    public mutating func newSession() {
        mode = .following
        unseen = false
        awaitingSentTurn = false
        followingSentTurn = false
        order = []
        revealing = false
        placing = false
        outstanding = .none
        tailOwed = .none
        last = nil
        repin.newThread(refillingPass: true)
    }
}
