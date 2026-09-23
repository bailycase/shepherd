import Testing
import ShepherdRemote

/// A previous/next-turn jump detaches from the tail. Its scroll starts at the bottom, and those
/// first positions must not re-stick; where it lands decides from then on.
@Suite("Scroll follower: turn jumps")
struct ScrollFollowerJumpTests {
    @Test func aJumpStartingAtTheTailIsNotReStuckByItsFirstFrames() {
        var follower = NativeScrollFollower()
        follower.beginJump()
        follower.observe(distanceFromBottom: 0)        // the scroll's first frames, still at the tail
        follower.observe(distanceFromBottom: 40)
        #expect(!follower.sticky)
        follower.observe(distanceFromBottom: 180)      // left the band: landed on the earlier turn
        #expect(!follower.jumping && !follower.sticky)
        follower.observe(distanceFromBottom: 240, contentGrew: true)
        #expect(follower.showsJump(running: true))
    }

    @Test func afterLandingTheBottomReStucksAsUsual() {
        var follower = NativeScrollFollower()
        follower.beginJump()
        follower.observe(distanceFromBottom: 180)
        follower.observe(distanceFromBottom: 20)
        #expect(follower.sticky)
    }

    @Test func aReaderScrollingEndsAJumpThatNeverLeftTheBand() {
        var follower = NativeScrollFollower()
        follower.beginJump()
        follower.observe(distanceFromBottom: 10)
        #expect(!follower.sticky)
        follower.observe(distanceFromBottom: 0, userIntent: true)
        #expect(follower.sticky && !follower.jumping)
    }

    @Test func growthWhileTheJumpIsInTheBandIsRememberedAsUnseen() {
        var follower = NativeScrollFollower()
        follower.beginJump()
        follower.observe(distanceFromBottom: 30, contentGrew: true)
        #expect(follower.unseen)
    }

    @Test func jumpingToLatestCancelsAJump() {
        var follower = NativeScrollFollower()
        follower.beginJump()
        follower.jumpToLatest()
        #expect(follower.sticky && !follower.jumping)
    }
}
