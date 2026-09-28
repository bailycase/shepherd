import Testing
import ShepherdRemote

@Suite("Automatic thread history")
@MainActor
struct HistoryPagingTests {
    @Test func aVisibleTopLoadsOnePageAndNeverSpinsOnAnUnchangedCursor() {
        let paging = NativeHistoryPaging()
        func request(_ cursor: String? = "a", session: String = "s", enabled: Bool = true) -> Bool {
            paging.takeRequest(session: session, cursor: cursor, enabled: enabled)
        }
        #expect(!request())
        paging.visible = true
        #expect(!request(enabled: false))
        #expect(request())
        #expect(!request("b"))
        paging.visible = false
        paging.visible = true
        #expect(!request("b"), "layout alone cannot start another page")
        paging.visible = false
        paging.beginScroll()
        paging.visible = true
        #expect(!request())
        #expect(request("b"))
        #expect(request("b", session: "another-session"))
        paging.visible = false
        paging.visible = true
        #expect(!request(nil, session: "another-session"))
    }

    @Test func navigationBeforeTheDeferredSendLandingCancelsIt() {
        var follower = NativeScrollFollower()
        follower.sent(queued: false)
        // The view leaves this pending until after its layout yield. Navigation can cancel it.
        #expect(follower.awaitingSentTurn)
        follower.beginJump()
        let shouldLand = follower.userTurnArrived()
        #expect(!shouldLand)
        #expect(!follower.sticky)
    }
}
