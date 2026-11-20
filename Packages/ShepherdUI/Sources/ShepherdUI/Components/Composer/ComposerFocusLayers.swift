#if canImport(AppKit)
import AppKit
import QuartzCore
import SwiftUI

// The composer card's focus line and ring are layers that Core Animation fades, not a SwiftUI
// animation: a SwiftUI animation runs on the main thread and lays the visible layout out again
// on every frame it lasts, which on a switch between threads was a third more CPU than the
// switch itself. A layer's opacity or border colour animates on the render server instead; the
// app does its work once, when focus changes.

extension Transaction {
    /// Set on a change of focus made as a layout comes on screen. The transaction lands everything
    /// else at once (`disablesAnimations`), as a hidden layout's does; the composer card's line and
    /// ring (`SHComposer`) still fade in over the hover motion's duration.
    @Entry public var shFocusFades: Bool = false
}

extension SHLayerMotion {
    static let focusKey = "sh.focus"

    /// A change of focus's fade: from what is on screen now to `to`, over the hover motion's
    /// duration on an ease-out, never a spring.
    static func focusFade(_ keyPath: String, from: Any?, to: Any) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: keyPath)
        fade.fromValue = from
        fade.toValue = to
        fade.duration = SH.Motion.hover.duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return fade
    }
}

/// One part of the focused composer card, drawn by a layer: the 1pt line (`lineStrong`, or
/// `textTertiary` while focused) along the card's edge, or the `bgSelected` ring (`SHComposer`)
/// around it. Both take a change of focus at once, or fade over `SH.Motion.hover.duration`.
final class SHComposerFocusView: NSView {
    enum Part { case line, ring }

    let part: Part
    /// The line's border, or the ring's fill.
    let drawn = CALayer()
    private var focused: Bool?
    /// The fade the last change of focus started; nil when it landed at once.
    private(set) var fade: CABasicAnimation?

    init(part: Part) {
        self.part = part
        super.init(frame: .zero)
        wantsLayer = true
        drawn.actions = SHLayerMotion.noActions.merging(
            ["borderColor": NSNull(), "borderWidth": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull()]) { $1 }
        layer?.addSublayer(drawn)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `color` is the line while focused or the ring's fill; `rest` is the line while not.
    /// `fades` lets a change of focus take its fade; otherwise, or in a view no window shows, it lands at once.
    func update(focused: Bool, color: CGColor, rest: CGColor, hairline: CGFloat, fades: Bool) {
        let changed = self.focused.map { $0 != focused } ?? false
        self.focused = focused
        let animates = changed && fades && window != nil
        switch part {
        case .line:
            drawn.borderWidth = hairline
            let to = focused ? color : rest
            let from = drawn.presentation()?.borderColor ?? drawn.borderColor
            drawn.borderColor = to
            settle(animates ? SHLayerMotion.focusFade("borderColor", from: from, to: to) : nil, changed: changed)
        case .ring:
            drawn.backgroundColor = color
            let to: Float = focused ? 1 : 0
            let from = drawn.presentation()?.opacity ?? drawn.opacity
            drawn.opacity = to
            settle(animates ? SHLayerMotion.focusFade("opacity", from: from, to: to) : nil, changed: changed)
        }
    }

    /// Starts `fade`, or lets go of the one running when the change it was for lands at once.
    private func settle(_ fade: CABasicAnimation?, changed: Bool) {
        guard changed else { return }
        self.fade = fade
        if let fade {
            drawn.add(fade, forKey: SHLayerMotion.focusKey)
        } else {
            drawn.removeAnimation(forKey: SHLayerMotion.focusKey)
        }
    }

    override func layout() {
        super.layout()
        drawn.frame = bounds
        drawn.cornerRadius = part == .line ? SH.Radius.m : SH.Radius.m + SHComposerMetrics.focusRing
    }
}

struct SHComposerFocusLayer: NSViewRepresentable {
    let part: SHComposerFocusView.Part
    let focused: Bool
    /// Read so that an appearance change updates the view, which resolves its colours again.
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> SHComposerFocusView { SHComposerFocusView(part: part) }

    func updateNSView(_ view: SHComposerFocusView, context: Context) {
        let sh = Color.sh
        let (on, rest) = part == .line ? (sh.textTertiary, sh.lineStrong) : (sh.bgSelected, sh.bgSelected)
        let transaction = context.transaction
        // A focus taken as a layout comes on screen fades although the transaction lands everything else
        // at once; a hidden layout's, or Reduce Motion's, lands at once.
        let fades = !context.environment.accessibilityReduceMotion && (transaction.shFocusFades || !transaction.disablesAnimations)
        view.update(focused: focused, color: on.resolve(in: context.environment).cgColor,
                    rest: rest.resolve(in: context.environment).cgColor,
                    hairline: SH.hairline(context.environment.displayScale), fades: fades)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SHComposerFocusView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}
#endif
