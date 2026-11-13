import Foundation

/// Where a thread's reader is, as its transcript keeps it between mounts: the follower, and the turn SwiftUI keeps under the top
/// edge that the next mount puts back there. A view mirrors the parts it draws (`follows`, `unseen`, `restoresTurn`, `turn`) and
/// leaves the rest as bookkeeping.
///
/// A transcript that `mountsAtTail` opens on its bottom anchors at the tail while it follows, so it keeps no turn from then: a turn
/// kept from a streaming reply would put the next mount back at the top of the reply it was reading. Writes SwiftUI makes through the
/// position binding while the reader follows are therefore dropped, and returning to the tail forgets the turn kept for a reader who
/// was away. A transcript that does not keeps the turn it is on whether it follows or not, except the bottom marker: that is the tail
/// itself, not a turn, and the id handed back to SwiftUI when the next turn's rows join resolves short of the tail (iOS 27.1 landed
/// 5,563 pt short and the view sat that far away for 0.2 s). The marker is kept only for a reader who is away from the tail.
public struct NativeTranscriptPlace: Equatable, Sendable {
    public private(set) var follower = NativeScrollFollower()
    /// The turn SwiftUI keeps under the top edge. Nil while following where `mountsAtTail`.
    public private(set) var turn: String?
    public let mountsAtTail: Bool

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
        if returned, mountsAtTail || turn == Self.bottomMarker { turn = nil }
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

    /// SwiftUI's write through the position binding: kept unless the reader follows, where `mountsAtTail` or when it is the bottom
    /// marker. Nil clears, as another session's turns are not the ones kept.
    public mutating func note(_ id: String?) {
        turn = follower.sticky && (mountsAtTail || id == Self.bottomMarker) ? nil : id
    }

    /// Keeps the oldest loaded turn at the top while older ones load above it, when SwiftUI has none to keep.
    public mutating func pin(_ id: String?) {
        guard turn == nil, let id else { return }
        turn = id
    }
}
