import SwiftUI

extension View {
    /// Makes an entrance once, when `isNew`: something that arrives in a subagent surface already
    /// on screen (a card's question, a card joining its group, a turn in the inspector's
    /// transcript). It fades in where it lands (a `.list` or `.disclosure` motion also nudges
    /// from `edge`), by opacity and offset alone and after it is placed, so the layout around it
    /// changes at once. A card in a thread cannot ease its height: what follows it in the turn
    /// (the next card, "Working…") moves at once, and a card shrinking under an animation would
    /// be drawn over by it. Created with `isNew` false (a first load, a row scrolled back into a
    /// lazy stack) the view is simply there. It leaves at once. Under Reduce Motion it only fades.
    public func nwRunArrival(_ isNew: Bool, _ motion: NW.Motion = .content, edge: Edge? = nil) -> some View {
        modifier(NWRunArrivalModifier(isNew: isNew, motion: motion, edge: edge))
    }
}

private struct NWRunArrivalModifier: ViewModifier {
    let motion: NW.Motion
    let edge: Edge?
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isNew: Bool, motion: NW.Motion, edge: Edge?) {
        self.motion = motion
        self.edge = edge
        _shown = State(initialValue: !isNew)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(shown ? .zero : offset)
            // Attached here and started from a task, after the view is placed: an animation
            // begun while it is laid out would carry that whole layout pass with it.
            .nwAnimation(motion, value: shown)
            .task { if !shown { shown = true } }
    }

    private var offset: CGSize {
        if case .nudge(let edge) = motion.transitionStyle(reduceMotion: reduceMotion, edge: edge) {
            return NW.Motion.nudgeOffset(edge)
        }
        return .zero
    }
}

/// Whether a view has been on screen, for the parts it creates later (`nwRunArrival`). A
/// reference, so noting the first appearance never renders.
@MainActor
public final class NWShownFlag {
    public var appeared = false

    public init() {}
}
