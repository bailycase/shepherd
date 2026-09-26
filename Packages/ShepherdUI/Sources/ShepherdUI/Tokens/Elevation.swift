import SwiftUI

extension View {
    /// Flat card (panes, cards, the composer, tool groups): raised fill and a 1px line. Night
    /// Watch separates with lines, never shadows.
    public func nwCard(radius: CGFloat = NW.Radius.m, fill: Color? = nil, line: Color? = nil) -> some View {
        modifier(NWCardModifier(radius: radius, fill: fill, line: line))
    }

    /// Floating surface (menus, the palette, popovers, tooltips, toasts): raised fill, a 1px
    /// strong line, and the system's only shadow.
    public func nwPopover(radius: CGFloat = NW.Radius.l) -> some View {
        modifier(NWPopoverModifier(radius: radius))
    }

    /// The popover's shadow, borrowed by a pane while it floats over the window (the overlaid
    /// sidebar and right pane); none while `floating` is false.
    public func nwFloatShadow(_ floating: Bool = true) -> some View {
        shadow(color: floating ? .nw.popoverShadow : .clear, radius: NWPopoverModifier.shadowRadius)
    }

    /// An opaque pane's fill (a color, or one that reaches under the safe area), casting the
    /// popover's shadow while `floating`. Cast by the fill rather than the content: Core
    /// Animation redraws a content shadow from every layer inside as it changes, a scrolling
    /// list each frame, and a clear one still shadows them all.
    public func nwFloatBackground(_ fill: some View, floating: Bool = true) -> some View {
        background {
            if floating {
                fill.shadow(color: .nw.popoverShadow, radius: NWPopoverModifier.shadowRadius)
            } else {
                fill
            }
        }
    }

    /// A pinned header's fill (a Changes file header at the top of its list): while `pinned` it
    /// casts a short shadow down onto the rows scrolling under it (ChangesSplit: 0 6 12 −8 black
    /// at 60%). Cast by the fill, never the content, and clipped by the list at its top and sides.
    public func nwPinnedBackground(_ fill: Color, pinned: Bool) -> some View {
        background {
            fill.shadow(color: pinned ? .nw.popoverShadow : .clear, radius: NWPinnedShadow.radius, y: NWPinnedShadow.offset)
        }
    }

    /// The keyboard focus ring for custom controls: running blue, 2pt wide, 2pt outside the
    /// control. Shown only while the control has keyboard focus (`isFocused`), never on click.
    /// Native controls keep the system's ring.
    public func nwFocusRing(radius: CGFloat = NW.Radius.s) -> some View {
        modifier(NWFocusRingModifier(shape: RoundedRectangle(cornerRadius: radius)))
    }

    /// The focus ring around a circular control.
    public func nwFocusRingCircle() -> some View {
        modifier(NWFocusRingModifier(shape: Circle()))
    }

    /// The same ring, shown while `visible`: for a field or card whose focus the caller tracks
    /// (a focused text field, the composer while typing, the inspected card).
    public func nwFocusRing(_ visible: Bool, radius: CGFloat = NW.Radius.s) -> some View {
        overlay {
            if visible {
                RoundedRectangle(cornerRadius: radius).inset(by: -4)
                    .strokeBorder(Color.nw.focusRing, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// A 1px (hairline) border inside the view's bounds. Every control, card, and pane border
    /// draws through this or `nwBorder(_:in:dash:)`, never a 1pt stroke.
    public func nwBorder(_ color: Color, radius: CGFloat = 0) -> some View {
        nwBorder(color, in: RoundedRectangle(cornerRadius: radius))
    }

    /// A 1px (hairline) border along `shape` (a capsule, a circle) inside the view's bounds;
    /// `dash` draws it dashed (a queued bubble, a framed empty state).
    public func nwBorder<S: InsettableShape>(_ color: Color, in shape: S, dash: [CGFloat] = []) -> some View {
        modifier(NWBorderModifier(color: color, shape: shape, dash: dash))
    }
}

/// A 1px rule; `lineSubtle` unless given a color.
public struct NWHairline: View {
    public enum Axis: Sendable { case horizontal, vertical }
    let axis: Axis
    let color: Color?
    @Environment(\.displayScale) private var displayScale

    public init(_ axis: Axis = .horizontal, color: Color? = nil) {
        self.axis = axis
        self.color = color
    }

    public var body: some View {
        let width = NW.hairline(displayScale)
        Rectangle()
            .fill(color ?? .nw.lineSubtle)
            .frame(width: axis == .vertical ? width : nil, height: axis == .horizontal ? width : nil)
            .accessibilityHidden(true)
    }
}

private struct NWBorderModifier<S: InsettableShape>: ViewModifier {
    let color: Color
    let shape: S
    let dash: [CGFloat]
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.overlay {
            shape.strokeBorder(color, style: StrokeStyle(lineWidth: NW.hairline(displayScale), dash: dash))
        }
    }
}

private struct NWCardModifier: ViewModifier {
    let radius: CGFloat
    let fill: Color?
    let line: Color?

    func body(content: Content) -> some View {
        content
            .background(fill ?? .nw.bgRaised, in: RoundedRectangle(cornerRadius: radius))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .nwBorder(line ?? .nw.lineSubtle, radius: radius)
    }
}

/// The pinned header's shadow: short and close, so it reads as an edge rather than a lift.
enum NWPinnedShadow {
    static let radius: CGFloat = 6
    static let offset: CGFloat = 6
}

private struct NWPopoverModifier: ViewModifier {
    static let shadowRadius: CGFloat = 16
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: radius))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .nwBorder(.nw.lineStrong, radius: radius)
            .shadow(color: .nw.popoverShadow, radius: Self.shadowRadius, y: 12)
    }
}

private struct NWFocusRingModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .focusEffectDisabled()
            .overlay {
                if isFocused {
                    shape.inset(by: -4).strokeBorder(Color.nw.focusRing, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }
}
