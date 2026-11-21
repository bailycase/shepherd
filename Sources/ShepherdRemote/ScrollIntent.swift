/// Native adapters supply motion and attribute displacement; this signal writes nothing.
public struct ScrollIntent {
    public enum State: String, Encodable, Sendable {
        case idle, touching, coasting, programmatic
    }

    public enum Phase {
        case idle, touching, coasting, animating
    }

    public enum WheelPhase {
        case absent, active, inactive
    }

    private var pendingReaderInput = false
    private var wheel: (state: State, until: ContinuousClock.Instant)?
    private var keyUntil: ContinuousClock.Instant?
    private var keyAnimating = false
    private var scrollerHeld = false
    public private(set) var physicalScrollerHeld = false
    private var commandFramesRemaining = 0
    private var animatedCommandFramesRemaining = 0
    private var previousIOSPhase: Phase = .idle
    private var commandAnimating = false
    private var layoutFramesRemaining = 0

    public init() {}

    public mutating func wheelInput(phase: WheelPhase, momentum: WheelPhase, moved: Bool, now: ContinuousClock.Instant) {
        // End/cancel may never arrive, even if the scroll view stays visible.
        if momentum == .active {
            wheel = (.coasting, now + .milliseconds(350))
        } else if momentum == .absent, phase == .active {
            wheel = (.touching, now + .milliseconds(350))
        } else {
            wheel = nil
            if moved, momentum == .absent, phase == .absent { pendingReaderInput = true }
        }
    }

    public func wheelInFlight(at now: ContinuousClock.Instant) -> Bool {
        wheel.map { now < $0.until } ?? false
    }

    public mutating func keyInput(at now: ContinuousClock.Instant) {
        pendingReaderInput = true
        keyUntil = now + .milliseconds(350)
    }

    public mutating func phaseChanged(from previous: Phase, to phase: Phase, now: ContinuousClock.Instant) {
        keyAnimating = phase == .animating && (keyUntil.map { now < $0 } ?? false)
        if phase != .idle || previous != .idle { keyUntil = nil }
    }

    public mutating func scrollerGrab(physical: Bool) {
        scrollerHeld = true
        physicalScrollerHeld = physical
        pendingReaderInput = true
    }

    public mutating func scrollerRelease() {
        scrollerHeld = false
        physicalScrollerHeld = false
    }

    public mutating func sampleMac(phase: Phase, now: ContinuousClock.Instant, leftMouseDown: Bool) -> State {
        // NSScroller's tracking loop can consume the mouse-up before the local monitor sees it.
        if physicalScrollerHeld && !leftMouseDown { scrollerRelease() }
        if !wheelInFlight(at: now) { wheel = nil }
        defer { pendingReaderInput = false }
        let coasting = wheel?.state == .coasting
        if pendingReaderInput || scrollerHeld || wheel?.state == .touching || (phase == .touching && !coasting) { return .touching }
        if coasting || phase == .coasting || keyAnimating { return .coasting }
        return phase == .animating ? .programmatic : .idle
    }

    public mutating func noteIOSCommand(animated: Bool) {
        // A command can land on the next layout pass, not just the frame that logged it.
        commandFramesRemaining = 2
        if animated { animatedCommandFramesRemaining = 2 }
    }

    public mutating func noteIOSLayout() {
        layoutFramesRemaining = 2
    }

    public mutating func sampleIOS(phase: Phase, offsetDelta: Double, layoutChanged: Bool) -> State {
        defer {
            previousIOSPhase = phase
            commandFramesRemaining = max(0, commandFramesRemaining - 1)
            animatedCommandFramesRemaining = max(0, animatedCommandFramesRemaining - 1)
            layoutFramesRemaining = max(0, layoutFramesRemaining - 1)
        }
        // Only a new animation within an animated command's grace keeps its attribution.
        let canStartCommandAnimation = previousIOSPhase != .animating && animatedCommandFramesRemaining > 0
        commandAnimating = phase == .animating && (commandAnimating || canStartCommandAnimation)
        if phase == .touching || phase == .coasting {
            commandFramesRemaining = 0
            animatedCommandFramesRemaining = 0
            return phase == .touching ? .touching : .coasting
        }
        if commandAnimating || commandFramesRemaining > 0 { return .programmatic }
        if abs(offsetDelta) > 0.5, !layoutChanged, layoutFramesRemaining == 0 { return .touching }
        return phase == .animating ? .programmatic : .idle
    }
}
