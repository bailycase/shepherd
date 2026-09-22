import SwiftUI

/// ShepherdButton (Components board): primary, secondary, ghost, destructive at sm 28 / md 30 /
/// lg 32. Hover: secondary → bgHover, ghost → bgHoverStrong, primary darkens.
public struct ShepherdButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary, ghost, destructive }
    public enum Size { case small, medium, large }

    let kind: Kind
    let size: Size
    let tint: Color?

    /// `tint` recolors a secondary or ghost label (the review's green Commit).
    public init(_ kind: Kind = .secondary, size: Size = .medium, tint: Color? = nil) {
        self.kind = kind
        self.size = size
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, size: size, tint: tint)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let size: Size
        let tint: Color?
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let height: CGFloat = switch size {
            case .small: Metrics.buttonSmall
            case .medium: Metrics.buttonMedium
            case .large: Metrics.buttonLarge
            }
            let radius = size == .large ? Radius.md : Radius.button
            configuration.label
                .font(kind == .primary ? Fonts.sans(13, .semibold) : Fonts.label)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .ghost ? 10 : (kind == .primary ? 14 : 12))
                .frame(minHeight: height)
                .background(background, in: RoundedRectangle(cornerRadius: radius))
                .overlay {
                    if kind == .secondary || kind == .destructive {
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(enabled ? Tokens.borderStrong : Tokens.border, lineWidth: 1)
                    }
                }
                .opacity(configuration.isPressed ? 0.85 : 1)
                .contentShape(RoundedRectangle(cornerRadius: radius))
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            guard enabled else { return Tokens.textDisabled }
            return switch kind {
            case .primary: Tokens.primaryLabel
            case .secondary: tint ?? Tokens.text
            case .ghost: tint ?? Tokens.textSecondary
            case .destructive: Tokens.dangerText
            }
        }

        private var background: Color {
            switch kind {
            case .primary: enabled ? Tokens.primaryFill.opacity(hovering ? 0.88 : 1) : Tokens.bgTrack
            case .secondary, .destructive: hovering && enabled ? Tokens.bgHover : Tokens.bgSurface
            case .ghost: hovering && enabled ? Tokens.bgHoverStrong : .clear
            }
        }
    }
}

/// Icon-only button (Components board): bordered 28/30, or ghost 28 for footer actions.
/// Always give it an accessibility label.
public struct IconButtonStyle: ButtonStyle {
    let bordered: Bool
    let size: CGFloat
    let tint: Color?

    public init(bordered: Bool = true, size: CGFloat = Metrics.buttonSmall, tint: Color? = nil) {
        self.bordered = bordered
        self.size = size
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyledIcon(configuration: configuration, bordered: bordered, size: size, tint: tint)
    }

    private struct StyledIcon: View {
        let configuration: ButtonStyleConfiguration
        let bordered: Bool
        let size: CGFloat
        let tint: Color?
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let radius = bordered ? Radius.button : Radius.sm
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? (tint ?? (bordered ? Tokens.text : Tokens.textMuted)) : Tokens.textDisabled)
                .frame(width: size, height: size)
                .background(hovering && enabled ? (bordered ? Tokens.bgHover : Tokens.bgHoverStrong) : (bordered ? Tokens.bgSurface : .clear),
                            in: RoundedRectangle(cornerRadius: radius))
                .overlay {
                    if bordered { RoundedRectangle(cornerRadius: radius).strokeBorder(Tokens.borderStrong, lineWidth: 1) }
                }
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(RoundedRectangle(cornerRadius: radius))
                .onHover { hovering = $0 }
        }
    }
}

/// The composer's single 32pt action: Send (arrow on the primary fill) or Stop (square on
/// danger) while a turn runs.
public struct ComposerActionButton: View {
    public enum Mode { case send, stop }
    let mode: Mode
    let enabled: Bool
    let action: () -> Void

    public init(_ mode: Mode, enabled: Bool = true, action: @escaping () -> Void) {
        self.mode = mode
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Group {
                switch mode {
                case .send:
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
                case .stop:
                    RoundedRectangle(cornerRadius: 1.5).frame(width: 9, height: 9)
                }
            }
            .foregroundStyle(Tokens.primaryLabel)
            .frame(width: Metrics.buttonLarge, height: Metrics.buttonLarge)
            .background(fill, in: RoundedRectangle(cornerRadius: Radius.md))
            .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(mode == .send ? "Send" : "Stop")
    }

    private var fill: Color {
        switch mode {
        case .send: enabled ? Tokens.primaryFill : Tokens.textDisabled
        case .stop: Tokens.danger
        }
    }
}

/// Plain accent text that acts as a link ("Show all", "review ›", "Reset").
public struct LinkButtonStyle: ButtonStyle {
    let color: Color?
    let font: Font?

    public init(color: Color? = nil, font: Font? = nil) {
        self.color = color
        self.font = font
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font ?? Fonts.caption)
            .foregroundStyle(color ?? Tokens.accentText)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}
