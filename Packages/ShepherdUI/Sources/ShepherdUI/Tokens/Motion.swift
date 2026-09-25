import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NW {
    /// Night Watch motion. The Foundations board's durations are the anchors (hover 120ms, panes
    /// 180ms, sheets 240ms, the glow 1.6s, the shimmer 1.8s; the spinner 1s and a placeholder's
    /// pulse 1.4s); every one-shot motion runs on a spring at its anchor, so an interrupted change
    /// retargets from where it is instead of restarting. Only attention glows, and live text
    /// shimmers: nothing in the thread spins (LiveText).
    ///
    /// Under Reduce Motion nothing moves: the continuous motions are static (live text reads as
    /// plain secondary text), anything that would slide, grow, or nudge cross-fades (120ms,
    /// eased), pops and scrolls are instant, and hover and content fades are unchanged because
    /// they are fades already.
    public enum Motion: CaseIterable, Sendable {
        /// Hover and press fills, focus rings, and color or opacity changes of a control: 120ms.
        case hover
        /// A value or label swapping in place (counters, status words, a button's icon): 120ms.
        case content
        /// Expanding or collapsing in place (activity lines, thinking, file diffs, chevrons): 180ms.
        case disclosure
        /// Rows arriving, leaving, or reordering in a list (sidebar, cards, files): 180ms.
        case list
        /// A pane opening or closing beside the thread (review, inspector, the overlaid sidebar):
        /// 180ms.
        case pane
        /// A floating layer appearing from its anchor (the palette, composer menus, popovers):
        /// 180ms, with a hint of bounce.
        case overlay
        /// An in-window sheet or a whole-window swap (Settings, a toast): 240ms.
        case sheet
        /// A small confirmation pop (viewed, copied, sent): 240ms, bouncy.
        case emphasis
        /// A programmatic scroll (turn jumps, revealing a row): 240ms.
        case scroll
        /// The attention glow: 1.6s ease-in-out, repeating. Attention only.
        case glow
        /// Work in progress outside the thread (a sheet's step, a host connecting): one turn per
        /// second, linear.
        case spin
        /// Live text (the running tool's line, thinking): a highlight moving across the text,
        /// 1.8s linear, repeating.
        case shimmer
        /// A loading placeholder's pulse: 1.4s ease-in-out, repeating.
        case pulse

        /// The board's anchor. For a spring this is its perceptual duration: the change reads as
        /// done by then, and the last fraction of a point settles a little later
        /// (`settlingDuration`).
        public var duration: TimeInterval {
            switch self {
            case .hover, .content: 0.12
            case .disclosure, .list, .pane, .overlay: 0.18
            case .sheet, .emphasis, .scroll: 0.24
            case .glow: 1.6
            case .spin: 1
            case .shimmer: 1.8
            case .pulse: 1.4
            }
        }

        /// Whether the motion loops (and so stops entirely under Reduce Motion).
        public var isContinuous: Bool { self == .glow || self == .spin || self == .shimmer || self == .pulse }

        /// The spring behind a one-shot motion; nil for the continuous ones. Anything that moves
        /// layout or slides in from an edge is critically damped (`.smooth`, no overshoot, so a
        /// pane never pulls away from the window's edge); overlays get `.snappy`'s slight bounce
        /// and the confirmation pop `.bouncy`'s.
        public var spring: Spring? {
            switch self {
            case .hover, .content, .disclosure, .list, .pane, .sheet, .scroll: .smooth(duration: duration)
            case .overlay: .snappy(duration: duration)
            case .emphasis: .bouncy(duration: duration)
            case .glow, .spin, .shimmer, .pulse: nil
            }
        }

        /// The animation to use, or nil when the change should apply at once.
        public func animation(reduceMotion: Bool) -> Animation? {
            switch self {
            case .glow: return reduceMotion ? nil : .easeInOut(duration: duration).repeatForever(autoreverses: true)
            case .spin: return reduceMotion ? nil : .linear(duration: duration).repeatForever(autoreverses: false)
            case .shimmer: return reduceMotion ? nil : .linear(duration: duration).repeatForever(autoreverses: false)
            case .pulse: return reduceMotion ? nil : .easeInOut(duration: duration / 2).repeatForever(autoreverses: true)
            case .hover, .content: return .smooth(duration: duration)
            case .disclosure, .list, .pane, .sheet:
                return reduceMotion ? Self.crossFade : .smooth(duration: duration)
            case .overlay: return reduceMotion ? Self.crossFade : .snappy(duration: duration)
            case .emphasis: return reduceMotion ? nil : .bouncy(duration: duration)
            case .scroll: return reduceMotion ? nil : .smooth(duration: duration)
            }
        }

        /// What stands in for movement under Reduce Motion: a short, eased cross-fade.
        public static let crossFade = Animation.easeInOut(duration: Motion.hover.duration)

        // MARK: Transitions

        /// How far a disclosed or listed row travels as it fades in.
        public static let nudge: CGFloat = NW.Space.s
        /// The scale an overlay grows from.
        public static let overlayScale: CGFloat = 0.96
        /// The scale a popped view grows from.
        public static let popScale: CGFloat = 0.85

        /// How a view arrives and leaves under a motion, as a value (see `transition`).
        public enum TransitionStyle: Equatable, Sendable {
            /// Opacity only.
            case fade
            /// Moves in from the edge, opaque the whole way (a pane).
            case slide(Edge)
            /// Moves in from the edge while fading (a toast, an in-window sheet).
            case rise(Edge)
            /// Fades in from `NW.Motion.nudge` points toward the edge (a disclosed or new row).
            case nudge(Edge)
            /// Grows from `overlayScale` at the anchor while fading (the palette, a menu).
            case grow(UnitPoint)
            /// Grows from `popScale` with a bounce while fading.
            case pop
            /// Appears and disappears at once.
            case identity
        }

        /// The edge a motion's transition uses when the caller names none.
        public var defaultEdge: Edge {
            switch self {
            case .pane: .trailing
            case .sheet: .bottom
            default: .top
            }
        }

        /// The transition for a view inserted or removed under this motion. `edge` is where a
        /// pane or sheet comes from, the side a row nudges from, or (for an overlay) the side of
        /// the anchor it grows from.
        public func transitionStyle(reduceMotion: Bool, edge: Edge? = nil) -> TransitionStyle {
            let edge = edge ?? defaultEdge
            switch self {
            case .hover, .content: return .fade
            case .glow, .spin, .shimmer, .pulse, .scroll: return .identity
            case .emphasis: return reduceMotion ? .fade : .pop
            case .disclosure, .list: return reduceMotion ? .fade : .nudge(edge)
            case .pane: return reduceMotion ? .fade : .slide(edge)
            case .sheet: return reduceMotion ? .fade : .rise(edge)
            case .overlay: return reduceMotion ? .fade : .grow(UnitPoint(edge))
            }
        }

        /// An overlay growing from a precise anchor (the composer's menus grow from their
        /// bottom-leading corner).
        public func transitionStyle(reduceMotion: Bool, anchor: UnitPoint) -> TransitionStyle {
            self == .overlay && !reduceMotion ? .grow(anchor) : transitionStyle(reduceMotion: reduceMotion)
        }

        public func transition(reduceMotion: Bool, edge: Edge? = nil) -> AnyTransition {
            transitionStyle(reduceMotion: reduceMotion, edge: edge).transition
        }
    }
}

extension NW.Motion.TransitionStyle {
    public var transition: AnyTransition {
        switch self {
        case .fade: .opacity
        case .slide(let edge): .move(edge: edge)
        case .rise(let edge): .move(edge: edge).combined(with: .opacity)
        case .nudge(let edge): .offset(NW.Motion.nudgeOffset(edge)).combined(with: .opacity)
        case .grow(let anchor): .scale(scale: NW.Motion.overlayScale, anchor: anchor).combined(with: .opacity)
        case .pop: .scale(scale: NW.Motion.popScale).combined(with: .opacity)
        case .identity: .identity
        }
    }
}

extension NW.Motion {
    static func nudgeOffset(_ edge: Edge) -> CGSize {
        switch edge {
        case .top: CGSize(width: 0, height: -nudge)
        case .bottom: CGSize(width: 0, height: nudge)
        case .leading: CGSize(width: -nudge, height: 0)
        case .trailing: CGSize(width: nudge, height: 0)
        }
    }
}

private extension UnitPoint {
    init(_ edge: Edge) {
        switch edge {
        case .top: self = .top
        case .bottom: self = .bottom
        case .leading: self = .leading
        case .trailing: self = .trailing
        }
    }
}

// MARK: Content transitions

extension NW {
    /// How a view's content changes in place. Under Reduce Motion the ones that move (rolling
    /// digits, symbol replacement) become a cross-fade.
    public enum ContentMotion: Equatable, Sendable {
        /// Digits roll to the new value (counts, stats, durations that change by the minute).
        case numeric(countsDown: Bool = false)
        /// Text interpolates weight and color (a row turning semibold as it is selected).
        case interpolate
        /// An SF Symbol replaces another (Send ⇄ Stop, a check appearing).
        case symbol
        /// The old content fades out as the new fades in.
        case crossFade

        public func contentTransition(reduceMotion: Bool) -> ContentTransition {
            switch self {
            case .numeric(let countsDown): reduceMotion ? .opacity : .numericText(countsDown: countsDown)
            case .interpolate: .interpolate
            case .symbol: reduceMotion ? .opacity : .symbolEffect(.replace)
            case .crossFade: .opacity
            }
        }
    }
}

// MARK: Applying motion

extension View {
    /// Animates every change in this view that happens with a change to `value`, with a Night
    /// Watch motion, honoring Reduce Motion. The way to animate state that a view model or a
    /// store changes (a pane opening from a menu, the palette's ⌘K): the view attaches the
    /// motion, so every path that flips the value animates the same way.
    public func nwAnimation<V: Equatable>(_ motion: NW.Motion, value: V) -> some View {
        modifier(NWAnimationModifier(motion: motion, value: value))
    }

    /// This view comes and goes with `motion`'s transition, from `edge` (see
    /// `NW.Motion.transitionStyle`), cross-fading under Reduce Motion. Pair it with
    /// `nwAnimation` on the container, or change the state in `withNWAnimation`.
    public func nwTransition(_ motion: NW.Motion, edge: Edge? = nil) -> some View {
        modifier(NWTransitionModifier(motion: motion, edge: edge, anchor: nil))
    }

    /// An overlay growing from `anchor`.
    public func nwTransition(_ motion: NW.Motion, anchor: UnitPoint) -> some View {
        modifier(NWTransitionModifier(motion: motion, edge: nil, anchor: anchor))
    }

    /// Comes from `insertion` and goes toward `removal` (a queued message rises from the bottom
    /// of its stack and leaves toward the thread when pi takes it).
    public func nwTransition(_ motion: NW.Motion, insertion: Edge, removal: Edge) -> some View {
        modifier(NWAsymmetricTransitionModifier(motion: motion, insertion: insertion, removal: removal))
    }

    /// How this view's content changes in place, honoring Reduce Motion. The change still
    /// needs an animation (`nwAnimation(.content, value:)`) to be seen.
    public func nwContentTransition(_ motion: NW.ContentMotion) -> some View {
        modifier(NWContentTransitionModifier(motion: motion))
    }

    /// A small bounce each time `trigger` changes (the emphasis motion); nothing under Reduce
    /// Motion. For an SF Symbol prefer `.symbolEffect(.bounce, value:)`.
    public func nwPop<T: Equatable>(trigger: T) -> some View {
        modifier(NWPopModifier(trigger: trigger))
    }

    /// Changes in this subtree apply at once, whatever animation the change arrived with (an
    /// ancestor's `nwAnimation`, a `withNWAnimation`). For what must never animate: terminal
    /// surfaces (SwiftUI resizes a hosted NSView every frame of an animated layout change, and
    /// each is a PTY resize), streaming text, and anything keyboard navigation moves. Motion
    /// attached inside the subtree with `nwAnimation` still runs, so put it on what must not
    /// move rather than on a whole pane.
    public func nwInstant() -> some View {
        transaction { $0.animation = nil }
    }
}

/// Runs `body` with a Night Watch motion, for state changed by an action (a click, a key)
/// rather than observed by a view. Reads Reduce Motion from the system, since there is no
/// environment here.
@MainActor
@discardableResult
public func withNWAnimation<Result>(_ motion: NW.Motion, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(motion.animation(reduceMotion: NW.Motion.systemReduceMotion), body)
}

/// `withNWAnimation` with a completion, called once the motion has finished (at once when
/// Reduce Motion drops it).
@MainActor
@discardableResult
public func withNWAnimation<Result>(_ motion: NW.Motion, _ body: () throws -> Result,
                                    completion: @escaping () -> Void) rethrows -> Result {
    try withAnimation(motion.animation(reduceMotion: NW.Motion.systemReduceMotion), completionCriteria: .removed, body,
                      completion: completion)
}

extension NW.Motion {
    /// The system's Reduce Motion setting, for code outside a view's environment.
    @MainActor public static var systemReduceMotion: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
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

private struct NWTransitionModifier: ViewModifier {
    let motion: NW.Motion
    let edge: Edge?
    let anchor: UnitPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let style = anchor.map { motion.transitionStyle(reduceMotion: reduceMotion, anchor: $0) }
            ?? motion.transitionStyle(reduceMotion: reduceMotion, edge: edge)
        content.transition(style.transition)
    }
}

private struct NWAsymmetricTransitionModifier: ViewModifier {
    let motion: NW.Motion
    let insertion: Edge
    let removal: Edge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(.asymmetric(insertion: motion.transition(reduceMotion: reduceMotion, edge: insertion),
                                       removal: motion.transition(reduceMotion: reduceMotion, edge: removal)))
    }
}

private struct NWContentTransitionModifier: ViewModifier {
    let motion: NW.ContentMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.contentTransition(motion.contentTransition(reduceMotion: reduceMotion))
    }
}

private struct NWPopModifier<T: Equatable>: ViewModifier {
    let trigger: T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One structure either way, so toggling Reduce Motion never remounts the popped view.
    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, scale in
            view.scaleEffect(reduceMotion ? 1 : scale)
        } keyframes: { _ in
            SpringKeyframe(NWPop.peak, duration: NW.Motion.emphasis.duration / 3, spring: .snappy)
            // No duration: the segment runs until the spring settles. Cut at the anchor it
            // would leave the view at a scale a hair off 1, with soft edges, until the next pop.
            SpringKeyframe(1.0, spring: NW.Motion.emphasis.spring ?? .bouncy)
        }
    }
}

enum NWPop {
    /// How far a pop swells before settling back.
    static let peak: Double = 1.12
}

extension EnvironmentValues {
    /// True under a subtree that stays mounted but is not on screen (an agent layout the
    /// workspace keeps while another one shows): the continuous motions (the spinner, the glow,
    /// the shimmer, the pulse) stop drawing frames there. It changes only when visibility flips.
    @Entry public var nwMotionPaused: Bool = false
}

/// Time-driven phase for the continuous motions. The spinner, the glow and the shimmer are Core
/// Animation animations started at the clock's phase (`NWLayerMotion`), so every one on screen
/// moves in step and costs the app nothing per frame; the pulse is a timeline that reads the
/// phase each frame. Either way Reduce Motion can toggle while one is on screen: the animation is removed
/// or the timeline pauses. Both also stop under `nwMotionPaused`, and the timeline while its view
/// is off screen (`onDisappear`), so motion no one sees costs nothing.
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

    /// The pulse's opacity, 0.55 → 1 → 0.55 over 1.4s, eased.
    static func pulseOpacity(_ date: Date) -> Double {
        let phase = fraction(date, .pulse)
        return 0.55 + 0.45 * (1 - cos(phase * 2 * .pi)) / 2
    }

    /// Where the shimmer's highlight is, in widths of its text: from one width before the text
    /// to one past it (`shimmerStart` … `shimmerEnd`), linear over 1.8s. The highlight fades to
    /// tertiary one width either side (`shimmerReach`), so the text is plain tertiary at both
    /// ends of a pass and the loop has no seam.
    static func shimmerCenter(_ date: Date) -> Double {
        shimmerStart + (shimmerEnd - shimmerStart) * fraction(date, .shimmer)
    }

    static let shimmerStart = -1.0
    static let shimmerEnd = 2.0
    static let shimmerReach = 1.0
}
