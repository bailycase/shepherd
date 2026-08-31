import SwiftUI
import AppKit
import ShepherdCore

extension Color {
    /// "#RRGGBB" per the design token table.
    init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Design tokens resolved against the active Basalt variant.
@MainActor
enum Tokens {
    private static var theme: ShepherdTheme { ThemeManager.shared.current }

    // Surfaces (flat — no vibrancy materials anywhere)
    static var sidebarBg: Color { theme.sidebarBg }
    static var workspaceBg: Color { theme.workspaceBg }
    /// Terminals share the workspace surface; the pane frame is the boundary.
    static var terminalBg: Color { theme.workspaceBg }
    static var rowSelection: Color { theme.rowSelection }
    /// The ⌘K palette panel: sidebar surface lifted slightly above the
    /// workspace — alpha-composited, so it needs no per-theme field.
    static var paletteBg: Color { theme.sidebarBg.opacity(0.98) }
    static var rowActiveHeader: Color { theme.rowActiveHeader }
    static var paneBorder: Color { theme.paneBorder }

    // Hairlines and fills derive from the current foreground so they work in
    // both Basalt variants without adding palette colors.
    static var separator: Color { theme.textPrimary.opacity(0.05) }
    static var rowHover: Color { theme.textPrimary.opacity(0.04) }
    static var keycapBorder: Color { theme.textPrimary.opacity(0.12) }
    static var chipBorder: Color { theme.textPrimary.opacity(0.10) }

    // Text ramp (all mono)
    static var textPrimary: Color { theme.textPrimary }
    static var textSecondary: Color { theme.textSecondary }
    static var textTertiary: Color { theme.textTertiary }
    static var textDim: Color { theme.textDim }
    static var textMetadata: Color { theme.textMetadata }
    static var textHint: Color { theme.textHint }

    // Status
    static var statusWorking: Color { theme.statusWorking }
    static var statusBlocked: Color { theme.statusBlocked }
    static var statusIdle: Color { theme.statusIdle }
    static var statusDone: Color { theme.statusDone }

    // Accents
    static var focusAccent: Color { theme.focusAccent }
    static var accentButton: Color { theme.accentButton }
    static var destructive: Color { theme.destructive }

    static func statusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .working: return statusWorking
        case .blocked: return statusBlocked
        case .idle: return statusIdle
        case .done: return statusDone
        }
    }
}

@MainActor
enum Metrics {
    /// User-adjustable chrome scaling (Settings → Appearance). Reading
    /// through AppSettings keeps every consumer live: the views observe the
    /// settings object, so a slider drag re-renders them with new metrics.
    private static var density: CGFloat { CGFloat(AppSettings.shared.uiDensity) }

    static var sidebarWidth: CGFloat { CGFloat(AppSettings.shared.sidebarWidth) }
    /// Traffic-light strip at the top of the sidebar column.
    static let trafficLightHeight: CGFloat = 38
    /// Workspace header strip (`space / agent · path · status`).
    static var headerHeight: CGFloat { (42 * density).rounded() }
    static var statusLineHeight: CGFloat { (28 * density).rounded() }
    static var rowHeight: CGFloat { (23 * density).rounded() }
    /// Inset of the framed pane region from header, sidebar edge, and status line.
    static let paneFrameInset: CGFloat = 2
    /// Rows are full-bleed and square.
    static let rowRadius: CGFloat = 0
    static let windowMinWidth: CGFloat = 1040
    static let windowMinHeight: CGFloat = 640
    static let windowDefaultWidth: CGFloat = 1440
    static let windowDefaultHeight: CGFloat = 900
    static let settingsSidebarWidth: CGFloat = 230
    static let settingsDefaultHeight: CGFloat = 620
    static let settingsMinWidth: CGFloat = 720
    static let settingsMinHeight: CGFloat = 480
}

@MainActor
enum Fonts {
    /// Everything is SF Mono — there is no proportional text in the app.
    /// Sizes scale by the user's text-scale setting (Settings → Appearance);
    /// call sites keep passing designed sizes.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * CGFloat(AppSettings.shared.uiTextScale), weight: weight, design: .monospaced)
    }
}
