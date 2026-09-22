import SwiftUI
import ShepherdCore
import ShepherdDesign

// Transitional names from the two pre-redesign token systems (Basalt terminal chrome and the
// first native-thread palette), mapped onto the ShepherdDesign roles. Deprecated so the
// compiler lists every call site still to move; this file goes away when the last one does.

@available(*, deprecated, message: "Use Tokens")
typealias NativeTokens = Tokens
@available(*, deprecated, message: "Use Fonts")
typealias NativeFonts = Fonts
@available(*, deprecated, message: "Use Metrics")
typealias NativeMetrics = Metrics

extension Tokens {
    @available(*, deprecated, message: "Use bgCanvas") static var sidebarBg: Color { bgCanvas }
    @available(*, deprecated, message: "Use bgSurface") static var workspaceBg: Color { bgSurface }
    @available(*, deprecated, message: "Use bgSurface") static var terminalBg: Color { bgSurface }
    @available(*, deprecated, message: "Use bgSelected") static var rowSelection: Color { bgSelected }
    @available(*, deprecated, message: "Use bgRaised") static var paletteBg: Color { bgRaised }
    @available(*, deprecated, message: "Use bgMuted") static var rowActiveHeader: Color { bgMuted }
    @available(*, deprecated, message: "Use border") static var paneBorder: Color { border }
    @available(*, deprecated, message: "Use borderSubtle") static var separator: Color { borderSubtle }
    @available(*, deprecated, message: "Use bgHover") static var rowHover: Color { bgHover }
    @available(*, deprecated, message: "Use borderStrong") static var keycapBorder: Color { borderStrong }
    @available(*, deprecated, message: "Use border") static var chipBorder: Color { border }
    @available(*, deprecated, message: "Use text") static var textPrimary: Color { text }
    @available(*, deprecated, message: "Use textMuted") static var textDim: Color { textMuted }
    @available(*, deprecated, message: "Use textMuted") static var textMetadata: Color { textMuted }
    @available(*, deprecated, message: "Use textMuted") static var textHint: Color { textMuted }
    @available(*, deprecated, message: "Use success") static var statusWorking: Color { success }
    @available(*, deprecated, message: "Use warning") static var statusBlocked: Color { warning }
    @available(*, deprecated, message: "Use dotIdle") static var statusIdle: Color { dotIdle }
    @available(*, deprecated, message: "Use accent") static var statusDone: Color { accent }
    @available(*, deprecated, message: "Use accent") static var focusAccent: Color { accent }
    @available(*, deprecated, message: "Use accent") static var accentButton: Color { accent }
    @available(*, deprecated, message: "Use danger / dangerText") static var destructive: Color { danger }
    @available(*, deprecated, message: "Use primaryFill") static var buttonPrimary: Color { primaryFill }
    @available(*, deprecated, message: "Use primaryLabel") static var buttonPrimaryLabel: Color { primaryLabel }
    @available(*, deprecated, message: "Use statusDot(_:isCurrent:)")
    static func statusColor(_ status: AgentStatus) -> Color { statusDot(status) }
}

extension Fonts {
    @available(*, deprecated, message: "Use label") static var sidebarRow: Font { mono(12) }
    @available(*, deprecated, message: "Use labelStrong") static var sidebarRowStrong: Font { mono(12, .semibold) }
    @available(*, deprecated, message: "Use micro") static var sidebarMeta: Font { mono(10.5) }
    @available(*, deprecated, message: "Use section") static var sidebarSection: Font { mono(10.5, .semibold) }
}

extension Metrics {
    @available(*, deprecated) @MainActor static var sidebarWidth: CGFloat { CGFloat(AppSettings.shared.sidebarWidth) }
    @available(*, deprecated) static let statusLineHeight: CGFloat = 22
    @available(*, deprecated) @MainActor static var rowHeight: CGFloat { (23 * CGFloat(AppSettings.shared.uiDensity)).rounded() }
    @available(*, deprecated) static let paneFrameInset: CGFloat = 2
    @available(*, deprecated) static let spacing2: CGFloat = 2
    @available(*, deprecated) static let spacing5: CGFloat = 5
    @available(*, deprecated) static let spacing8: CGFloat = 8
    @available(*, deprecated) static let spacing12: CGFloat = 12
    @available(*, deprecated) static let spacing14: CGFloat = 14
    @available(*, deprecated) static let spacing20: CGFloat = 20
    @available(*, deprecated) static let settingsSidebarWidth: CGFloat = 230
    @available(*, deprecated) static let settingsMinWidth: CGFloat = 720
    @available(*, deprecated) static let settingsMinHeight: CGFloat = 480
    @available(*, deprecated, message: "Use buttonSmall") static let iconButton: CGFloat = 28
    @available(*, deprecated) static let composerInset: CGFloat = 120
    @available(*, deprecated) static let listMarker: CGFloat = 18
    @available(*, deprecated) static let subagentCardPadding: CGFloat = 12
    @available(*, deprecated) static let subagentCardHeaderHeight: CGFloat = 20
    @available(*, deprecated) static let subagentCardRowSpacing: CGFloat = 8
    @available(*, deprecated) static let subagentCardButton: CGFloat = 28
    @available(*, deprecated) static let subagentProgressHeight: CGFloat = 4
    @available(*, deprecated) static let subagentGlyph: CGFloat = 14
    @available(*, deprecated) static let runsStripHeight: CGFloat = 36
    @available(*, deprecated) static let subagentLedgerRowHeight: CGFloat = 44
    @available(*, deprecated) static let subagentLedgerRoleWidth: CGFloat = 72
    @available(*, deprecated) static let subagentSelectionWidth: CGFloat = 3
    @available(*, deprecated) static let runsStripCell: CGFloat = 8
    @available(*, deprecated) static let runsStripCellGap: CGFloat = 3
    @available(*, deprecated) static let inspectorMinWidth: CGFloat = 420
    @available(*, deprecated) static let inspectorDefaultFraction: CGFloat = 0.44
    @available(*, deprecated) static let inspectorHeaderHeight: CGFloat = 52
    @available(*, deprecated) static let inspectorGoalPadding: CGFloat = 12
}

extension Tokens {
    @available(*, deprecated, message: "Use CodeHighlight.Style.theme")
    static var codeHighlightStyle: CodeHighlight.Style { .theme }
}
