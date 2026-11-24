import SwiftUI

extension View {
    /// Card (panes, cards, the composer, tool groups): raised fill and a 1px line, sitting on the
    /// soft `lift` shadow when `lift` is set (the composer, the edits card, the side pane card).
    public func shCard(radius: CGFloat = SH.Radius.xl, fill: Color? = nil, line: Color? = nil, lift: Bool = false) -> some View {
        modifier(SHCardModifier(radius: radius, fill: fill, line: line, lift: lift))
    }

    /// The boards' `lift`: a close 1pt shadow and a soft 20pt one under a card's fill. Cast by the
    /// fill shape, never the content, so a scrolling card does not redraw it per layer.
    public func shLift<S: Shape>(_ shape: S, fill: Color? = nil) -> some View {
        // Each shadow cast by a fill of its own: stacked on one fill, the outer shadow is cast from a layer with a child,
        // which Core Animation redraws from its whole subtree.
        background {
            ZStack {
                shape.fill(fill ?? .sh.bgRaised).shadow(color: .sh.liftFar, radius: SHLift.farRadius, y: SHLift.farOffset)
                shape.fill(fill ?? .sh.bgRaised).shadow(color: .sh.liftNear, radius: SHLift.nearRadius, y: SHLift.nearOffset)
            }
        }
    }

    /// Floating surface (menus, the palette, popovers, tooltips, toasts): raised fill, a 1px
    /// strong line, and the system's only shadow.
    public func shPopover(radius: CGFloat = SH.Radius.l, line: Color? = nil) -> some View {
        modifier(SHPopoverModifier(radius: radius, line: line))
    }

    /// The popover's shadow, borrowed by a pane while it floats over the window (the overlaid
    /// sidebar and right pane); none while `floating` is false.
    public func shFloatShadow(_ floating: Bool = true) -> some View {
        shadow(color: floating ? .sh.popoverShadow : .clear, radius: SHPopoverModifier.shadowRadius)
    }

    /// A card's popover shadow while it floats over the window (the thread's side pane overlaid), cast by a fill of the card's
    /// shape beneath it, never by its content; none while `floating` is false.
    public func shFloatCardShadow<S: Shape>(_ shape: S, floating: Bool) -> some View {
        background {
            if floating {
                shape.fill(Color.sh.bgRaised).shadow(color: .sh.popoverShadow, radius: SHPopoverModifier.shadowRadius)
            }
        }
    }

    /// An opaque pane's fill (a color, or one that reaches under the safe area), casting the
    /// popover's shadow while `floating`. Cast by the fill rather than the content: Core
    /// Animation redraws a content shadow from every layer inside as it changes, a scrolling
    /// list each frame, and a clear one still shadows them all.
    public func shFloatBackground(_ fill: some View, floating: Bool = true) -> some View {
        background {
            if floating {
                fill.shadow(color: .sh.popoverShadow, radius: SHPopoverModifier.shadowRadius)
            } else {
                fill
            }
        }
    }

    /// A pinned header's fill (a Changes file header at the top of its list): while `pinned` it
    /// casts a short shadow down onto the rows scrolling under it (ChangesSplit: 0 6 12 −8 black
    /// at 60%). Cast by the fill, never the content, and clipped by the list at its top and sides.
    public func shPinnedBackground(_ fill: Color, pinned: Bool) -> some View {
        background {
            fill.shadow(color: pinned ? .sh.popoverShadow : .clear, radius: SHPinnedShadow.radius, y: SHPinnedShadow.offset)
        }
    }

    /// The keyboard focus ring for custom controls: running blue, 2pt wide, 2pt outside the
    /// control. Shown only while the control has keyboard focus (`isFocused`), never on click.
    /// Native controls keep the system's ring.
    public func shFocusRing(radius: CGFloat = SH.Radius.s, color: Color? = nil) -> some View {
        modifier(SHFocusRingModifier(shape: RoundedRectangle(cornerRadius: radius), color: color))
    }

    /// The focus ring around a circular control.
    public func shFocusRingCircle() -> some View {
        modifier(SHFocusRingModifier(shape: Circle(), color: nil))
    }

    /// The same ring, shown while `visible`: for a field or card whose focus the caller tracks
    /// (a focused text field, the composer while typing, the inspected card).
    public func shFocusRing(_ visible: Bool, radius: CGFloat = SH.Radius.s, color: Color? = nil) -> some View {
        overlay {
            if visible {
                RoundedRectangle(cornerRadius: radius).inset(by: -4)
                    .strokeBorder(color ?? Color.sh.focusRing, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// A 1px (hairline) border inside the view's bounds. Every control, card, and pane border
    /// draws through this or `shBorder(_:in:dash:)`. `width` pins a board's CSS-point stroke
    /// instead of the default device-pixel hairline.
    public func shBorder(_ color: Color, radius: CGFloat = 0, width: CGFloat? = nil) -> some View {
        shBorder(color, in: RoundedRectangle(cornerRadius: radius), width: width)
    }

    /// A 1px (hairline) border along `shape` (a capsule, a circle) inside the view's bounds;
    /// `dash` draws it dashed (a queued bubble, a framed empty state).
    public func shBorder<S: InsettableShape>(_ color: Color, in shape: S, dash: [CGFloat] = [], width: CGFloat? = nil) -> some View {
        modifier(SHBorderModifier(color: color, shape: shape, dash: dash, width: width))
    }
}

/// A 1px rule; `lineSubtle` unless given a color.
public struct SHHairline: View {
    public enum Axis: Sendable { case horizontal, vertical }
    let axis: Axis
    let color: Color?
    let fixedWidth: CGFloat?
    @Environment(\.displayScale) private var displayScale

    public init(_ axis: Axis = .horizontal, color: Color? = nil, width: CGFloat? = nil) {
        self.axis = axis
        self.color = color
        self.fixedWidth = width
    }

    public var body: some View {
        let width = fixedWidth ?? SH.hairline(displayScale)
        Rectangle()
            .fill(color ?? .sh.lineSubtle)
            .frame(width: axis == .vertical ? width : nil, height: axis == .horizontal ? width : nil)
            .accessibilityHidden(true)
    }
}

private struct SHBorderModifier<S: InsettableShape>: ViewModifier {
    let color: Color
    let shape: S
    let dash: [CGFloat]
    let width: CGFloat?
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.overlay {
            shape.strokeBorder(color, style: StrokeStyle(lineWidth: width ?? SH.hairline(displayScale), dash: dash))
        }
    }
}

private struct SHCardModifier: ViewModifier {
    let radius: CGFloat
    let fill: Color?
    let line: Color?
    let lift: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        if lift {
            content
                .clipShape(shape)
                .shLift(shape, fill: fill)
                .shBorder(line ?? .sh.lineSubtle, radius: radius)
        } else {
            content
                .background(fill ?? .sh.bgRaised, in: shape)
                .clipShape(shape)
                .shBorder(line ?? .sh.lineSubtle, radius: radius)
        }
    }
}

/// The boards' `lift` (0 1 2, 0 6 20) in SwiftUI radii, which are half a CSS blur.
enum SHLift {
    static let nearRadius: CGFloat = 1
    static let nearOffset: CGFloat = 1
    static let farRadius: CGFloat = 10
    static let farOffset: CGFloat = 6
}

/// The pinned header's shadow: short and close, so it reads as an edge rather than a lift.
enum SHPinnedShadow {
    static let radius: CGFloat = 6
    static let offset: CGFloat = 6
}

private struct SHPopoverModifier: ViewModifier {
    static let shadowRadius: CGFloat = 16
    let radius: CGFloat
    let line: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        // The shadow is cast by the fill, not the content: a content shadow redraws from every
        // layer inside it as the menu's rows change.
        content
            .clipShape(shape)
            .background {
                shape.fill(Color.sh.bgRaised).shadow(color: .sh.popoverShadow, radius: Self.shadowRadius, y: 12)
            }
            .shBorder(line ?? .sh.lineStrong, radius: radius)
    }
}

private struct SHFocusRingModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let color: Color?
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .focusEffectDisabled()
            .overlay {
                if isFocused {
                    shape.inset(by: -4).strokeBorder(color ?? Color.sh.focusRing, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }
}
