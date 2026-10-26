import SwiftUI

/// Shepherd Design buttons on a native `Button` (Controls board): `.buttonStyle(.sh(.primary))`.
/// Hover and pressed come from the style; the focus ring shows for keyboard focus only;
/// disabled is 40% opacity. Primary appears at most once per view, and a destructive action is
/// never the ⏎ default.
public struct SHButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        /// Lantern fill: the view's one main action.
        case primary
        /// Raised, bordered: everything else.
        case secondary
        /// A bordered button on the raised fill, including SettingsProjects' Add project.
        case raised
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
        SHStyledButton(configuration: configuration, kind: kind, size: size, tint: tint)
    }
}

extension ButtonStyle where Self == SHButtonStyle {
    /// `.buttonStyle(.sh(.primary, size: .m))`.
    public static func sh(_ kind: SHButtonStyle.Kind = .secondary, size: SHButtonStyle.Size = .m, tint: Color? = nil) -> SHButtonStyle {
        SHButtonStyle(kind, size: size, tint: tint)
    }
}

private struct SHStyledButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: SHButtonStyle.Kind
    let size: SHButtonStyle.Size
    let tint: Color?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.shControlScale) private var scale
    @State private var hovering = false

    var body: some View {
        let sh = Color.sh
        let settings = scale == .settings
        let M = SHSettingsControlMetrics.self
        // A Settings page draws every size as its boards' one button: 32pt at radius 7, Geist 13.
        let standard: (CGFloat, CGFloat, CGFloat) = switch size {
        case .s: (SH.Height.controlS, SH.Space.m, 12)
        case .m: (SH.Height.controlM, 10, 12.5)
        case .l: (SH.Height.controlL, 14, 13)
        }
        let (height, padding, fontSize) = settings ? (M.controlHeight, M.buttonPadding, M.textSize) : standard
        let radius = settings ? M.radius : SH.Radius.s
        let filled = kind == .primary || kind == .dangerFill
        let shape = RoundedRectangle(cornerRadius: radius)
        configuration.label
            .font(.shSans(fontSize, filled ? .semibold : .medium))
            .labelStyle(SHButtonLabelStyle())
            .lineLimit(1)
            .foregroundStyle(foreground(sh))
            .padding(.horizontal, padding)
            .frame(minHeight: height)
            .background(background(sh), in: shape)
            .shBorder(kind == .secondary || kind == .raised || kind == .danger ? sh.lineStrong : .clear, radius: radius)
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .shEnabledOpacity(enabled)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
            .shFocusRing(radius: radius)
            .shTouchTarget(height: height)
    }

    private var active: Bool { enabled && (hovering || configuration.isPressed) }

    private func foreground(_ sh: SHPalette) -> Color {
        switch kind {
        case .primary: sh.textOnLantern
        case .secondary, .raised: tint ?? sh.textPrimary
        case .ghost: tint ?? (hovering && enabled && !configuration.isPressed ? sh.textPrimary : sh.textSecondary)
        case .danger: sh.failed
        case .dangerFill: sh.textOnFailed
        }
    }

    private func background(_ sh: SHPalette) -> AnyShapeStyle {
        switch kind {
        case .primary:
            // Hover lifts the fill, pressed sinks it (the board's #f7b84f and #d9922a).
            let fill = !enabled ? sh.lantern : configuration.isPressed ? sh.lanternPressed : hovering ? sh.lanternHover : sh.lantern
            return AnyShapeStyle(fill)
        case .dangerFill:
            // A confirmed destructive action stays put on hover and sinks while pressed.
            return AnyShapeStyle(enabled && configuration.isPressed ? sh.failedPressed : sh.failed)
        case .secondary:
            // The Settings boards' buttons rest on the page's own fill.
            return AnyShapeStyle(active ? sh.bgSelected : scale == .settings ? sh.bgWindow : sh.bgRaised)
        case .raised:
            return AnyShapeStyle(active ? sh.bgSelected : sh.bgRaised)
        case .ghost:
            return AnyShapeStyle(enabled && configuration.isPressed ? sh.bgSelected : hovering && enabled ? sh.bgHover : Color.clear)
        case .danger:
            return AnyShapeStyle(enabled && configuration.isPressed ? sh.bgSelected : hovering && enabled ? sh.failedTint
                : scale == .settings ? sh.bgWindow : sh.bgRaised)
        }
    }
}

/// A button's title with its chord after it (Controls board: "Land ⌘↩", "New agent ⌘N"), for
/// the view's main action only: the chord in Geist Mono 10.5 regular at 60%, 6pt after the title.
/// Bind the same chord with `.keyboardShortcut`; VoiceOver hears the title alone.
public struct SHButtonTitle: View {
    let title: String
    let chord: String

    public init(_ title: String, chord: String) {
        self.title = title
        self.chord = chord
    }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            Text(title)
            Text(chord)
                .font(.shMono(10.5))
                .opacity(0.6)
                .accessibilityHidden(true)
        }
    }
}

/// Icon and title 6pt apart, the icon one step smaller than the title.
private struct SHButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SH.Space.s) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// An icon-only button (Controls board): always a circle, 28pt (44 on iOS). Default, hover
/// (`bgHover`), on (lantern tint, for a pane toggle while its pane is open), bordered, focus,
/// disabled. Always give it an accessibility label.
public struct SHIconButtonStyle: ButtonStyle {
    let bordered: Bool
    let isOn: Bool
    let size: CGFloat
    let tint: Color?

    public init(bordered: Bool = false, isOn: Bool = false, size: CGFloat = SH.Height.controlM, tint: Color? = nil) {
        self.bordered = bordered
        self.isOn = isOn
        self.size = size
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        SHIconButton(configuration: configuration, style: self)
    }
}

extension ButtonStyle where Self == SHIconButtonStyle {
    /// `.buttonStyle(.shIcon)`.
    public static var shIcon: SHIconButtonStyle { SHIconButtonStyle() }

    public static func shIcon(bordered: Bool = false, isOn: Bool = false, size: CGFloat = SH.Height.controlM, tint: Color? = nil) -> SHIconButtonStyle {
        SHIconButtonStyle(bordered: bordered, isOn: isOn, size: size, tint: tint)
    }
}

private struct SHIconButton: View {
    let configuration: ButtonStyleConfiguration
    let style: SHIconButtonStyle
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let sh = Color.sh
        #if os(iOS)
        let side = max(style.size, SH.Height.touch)
        #else
        let side = style.size
        #endif
        let active = enabled && (hovering || configuration.isPressed)
        let foreground: Color = style.tint ?? (style.isOn ? sh.lanternText : active ? sh.textPrimary : sh.textSecondary)
        let fill: Color = style.isOn ? sh.lanternTint : configuration.isPressed && enabled ? sh.bgSelected : active ? sh.bgHover : .clear
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(foreground)
            .frame(width: side, height: side)
            .background(fill, in: Circle())
            .shBorder(style.bordered ? sh.lineStrong : .clear, in: Circle())
            .shEnabledOpacity(enabled)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
            // A pane toggle lights up however its pane opened (a menu, a shortcut, an agent).
            .shComponentAnimation(.hover, value: style.isOn)
            .shFocusRingCircle()
    }
}

/// Inline text that acts as a link ("Show all", "review ›", "Reset"): running blue unless given
/// a color.
public struct SHLinkButtonStyle: ButtonStyle {
    let color: Color?
    let font: Font?

    public init(color: Color? = nil, font: Font? = nil) {
        self.color = color
        self.font = font
    }

    public func makeBody(configuration: Configuration) -> some View {
        SHLinkButton(configuration: configuration, color: color, font: font)
    }
}

extension ButtonStyle where Self == SHLinkButtonStyle {
    /// `.buttonStyle(.shLink)`.
    public static var shLink: SHLinkButtonStyle { SHLinkButtonStyle() }

    public static func shLink(color: Color? = nil, font: Font? = nil) -> SHLinkButtonStyle {
        SHLinkButtonStyle(color: color, font: font)
    }
}

private struct SHLinkButton: View {
    let configuration: ButtonStyleConfiguration
    let color: Color?
    let font: Font?
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(font ?? .sh(.caption))
            .foregroundStyle(color ?? .sh.running)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .shEnabledOpacity(enabled)
            .contentShape(Rectangle())
            .shFocusRing(radius: SH.Radius.xs)
    }
}

/// A hover-tracking row button (sidebar rows, palette rows, menu rows).
public struct SHRowButtonStyle: ButtonStyle {
    let selected: Bool
    let radius: CGFloat
    let selectedFill: Color?
    let hoverFill: Color?
    let focusColor: Color?

    public init(selected: Bool = false, radius: CGFloat = SH.Radius.s, selectedFill: Color? = nil, hoverFill: Color? = nil, focusColor: Color? = nil) {
        self.selected = selected
        self.radius = radius
        self.selectedFill = selectedFill
        self.hoverFill = hoverFill
        self.focusColor = focusColor
    }

    public func makeBody(configuration: Configuration) -> some View {
        SHRowButton(configuration: configuration, style: self)
    }
}

extension ButtonStyle where Self == SHRowButtonStyle {
    public static func shRow(selected: Bool = false, radius: CGFloat = SH.Radius.s, selectedFill: Color? = nil, hoverFill: Color? = nil, focusColor: Color? = nil) -> SHRowButtonStyle {
        SHRowButtonStyle(selected: selected, radius: radius, selectedFill: selectedFill, hoverFill: hoverFill, focusColor: focusColor)
    }
}

private struct SHRowButton: View {
    let configuration: ButtonStyleConfiguration
    let style: SHRowButtonStyle
    @State private var hovering = false

    var body: some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: style.radius))
            .shRowBackground(selected: style.selected, hovering: hovering || Self.pressed(configuration), radius: style.radius,
                             selectedFill: style.selectedFill, hoverFill: style.hoverFill)
            .onHover { hovering = $0 }
            // Keyed on the pointer only: a selection moved by the keyboard lands at once.
            .shAnimation(.hover, value: hovering)
            .shFocusRing(radius: style.radius, color: style.focusColor)
    }

    /// Touch has no hover, so a row shows its hover fill while pressed instead.
    private static func pressed(_ configuration: ButtonStyleConfiguration) -> Bool {
        #if os(iOS)
        configuration.isPressed
        #else
        false
        #endif
    }
}

extension View {
    /// Row chrome: `bgSelected` when selected, `bgHover` while hovered.
    public func shRowBackground(selected: Bool, hovering: Bool, radius: CGFloat = SH.Radius.s,
                                selectedFill: Color? = nil, hoverFill: Color? = nil) -> some View {
        background(
            selected ? (selectedFill ?? .sh.bgSelected) : hovering ? (hoverFill ?? .sh.bgHover) : Color.clear,
            in: RoundedRectangle(cornerRadius: radius)
        )
    }
}
