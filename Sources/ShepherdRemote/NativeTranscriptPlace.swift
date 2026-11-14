import Foundation

/// Where a thread's reader is, as its transcript keeps it between mounts: the follower, and the turn SwiftUI keeps under the top
/// edge that the next mount puts back there. A view mirrors the parts it draws (`follows`, `unseen`, `restoresTurn`, `turn`) and
/// leaves the rest as bookkeeping.
///
/// A transcript that `mountsAtTail` opens on its bottom anchors at the tail while it follows, so it keeps no turn from then: a turn
/// kept from a streaming reply would put the next mount back at the top of the reply it was reading. Writes SwiftUI makes through the
/// position binding while the reader follows are therefore dropped, and returning to the tail forgets the turn kept for a reader who
/// was away. A transcript that does not keeps the turn it is on whether it follows or not.
///
/// What it keeps may be the bottom marker, the 1 pt row that ends the turns, which SwiftUI reports at the end of a drag to the tail.
/// Held there, SwiftUI keeps the view on the tail through everything that grows it, with a handful of landings for a reply. But the
/// pass that adds rows after the marker resolves it against the lazy stack's estimate, and on iOS 27.1 the first landing then comes
/// out 5,563 pt short of the tail (the view sat 9,000 to 12,000 pt away for 0.2 s on a phone, and 80,000 pt for 0.5 s on a Duo's open
/// display). So `position(tail:)` hands the marker to SwiftUI only while the last row is the one it was kept for, and `hold(tail:)`
/// keeps it again for the tail as it is once the landings after the new rows have settled. That is only ever the marker taken from a
/// follower who had it, whether rows joined after it or the transcript left and mounts again (`leave()`): one who never kept it (a first
/// open, a re-open, a follower SwiftUI reported a row for) is left as it was.
public struct NativeTranscriptPlace: Equatable, Sendable {
    public private(set) var follower = NativeScrollFollower()
    /// The turn SwiftUI keeps under the top edge. Nil while following where `mountsAtTail`.
    public private(set) var turn: String?
    public let mountsAtTail: Bool
    /// The last row the transcript had when the bottom marker was kept: the marker stands for that tail, not for the next one.
    public private(set) var markerTail: String?
    /// The marker was kept for a follower and has been withheld since rows joined after it. SwiftUI may then report a row or nothing
    /// through the binding, which replaces the marker as the turn but not the follower's claim to it, so this stays until the marker is
    /// kept again, the reader detaches or the session changes.
    private var withheld = false

    /// The id of the 1 pt row that ends the transcript's turns. SwiftUI reports it through the position binding at the end of a drag
    /// to the tail, and the transcript lands on it.
    public static let bottomMarker = "thread-bottom"

    public init(mountsAtTail: Bool) { self.mountsAtTail = mountsAtTail }

    public var follows: Bool { follower.sticky }
    public var unseen: Bool { follower.unseen }
    /// Whether the next mount restores a turn, which is when its initial anchor is the turn's rather than the tail's.
    public var restoresTurn: Bool { turn != nil }

    /// Takes the follower as the transcript changed it.
    public mutating func follow(_ next: NativeScrollFollower) {
        let returned = next.sticky && !follower.sticky
        follower = next
        if returned, mountsAtTail { turn = nil }
        if !next.sticky { withheld = false }
    }

    /// A transcript mounting with no turn to restore opens on its bottom anchor, at its tail, so the reader must follow it: one left
    /// detached with nothing kept (SwiftUI can leave the position nil, as after a jump) would sit there without following the tail,
    /// with the jump pill showing while the agent runs. Nothing changes where a turn is kept or where the transcript does not mount
    /// at its tail.
    public mutating func mount() {
        guard mountsAtTail, turn == nil, !follower.sticky else { return }
        var next = follower
        next.jumpToLatest()
        follow(next)
    }

    /// The transcript left the screen. A follower who holds the bottom marker is not handed it at the next mount, which on iOS 27.1
    /// opens a lazy stack at the marker's estimated place, among rows built nowhere near it (the Duo's cover display did it on every
    /// re-open), for the tail guard to jump out of, and once 39 pt past the end. The marker is withheld as it is after rows joined
    /// (`withholdsMarker`): the pin lands the view at the mount, and `hold(tail:)` keeps the marker again once that landing has settled.
    /// A follower who keeps a row, a detached reader and a transcript that mounts at its tail are unchanged.
    public mutating func leave() {
        guard follower.sticky, !mountsAtTail, turn == Self.bottomMarker else { return }
        markerTail = nil
    }

    /// SwiftUI's write through the position binding: kept unless the reader follows where `mountsAtTail`. Nil clears, as another
    /// session's turns are not the ones kept. `tail` is the transcript's last row, which the bottom marker is then kept for.
    public mutating func note(_ id: String?, tail: String? = nil) {
        if follower.sticky, !mountsAtTail, turn == Self.bottomMarker, markerTail != tail { withheld = true }
        turn = follower.sticky && mountsAtTail ? nil : id
        if turn == Self.bottomMarker {
            markerTail = tail
            withheld = false
        }
    }

    /// Another session's turns replace this one's: none is kept, and the marker is not the new session's to have back.
    public mutating func newSession() {
        turn = nil
        markerTail = nil
        withheld = false
    }

    /// What SwiftUI is handed as its position for a transcript whose last row is `tail`: the turn kept, but not the bottom marker
    /// of a follower once rows have joined after it. The pass that adds them would resolve it short of the tail.
    public func position(tail: String?) -> String? {
        turn == Self.bottomMarker && follower.sticky && markerTail != tail ? nil : turn
    }

    /// Whether a follower's bottom marker is withheld for the transcript's last row `tail`: it was kept for one it has since grown
    /// past. Never for a follower who did not keep it, for a reader who is away, or where `mountsAtTail`.
    public func withholdsMarker(tail: String?) -> Bool {
        guard follower.sticky, !mountsAtTail else { return false }
        return withheld || (turn == Self.bottomMarker && markerTail != tail)
    }

    /// Keeps the bottom marker again for a follower whose marker was withheld, for the tail as it is now (`tail` is the last row): the
    /// landings after new rows joined have settled, and SwiftUI follows the tail from there. Nothing to keep for a follower who never
    /// kept it, so a transcript that only opened or re-opened is left as it was.
    public mutating func hold(tail: String?) {
        guard withholdsMarker(tail: tail) else { return }
        turn = Self.bottomMarker
        markerTail = tail
        withheld = false
    }

    /// Keeps the oldest loaded turn at the top while older ones load above it, when SwiftUI has none to keep.
    public mutating func pin(_ id: String?) {
        guard turn == nil, let id else { return }
        turn = id
    }
}
