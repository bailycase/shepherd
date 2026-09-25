import Foundation
import ShepherdProtocol
import ShepherdRemote
import Testing
@testable import ShepherdApp

/// A user turn as the thread draws it: messages the queue delivered as one read as the messages
/// they were, each with the time it was sent, under "From the queue".
@Suite("User turn")
@MainActor
struct UserTurnTests {
    static func user(_ id: String, _ text: String, at time: Double?, origin: NativeMessageOrigin? = nil, status: String? = nil) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "user", blocks: [NativeThreadBlock(kind: .text, text: text)], status: status,
                            timestamp: time, origin: origin)
    }

    @Test func aDeliveryFromTheQueueShowsEachMessageWithTheTimeItWasSent() throws {
        let parts = [NativeQueuePart(text: "Also cover partial refunds.", sentAt: 1_000_000), NativeQueuePart(text: "Then open a PR.", sentAt: 1_060_000)]
        let turn = try #require(nativeTurns([Self.user("u", "joined", at: 2_000_000, origin: .queue(parts: parts))]).first)

        let view = UserTurn(turn: turn)

        #expect(view.fromQueue == 2)
        #expect(view.bubbles.map(\.text) == parts.map(\.text))
        #expect(view.bubbles.map(\.caption) == parts.map { nativeClockText($0.sentAt) })
    }

    @Test func aSentMessageShowsItsOwnTimeAndAnUnreadSendWaitsAt70Percent() throws {
        let turn = try #require(nativeTurns([Self.user("u", "Fix it", at: 3_000_000), Self.user("p", "And test it", at: nil, status: "pending")]).first)

        let view = UserTurn(turn: turn)

        #expect(view.fromQueue == nil)
        #expect(view.bubbles.map(\.caption) == [nativeClockText(3_000_000), nil])
        #expect(view.bubbles.map(\.pending) == [false, true])
    }
}
