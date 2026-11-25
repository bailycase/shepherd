import SwiftUI

/// One shadow cast by a `SHShadowFill`, in SwiftUI's terms (`View.shadow`): the same radius and offsets draw the same blur.
struct SHShadowSpec {
    let color: Color
    let radius: CGFloat
    var x: CGFloat = 0
    var y: CGFloat = 0
}

#if os(macOS)
import AppKit

/// A fill of `shape` casting `shadows`, each drawn by Core Animation from a `shadowPath` set at layout.
///
/// SwiftUI's `.shadow` on a shape sets no path, so Core Animation draws the shadow offscreen from the layer's alpha and draws it
/// again whenever the layer's size changes: a card, a composer or a terminal panel whose size follows a drag drew two offscreen
/// shadows a frame. With a path the shadow is cast from the path itself, and the size changing costs only the path.
/// Cast by a fill of its own (never by the content), as `View.shLift` and the floating pane's shadow have always been.
struct SHShadowFill<S: Shape>: NSViewRepresentable {
    let shape: S
    let fill: Color
    let shadows: [SHShadowSpec]

    func makeNSView(context: Context) -> SHShadowFillView { SHShadowFillView() }

    func updateNSView(_ view: SHShadowFillView, context: Context) {
        let environment = context.environment
        view.update(path: { rect in shape.path(in: rect).cgPath },
                    fill: fill.resolve(in: environment).cgColor,
                    shadows: shadows.map { shadow in
                        SHShadowFillView.Shadow(color: shadow.color.resolve(in: environment).cgColor, radius: shadow.radius,
                                                offset: CGSize(width: shadow.x, height: shadow.y))
                    })
    }
}

/// The backing view: a layer of the fill's shape for each shadow (they stack as one fill under the card's content), its
/// `path` and `shadowPath` the shape in the view's bounds. It takes no clicks and says nothing to accessibility.
final class SHShadowFillView: NSView {
    struct Shadow {
        let color: CGColor
        let radius: CGFloat
        /// Down is positive, as in SwiftUI.
        let offset: CGSize
    }

    private var path: (CGRect) -> CGPath = { CGPath(rect: $0, transform: nil) }
    private var fill: CGColor = .clear
    private var shadows: [Shadow] = []
    private var layers: [CAShapeLayer] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func update(path: @escaping (CGRect) -> CGPath, fill: CGColor, shadows: [Shadow]) {
        self.path = path
        self.fill = fill
        self.shadows = shadows
        // Applied now, so a change of color or of shadow lands in the same pass as the state that asked for it.
        apply()
    }

    override func layout() {
        super.layout()
        apply()
    }

    private func apply() {
        guard let host = layer else { return }
        // Nothing here animates: a card resizes and recolors at once, as the SwiftUI fill it replaces did.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let count = max(shadows.count, 1)
        while layers.count < count {
            let sublayer = CAShapeLayer()
            sublayer.shadowOpacity = 1
            host.addSublayer(sublayer)
            layers.append(sublayer)
        }
        while layers.count > count { layers.removeLast().removeFromSuperlayer() }
        let outline = path(bounds)
        for (index, sublayer) in layers.enumerated() {
            sublayer.frame = bounds
            sublayer.path = outline
            sublayer.fillColor = fill
            sublayer.shadowPath = outline
            guard index < shadows.count else {
                sublayer.shadowColor = nil
                sublayer.isHidden = false
                continue
            }
            let shadow = shadows[index]
            sublayer.shadowColor = shadow.color
            sublayer.shadowRadius = shadow.radius
            // The view is flipped, so Core Animation's offset reads down as positive too.
            sublayer.shadowOffset = CGSize(width: shadow.offset.width, height: shadow.offset.height)
            // A shadow with no ink (the lift's far shadow in the dark appearance) draws nothing, as it did, and costs nothing: the
            // first layer keeps the fill the others repeat.
            sublayer.isHidden = shadow.color.alpha == 0 && index > 0
        }
    }
}
#endif
