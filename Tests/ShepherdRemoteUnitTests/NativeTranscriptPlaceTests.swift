import Testing
import ShepherdRemote

/// What a transcript remembers of its reader between mounts: whether they follow the tail, and the turn SwiftUI kept under the top
/// edge. A transcript that mounts at its tail keeps no turn while the reader follows; one that does not keeps the turn it is on.
@Suite("Transcript place: following, the turn kept, and the next mount")
struct NativeTranscriptPlaceTests {
    enum Event: Sendable {
        /// The reader's drag took the view away from the tail.
        case detach
        /// The reader came back to the tail (a drag that ended near it, the jump pill, a send).
        case reattach
        /// SwiftUI reports the turn under the top edge through the position binding; nil is its report of none. `tail` is the
        /// transcript's last row at the time.
        case swiftUI(String?, tail: String? = nil)
        /// The landings after new rows joined have settled, and the transcript's last row is `tail`.
        case hold(tail: String?)
        /// The history pager keeps the oldest loaded turn while older ones load.
        case pin(String?)
        /// The transcript mounts again.
        case mount
        /// The transcript leaves the screen.
        case leave
        /// Another session's turns replace this one's (the thread's session key changed).
        case newSession
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var mountsAtTail: Bool
        var events: [Event]
        var turn: String?
        var follows: Bool
    }

    static let cases: [Case] = [
        // A transcript that mounts at its tail.
        Case(testDescription: "a follower keeps nothing of what SwiftUI reports under the top edge",
             mountsAtTail: true, events: [.swiftUI("reply")], turn: nil, follows: true),
        Case(testDescription: "a detached reader keeps the turn SwiftUI reports",
             mountsAtTail: true, events: [.detach, .swiftUI("reply")], turn: "reply", follows: false),
        Case(testDescription: "a later report replaces the turn kept",
             mountsAtTail: true, events: [.detach, .swiftUI("reply"), .swiftUI("earlier")], turn: "earlier", follows: false),
        Case(testDescription: "coming back to the tail forgets the turn kept for the reader who was away",
             mountsAtTail: true, events: [.detach, .swiftUI("reply"), .reattach], turn: nil, follows: true),
        Case(testDescription: "a report after coming back is dropped again",
             mountsAtTail: true, events: [.detach, .swiftUI("reply"), .reattach, .swiftUI("reply")], turn: nil, follows: true),
        Case(testDescription: "a detached reader with a turn kept mounts where they were, detached",
             mountsAtTail: true, events: [.detach, .swiftUI("reply"), .mount], turn: "reply", follows: false),
        Case(testDescription: "a detached reader SwiftUI left with nothing is put back on the tail at a mount",
             mountsAtTail: true, events: [.detach, .swiftUI("reply"), .swiftUI(nil), .mount], turn: nil, follows: true),
        Case(testDescription: "a detached reader who never had a turn is put back on the tail at a mount",
             mountsAtTail: true, events: [.detach, .mount], turn: nil, follows: true),
        Case(testDescription: "a follower mounting changes nothing",
             mountsAtTail: true, events: [.mount], turn: nil, follows: true),
        Case(testDescription: "the session changing takes the turn kept away, and the reader stays detached",
             mountsAtTail: true, events: [.detach, .swiftUI("reply"), .newSession], turn: nil, follows: false),
        Case(testDescription: "a detached reader whose session changed is put back on the tail at the next mount",
             mountsAtTail: true, events: [.detach, .swiftUI("reply"), .newSession, .mount], turn: nil, follows: true),
        Case(testDescription: "the history pager keeps the oldest turn for a detached reader with none",
             mountsAtTail: true, events: [.detach, .pin("first")], turn: "first", follows: false),
        Case(testDescription: "the history pager leaves the turn SwiftUI reported alone",
             mountsAtTail: true, events: [.detach, .swiftUI("reply"), .pin("first")], turn: "reply", follows: false),
        Case(testDescription: "the history pager keeping nothing keeps nothing",
             mountsAtTail: true, events: [.detach, .pin(nil)], turn: nil, follows: false),
        // A transcript that does not mount at its tail keeps the turn it is on, whether or not it follows.
        Case(testDescription: "without a mount at the tail, a follower keeps the turn SwiftUI reports",
             mountsAtTail: false, events: [.swiftUI("reply")], turn: "reply", follows: true),
        Case(testDescription: "without a mount at the tail, coming back to the tail keeps the turn",
             mountsAtTail: false, events: [.detach, .swiftUI("reply"), .reattach], turn: "reply", follows: true),
        Case(testDescription: "without a mount at the tail, a detached reader with nothing kept stays detached at a mount",
             mountsAtTail: false, events: [.detach, .mount], turn: nil, follows: false),
        Case(testDescription: "without a mount at the tail, SwiftUI reporting none clears the turn",
             mountsAtTail: false, events: [.swiftUI("reply"), .swiftUI(nil)], turn: nil, follows: true),
        // The bottom marker is kept like any turn, for the tail it was reported at.
        Case(testDescription: "without a mount at the tail, a follower keeps the bottom marker",
             mountsAtTail: false, events: [.swiftUI(marker, tail: "a")], turn: marker, follows: true),
        Case(testDescription: "without a mount at the tail, a row replaces the bottom marker",
             mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .swiftUI("reply", tail: "a")], turn: "reply", follows: true),
        Case(testDescription: "without a mount at the tail, a detached reader keeps the bottom marker",
             mountsAtTail: false, events: [.detach, .swiftUI(marker, tail: "a")], turn: marker, follows: false),
        Case(testDescription: "without a mount at the tail, coming back to the tail keeps the bottom marker",
             mountsAtTail: false, events: [.detach, .swiftUI(marker, tail: "a"), .reattach], turn: marker, follows: true),
        // A transcript that mounts at its tail drops the marker with everything else while it follows.
        Case(testDescription: "a follower keeps nothing of the bottom marker",
             mountsAtTail: true, events: [.swiftUI(marker, tail: "a")], turn: nil, follows: true),
        Case(testDescription: "a detached reader keeps the bottom marker",
             mountsAtTail: true, events: [.detach, .swiftUI(marker, tail: "a")], turn: marker, follows: false),
        // Holding the marker again, for a follower whose marker was withheld.
        Case(testDescription: "holding keeps nothing for a follower that was never withheld",
             mountsAtTail: false, events: [.hold(tail: "a")], turn: nil, follows: true),
        Case(testDescription: "holding leaves the row kept for a follower that never kept the marker",
             mountsAtTail: false, events: [.swiftUI("reply", tail: "a"), .hold(tail: "a")], turn: "reply", follows: true),
        Case(testDescription: "holding leaves the row kept for a follower that never kept the marker, whatever joined",
             mountsAtTail: false, events: [.swiftUI("reply", tail: "a"), .swiftUI("other", tail: "b"), .hold(tail: "b")],
             turn: "other", follows: true),
        Case(testDescription: "a follower who opened and re-opened is held nothing by the landings of the mounts",
             mountsAtTail: false, events: [.leave, .mount, .hold(tail: "a"), .leave, .mount, .hold(tail: "b")],
             turn: nil, follows: true),
        Case(testDescription: "a follower re-holds the marker after a row joined",
             mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .hold(tail: "b")], turn: marker, follows: true),
        Case(testDescription: "a follower re-holds the marker after SwiftUI wrote a row for it",
             mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .swiftUI("reply", tail: "b"), .hold(tail: "b")],
             turn: marker, follows: true),
        Case(testDescription: "a follower re-holds the marker after SwiftUI wrote nothing for it",
             mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .swiftUI(nil, tail: "b"), .hold(tail: "b")],
             turn: marker, follows: true),
        Case(testDescription: "a follower re-holds the marker after later writes of rows, as the rows keep joining",
             mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .swiftUI("one", tail: "b"), .swiftUI("two", tail: "c"), .hold(tail: "c")],
             turn: marker, follows: true),
        Case(testDescription: "a follower withheld again by the next row to join re-holds again",
             mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .swiftUI("one", tail: "b"), .hold(tail: "b"),
                                           .swiftUI("two", tail: "c"), .hold(tail: "c")],
             turn: marker, follows: true),
        Case(testDescription: "a follower holding the marker for the tail it has keeps it",
             mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .hold(tail: "a")], turn: marker, follows: true),
        Case(testDescription: "a follower who took the marker back for the new tail and then kept a row is held nothing",
             mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .swiftUI("one", tail: "b"), .swiftUI(marker, tail: "b"),
                                           .swiftUI("two", tail: "b"), .hold(tail: "b")],
             turn: "two", follows: true),
        Case(testDescription: "detaching takes the claim to the marker away",
             mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .swiftUI("reply", tail: "b"), .detach, .reattach, .hold(tail: "b")],
             turn: "reply", follows: true),
        Case(testDescription: "a new session takes the claim to the marker away",
             mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .swiftUI("reply", tail: "b"), .newSession, .hold(tail: "b")],
             turn: nil, follows: true),
        Case(testDescription: "a new session takes the marker away",
             mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .newSession], turn: nil, follows: true),
        Case(testDescription: "without a mount at the tail, holding leaves a detached reader's turn alone",
             mountsAtTail: false, events: [.detach, .swiftUI("reply", tail: "a"), .hold(tail: "a")], turn: "reply", follows: false),
        Case(testDescription: "without a mount at the tail, holding keeps nothing for a detached reader with nothing kept",
             mountsAtTail: false, events: [.detach, .hold(tail: "a")], turn: nil, follows: false),
        Case(testDescription: "without a mount at the tail, holding leaves a detached reader's marker for the tail it was kept for",
             mountsAtTail: false, events: [.detach, .swiftUI(marker, tail: "a"), .hold(tail: "b")], turn: marker, follows: false),
        Case(testDescription: "holding keeps nothing for a transcript that mounts at its tail",
             mountsAtTail: true, events: [.hold(tail: "a")], turn: nil, follows: true),
        Case(testDescription: "holding keeps nothing for a transcript that mounts at its tail, whatever it was reported",
             mountsAtTail: true, events: [.detach, .swiftUI(marker, tail: "a"), .reattach, .hold(tail: "b")], turn: nil, follows: true),
        // A follower who leaves holding the marker still holds it at the next mount: it is withheld there (see `positions`), not lost.
        Case(testDescription: "without a mount at the tail, a follower who left holds the bottom marker through the next mount",
             mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .leave, .mount], turn: marker, follows: true),
        Case(testDescription: "without a mount at the tail, a follower who left keeps the row",
             mountsAtTail: false, events: [.swiftUI("reply", tail: "a"), .leave, .mount], turn: "reply", follows: true),
        Case(testDescription: "without a mount at the tail, a follower who left holds the marker again once its landing settled",
             mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .leave, .mount, .hold(tail: "a")], turn: marker, follows: true),
        Case(testDescription: "without a mount at the tail, a detached reader who left keeps the bottom marker",
             mountsAtTail: false, events: [.detach, .swiftUI(marker, tail: "a"), .leave, .mount], turn: marker, follows: false),
        Case(testDescription: "a transcript that mounts at its tail keeps no marker through a leave and a mount",
             mountsAtTail: true, events: [.swiftUI(marker, tail: "a"), .leave, .mount], turn: nil, follows: true),
    ]

    /// The bottom anchor row of the transcript, as SwiftUI reports it through the position binding.
    static let marker = NativeTranscriptPlace.bottomMarker

    /// The place after the events, from a fresh one.
    static func played(_ events: [Event], mountsAtTail: Bool) -> NativeTranscriptPlace {
        var place = NativeTranscriptPlace(mountsAtTail: mountsAtTail)
        for event in events {
            switch event {
            case .detach:
                var next = place.follower
                next.observe(distanceFromBottom: 600, userIntent: true)
                place.follow(next)
            case .reattach:
                var next = place.follower
                next.jumpToLatest()
                place.follow(next)
            case .swiftUI(let id, let tail): place.note(id, tail: tail)
            case .hold(let tail): place.hold(tail: tail)
            case .pin(let id): place.pin(id)
            case .mount: place.mount()
            case .leave: place.leave()
            case .newSession: place.newSession()
            }
        }
        return place
    }

    @Test(arguments: cases)
    func place(_ c: Case) {
        let place = Self.played(c.events, mountsAtTail: c.mountsAtTail)
        #expect(place.turn == c.turn)
        #expect(place.restoresTurn == (c.turn != nil))
        #expect(place.follows == c.follows)
    }

    struct PositionCase: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var mountsAtTail: Bool
        var events: [Event]
        /// The transcript's last row when SwiftUI is handed its position, and what it is handed.
        var tail: String?
        var handed: String?
    }

    /// The position handed to SwiftUI: the pass that adds rows after the bottom marker would resolve it short of the tail, so a follower
    /// is handed the marker only for the tail it was kept for.
    static let positions: [PositionCase] = [
        PositionCase(testDescription: "a follower is handed the bottom marker while the last row is the one it was kept for",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a")], tail: "a", handed: marker),
        PositionCase(testDescription: "a follower is handed nothing once a row joined after the marker",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a")], tail: "b", handed: nil),
        PositionCase(testDescription: "a follower is handed the marker again once it was held for the new tail",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .hold(tail: "b")], tail: "b", handed: marker),
        PositionCase(testDescription: "a follower holding the marker is handed nothing at the next row to join",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .hold(tail: "b")], tail: "c", handed: nil),
        PositionCase(testDescription: "a follower is handed nothing for a tail that was held for another",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .hold(tail: "b")], tail: "a", handed: nil),
        PositionCase(testDescription: "a follower who never kept the marker is handed nothing, held or not",
                     mountsAtTail: false, events: [.hold(tail: "a")], tail: "a", handed: nil),
        PositionCase(testDescription: "a follower who left holding the marker is handed nothing at the mount, whatever the tail is",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .leave, .mount], tail: "a", handed: nil),
        PositionCase(testDescription: "a follower who left holding the marker is handed nothing at the mount of a thread that moved on",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .leave, .mount], tail: "b", handed: nil),
        PositionCase(testDescription: "a follower who left holding the marker is handed it again once held for the tail it mounted at",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .leave, .mount, .hold(tail: "b")], tail: "b", handed: marker),
        PositionCase(testDescription: "a follower who left holding the marker is handed nothing at the next row to join after it was held",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .leave, .mount, .hold(tail: "b")], tail: "c", handed: nil),
        PositionCase(testDescription: "a follower who left with a row is handed the row at the mount",
                     mountsAtTail: false, events: [.swiftUI("reply", tail: "a"), .leave, .mount], tail: "b", handed: "reply"),
        PositionCase(testDescription: "a detached reader who left is handed the marker at the mount",
                     mountsAtTail: false, events: [.detach, .swiftUI(marker, tail: "a"), .leave, .mount], tail: "b", handed: marker),
        PositionCase(testDescription: "a transcript that mounts at its tail is handed a follower nothing after a leave",
                     mountsAtTail: true, events: [.swiftUI(marker, tail: "a"), .leave, .mount], tail: "a", handed: nil),
        PositionCase(testDescription: "a follower with no rows is handed the marker kept for none after a leave",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: nil), .leave, .mount], tail: nil, handed: marker),
        PositionCase(testDescription: "a follower with no rows yet is handed the marker kept for none",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: nil)], tail: nil, handed: marker),
        PositionCase(testDescription: "a follower is handed a row it keeps whatever joins",
                     mountsAtTail: false, events: [.swiftUI("reply", tail: "a")], tail: "b", handed: "reply"),
        PositionCase(testDescription: "a detached reader is handed the marker whatever joins",
                     mountsAtTail: false, events: [.detach, .swiftUI(marker, tail: "a")], tail: "b", handed: marker),
        PositionCase(testDescription: "a reader who came back is handed nothing once a row joined while they were away",
                     mountsAtTail: false, events: [.detach, .swiftUI(marker, tail: "a"), .reattach], tail: "b", handed: nil),
        PositionCase(testDescription: "a reader who came back is handed the marker while the tail is as it was",
                     mountsAtTail: false, events: [.detach, .swiftUI(marker, tail: "a"), .reattach], tail: "a", handed: marker),
        PositionCase(testDescription: "a follower with nothing kept is handed nothing",
                     mountsAtTail: false, events: [], tail: "a", handed: nil),
        PositionCase(testDescription: "a transcript that mounts at its tail hands a follower nothing",
                     mountsAtTail: true, events: [.swiftUI(marker, tail: "a")], tail: "a", handed: nil),
        PositionCase(testDescription: "a transcript that mounts at its tail hands a detached reader the turn kept",
                     mountsAtTail: true, events: [.detach, .swiftUI("reply", tail: "a")], tail: "b", handed: "reply"),
    ]

    @Test(arguments: positions)
    func position(_ c: PositionCase) {
        let place = Self.played(c.events, mountsAtTail: c.mountsAtTail)
        #expect(place.position(tail: c.tail) == c.handed)
    }

    struct WithheldCase: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var mountsAtTail: Bool
        var events: [Event]
        var tail: String?
        var withheld: Bool
    }

    /// Whether the marker is withheld, which is what the landings after new rows joined ask before they wait to hold it again: only
    /// a follower who kept it has it taken, so only that one gets it back.
    static let withheld: [WithheldCase] = [
        WithheldCase(testDescription: "a follower who never kept the marker has none withheld",
                     mountsAtTail: false, events: [.swiftUI("reply", tail: "a")], tail: "b", withheld: false),
        WithheldCase(testDescription: "a follower with nothing kept has none withheld",
                     mountsAtTail: false, events: [], tail: "a", withheld: false),
        WithheldCase(testDescription: "a follower's marker is not withheld for the tail it was kept for",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a")], tail: "a", withheld: false),
        WithheldCase(testDescription: "a follower's marker is withheld once a row joined",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a")], tail: "b", withheld: true),
        WithheldCase(testDescription: "a follower's marker stays withheld after SwiftUI wrote a row for it",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .swiftUI("reply", tail: "b")], tail: "b", withheld: true),
        WithheldCase(testDescription: "a follower's marker is not withheld once held for the tail",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .swiftUI("reply", tail: "b"), .hold(tail: "b")],
                     tail: "b", withheld: false),
        WithheldCase(testDescription: "a follower's marker is withheld again at the next row to join",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .hold(tail: "b")], tail: "c", withheld: true),
        WithheldCase(testDescription: "a follower's marker is withheld at the mount after a leave, so the landing keeps it again",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .leave, .mount], tail: "a", withheld: true),
        WithheldCase(testDescription: "a follower's marker is not withheld after a leave until the next mount's landing has held it again",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .leave, .mount, .hold(tail: "a")], tail: "a", withheld: false),
        WithheldCase(testDescription: "a follower who never kept the marker has none withheld at a mount",
                     mountsAtTail: false, events: [.swiftUI("reply", tail: "a"), .leave, .mount], tail: "a", withheld: false),
        WithheldCase(testDescription: "a detached reader has none withheld",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .detach], tail: "b", withheld: false),
        WithheldCase(testDescription: "a reader who came back after being withheld has none withheld",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .swiftUI("reply", tail: "b"), .detach, .reattach],
                     tail: "b", withheld: false),
        WithheldCase(testDescription: "a new session has none withheld",
                     mountsAtTail: false, events: [.swiftUI(marker, tail: "a"), .swiftUI("reply", tail: "b"), .newSession], tail: "b", withheld: false),
        WithheldCase(testDescription: "a transcript that mounts at its tail has none withheld",
                     mountsAtTail: true, events: [.swiftUI(marker, tail: "a")], tail: "b", withheld: false),
    ]

    @Test(arguments: withheld)
    func withholdsMarker(_ c: WithheldCase) {
        let place = Self.played(c.events, mountsAtTail: c.mountsAtTail)
        #expect(place.withholdsMarker(tail: c.tail) == c.withheld)
    }

    @Test("what the transcript draws of the follower: following, and output it has not seen")
    func mirrorsTheFollower() {
        var place = NativeTranscriptPlace(mountsAtTail: true)
        #expect(place.follows && !place.unseen)
        var next = place.follower
        next.observe(distanceFromBottom: 600, userIntent: true)
        next.contentArrived()
        place.follow(next)
        #expect(!place.follows && place.unseen)
        next.jumpToLatest()
        place.follow(next)
        #expect(place.follows && !place.unseen)
    }

    @Test("a mount re-sticks the follower the way the jump pill does")
    func mountJumpsToLatest() {
        var place = NativeTranscriptPlace(mountsAtTail: true)
        var next = place.follower
        next.observe(distanceFromBottom: 600, userIntent: true)
        next.contentArrived()
        place.follow(next)
        place.mount()
        var expected = next
        expected.jumpToLatest()
        #expect(place.follower == expected)
    }
}
