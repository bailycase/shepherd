import ShepherdRemote
import Testing

struct ScrollIntentTests {
    private let now = ContinuousClock.now

    @Test func wheelNotchSurvivesForExactlyOneFrame() {
        var intent = ScrollIntent()
        intent.wheelInput(phase: .absent, momentum: .absent, moved: true, now: now)
        #expect(intent.sampleMac(phase: .idle, now: now, leftMouseDown: false) == .touching)
        #expect(intent.sampleMac(phase: .idle, now: now, leftMouseDown: false) == .idle)
    }

    @Test func wheelMomentumWinsOverTheOrdinaryPhaseAndEnds() {
        var intent = ScrollIntent()
        intent.wheelInput(phase: .active, momentum: .absent, moved: true, now: now)
        #expect(intent.sampleMac(phase: .idle, now: now, leftMouseDown: false) == .touching)
        intent.wheelInput(phase: .active, momentum: .active, moved: true, now: now)
        #expect(intent.sampleMac(phase: .touching, now: now, leftMouseDown: false) == .coasting)
        intent.wheelInput(phase: .inactive, momentum: .inactive, moved: true, now: now)
        #expect(intent.sampleMac(phase: .idle, now: now, leftMouseDown: false) == .idle)
    }

    @Test(arguments: [false, true]) func aMissingWheelEndExpires(momentum: Bool) {
        var intent = ScrollIntent()
        intent.wheelInput(phase: .active, momentum: momentum ? .active : .absent, moved: true, now: now)
        #expect(intent.sampleMac(phase: .idle, now: now, leftMouseDown: false) == (momentum ? .coasting : .touching))
        let later = now + .seconds(1)
        #expect(!intent.wheelInFlight(at: later))
        #expect(intent.sampleMac(phase: .idle, now: later, leftMouseDown: false) == .idle)
    }

    @Test func onlyAnAnimationWithinTheKeyWindowCountsAsReaderMotion() {
        var intent = ScrollIntent()
        intent.keyInput(at: now)
        #expect(intent.sampleMac(phase: .idle, now: now, leftMouseDown: false) == .touching)
        intent.phaseChanged(from: .idle, to: .animating, now: now + .milliseconds(20))
        #expect(intent.sampleMac(phase: .animating, now: now, leftMouseDown: false) == .coasting)
        intent.phaseChanged(from: .animating, to: .idle, now: now)
        #expect(intent.sampleMac(phase: .idle, now: now, leftMouseDown: false) == .idle)
        intent.keyInput(at: now)
        _ = intent.sampleMac(phase: .idle, now: now, leftMouseDown: false)
        let later = now + .seconds(1)
        intent.phaseChanged(from: .idle, to: .animating, now: later)
        #expect(intent.sampleMac(phase: .animating, now: later, leftMouseDown: false) == .programmatic)
    }

    @Test func scrollerDoesNotNeedAMouseUpEventToRelease() {
        var intent = ScrollIntent()
        intent.scrollerGrab(physical: true)
        #expect(intent.sampleMac(phase: .idle, now: now, leftMouseDown: true) == .touching)
        #expect(intent.sampleMac(phase: .idle, now: now, leftMouseDown: true) == .touching)
        #expect(intent.sampleMac(phase: .idle, now: now, leftMouseDown: false) == .idle)
        intent.scrollerGrab(physical: false)
        #expect(intent.sampleMac(phase: .idle, now: now, leftMouseDown: false) == .touching)
        intent.scrollerRelease()
        #expect(intent.sampleMac(phase: .idle, now: now, leftMouseDown: false) == .idle)
    }

    @Test func nonTouchPageIsReaderMotionUnlessACommandOrLayoutExplainsIt() {
        var intent = ScrollIntent()
        #expect(intent.sampleIOS(phase: .touching, offsetDelta: 0, layoutChanged: true) == .touching)
        #expect(intent.sampleIOS(phase: .coasting, offsetDelta: 20, layoutChanged: false) == .coasting)
        #expect(intent.sampleIOS(phase: .idle, offsetDelta: 0.25, layoutChanged: false) == .idle)
        #expect(intent.sampleIOS(phase: .idle, offsetDelta: 20, layoutChanged: true) == .idle)
        #expect(intent.sampleIOS(phase: .animating, offsetDelta: -20, layoutChanged: false) == .touching)
    }

    @Test func layoutEventExplainsDisplacementOnThisFrameAndTheNext() {
        var intent = ScrollIntent()
        intent.noteIOSLayout()
        #expect(intent.sampleIOS(phase: .idle, offsetDelta: 20, layoutChanged: false) == .idle)
        #expect(intent.sampleIOS(phase: .idle, offsetDelta: 20, layoutChanged: false) == .idle)
        #expect(intent.sampleIOS(phase: .idle, offsetDelta: 20, layoutChanged: false) == .touching)
    }

    @Test func commandedFindScrollStaysProgrammaticUntilAnimationEnds() {
        var intent = ScrollIntent()
        intent.noteIOSCommand()
        #expect(intent.sampleIOS(phase: .idle, offsetDelta: 0, layoutChanged: false) == .programmatic)
        for _ in 0..<4 {
            #expect(intent.sampleIOS(phase: .animating, offsetDelta: 20, layoutChanged: false) == .programmatic)
        }
        #expect(intent.sampleIOS(phase: .idle, offsetDelta: 0, layoutChanged: false) == .idle)
        #expect(intent.sampleIOS(phase: .animating, offsetDelta: -20, layoutChanged: false) == .touching)
    }
}
