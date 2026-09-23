import SwiftUI

extension View {
    /// A control's disabled look, 40% opacity, fading on the hover motion. Every `.disabled`
    /// flip in the app reaches a control through here (Send, Commit, Retry, Fork…). Only the
    /// opacity animates, so a label that changes along with it still lands at once.
    func nwEnabledOpacity(_ enabled: Bool) -> some View {
        modifier(NWEnabledOpacity(enabled: enabled))
    }
}

enum NWControlMetrics {
    /// A disabled control's opacity (Controls board).
    static let disabledOpacity: Double = 0.4
}

private struct NWEnabledOpacity: ViewModifier {
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(NW.Motion.hover.animation(reduceMotion: reduceMotion)) {
            $0.opacity(enabled ? 1 : NWControlMetrics.disabledOpacity)
        }
    }
}
