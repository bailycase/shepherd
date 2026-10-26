import SwiftUI

extension View {
    /// A control's disabled look, 40% opacity, fading on the hover motion. Every `.disabled`
    /// flip in the app reaches a control through here (Send, Commit, Retry, Fork…). Only the
    /// opacity animates, so a label that changes along with it still lands at once.
    public func shEnabledOpacity(_ enabled: Bool) -> some View {
        modifier(SHEnabledOpacity(enabled: enabled))
    }

    /// A component's own motion for a change of `value` (a status, a selection, a switch
    /// turning on) when the change arrives without one. A change that arrives animated (a list
    /// making room, a disclosure opening above) keeps its container's motion instead: an
    /// `shAnimation` here would move this view on its own, shorter motion, and it would drift
    /// off its row until both settle.
    public func shComponentAnimation<V: Equatable>(_ motion: SH.Motion, value: V) -> some View {
        modifier(SHComponentAnimation(motion: motion, value: value))
    }
}

enum SHControlMetrics {
    /// A disabled control's opacity (Controls board).
    static let disabledOpacity: Double = 0.4
}

private struct SHComponentAnimation<V: Equatable>: ViewModifier {
    let motion: SH.Motion
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let animation = motion.animation(reduceMotion: reduceMotion)
        content.transaction(value: value) { transaction in
            guard transaction.animation == nil, !transaction.disablesAnimations else { return }
            transaction.animation = animation
        }
    }
}

private struct SHEnabledOpacity: ViewModifier {
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(SH.Motion.hover.animation(reduceMotion: reduceMotion)) {
            $0.opacity(enabled ? 1 : SHControlMetrics.disabledOpacity)
        }
    }
}
