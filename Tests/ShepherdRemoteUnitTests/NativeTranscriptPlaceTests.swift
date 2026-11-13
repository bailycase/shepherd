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
        /// SwiftUI reports the turn under the top edge through the position binding; nil is its report of none.
        case swiftUI(String?)
        /// The history pager keeps the oldest loaded turn while older ones load.
        case pin(String?)
        /// The transcript mounts again.
        case mount
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
    ]

    @Test(arguments: cases)
    func place(_ c: Case) {
        var place = NativeTranscriptPlace(mountsAtTail: c.mountsAtTail)
        for event in c.events {
            switch event {
            case .detach:
                var next = place.follower
                next.observe(distanceFromBottom: 600, userIntent: true)
                place.follow(next)
            case .reattach:
                var next = place.follower
                next.jumpToLatest()
                place.follow(next)
            case .swiftUI(let id): place.note(id)
            case .pin(let id): place.pin(id)
            case .mount: place.mount()
            case .newSession: place.note(nil)
            }
        }
        #expect(place.turn == c.turn)
        #expect(place.restoresTurn == (c.turn != nil))
        #expect(place.follows == c.follows)
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
