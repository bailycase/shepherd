import SwiftUI
import Testing
@testable import ShepherdUI

/// Night Watch motion: the board's durations as anchors, the springs behind them, and what
/// Reduce Motion leaves.
@Suite("Night Watch motion")
struct MotionTests {
    typealias Motion = NW.Motion

    @Test(arguments: [
        (Motion.hover, 0.12), (.content, 0.12),
        (.disclosure, 0.18), (.list, 0.18), (.pane, 0.18), (.overlay, 0.18),
        (.sheet, 0.24), (.emphasis, 0.24), (.scroll, 0.24),
        (.glow, 1.6), (.spin, 1), (.shimmer, 1.4),
    ])
    func everyMotionIsAnchoredToABoardDuration(_ motion: Motion, duration: TimeInterval) {
        #expect(motion.duration == duration)
    }

    @Test func onlyTheGlowTheSpinnerAndTheShimmerLoop() {
        #expect(Motion.allCases.filter(\.isContinuous) == [.glow, .spin, .shimmer])
        #expect(Motion.allCases.filter(\.isContinuous).allSatisfy { $0.spring == nil })
    }

    /// Springs at the anchors: smooth for layout, snappy for overlays, bouncy for the pop.
    @Test(arguments: [
        (Motion.hover, Animation.smooth(duration: 0.12)), (.content, .smooth(duration: 0.12)),
        (.disclosure, .smooth(duration: 0.18)), (.list, .smooth(duration: 0.18)), (.pane, .smooth(duration: 0.18)),
        (.overlay, .snappy(duration: 0.18)), (.sheet, .smooth(duration: 0.24)), (.emphasis, .bouncy(duration: 0.24)),
        (.scroll, .smooth(duration: 0.24)),
    ])
    func oneShotMotionsRunOnSpringsAtTheirAnchors(_ motion: Motion, animation: Animation) throws {
        #expect(motion.animation(reduceMotion: false) == animation)
        let spring = try #require(motion.spring)
        #expect(abs(spring.duration - motion.duration) < 1e-9)
    }

    /// Anything that moves layout or slides from an edge is critically damped: a pane never
    /// pulls away from the window's edge, a row never overshoots its slot.
    @Test(arguments: [Motion.hover, .content, .disclosure, .list, .pane, .sheet, .scroll])
    func layoutMotionsNeverOvershoot(_ motion: Motion) throws {
        let spring = try #require(motion.spring)
        #expect(spring.bounce == 0)
        for step in 0...40 {
            let time = motion.duration * 3 * Double(step) / 40
            #expect(spring.value(target: 1.0, time: time) <= 1 + 1e-9)
        }
    }

    @Test(arguments: [Motion.overlay, .emphasis])
    func overlaysAndThePopBounce(_ motion: Motion) throws {
        let spring = try #require(motion.spring)
        #expect(spring.bounce > 0)
        let peak = (0...60).map { spring.value(target: 1.0, time: motion.duration * 3 * Double($0) / 60) }.max() ?? 0
        #expect(peak > 1)
    }

    /// The anchor is when a change reads as done: by then every spring is within 5% of its
    /// target, and the tail settles well inside a second.
    @Test(arguments: Motion.allCases.filter { !$0.isContinuous })
    func springsReadAsDoneByTheirAnchor(_ motion: Motion) throws {
        let spring = try #require(motion.spring)
        #expect(abs(spring.value(target: 1.0, time: motion.duration) - 1) < 0.05)
        #expect(spring.settlingDuration < 3 * motion.duration)
    }

    @Test(arguments: [
        (Motion.hover, Motion.hover.animation(reduceMotion: false)), (.content, Motion.content.animation(reduceMotion: false)),
        (.disclosure, Motion.crossFade), (.list, Motion.crossFade), (.pane, Motion.crossFade),
        (.overlay, Motion.crossFade), (.sheet, Motion.crossFade),
        (.emphasis, nil), (.scroll, nil), (.glow, nil), (.spin, nil), (.shimmer, nil),
    ])
    func reduceMotionKeepsFadesAndDropsMovement(_ motion: Motion, animation: Animation?) {
        #expect(motion.animation(reduceMotion: true) == animation)
    }

    @Test func theCrossFadeIsAShortEase() {
        #expect(Motion.crossFade == .easeInOut(duration: Motion.hover.duration))
    }

    @Test(arguments: [
        (Motion.pane, nil, Motion.TransitionStyle.slide(.trailing)), (.pane, .leading, .slide(.leading)),
        (.sheet, nil, .rise(.bottom)), (.sheet, .top, .rise(.top)),
        (.disclosure, nil, .nudge(.top)), (.list, nil, .nudge(.top)), (.list, .bottom, .nudge(.bottom)),
        (.overlay, nil, .grow(.top)), (.overlay, .bottom, .grow(.bottom)),
        (.emphasis, nil, .pop), (.hover, nil, .fade), (.content, .leading, .fade),
        (.scroll, nil, .identity), (.glow, nil, .identity), (.spin, nil, .identity), (.shimmer, nil, .identity),
    ] as [(Motion, Edge?, Motion.TransitionStyle)])
    func transitionsComeFromTheirEdges(_ motion: Motion, edge: Edge?, style: Motion.TransitionStyle) {
        #expect(motion.transitionStyle(reduceMotion: false, edge: edge) == style)
    }

    @Test func anOverlayGrowsFromItsAnchor() {
        #expect(Motion.overlay.transitionStyle(reduceMotion: false, anchor: .bottomLeading) == .grow(.bottomLeading))
        #expect(Motion.overlay.transitionStyle(reduceMotion: true, anchor: .bottomLeading) == .fade)
        #expect(Motion.pane.transitionStyle(reduceMotion: false, anchor: .bottomLeading) == .slide(.trailing))
    }

    /// Under Reduce Motion nothing slides, rises, nudges, grows, or pops.
    @Test(arguments: Motion.allCases)
    func reduceMotionTurnsMovementIntoAFade(_ motion: Motion) {
        for edge in [nil, Edge.top, .bottom, .leading, .trailing] {
            let style = motion.transitionStyle(reduceMotion: true, edge: edge)
            #expect(style == .fade || style == .identity, "\(motion) from \(String(describing: edge)): \(style)")
        }
    }

    @Test(arguments: [
        (NW.ContentMotion.numeric(), ContentTransition.numericText(countsDown: false), ContentTransition.opacity),
        (.numeric(countsDown: true), .numericText(countsDown: true), .opacity),
        (.interpolate, .interpolate, .interpolate),
        (.symbol, .symbolEffect(.replace), .opacity),
        (.crossFade, .opacity, .opacity),
    ])
    func contentChangesStopMovingUnderReduceMotion(_ motion: NW.ContentMotion, normal: ContentTransition, reduced: ContentTransition) {
        #expect(motion.contentTransition(reduceMotion: false) == normal)
        #expect(motion.contentTransition(reduceMotion: true) == reduced)
    }

    @Test func theGlowPulsesBetweenFullAndDim() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(abs(NWPhase.glowOpacity(start) - 1) < 1e-9)
        #expect(abs(NWPhase.glowOpacity(start.addingTimeInterval(0.8)) - 0.35) < 1e-9)
    }

    /// The render server plays the glow from keyframes: the clock's curve, sampled evenly over
    /// one period and closed where it began, so the pulse is the cosine it was.
    @Test func theGlowsKeyframesFollowItsCurve() {
        let frames = NWPhase.glowKeyframes(count: 64)
        #expect(frames.values.count == 65 && frames.keyTimes.count == 65)
        #expect(frames.keyTimes.first == 0 && frames.keyTimes.last == 1)
        #expect(abs(frames.values[0] - 1) < 1e-9 && abs(frames.values[64] - 1) < 1e-9)
        #expect(abs(frames.values[32] - 0.35) < 1e-9)
        for (value, time) in zip(frames.values, frames.keyTimes) {
            let date = Date(timeIntervalSinceReferenceDate: time * Motion.glow.duration)
            #expect(abs(value - NWPhase.glowOpacity(date)) < 1e-9)
        }
        // Linear between frames, the pulse never strays a percent from the cosine.
        for step in 0..<640 {
            let fraction = Double(step) / 640
            let index = Int(fraction * 64)
            let local = fraction * 64 - Double(index)
            let interpolated = frames.values[index] + (frames.values[index + 1] - frames.values[index]) * local
            let exact = NWPhase.glowOpacity(Date(timeIntervalSinceReferenceDate: fraction * Motion.glow.duration))
            #expect(abs(interpolated - exact) < 0.01)
        }
    }

    @Test(arguments: [(CGFloat(8), CGFloat(1.5)), (13, 1.885), (48, 6.96)])
    func theSpinnersStrokeScalesWithItsSize(size: CGFloat, width: CGFloat) {
        #expect(abs(NWPhase.spinnerLineWidth(size: size) - width) < 1e-6)
    }

    @Test func theShimmerPulsesBetweenDimAndFull() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(abs(NWPhase.shimmerOpacity(start) - 0.55) < 1e-9)
        #expect(abs(NWPhase.shimmerOpacity(start.addingTimeInterval(0.7)) - 1) < 1e-9)
    }
}
