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
        /// Text-colored fill on the window's color: a page header's state action beside its
        /// secondary buttons (PRReview's Merge, IssueReview's Start a thread).
        case strong
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
        // A Settings page draws every size as its one button: 26pt at radius `s`, `caption`.
        #if os(iOS)
        // The phone and iPad boards' pills: 30, 36 and 44pt capsules at 13, 14 and 15.
        let standard: (CGFloat, CGFloat, CGFloat) = switch size {
        case .s: (30, SH.Space.l, 13)
        case .m: (36, 14, 14)
        case .l: (SH.Height.touch, SH.Space.xl, 15)
        }
        #else
        let standard: (CGFloat, CGFloat, CGFloat) = switch size {
        case .s: (SH.Height.controlS, SH.Space.m, 12)
        case .m: (SH.Height.controlM, 10, 12.5)
        case .l: (SH.Height.controlL, 14, 13)
        }
        #endif
        let (height, padding, fontSize) = settings ? (M.controlHeight, M.buttonPadding, M.textSize) : standard
        #if os(iOS)
        let radius = settings ? M.radius : height / 2
        #else
        let radius = settings ? M.radius : SH.Radius.s
        #endif
        let filled = kind == .primary || kind == .dangerFill || kind == .strong
        let shape = RoundedRectangle(cornerRadius: radius)
        #if os(macOS)
        if settings && !filled {
            // The Settings boards write a row's action as plain words (500, 400 for a quiet one) with no box;
            // the hit area overhangs them so a 26pt target keeps the words flush with the row's padding.
            let overhang = M.buttonOverhang
            configuration.label
                .font(.shSans(M.textSize, kind == .ghost ? .regular : .medium))
                .labelStyle(SHButtonLabelStyle())
                .lineLimit(1)
                .foregroundStyle(foreground(sh))
                .padding(.horizontal, overhang)
                .frame(minHeight: height)
                .background(active ? sh.bgHover : Color.clear, in: shape)
                .contentShape(shape)
                .padding(.horizontal, -overhang)
                .offset(y: configuration.isPressed ? 0.5 : 0)
                .shEnabledOpacity(enabled)
                .onHover { hovering = $0 }
                .shAnimation(.hover, value: hovering)
                .shFocusRing(radius: radius)
                .shTouchTarget(height: height)
        } else {
            styled(configuration, sh: sh, height: height, padding: padding, fontSize: fontSize, radius: radius, filled: filled, shape: shape)
        }
        #else
        styled(configuration, sh: sh, height: height, padding: padding, fontSize: fontSize, radius: radius, filled: filled, shape: shape)
        #endif
    }

    private func styled(_ configuration: ButtonStyleConfiguration, sh: SHPalette, height: CGFloat, padding: CGFloat, fontSize: CGFloat,
                        radius: CGFloat, filled: Bool, shape: RoundedRectangle) -> some View {
        configuration.label
            .font(.shSans(fontSize, filled ? .semibold : .medium))
            .labelStyle(SHButtonLabelStyle())
            .lineLimit(1)
            .foregroundStyle(foreground(sh))
            .padding(.horizontal, padding)
            .frame(minHeight: height)
            .background(background(sh), in: shape)
            .shBorder(bordered ? sh.lineStrong : .clear, radius: radius)
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .shEnabledOpacity(enabled)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
            .shFocusRing(radius: radius)
            .shTouchTarget(height: height)
    }

    private var active: Bool { enabled && (hovering || configuration.isPressed) }

    /// The Mac's secondary buttons carry a line; the phone boards' pills are a plain `bgSelected` fill.
    private var bordered: Bool {
        #if os(iOS)
        kind == .raised || kind == .danger || (kind == .secondary && scale == .settings)
        #else
        kind == .secondary || kind == .raised || kind == .danger
        #endif
    }

    private func foreground(_ sh: SHPalette) -> Color {
        switch kind {
        case .primary: sh.textOnPrimary
        case .secondary, .raised: tint ?? sh.textPrimary
        case .ghost: tint ?? (hovering && enabled && !configuration.isPressed ? sh.textPrimary : sh.textSecondary)
        case .danger: sh.failed
        case .dangerFill: sh.textOnFailed
        case .strong: sh.bgWindow
        }
    }

    private func background(_ sh: SHPalette) -> AnyShapeStyle {
        switch kind {
        case .primary:
            // Hover lifts the fill, pressed sinks it.
            let fill = !enabled ? sh.primary : configuration.isPressed ? sh.primaryPressed : hovering ? sh.primaryHover : sh.primary
            return AnyShapeStyle(fill)
        case .dangerFill:
            // A confirmed destructive action stays put on hover and sinks while pressed.
            return AnyShapeStyle(enabled && configuration.isPressed ? sh.failedPressed : sh.failed)
        case .strong:
            return AnyShapeStyle(enabled && configuration.isPressed ? sh.textSecondary : sh.textPrimary)
        case .secondary:
            // The Settings buttons are unfilled.
            #if os(iOS)
            return AnyShapeStyle(scale == .settings && !active ? Color.clear : sh.bgSelected)
            #else
            return AnyShapeStyle(active ? sh.bgSelected : scale == .settings ? Color.clear : sh.bgRaised)
            #endif
        case .raised:
            return AnyShapeStyle(active ? sh.bgSelected : sh.bgRaised)
        case .ghost:
            return AnyShapeStyle(enabled && configuration.isPressed ? sh.bgSelected : hovering && enabled ? sh.bgHover : Color.clear)
        case .danger:
            return AnyShapeStyle(enabled && configuration.isPressed ? sh.bgSelected : hovering && enabled ? sh.failedTint
                : scale == .settings ? Color.clear : sh.bgRaised)
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
/// disabled. Always give it an accessibility label. `hoverFill` replaces `bgHover` for a tinted
/// button that lights up in its own color (`SHUpdateButton`).
public struct SHIconButtonStyle: ButtonStyle {
    let bordered: Bool
    let isOn: Bool
    let size: CGFloat
    let tint: Color?
    let hoverFill: Color?
    /// A circle rather than the rounded square (the composer's attach plus).
    let round: Bool
    /// The least the button is pressed over, when its drawing is smaller: the press grows, the drawing and the room it takes do not.
    let pressSize: CGFloat

    public init(bordered: Bool = false, isOn: Bool = false, size: CGFloat = SH.Height.controlM, tint: Color? = nil, hoverFill: Color? = nil,
                round: Bool = false, pressSize: CGFloat = 0) {
        self.pressSize = pressSize
        self.round = round
        self.bordered = bordered
        self.isOn = isOn
        self.size = size
        self.tint = tint
        self.hoverFill = hoverFill
    }

    public func makeBody(configuration: Configuration) -> some View {
        SHIconButton(configuration: configuration, style: self)
    }
}

extension ButtonStyle where Self == SHIconButtonStyle {
    /// `.buttonStyle(.shIcon)`.
    public static var shIcon: SHIconButtonStyle { SHIconButtonStyle() }

    public static func shIcon(bordered: Bool = false, isOn: Bool = false, size: CGFloat = SH.Height.controlM, tint: Color? = nil,
                              hoverFill: Color? = nil, round: Bool = false, pressSize: CGFloat = 0) -> SHIconButtonStyle {
        SHIconButtonStyle(bordered: bordered, isOn: isOn, size: size, tint: tint, hoverFill: hoverFill, round: round, pressSize: pressSize)
    }
}

extension EnvironmentValues {
    /// Icon buttons draw round: inside the toolbar's capsule, whose ends they follow (`SHToolbarCapsule`).
    @Entry var shIconButtonsRound = false
}

private struct SHIconButton: View {
    let configuration: ButtonStyleConfiguration
    let style: SHIconButtonStyle
    @Environment(\.isEnabled) private var enabled
    @Environment(\.shIconButtonsRound) private var roundHere
    @State private var hovering = false

    var body: some View {
        let sh = Color.sh
        #if os(iOS)
        let side = max(style.size, SH.Height.touch)
        #else
        let side = style.size
        #endif
        let active = enabled && (hovering || configuration.isPressed)
        // On is the boards' `.ib.on`: the selection fill with the glyph in ink.
        let foreground: Color = style.tint ?? (style.isOn || active ? sh.textPrimary : sh.textSecondary)
        let fill: Color = style.isOn ? sh.bgSelected : configuration.isPressed && enabled ? sh.bgSelected : active ? style.hoverFill ?? sh.bgHover : .clear
        // The boards' icon button: a rounded square (radius 7), not a circle, but in the toolbar's capsule.
        let round = style.round || roundHere
        let shape = RoundedRectangle(cornerRadius: round ? side / 2 : SH.Radius.s)
        let slop = max(0, (style.pressSize - side) / 2)
        configuration.label
            .font(.system(size: 14, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(foreground)
            .frame(width: side, height: side)
            .background(fill, in: shape)
            .shBorder(style.bordered ? sh.lineStrong : .clear, in: shape)
            .shEnabledOpacity(enabled)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
            // A pane toggle lights up however its pane opened (a menu, a shortcut, an agent).
            .shComponentAnimation(.hover, value: style.isOn)
            .shFocusRing(radius: round ? side / 2 : SH.Radius.s)
            .padding(slop)
            .contentShape(shape)
            .padding(-slop)
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
