import SwiftUI
import ShepherdCore

// Basalt Standard, dark/light. Mobile keeps these local so the app never imports the Mac theme module.
struct MobileTokens {
    let scheme: ColorScheme

    var background: Color { color(0x111215, 0xF3F1ED) }
    var sidebar: Color { color(0x0D0E10, 0xE7E4DE) }
    // Basalt's user-message surface: the one tinted fill in the transcript (user turns, code, tool output).
    var raised: Color { color(0x16171A, 0xECE9E3) }
    var border: Color { color(0x323337, 0xD4D0C9) }
    var primary: Color { color(0xEDEDED, 0x242424) }
    // Use Basalt's secondary ramp for readable mobile metadata in both variants.
    var secondary: Color { color(0xADADAE, 0x4F504F) }
    var accent: Color { color(0x8892B5, 0x526184) }
    var onAccent: Color { color(0x111215, 0xFFFFFF) }
    var danger: Color { color(0xB87D6E, 0x94493F) }

    func status(_ status: AgentStatus) -> Color {
        switch status {
        case .working: return color(0x9DB56B, 0x456536)
        case .blocked: return color(0xC18065, 0x8F4E37)
        case .idle: return secondary
        case .done: return accent
        }
    }

    // Prose is the system text face (see DESIGN.md, mobile exception); code, tool output, and metadata stay mono.
    static let prose = Font.system(.body)
    static let mono = Font.system(.callout, design: .monospaced)
    static let caption = Font.system(.caption, design: .monospaced)
    static let heading = Font.system(.headline)
    static let spacing: CGFloat = 8
    static let inset: CGFloat = 16
    static let radius: CGFloat = 10
    static let statusSize: CGFloat = 7

    private func color(_ dark: UInt32, _ light: UInt32) -> Color {
        let value = scheme == .dark ? dark : light
        return Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255, opacity: 1)
    }
}

struct AgentStatusLabel: View {
    let status: AgentStatus
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(MobileTokens(scheme: scheme).status(status))
                .frame(width: MobileTokens.statusSize, height: MobileTokens.statusSize)
                .accessibilityHidden(true)
            Text(status.rawValue)
        }
        .font(MobileTokens.caption)
    }
}
