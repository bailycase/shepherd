import Testing
import ShepherdRemote

/// A previous/next-turn jump detaches from the tail. Its animation passes through positions
/// that are not the reader's; only where it lands counts.
@Suite("Scroll follower: turn jumps")
struct ScrollFollowerJumpTests {
    @Test func aJumpStartingAtTheTailIsNotReStuckByItsFirstFrames() {
        var follower = NativeScrollFollower()
        follower.beginJump()
        follower.observe(distanceFromBottom: 0)        // animation's first frames, still at the tail
        follower.observe(distanceFromBottom: 40)
        #expect(!follower.sticky)
        follower.endJump(distanceFromBottom: 180)      // landed above the threshold
        #expect(!follower.sticky)
        follower.observe(distanceFromBottom: 240, contentGrew: true)
        #expect(follower.showsJump(running: true))
    }

    @Test func aJumpThatLandsAtTheBottomFollowsTheTailAgain() {
        var follower = NativeScrollFollower()
        follower.beginJump()
        follower.endJump(distanceFromBottom: 10)
        #expect(follower.sticky)
        #expect(!follower.jumping)
    }

    @Test func growthDuringAJumpIsRememberedAsUnseen() {
        var follower = NativeScrollFollower()
        follower.beginJump()
        follower.observe(distanceFromBottom: 300, contentGrew: true)
        follower.endJump(distanceFromBottom: 300)
        #expect(follower.unseen)
    }

    @Test func jumpingToLatestCancelsAJump() {
        var follower = NativeScrollFollower()
        follower.beginJump()
        follower.jumpToLatest()
        #expect(follower.sticky && !follower.jumping)
        follower.endJump(distanceFromBottom: 500)      // the stale settle check is ignored
        #expect(follower.sticky)
    }
}
