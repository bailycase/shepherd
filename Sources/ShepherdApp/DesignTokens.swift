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

    /// Diff-review syntax colors, derived from the theme's ANSI palette so
    /// highlighted code matches the terminal panes.
    static var codeHighlightStyle: CodeHighlight.Style {
        CodeHighlight.Style(palette: theme.terminal.palette)
    }

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
    static let spacing2: CGFloat = 2
    static let spacing5: CGFloat = 5
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing14: CGFloat = 14
    static let spacing20: CGFloat = 20
    static let windowMinWidth: CGFloat = 1040
    static let windowMinHeight: CGFloat = 640
    static let windowDefaultWidth: CGFloat = 1440
    static let windowDefaultHeight: CGFloat = 900
    static let settingsSidebarWidth: CGFloat = 230
    static let settingsDefaultHeight: CGFloat = 620
    static let settingsMinWidth: CGFloat = 720
    static let settingsMinHeight: CGFloat = 480
}

// MARK: Native thread palette (docs/design-spec, page 7)

/// Colors for the native thread, its header, and the sidebar. Light and dark
/// values come from the design spec's tokens; the variant follows the active
/// Basalt theme so Terminal-mode chrome and native chrome flip together.
@MainActor
enum NativeTokens {
    private static var dark: Bool { ThemeManager.shared.current.id == "basalt-dark" }
    private static func pick(_ light: String, _ dark: String) -> Color { Color(hex: Self.dark ? dark : light) }

    // Backgrounds
    static var bgCanvas: Color { pick("#f4f3ef", "#141413") }
    static var bgSurface: Color { pick("#fbfaf7", "#1a1917") }
    static var bgRaised: Color { pick("#ffffff", "#201f1d") }
    static var bgMuted: Color { pick("#f6f5f0", "#1f1e1b") }
    static var bgBubble: Color { pick("#ecebe5", "#2a2926") }
    static var bgSelected: Color { pick("#e4e2db", "#2e2d29") }
    static var bgHover: Color { pick("#f1f0eb", "#232220") }
    static var bgHoverStrong: Color { pick("#e9e7e1", "#2a2926") }
    static var bgTrack: Color { pick("#ece9e2", "#26251f") }

    // Borders
    static var borderSubtle: Color { pick("#edebe5", "#262523") }
    static var border: Color { pick("#e2e0d9", "#2e2d29") }
    static var borderStrong: Color { pick("#d9d6ce", "#3a3835") }

    // Text
    static var text: Color { pick("#1c1b19", "#e6e3da") }
    static var textSecondary: Color { pick("#4b4842", "#c9c6bc") }
    static var textTertiary: Color { pick("#6f6c64", "#9c988e") }
    static var textMuted: Color { pick("#8a877e", "#7a776f") }
    static var textDisabled: Color { pick("#b8b5ac", "#5c5a54") }

    // Semantic. A `.bg` fill is only ever paired with its `.text`; the base color
    // is for dots, spinners, and links, never body text.
    static var accent: Color { pick("#2c57b8", "#6f95e6") }
    static var accentText: Color { pick("#2c57b8", "#8fb0f0") }
    static var accentBg: Color { pick("#e8eefb", "#1e2637") }
    static var success: Color { pick("#2c8a5c", "#4fb07f") }
    static var successText: Color { pick("#1f6b46", "#7fcba3") }
    static var successBg: Color { pick("#e4f3ea", "#1c2a22") }
    static var danger: Color { pick("#b0492f", "#d8674b") }
    static var dangerText: Color { pick("#9a3d26", "#eb9a85") }
    static var dangerBg: Color { pick("#f8e9e4", "#2f1f1a") }
    static var warning: Color { pick("#c48a1c", "#d9a43a") }
    static var warningText: Color { pick("#8a5f10", "#e6bd68") }
    static var warningBg: Color { pick("#f9f1de", "#2e2818") }
    /// Sidebar dot for an idle agent that is not the open thread.
    static var dotIdle: Color { pick("#c9c6bd", "#4a4843") }
    /// Primary button fill: text color on the raised surface.
    static var buttonPrimary: Color { text }
    static var buttonPrimaryLabel: Color { bgRaised }

    static var composerShadow: Color { Color.black.opacity(0.06) }
    static var thumbShadow: Color { Color.black.opacity(0.12) }
}

/// Type ramp for native views. The spec names IBM Plex Sans + JetBrains Mono;
/// no fonts are bundled, so prose is the system face and code is the system
/// monospace at the spec's sizes and weights. Scales with the text-scale setting.
@MainActor
enum NativeFonts {
    private static var scale: CGFloat { CGFloat(AppSettings.shared.uiTextScale) }
    private static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight, design: .default)
    }
    private static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight, design: .monospaced)
    }
    static var display: Font { sans(22, .semibold) }
    static var title: Font { sans(15, .semibold) }
    static var body: Font { sans(15) }
    static var bodySmall: Font { sans(14) }
    static var label: Font { sans(13, .medium) }
    static var labelRegular: Font { sans(13) }
    static var caption: Font { sans(12) }
    static var captionMedium: Font { sans(12, .medium) }
    static var section: Font { sans(11, .semibold) }
    static var code: Font { mono(12.5) }
    static var output: Font { mono(12) }
    static var micro: Font { mono(11) }
    static var microMedium: Font { mono(11, .medium) }
    /// Sidebar ramp: compact mono like the terminal chrome (rows 12, meta 10.5, headings 10.5).
    static var sidebarRow: Font { mono(12) }
    static var sidebarRowStrong: Font { mono(12, .semibold) }
    static var sidebarMeta: Font { mono(10.5) }
    static var sidebarSection: Font { mono(10.5, .semibold) }
    /// Extra leading to reach the spec's line heights (body ×1.6, bodySmall ×1.5, output ×1.55).
    static var bodyLeading: CGFloat { 15 * scale * 0.6 - 3 }
    static var bodySmallLeading: CGFloat { 14 * scale * 0.5 - 3 }
    static var outputLeading: CGFloat { 12 * scale * 0.55 - 2 }
}

/// Sizes for the native thread (spec §3, §5) and the restyled sidebar. Not
/// density-scaled: the spec's rows are designed at fixed heights.
enum NativeMetrics {
    static let headerHeight: CGFloat = 52
    static let headerPadding: CGFloat = 20
    static let threadMaxWidth: CGFloat = 760
    static let proseMaxWidth: CGFloat = 680
    static let userMaxWidth: CGFloat = 600
    static let gutter: CGFloat = 32
    /// Gutter when the window is too narrow for the full column plus 32pt margins.
    static let gutterCompact: CGFloat = 16
    static let threadTop: CGFloat = 28
    static let turnSpacing: CGFloat = 28
    static let blockSpacing: CGFloat = 10
    static let toolRowHeight: CGFloat = 36
    static let toolOutputIndent: CGFloat = 62
    static let iconButton: CGFloat = 28
    /// Thread tail space under the floating composer card.
    /// Initial guess for the floating composer's height; the view measures the real one.
    static let composerInset: CGFloat = 120
    /// Persistent "Working…" row at the tail of a running thread (bb TimelineWorkingIndicator).
    static let workingRowHeight: CGFloat = 28
    /// "Running bash · 12s" line above the composer card.
    static let statusLineHeight: CGFloat = 22
    static let chipHeight: CGFloat = 24
    /// Marker column for rendered Markdown lists.
    static let listMarker: CGFloat = 18
    // Subagent cards (docs/design-spec/subagent-card-states.png).
    static let subagentCardPadding: CGFloat = 12
    static let subagentCardHeaderHeight: CGFloat = 20
    static let subagentCardRowSpacing: CGFloat = 8
    static let subagentCardButton: CGFloat = 28
    static let subagentProgressHeight: CGFloat = 4
    static let subagentProgressWidth: CGFloat = 240
    static let subagentGlyph: CGFloat = 14
    /// RunsStrip collapsed row and its 8×8 cells.
    static let runsStripHeight: CGFloat = 36
    static let runsStripCell: CGFloat = 8
    static let runsStripCellGap: CGFloat = 3
    // Subagent inspector panel.
    static let inspectorMinWidth: CGFloat = 420
    static let inspectorDefaultFraction: CGFloat = 0.6
    static let inspectorHeaderHeight: CGFloat = 52
    static let inspectorGoalPadding: CGFloat = 12
    /// Sidebar rows keep the pre-spec density (23pt rows, 12pt indent, density-scaled): the
    /// spec's 32/22 was tried and lost a third of the tree on real fleets.
    @MainActor static var sidebarRowHeight: CGFloat { Metrics.rowHeight }
    static let sidebarIndent: CGFloat = 12
    static let sidebarPadding: CGFloat = 6
}

enum Radius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let button: CGFloat = 7
    static let md: CGFloat = 8
    static let lg: CGFloat = 10
    static let xl: CGFloat = 12
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
