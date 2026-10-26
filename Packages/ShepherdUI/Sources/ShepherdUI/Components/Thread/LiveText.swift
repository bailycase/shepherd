import SwiftUI

// Live text (LiveText board): how the thread shows that pi is working. The live line shimmers,
// nothing spins, and only one thing moves at a time: the running tool's own line, or "Thinking…"
// between tools. A counting timer may tick beside it, in tertiary.

extension View {
    /// Live text: while `active`, a highlight moves across this text, tertiary → primary →
    /// tertiary, 1.8s linear (`SH.Motion.shimmer`). The band runs on the render server, masked
    /// by the text, so a live line costs the app no frames. Under Reduce Motion it is plain
    /// `textSecondary` text; while its layout is hidden (`shMotionPaused`) the band rests.
    ///
    /// While active it sets the text's color itself: style the inactive text after this
    /// modifier (`.shShimmer(active: running).foregroundStyle(…)`), whose color the active one
    /// overrides. Loading placeholders pulse with `shShimmer()` instead.
    public func shShimmer(active: Bool) -> some View {
        modifier(SHShimmerText(active: active))
    }
}

private struct SHShimmerText: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if !active {
            content
        } else if reduceMotion {
            content.foregroundStyle(Color.sh.textSecondary)
        } else {
            content
                .foregroundStyle(Color.sh.textTertiary)
                .overlay {
                    SHLayerShimmer()
                        .mask { content }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }
}
