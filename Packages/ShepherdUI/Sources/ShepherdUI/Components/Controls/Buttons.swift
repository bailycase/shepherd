import SwiftUI

/// Night Watch buttons on a native `Button` (Controls board): `.buttonStyle(.nw(.primary))`.
/// Hover and pressed come from the style; the focus ring shows for keyboard focus only;
/// disabled is 40% opacity. Primary appears at most once per view, and a destructive action is
/// never the ⏎ default.
public struct NWButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        /// Lantern fill: the view's one main action.
        case primary
        /// Raised, bordered: everything else.
        case secondary
        /// Borderless: Cancel, low-emphasis actions.
        case ghost
        /// Bordered with failed text: Stop, Revert.
        case danger
        /// Failed fill: a confirmed destructive action (Delete).
        case dangerFill
    }

    /// s 24 · m 28 · l 32.
    public enum Size: Sendable { case s, m, l }

    let kind: Kind
    let size: Size
    let tint: Color?

    /// `tint` recolors a secondary or ghost label (the review's Commit in `done`).
    public init(_ kind: Kind = .secondary, size: Size = .m, tint: Color? = nil) {
        self.kind = kind
        self.size = size
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        NWStyledButton(configuration: configuration, kind: kind, size: size, tint: tint)
    }
}

extension ButtonStyle where Self == NWButtonStyle {
    /// `.buttonStyle(.nw(.primary, size: .m))`.
    public static func nw(_ kind: NWButtonStyle.Kind = .secondary, size: NWButtonStyle.Size = .m, tint: Color? = nil) -> NWButtonStyle {
        NWButtonStyle(kind, size: size, tint: tint)
    }
}

private struct NWStyledButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: NWButtonStyle.Kind
    let size: NWButtonStyle.Size
    let tint: Color?
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let nw = Color.nw
        let (height, padding, fontSize): (CGFloat, CGFloat, CGFloat) = switch size {
        case .s: (NW.Height.controlS, NW.Space.m, 12)
        case .m: (NW.Height.controlM, 10, 12.5)
        case .l: (NW.Height.controlL, 14, 13)
        }
        let filled = kind == .primary || kind == .dangerFill
        let shape = RoundedRectangle(cornerRadius: NW.Radius.s)
        configuration.label
            .font(.nwSans(fontSize, filled ? .semibold : .medium))
            .labelStyle(NWButtonLabelStyle())
            .lineLimit(1)
            .foregroundStyle(foreground(nw))
            .padding(.horizontal, padding)
            .frame(minHeight: height)
            .background(background(nw), in: shape)
            .nwBorder(kind == .secondary || kind == .danger ? nw.lineStrong : .clear, radius: NW.Radius.s)
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .nwEnabledOpacity(enabled)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .nwAnimation(.hover, value: hovering)
            .nwFocusRing(radius: NW.Radius.s)
    }

    private var active: Bool { enabled && (hovering || configuration.isPressed) }

    private func foreground(_ nw: NWPalette) -> Color {
        switch kind {
        case .primary: nw.textOnLantern
        case .secondary: tint ?? nw.textPrimary
        case .ghost: tint ?? (hovering && enabled && !configuration.isPressed ? nw.textPrimary : nw.textSecondary)
        case .danger: nw.failed
        case .dangerFill: nw.textOnFailed
        }
    }

    private func background(_ nw: NWPalette) -> AnyShapeStyle {
        switch kind {
        case .primary, .dangerFill:
            let fill = kind == .primary ? nw.lantern : nw.failed
            // Hover lifts the fill, pressed sinks it (the board's #f7b84f / #d9922a steps).
            return AnyShapeStyle(fill.mix(with: configuration.isPressed ? .black : .white,
                                          by: enabled ? (configuration.isPressed ? 0.1 : hovering ? 0.12 : 0) : 0))
        case .secondary:
            return AnyShapeStyle(active ? nw.bgSelected : nw.bgRaised)
        case .ghost:
            return AnyShapeStyle(enabled && configuration.isPressed ? nw.bgSelected : hovering && enabled ? nw.bgHover : Color.clear)
        case .danger:
            return AnyShapeStyle(enabled && configuration.isPressed ? nw.bgSelected : hovering && enabled ? nw.failedTint : nw.bgRaised)
        }
    }
}

/// Icon and title 6pt apart, the icon one step smaller than the title.
private struct NWButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: NW.Space.s) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// An icon-only button (Controls board): always a circle, 28pt (44 on iOS). Default, hover
/// (`bgHover`), on (lantern tint, for a pane toggle while its pane is open), bordered, focus,
/// disabled. Always give it an accessibility label.
public struct NWIconButtonStyle: ButtonStyle {
    let bordered: Bool
    let isOn: Bool
    let size: CGFloat
    let tint: Color?

    public init(bordered: Bool = false, isOn: Bool = false, size: CGFloat = NW.Height.controlM, tint: Color? = nil) {
        self.bordered = bordered
        self.isOn = isOn
        self.size = size
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        NWIconButton(configuration: configuration, style: self)
    }
}

extension ButtonStyle where Self == NWIconButtonStyle {
    /// `.buttonStyle(.nwIcon)`.
    public static var nwIcon: NWIconButtonStyle { NWIconButtonStyle() }

    public static func nwIcon(bordered: Bool = false, isOn: Bool = false, size: CGFloat = NW.Height.controlM, tint: Color? = nil) -> NWIconButtonStyle {
        NWIconButtonStyle(bordered: bordered, isOn: isOn, size: size, tint: tint)
    }
}

private struct NWIconButton: View {
    let configuration: ButtonStyleConfiguration
    let style: NWIconButtonStyle
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let nw = Color.nw
        #if os(iOS)
        let side = max(style.size, NW.Height.touch)
        #else
        let side = style.size
        #endif
        let active = enabled && (hovering || configuration.isPressed)
        let foreground: Color = style.tint ?? (style.isOn ? nw.lanternText : active ? nw.textPrimary : nw.textSecondary)
        let fill: Color = style.isOn ? nw.lanternTint : configuration.isPressed && enabled ? nw.bgSelected : active ? nw.bgHover : .clear
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(foreground)
            .frame(width: side, height: side)
            .background(fill, in: Circle())
            .nwBorder(style.bordered ? nw.lineStrong : .clear, in: Circle())
            .nwEnabledOpacity(enabled)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .nwAnimation(.hover, value: hovering)
            .nwFocusRingCircle()
    }
}

/// Inline text that acts as a link ("Show all", "review ›", "Reset"): running blue unless given
/// a color.
public struct NWLinkButtonStyle: ButtonStyle {
    let color: Color?
    let font: Font?

    public init(color: Color? = nil, font: Font? = nil) {
        self.color = color
        self.font = font
    }

    public func makeBody(configuration: Configuration) -> some View {
        NWLinkButton(configuration: configuration, color: color, font: font)
    }
}

extension ButtonStyle where Self == NWLinkButtonStyle {
    /// `.buttonStyle(.nwLink)`.
    public static var nwLink: NWLinkButtonStyle { NWLinkButtonStyle() }

    public static func nwLink(color: Color? = nil, font: Font? = nil) -> NWLinkButtonStyle {
        NWLinkButtonStyle(color: color, font: font)
    }
}

private struct NWLinkButton: View {
    let configuration: ButtonStyleConfiguration
    let color: Color?
    let font: Font?
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(font ?? .nw(.caption))
            .foregroundStyle(color ?? .nw.running)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .nwEnabledOpacity(enabled)
            .contentShape(Rectangle())
            .nwFocusRing(radius: NW.Radius.xs)
    }
}

/// A hover-tracking row button (sidebar rows, palette rows, menu rows).
public struct NWRowButtonStyle: ButtonStyle {
    let selected: Bool
    let radius: CGFloat
    let selectedFill: Color?
    let hoverFill: Color?

    public init(selected: Bool = false, radius: CGFloat = NW.Radius.s, selectedFill: Color? = nil, hoverFill: Color? = nil) {
        self.selected = selected
        self.radius = radius
        self.selectedFill = selectedFill
        self.hoverFill = hoverFill
    }

    public func makeBody(configuration: Configuration) -> some View {
        NWRowButton(configuration: configuration, style: self)
    }
}

extension ButtonStyle where Self == NWRowButtonStyle {
    public static func nwRow(selected: Bool = false, radius: CGFloat = NW.Radius.s, selectedFill: Color? = nil, hoverFill: Color? = nil) -> NWRowButtonStyle {
        NWRowButtonStyle(selected: selected, radius: radius, selectedFill: selectedFill, hoverFill: hoverFill)
    }
}

private struct NWRowButton: View {
    let configuration: ButtonStyleConfiguration
    let style: NWRowButtonStyle
    @State private var hovering = false

    var body: some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: style.radius))
            .nwRowBackground(selected: style.selected, hovering: hovering, radius: style.radius,
                             selectedFill: style.selectedFill, hoverFill: style.hoverFill)
            .onHover { hovering = $0 }
            .nwFocusRing(radius: style.radius)
    }
}

extension View {
    /// Row chrome: `bgSelected` when selected, `bgHover` while hovered.
    public func nwRowBackground(selected: Bool, hovering: Bool, radius: CGFloat = NW.Radius.s,
                                selectedFill: Color? = nil, hoverFill: Color? = nil) -> some View {
        background(
            selected ? (selectedFill ?? .nw.bgSelected) : hovering ? (hoverFill ?? .nw.bgHover) : Color.clear,
            in: RoundedRectangle(cornerRadius: radius)
        )
    }
}
