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
        follower.contentArrived()
        #expect(follower.showsJump(running: false))
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

    @Test func outputWhileTheJumpIsInTheBandIsRememberedAsUnseen() {
        var follower = NativeScrollFollower()
        follower.beginJump()
        follower.observe(distanceFromBottom: 30)
        follower.contentArrived()
        #expect(follower.unseen)
    }

    /// ⌥⌘↑ with pi idle: the lazy stack measures the rows the jump reveals, so the content
    /// height rises in the band and after landing. Nothing new arrived, so no pill.
    @Test func rowsMeasuredDuringAndAfterAJumpAreNothingNew() {
        var follower = NativeScrollFollower()
        let tail = NativeScrollProbe(content: 2000, offset: 1420, container: 520, insetTop: 60, insetBottom: 120)
        follower.beginJump()
        let inBand = NativeScrollProbe(content: 2040, offset: 1420, container: 520, insetTop: 60, insetBottom: 120)
        let landed = NativeScrollProbe(content: 2040, offset: 200, container: 520, insetTop: 60, insetBottom: 120)
        let measured = NativeScrollProbe(content: 2300, offset: 200, container: 520, insetTop: 60, insetBottom: 120)
        _ = follower.observe(from: tail, to: inBand, gesture: false)
        _ = follower.observe(from: inBand, to: landed, gesture: false)
        _ = follower.observe(from: landed, to: measured, gesture: false)
        #expect(!follower.sticky && !follower.unseen)
        #expect(!follower.showsJump(running: false))
    }

    @Test func jumpingToLatestCancelsAJump() {
        var follower = NativeScrollFollower()
        follower.beginJump()
        follower.jumpToLatest()
        #expect(follower.sticky && !follower.jumping)
    }
}
