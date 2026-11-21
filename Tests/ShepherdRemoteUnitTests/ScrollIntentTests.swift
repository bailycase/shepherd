#if DEBUG
import ShepherdRemote
import Testing

struct ScrollIntentTests {
    @Test func readerTakesOverAnimationThenCoastsToIdle() {
        var intent = ScrollIntent()
        #expect(intent.sample(programmatic: true) == .programmatic)
        #expect(intent.sample(touching: true, coasting: true, programmatic: true) == .touching)
        #expect(intent.sample(coasting: true, programmatic: true) == .coasting)
        #expect(intent.sample() == .idle)
    }

    @Test func aDiscreteReaderEventSurvivesUntilTheNextFrameOnly() {
        var intent = ScrollIntent()
        intent.readerInput()
        #expect(intent.sample(coasting: true) == .touching)
        #expect(intent.sample(coasting: true) == .coasting)
        #expect(intent.sample() == .idle)
    }

    @Test func unexplainedDisplacementCountsAsReaderMotionWithoutTouch() {
        var intent = ScrollIntent()
        #expect(intent.sample(unexplainedDisplacement: true) == .touching)
        #expect(intent.sample() == .idle)
        #expect(intent.sample(programmatic: true, unexplainedDisplacement: true) == .programmatic)
    }
}
#endif
