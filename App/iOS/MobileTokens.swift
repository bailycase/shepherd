import SwiftUI
import ShepherdCore

// Design-spec tokens (docs/design-spec page 7), light/dark, same hex as the desktop's
// NativeTokens. Mobile keeps these local so the app never imports the Mac app module. The
// spec names IBM Plex Sans + JetBrains Mono; no fonts are bundled, so prose is the system
// face and code is the system monospace at the spec's iOS sizes (page 9 §8).
struct MobileTokens {
    let scheme: ColorScheme

    // Backgrounds
    var canvas: Color { color(0x141413, 0xF4F3EF) }
    var surface: Color { color(0x1A1917, 0xFBFAF7) }
    var raised: Color { color(0x201F1D, 0xFFFFFF) }
    var muted: Color { color(0x1F1E1B, 0xF6F5F0) }
    var bubble: Color { color(0x2A2926, 0xECEBE5) }
    var selected: Color { color(0x2E2D29, 0xE4E2DB) }
    var hover: Color { color(0x232220, 0xF1F0EB) }
    var hoverStrong: Color { color(0x2A2926, 0xE9E7E1) }
    var track: Color { color(0x26251F, 0xECE9E2) }

    // Borders
    var borderSubtle: Color { color(0x262523, 0xEDEBE5) }
    var border: Color { color(0x2E2D29, 0xE2E0D9) }
    var borderStrong: Color { color(0x3A3835, 0xD9D6CE) }

    // Text
    var text: Color { color(0xE6E3DA, 0x1C1B19) }
    var textSecondary: Color { color(0xC9C6BC, 0x4B4842) }
    var textTertiary: Color { color(0x9C988E, 0x6F6C64) }
    var textMuted: Color { color(0x7A776F, 0x8A877E) }
    var textDisabled: Color { color(0x5C5A54, 0xB8B5AC) }

    // Semantic. A `.bg` fill only ever carries its `.text`; the base color is for dots and glyphs.
    var accent: Color { color(0x6F95E6, 0x2C57B8) }
    var accentText: Color { color(0x8FB0F0, 0x2C57B8) }
    var accentBg: Color { color(0x1E2637, 0xE8EEFB) }
    var success: Color { color(0x4FB07F, 0x2C8A5C) }
    var successText: Color { color(0x7FCBA3, 0x1F6B46) }
    var successBg: Color { color(0x1C2A22, 0xE4F3EA) }
    var danger: Color { color(0xD8674B, 0xB0492F) }
    var dangerText: Color { color(0xEB9A85, 0x9A3D26) }
    var dangerBg: Color { color(0x2F1F1A, 0xF8E9E4) }
    var warning: Color { color(0xD9A43A, 0xC48A1C) }
    var warningText: Color { color(0xE6BD68, 0x8A5F10) }
    var warningBg: Color { color(0x2E2818, 0xF9F1DE) }
    var dotIdle: Color { color(0x4A4843, 0xC9C6BD) }
    /// Primary button: text color on the raised surface.
    var buttonPrimary: Color { text }
    var onButtonPrimary: Color { raised }

    /// Sidebar/list dot per spec §6: running = success ("alive"), blocked = warning, idle = grey.
    func status(_ status: AgentStatus) -> Color {
        switch status {
        case .working: return success
        case .blocked: return warning
        case .idle: return dotIdle
        case .done: return dotIdle
        }
    }

    func statusText(_ status: AgentStatus) -> Color {
        switch status {
        case .working: return successText
        case .blocked: return warningText
        case .idle, .done: return textMuted
        }
    }

    static func statusWord(_ status: AgentStatus) -> String {
        switch status {
        case .working: return "running"
        case .blocked: return "needs approval"
        case .idle: return "idle"
        case .done: return "done"
        }
    }

    // Type (spec §8): body 16 ×1.5, user bubble 15, tool rows 12 mono, label/600 title, micro 11 mono.
    static let prose = Font.system(size: 16)
    /// Extra leading so 16pt body reaches ×1.5 (24pt lines).
    static let proseLeading: CGFloat = 5
    static let bubble = Font.system(size: 15)
    static let bubbleLeading: CGFloat = 4
    static let display = Font.system(size: 28, weight: .bold)
    static let title = Font.system(size: 16, weight: .semibold)
    static let label = Font.system(size: 15, weight: .medium)
    static let labelStrong = Font.system(size: 15, weight: .semibold)
    static let labelRegular = Font.system(size: 15)
    static let heading = Font.system(size: 17, weight: .semibold)
    static let caption12 = Font.system(size: 12)
    static let section = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let code = Font.system(size: 12.5, design: .monospaced)
    /// Code runs inside 16pt prose; the mono face is wider, so 14 reads as the same size.
    static let inlineCode = Font.system(size: 14, design: .monospaced)
    static let output = Font.system(size: 12, design: .monospaced)
    static let caption = Font.system(size: 11, design: .monospaced)
    static let micro = Font.system(size: 11, design: .monospaced)

    static let spacing: CGFloat = 8
    static let blockSpacing: CGFloat = 10
    static let inset: CGFloat = 16
    static let turnSpacing: CGFloat = 24
    static let radius: CGFloat = 10
    static let bubbleRadius: CGFloat = 14
    static let bubbleCorner: CGFloat = 4
    static let sheetRadius: CGFloat = 20
    static let pillRadius: CGFloat = 22
    static let agentRowHeight: CGFloat = 56
    static let toolSummaryHeight: CGFloat = 44
    static let toolRowHeight: CGFloat = 40
    static let sheetActionHeight: CGFloat = 50
    static let touch: CGFloat = 44
    static let homeIndicatorPadding: CGFloat = 30
    static let statusSize: CGFloat = 7

    private func color(_ dark: UInt32, _ light: UInt32) -> Color {
        let value = scheme == .dark ? dark : light
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255, opacity: 1)
    }
}

/// Accent spinner; a pulsing dot under Reduce Motion (spec §7).
struct MobileSpinner: View {
    var color: Color
    var size: CGFloat = 12
    @State private var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Circle().fill(color).frame(width: size / 2, height: size / 2)
                .opacity(animating ? 0.3 : 1)
                .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { animating = true } }
        } else {
            Circle().trim(from: 0.15, to: 1)
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(animating ? 360 : 0))
                .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { animating = true } }
        }
    }
}

/// Stacked 50pt sheet/list action (spec §8). Primary = text on raised; secondary = bordered; ghost = plain.
struct MobileActionStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive }
    let kind: Kind
    let tokens: MobileTokens
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = switch kind {
        case .primary: tokens.buttonPrimary.opacity(configuration.isPressed ? 0.9 : 1)
        case .secondary: configuration.isPressed ? tokens.hover : tokens.raised
        case .ghost, .destructive: configuration.isPressed ? tokens.hoverStrong : .clear
        }
        let label: Color = switch kind {
        case .primary: tokens.onButtonPrimary
        case .secondary, .ghost: tokens.text
        case .destructive: tokens.dangerText
        }
        configuration.label
            .font(MobileTokens.labelStrong)
            .foregroundStyle(label)
            .frame(maxWidth: .infinity, minHeight: MobileTokens.sheetActionHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: MobileTokens.radius))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: MobileTokens.radius).strokeBorder(tokens.borderStrong, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}
