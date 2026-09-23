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

    /// A 1px (hairline) border inside the view's bounds.
    public func nwBorder(_ color: Color, radius: CGFloat = 0) -> some View {
        modifier(NWBorderModifier(color: color, radius: radius))
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

private struct NWBorderModifier: ViewModifier {
    let color: Color
    let radius: CGFloat
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: radius).strokeBorder(color, lineWidth: NW.hairline(displayScale))
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

private struct NWPopoverModifier: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: radius))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .nwBorder(.nw.lineStrong, radius: radius)
            .shadow(color: .nw.popoverShadow, radius: 16, y: 12)
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
