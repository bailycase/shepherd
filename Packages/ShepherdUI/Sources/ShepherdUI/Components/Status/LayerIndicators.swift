import SwiftUI
import QuartzCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// The attention glow and live text's shimmer run on the render server: a Core
// Animation animation on a layer, installed once, so one on screen costs the app no frames (a
// SwiftUI timeline redrew its window on every display frame, most of a core in a debug build off
// screen). All keep their clock phase (`SHPhase`), so every dot
// pulses together, and every live line's highlight moves as one. Under Reduce Motion, or while
// `shMotionPaused`, the animation is removed and the layer rests as it draws statically.

/// A status dot that glows (only attention glows).
struct SHLayerGlowDot: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shMotionPaused) private var motionPaused
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SHGlowLayerRepresentable(color: color, animates: !reduceMotion && !motionPaused, colorScheme: colorScheme)
    }
}

extension SHPhase {
    /// The glow's opacity through one period as keyframes: `SHPhase.glowOpacity` sampled at
    /// `count` even steps and back to the start, so a linear interpolation between them follows
    /// the cosine to well under a percent.
    static func glowKeyframes(count: Int = 64) -> (values: [Double], keyTimes: [Double]) {
        let times = (0...count).map { Double($0) / Double(count) }
        let period = SH.Motion.glow.duration
        return (times.map { glowOpacity(Date(timeIntervalSinceReferenceDate: $0 * period)) }, times)
    }
}

/// Live text's moving highlight: a `textTertiary` → `textPrimary` → `textTertiary` band that
/// Core Animation slides across the view (`SH.Motion.shimmer`). Masked by the text it lights.
struct SHLayerShimmer: View {
    @Environment(\.shMotionPaused) private var motionPaused
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SHShimmerLayerRepresentable(base: .sh.textTertiary, highlight: .sh.textPrimary, animates: !motionPaused,
                                    colorScheme: colorScheme)
    }
}

extension SHPhase {
    /// The band's ends in unit coordinates of the text when its highlight is at `center` (in
    /// widths of the text).
    static func shimmerPoints(center: Double) -> (start: CGPoint, end: CGPoint) {
        (CGPoint(x: center - shimmerReach, y: 0.5), CGPoint(x: center + shimmerReach, y: 0.5))
    }

    /// Where a band that is not moving rests (a paused layout, a render for a preview): its
    /// highlight on the text's first half, as the boards draw it.
    static let shimmerRest = 0.35
}

/// The layer animations, shared by both platforms' views.
enum SHLayerMotion {
    static let glowKey = "sh.glow"
    static let shimmerKey = "sh.shimmer"

    /// The shimmer's band sliding once across its text per `SH.Motion.shimmer.duration`, linear,
    /// from where the clock's phase puts it now.
    static func shimmer(now: Date = Date()) -> CAAnimationGroup {
        let from = SHPhase.shimmerPoints(center: SHPhase.shimmerStart)
        let to = SHPhase.shimmerPoints(center: SHPhase.shimmerEnd)
        let start = CABasicAnimation(keyPath: "startPoint")
        start.fromValue = from.start
        start.toValue = to.start
        let end = CABasicAnimation(keyPath: "endPoint")
        end.fromValue = from.end
        end.toValue = to.end
        let group = CAAnimationGroup()
        group.animations = [start, end]
        group.duration = SH.Motion.shimmer.duration
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        group.timeOffset = SHPhase.fraction(now, .shimmer) * SH.Motion.shimmer.duration
        group.isRemovedOnCompletion = false
        return group
    }

    /// A band layer at rest: its stops and resting points, with no implicit animation.
    static func configure(_ band: CAGradientLayer) {
        band.actions = noActions.merging(["colors": NSNull(), "startPoint": NSNull(), "endPoint": NSNull()]) { $1 }
        band.type = .axial
        band.locations = [0, 0.5, 1]
        let rest = SHPhase.shimmerPoints(center: SHPhase.shimmerRest)
        band.startPoint = rest.start
        band.endPoint = rest.end
    }

    /// Layers that animate nothing implicitly: every change lands as the view model sets it.
    static let noActions: [String: CAAction] = [
        "path": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(), "lineWidth": NSNull(), "bounds": NSNull(),
        "position": NSNull(), "frame": NSNull(), "transform": NSNull(), "opacity": NSNull(), "hidden": NSNull(),
    ]

    /// The glow's pulse, 1 → 0.35 → 1 over `SH.Motion.glow.duration`, in phase with the clock.
    static func glow(now: Date = Date()) -> CAKeyframeAnimation {
        let frames = SHPhase.glowKeyframes()
        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = frames.values
        glow.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
        glow.calculationMode = .linear
        glow.duration = SH.Motion.glow.duration
        glow.repeatCount = .infinity
        glow.timeOffset = SHPhase.fraction(now, .glow) * SH.Motion.glow.duration
        glow.isRemovedOnCompletion = false
        return glow
    }

    /// Adds or removes `key`'s animation so the layer animates exactly when it should.
    static func sync(_ layer: CALayer, key: String, animates: Bool, make: () -> CAAnimation) {
        if animates, layer.animation(forKey: key) == nil {
            layer.add(make(), forKey: key)
        } else if !animates, layer.animation(forKey: key) != nil {
            layer.removeAnimation(forKey: key)
        }
    }
}

#if canImport(AppKit)

/// A filled circle whose opacity Core Animation pulses.
final class SHGlowLayerView: NSView {
    let dot = CAShapeLayer()
    private var animates = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dot.actions = SHLayerMotion.noActions
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { nil }

    func update(color: CGColor, animates: Bool) {
        dot.fillColor = color
        self.animates = animates
        syncAnimation()
    }

    override func layout() {
        super.layout()
        dot.frame = bounds
        dot.path = CGPath(ellipseIn: bounds, transform: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncAnimation()
    }

    private func syncAnimation() {
        SHLayerMotion.sync(dot, key: SHLayerMotion.glowKey, animates: animates && window != nil) { SHLayerMotion.glow() }
    }
}

struct SHGlowLayerRepresentable: NSViewRepresentable {
    let color: Color
    let animates: Bool
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> SHGlowLayerView { SHGlowLayerView() }

    func updateNSView(_ view: SHGlowLayerView, context: Context) {
        view.update(color: color.resolve(in: context.environment).cgColor, animates: animates)
    }
}


/// Live text's highlight band (`SHLayerShimmer`).
final class SHShimmerLayerView: NSView {
    let band = CAGradientLayer()
    private var animates = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        SHLayerMotion.configure(band)
        layer?.addSublayer(band)
    }

    required init?(coder: NSCoder) { nil }

    func update(base: CGColor, highlight: CGColor, animates: Bool) {
        band.colors = [base, highlight, base]
        self.animates = animates
        syncAnimation()
    }

    override func layout() {
        super.layout()
        band.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncAnimation()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func syncAnimation() {
        SHLayerMotion.sync(band, key: SHLayerMotion.shimmerKey, animates: animates && window != nil) { SHLayerMotion.shimmer() }
    }
}

struct SHShimmerLayerRepresentable: NSViewRepresentable {
    let base: Color
    let highlight: Color
    let animates: Bool
    /// Read so that an appearance change updates the view, which resolves the colors again.
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> SHShimmerLayerView { SHShimmerLayerView() }

    func updateNSView(_ view: SHShimmerLayerView, context: Context) {
        view.update(base: base.resolve(in: context.environment).cgColor, highlight: highlight.resolve(in: context.environment).cgColor,
                    animates: animates)
    }
}

#elseif canImport(UIKit)

final class SHGlowLayerView: UIView {
    let dot = CAShapeLayer()
    private var animates = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        dot.actions = SHLayerMotion.noActions
        layer.addSublayer(dot)
    }

    required init?(coder: NSCoder) { nil }

    func update(color: CGColor, animates: Bool) {
        dot.fillColor = color
        self.animates = animates
        syncAnimation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dot.frame = bounds
        dot.path = CGPath(ellipseIn: bounds, transform: nil)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncAnimation()
    }

    private func syncAnimation() {
        SHLayerMotion.sync(dot, key: SHLayerMotion.glowKey, animates: animates && window != nil) { SHLayerMotion.glow() }
    }
}

struct SHGlowLayerRepresentable: UIViewRepresentable {
    let color: Color
    let animates: Bool
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> SHGlowLayerView { SHGlowLayerView() }

    func updateUIView(_ view: SHGlowLayerView, context: Context) {
        view.update(color: color.resolve(in: context.environment).cgColor, animates: animates)
    }
}

/// Live text's highlight band (`SHLayerShimmer`).
final class SHShimmerLayerView: UIView {
    let band = CAGradientLayer()
    private var animates = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        SHLayerMotion.configure(band)
        layer.addSublayer(band)
    }

    required init?(coder: NSCoder) { nil }

    func update(base: CGColor, highlight: CGColor, animates: Bool) {
        band.colors = [base, highlight, base]
        self.animates = animates
        syncAnimation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        band.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncAnimation()
    }

    private func syncAnimation() {
        SHLayerMotion.sync(band, key: SHLayerMotion.shimmerKey, animates: animates && window != nil) { SHLayerMotion.shimmer() }
    }
}

struct SHShimmerLayerRepresentable: UIViewRepresentable {
    let base: Color
    let highlight: Color
    let animates: Bool
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> SHShimmerLayerView { SHShimmerLayerView() }

    func updateUIView(_ view: SHShimmerLayerView, context: Context) {
        view.update(base: base.resolve(in: context.environment).cgColor, highlight: highlight.resolve(in: context.environment).cgColor,
                    animates: animates)
    }
}

#endif
