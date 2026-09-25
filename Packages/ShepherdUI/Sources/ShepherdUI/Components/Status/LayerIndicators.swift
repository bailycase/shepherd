import SwiftUI
import QuartzCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// The spinner, the attention glow and live text's shimmer run on the render server: a Core
// Animation animation on a layer, installed once, so one on screen costs the app no frames (a
// SwiftUI timeline redrew its window on every display frame, most of a core in a debug build off
// screen). All keep their clock phase (`NWPhase`), so every spinner turns in step, every dot
// pulses together, and every live line's highlight moves as one. Under Reduce Motion, or while
// `nwMotionPaused`, the animation is removed and the layer rests as it draws statically.

/// The running spinner's 3/4 arc.
struct NWLayerSpinner: View {
    let size: CGFloat
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nwMotionPaused) private var motionPaused
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NWSpinnerLayerRepresentable(size: size, color: color, animates: !reduceMotion && !motionPaused, colorScheme: colorScheme)
            .frame(width: size, height: size)
    }
}

/// A status dot that glows (only attention glows).
struct NWLayerGlowDot: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nwMotionPaused) private var motionPaused
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NWGlowLayerRepresentable(color: color, animates: !reduceMotion && !motionPaused, colorScheme: colorScheme)
    }
}

extension NWPhase {
    /// The spinner's stroke: at least 1.5pt, else 14.5% of its size.
    static func spinnerLineWidth(size: CGFloat) -> CGFloat { max(1.5, size * 0.145) }

    /// The glow's opacity through one period as keyframes: `NWPhase.glowOpacity` sampled at
    /// `count` even steps and back to the start, so a linear interpolation between them follows
    /// the cosine to well under a percent.
    static func glowKeyframes(count: Int = 64) -> (values: [Double], keyTimes: [Double]) {
        let times = (0...count).map { Double($0) / Double(count) }
        let period = NW.Motion.glow.duration
        return (times.map { glowOpacity(Date(timeIntervalSinceReferenceDate: $0 * period)) }, times)
    }
}

/// Live text's moving highlight: a `textTertiary` → `textPrimary` → `textTertiary` band that
/// Core Animation slides across the view (`NW.Motion.shimmer`). Masked by the text it lights.
struct NWLayerShimmer: View {
    @Environment(\.nwMotionPaused) private var motionPaused
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NWShimmerLayerRepresentable(base: .nw.textTertiary, highlight: .nw.textPrimary, animates: !motionPaused,
                                    colorScheme: colorScheme)
    }
}

extension NWPhase {
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
enum NWLayerMotion {
    static let spinKey = "nw.spin"
    static let glowKey = "nw.glow"
    static let shimmerKey = "nw.shimmer"

    /// The shimmer's band sliding once across its text per `NW.Motion.shimmer.duration`, linear,
    /// from where the clock's phase puts it now.
    static func shimmer(now: Date = Date()) -> CAAnimationGroup {
        let from = NWPhase.shimmerPoints(center: NWPhase.shimmerStart)
        let to = NWPhase.shimmerPoints(center: NWPhase.shimmerEnd)
        let start = CABasicAnimation(keyPath: "startPoint")
        start.fromValue = from.start
        start.toValue = to.start
        let end = CABasicAnimation(keyPath: "endPoint")
        end.fromValue = from.end
        end.toValue = to.end
        let group = CAAnimationGroup()
        group.animations = [start, end]
        group.duration = NW.Motion.shimmer.duration
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        group.timeOffset = NWPhase.fraction(now, .shimmer) * NW.Motion.shimmer.duration
        group.isRemovedOnCompletion = false
        return group
    }

    /// A band layer at rest: its stops and resting points, with no implicit animation.
    static func configure(_ band: CAGradientLayer) {
        band.actions = noActions.merging(["colors": NSNull(), "startPoint": NSNull(), "endPoint": NSNull()]) { $1 }
        band.type = .axial
        band.locations = [0, 0.5, 1]
        let rest = NWPhase.shimmerPoints(center: NWPhase.shimmerRest)
        band.startPoint = rest.start
        band.endPoint = rest.end
    }

    /// Layers that animate nothing implicitly: every change lands as the view model sets it.
    static let noActions: [String: CAAction] = [
        "path": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(), "lineWidth": NSNull(), "bounds": NSNull(),
        "position": NSNull(), "frame": NSNull(), "transform": NSNull(), "opacity": NSNull(), "hidden": NSNull(),
    ]

    /// One turn per `NW.Motion.spin.duration`, starting where the clock's phase is now.
    /// `clockwise` is the sign that turns the layer clockwise on screen: negative in AppKit's
    /// y-up layers, positive in UIKit's.
    static func spin(clockwise: Double, now: Date = Date()) -> CABasicAnimation {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = clockwise * 2 * Double.pi
        spin.duration = NW.Motion.spin.duration
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.timeOffset = NWPhase.fraction(now, .spin) * NW.Motion.spin.duration
        spin.isRemovedOnCompletion = false
        return spin
    }

    /// The glow's pulse, 1 → 0.35 → 1 over `NW.Motion.glow.duration`, in phase with the clock.
    static func glow(now: Date = Date()) -> CAKeyframeAnimation {
        let frames = NWPhase.glowKeyframes()
        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = frames.values
        glow.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
        glow.calculationMode = .linear
        glow.duration = NW.Motion.glow.duration
        glow.repeatCount = .infinity
        glow.timeOffset = NWPhase.fraction(now, .glow) * NW.Motion.glow.duration
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

/// Draws the spinner's arc in a shape layer that Core Animation turns. AppKit layers are y-up:
/// the arc runs clockwise on screen from three o'clock to twelve, as `Circle().trim(0, 0.75)`
/// does in SwiftUI, and turns clockwise.
final class NWSpinnerLayerView: NSView {
    let arc = CAShapeLayer()
    private var size: CGFloat = 0
    private var animates = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.actions = NWLayerMotion.noActions
        arc.fillColor = nil
        arc.lineCap = .round
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { nil }

    func update(size: CGFloat, color: CGColor, animates: Bool) {
        arc.strokeColor = color
        if size != self.size {
            self.size = size
            arc.lineWidth = NWPhase.spinnerLineWidth(size: size)
            needsLayout = true
        }
        self.animates = animates
        syncAnimation()
    }

    override func layout() {
        super.layout()
        arc.frame = bounds
        let inset = arc.lineWidth / 2
        let radius = max(0, min(bounds.width, bounds.height) / 2 - inset)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius, startAngle: 0,
                    endAngle: -1.5 * .pi, clockwise: true)
        arc.path = path
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncAnimation()
    }

    private func syncAnimation() {
        NWLayerMotion.sync(arc, key: NWLayerMotion.spinKey, animates: animates && window != nil) {
            NWLayerMotion.spin(clockwise: -1)
        }
    }
}

struct NWSpinnerLayerRepresentable: NSViewRepresentable {
    let size: CGFloat
    let color: Color
    let animates: Bool
    /// Read so that an appearance change updates the view, which resolves `color` again.
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> NWSpinnerLayerView { NWSpinnerLayerView() }

    func updateNSView(_ view: NWSpinnerLayerView, context: Context) {
        view.update(size: size, color: color.resolve(in: context.environment).cgColor, animates: animates)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NWSpinnerLayerView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

/// A filled circle whose opacity Core Animation pulses.
final class NWGlowLayerView: NSView {
    let dot = CAShapeLayer()
    private var animates = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dot.actions = NWLayerMotion.noActions
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
        NWLayerMotion.sync(dot, key: NWLayerMotion.glowKey, animates: animates && window != nil) { NWLayerMotion.glow() }
    }
}

struct NWGlowLayerRepresentable: NSViewRepresentable {
    let color: Color
    let animates: Bool
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> NWGlowLayerView { NWGlowLayerView() }

    func updateNSView(_ view: NWGlowLayerView, context: Context) {
        view.update(color: color.resolve(in: context.environment).cgColor, animates: animates)
    }
}


/// Live text's highlight band (`NWLayerShimmer`).
final class NWShimmerLayerView: NSView {
    let band = CAGradientLayer()
    private var animates = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        NWLayerMotion.configure(band)
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
        NWLayerMotion.sync(band, key: NWLayerMotion.shimmerKey, animates: animates && window != nil) { NWLayerMotion.shimmer() }
    }
}

struct NWShimmerLayerRepresentable: NSViewRepresentable {
    let base: Color
    let highlight: Color
    let animates: Bool
    /// Read so that an appearance change updates the view, which resolves the colors again.
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> NWShimmerLayerView { NWShimmerLayerView() }

    func updateNSView(_ view: NWShimmerLayerView, context: Context) {
        view.update(base: base.resolve(in: context.environment).cgColor, highlight: highlight.resolve(in: context.environment).cgColor,
                    animates: animates)
    }
}

#elseif canImport(UIKit)

/// UIKit layers are y-down: the same arc and turn with the opposite signs.
final class NWSpinnerLayerView: UIView {
    let arc = CAShapeLayer()
    private var size: CGFloat = 0
    private var animates = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        arc.actions = NWLayerMotion.noActions
        arc.fillColor = nil
        arc.lineCap = .round
        layer.addSublayer(arc)
    }

    required init?(coder: NSCoder) { nil }

    func update(size: CGFloat, color: CGColor, animates: Bool) {
        arc.strokeColor = color
        if size != self.size {
            self.size = size
            arc.lineWidth = NWPhase.spinnerLineWidth(size: size)
            setNeedsLayout()
        }
        self.animates = animates
        syncAnimation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        arc.frame = bounds
        let inset = arc.lineWidth / 2
        let radius = max(0, min(bounds.width, bounds.height) / 2 - inset)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius, startAngle: 0,
                    endAngle: 1.5 * .pi, clockwise: false)
        arc.path = path
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncAnimation()
    }

    private func syncAnimation() {
        NWLayerMotion.sync(arc, key: NWLayerMotion.spinKey, animates: animates && window != nil) {
            NWLayerMotion.spin(clockwise: 1)
        }
    }
}

struct NWSpinnerLayerRepresentable: UIViewRepresentable {
    let size: CGFloat
    let color: Color
    let animates: Bool
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> NWSpinnerLayerView { NWSpinnerLayerView() }

    func updateUIView(_ view: NWSpinnerLayerView, context: Context) {
        view.update(size: size, color: color.resolve(in: context.environment).cgColor, animates: animates)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NWSpinnerLayerView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class NWGlowLayerView: UIView {
    let dot = CAShapeLayer()
    private var animates = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        dot.actions = NWLayerMotion.noActions
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
        NWLayerMotion.sync(dot, key: NWLayerMotion.glowKey, animates: animates && window != nil) { NWLayerMotion.glow() }
    }
}

struct NWGlowLayerRepresentable: UIViewRepresentable {
    let color: Color
    let animates: Bool
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> NWGlowLayerView { NWGlowLayerView() }

    func updateUIView(_ view: NWGlowLayerView, context: Context) {
        view.update(color: color.resolve(in: context.environment).cgColor, animates: animates)
    }
}

/// Live text's highlight band (`NWLayerShimmer`).
final class NWShimmerLayerView: UIView {
    let band = CAGradientLayer()
    private var animates = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        NWLayerMotion.configure(band)
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
        NWLayerMotion.sync(band, key: NWLayerMotion.shimmerKey, animates: animates && window != nil) { NWLayerMotion.shimmer() }
    }
}

struct NWShimmerLayerRepresentable: UIViewRepresentable {
    let base: Color
    let highlight: Color
    let animates: Bool
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> NWShimmerLayerView { NWShimmerLayerView() }

    func updateUIView(_ view: NWShimmerLayerView, context: Context) {
        view.update(base: base.resolve(in: context.environment).cgColor, highlight: highlight.resolve(in: context.environment).cgColor,
                    animates: animates)
    }
}

#endif
