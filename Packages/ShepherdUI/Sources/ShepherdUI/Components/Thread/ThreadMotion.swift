import SwiftUI

extension View {
    /// Makes an entrance once, the first time this view is created, when `isNew`: a turn, an
    /// activity line, or a card that streamed into a thread already on screen. It fades in (a
    /// `.list` motion also nudges from `edge`) with opacity and offset only, so the list's
    /// layout, and a scroll view following its tail, never moves. A view created later with
    /// `isNew` false (a first load, a page of history, a row scrolled back into a lazy stack)
    /// is simply there. Under Reduce Motion it only fades.
    ///
    /// A transition would need the insertion itself to animate, and a thread's rows arrive in
    /// the store's plain transactions alongside streaming text that must not animate.
    public func nwArrival(_ isNew: Bool, _ motion: NW.Motion = .content, edge: Edge? = nil) -> some View {
        modifier(NWArrivalModifier(isNew: isNew, motion: motion, edge: edge))
    }
}

extension View {
    /// Arrives with `motion`'s transition (from `edge`) and leaves at once. For one view taking
    /// another's place in a card that is resizing (the composer's field and a question): a
    /// leaving view keeps drawing where it was, over whatever has moved there.
    public func nwEntrance(_ motion: NW.Motion, edge: Edge? = nil) -> some View {
        modifier(NWEntranceModifier(motion: motion, edge: edge))
    }
}

private struct NWEntranceModifier: ViewModifier {
    let motion: NW.Motion
    let edge: Edge?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(.asymmetric(insertion: motion.transition(reduceMotion: reduceMotion, edge: edge), removal: .identity))
    }
}

private struct NWArrivalModifier: ViewModifier {
    let motion: NW.Motion
    let edge: Edge?
    @State private var arrived: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isNew: Bool, motion: NW.Motion, edge: Edge?) {
        self.motion = motion
        self.edge = edge
        _arrived = State(initialValue: !isNew)
    }

    func body(content: Content) -> some View {
        content
            .opacity(arrived ? 1 : 0)
            .offset(arrived ? .zero : offset)
            .onAppear {
                guard !arrived else { return }
                NWRenderProbe.tick("arrival.animates")
                withAnimation(motion.animation(reduceMotion: reduceMotion)) { arrived = true }
            }
    }

    private var offset: CGSize {
        if case .nudge(let edge) = motion.transitionStyle(reduceMotion: reduceMotion, edge: edge) {
            return NW.Motion.nudgeOffset(edge)
        }
        return .zero
    }
}
