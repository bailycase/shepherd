import Testing
import ShepherdRemote

/// What the reader's sends and the thread's new output do to the follower: a send that goes in
/// now re-attaches and lands on its turn; a follow-up that waits in Up next leaves the reader's
/// place alone, then and when it goes; only output arriving (never the content height) is unseen.
@Suite("Scroll follower: sends and arrivals")
struct ScrollFollowerSendTests {
    enum Event: Sendable {
        /// The reader's gesture moved the view up, away from the tail.
        case dragUp
        /// ⌥⌘↑ to an earlier turn, landing well above the tail.
        case jumpUp
        case send(queued: Bool)
        /// The thread's last user turn changed.
        case userTurn
        case output
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var events: [Event]
        var sticky: Bool
        /// Whether the last `userTurn` asked for the tail.
        var lands: Bool
        var pill: Bool
    }

    static let cases: [Case] = [
        Case(testDescription: "a send that goes in now, from an earlier turn, re-attaches and lands on its turn",
             events: [.jumpUp, .send(queued: false), .userTurn], sticky: true, lands: true, pill: false),
        Case(testDescription: "a queued follow-up sent while detached leaves the reader where they are",
             events: [.dragUp, .send(queued: true)], sticky: false, lands: false, pill: false),
        Case(testDescription: "a queued follow-up going in later, while detached, is new output and never a pull",
             events: [.send(queued: true), .jumpUp, .userTurn, .output], sticky: false, lands: false, pill: true),
        Case(testDescription: "a queued follow-up sent at the tail, delivered after the reader left, keeps their place",
             events: [.send(queued: true), .dragUp, .userTurn, .output], sticky: false, lands: false, pill: true),
        Case(testDescription: "leaving the tail before the sent turn arrives cancels the landing",
             events: [.send(queued: false), .dragUp, .userTurn], sticky: false, lands: false, pill: false),
        Case(testDescription: "a turn jump before the sent turn arrives cancels the landing",
             events: [.send(queued: false), .jumpUp, .userTurn], sticky: false, lands: false, pill: false),
        Case(testDescription: "a user turn nobody here sent is not a landing",
             events: [.userTurn], sticky: true, lands: false, pill: false),
        Case(testDescription: "the send lands once, not again on the next user turn",
             events: [.send(queued: false), .userTurn, .userTurn], sticky: true, lands: false, pill: false),
        Case(testDescription: "output at the tail while stuck is followed, not unseen",
             events: [.output], sticky: true, lands: false, pill: false),
        Case(testDescription: "output while detached shows the pill with pi idle",
             events: [.dragUp, .output], sticky: false, lands: false, pill: true),
        Case(testDescription: "a jump with nothing new shows no pill with pi idle",
             events: [.jumpUp], sticky: false, lands: false, pill: false),
    ]

    @Test(arguments: cases)
    func sendsAndArrivals(_ c: Case) {
        var follower = NativeScrollFollower()
        var lands = false
        for event in c.events {
            switch event {
            case .dragUp: follower.observe(distanceFromBottom: 600, userIntent: true)
            case .jumpUp:
                follower.beginJump()
                follower.observe(distanceFromBottom: 600)
            case .send(let queued): follower.sent(queued: queued)
            case .userTurn: lands = follower.userTurnArrived()
            case .output: follower.contentArrived()
            }
        }
        #expect(follower.sticky == c.sticky)
        #expect(lands == c.lands)
        #expect(follower.showsJump(running: false) == c.pill)
    }
}
