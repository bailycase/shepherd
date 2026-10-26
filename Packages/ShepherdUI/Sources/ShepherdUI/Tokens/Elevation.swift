import SwiftUI

extension View {
    /// Flat card (panes, cards, the composer, tool groups): raised fill and a 1px line. Night
    /// Watch separates with lines, never shadows.
    public func shCard(radius: CGFloat = SH.Radius.m, fill: Color? = nil, line: Color? = nil) -> some View {
        modifier(SHCardModifier(radius: radius, fill: fill, line: line))
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

    func body(content: Content) -> some View {
        content
            .background(fill ?? .sh.bgRaised, in: RoundedRectangle(cornerRadius: radius))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shBorder(line ?? .sh.lineSubtle, radius: radius)
    }
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
        content
            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: radius))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shBorder(line ?? .sh.lineStrong, radius: radius)
            .shadow(color: .sh.popoverShadow, radius: Self.shadowRadius, y: 12)
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
