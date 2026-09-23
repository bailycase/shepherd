import SwiftUI

extension NW {
    /// Night Watch motion (Foundations board). Only attention glows and only running work
    /// spins. Under Reduce Motion the glow and the spinner are static, and panes and sheets
    /// cross-fade instead of moving.
    public enum Motion: Sendable {
        /// The attention glow: 1.6s ease-in-out, repeating.
        case glow
        /// A running tool or turn: one turn per second, linear.
        case spin
        /// Hover fills: 120ms.
        case hover
        /// Panes opening, closing, expanding: 180ms.
        case pane
        /// Sheets: 240ms.
        case sheet

        public var duration: TimeInterval {
            switch self {
            case .glow: 1.6
            case .spin: 1
            case .hover: 0.12
            case .pane: 0.18
            case .sheet: 0.24
            }
        }

        /// Whether the motion loops (and so stops entirely under Reduce Motion).
        public var isContinuous: Bool { self == .glow || self == .spin }

        /// The animation to use, or nil when Reduce Motion drops it. Transitions (`hover`,
        /// `pane`, `sheet`) keep a short cross-fade under Reduce Motion; pair them with
        /// `transition(reduceMotion:)`.
        public func animation(reduceMotion: Bool) -> Animation? {
            switch self {
            case .glow: reduceMotion ? nil : .easeInOut(duration: duration).repeatForever(autoreverses: true)
            case .spin: reduceMotion ? nil : .linear(duration: duration).repeatForever(autoreverses: false)
            case .hover: .easeOut(duration: duration)
            case .pane, .sheet: reduceMotion ? .easeInOut(duration: NW.Motion.hover.duration) : .easeInOut(duration: duration)
            }
        }

        /// Panes and sheets move in; under Reduce Motion they only fade.
        public func transition(reduceMotion: Bool, edge: Edge = .trailing) -> AnyTransition {
            reduceMotion || self == .hover ? .opacity : .move(edge: edge).combined(with: .opacity)
        }
    }
}

extension View {
    /// Animates changes to `value` with a Night Watch motion, honoring Reduce Motion.
    public func nwAnimation<V: Equatable>(_ motion: NW.Motion, value: V) -> some View {
        modifier(NWAnimationModifier(motion: motion, value: value))
    }
}

private struct NWAnimationModifier<V: Equatable>: ViewModifier {
    let motion: NW.Motion
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(motion.animation(reduceMotion: reduceMotion), value: value)
    }
}

/// Time-driven phase for the continuous motions. Deriving the phase from the clock (instead of
/// a repeating animation started in `onAppear`) keeps a spinner or glow correct when Reduce
/// Motion toggles while it is on screen: the timeline simply pauses or resumes.
enum NWPhase {
    /// 0..<1 through one period of `motion`.
    static func fraction(_ date: Date, _ motion: NW.Motion) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return t.truncatingRemainder(dividingBy: motion.duration) / motion.duration
    }

    /// The glow's opacity, 1 → 0.35 → 1 over 1.6s, eased.
    static func glowOpacity(_ date: Date) -> Double {
        let phase = fraction(date, .glow)
        return 0.35 + 0.65 * (cos(phase * 2 * .pi) + 1) / 2
    }
}
