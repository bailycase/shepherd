import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Every color a view uses, resolved once from a theme. Each is dynamic: it follows the light or
/// dark appearance of the view drawing it, so an appearance change needs no re-render. Read it as
/// `Color.nw.textPrimary` (or `.nw.textPrimary` wherever a `ShapeStyle` or `Color` is expected).
///
/// Never hardcode a color in a view: add a role to `ThemeColors` (filled in both variants of
/// every theme) or a derived color here.
public final class NWPalette: Sendable {
    // Surfaces
    public let bgBase: Color
    public let bgWindow: Color
    public let bgRaised: Color
    public let bgSunken: Color
    public let bgBubble: Color
    public let bgHover: Color
    public let bgSelected: Color
    /// SettingsProjects' selected navigation row; custom themes keep their selection role.
    public let settingsNavSelected: Color
    /// Muted Settings metadata in SettingsProjects; custom themes keep textTertiary.
    public let settingsMuted: Color
    /// ProjectInstructions' divider and plain Markdown body.
    public let projectDivider: Color
    public let projectRowDivider: Color
    public let subagentFailureTile: Color
    public let subagentFailureBorder: Color
    public let projectCookieDanger: Color
    public let projectCookieConfirm: Color
    public let projectCookieConfirmHover: Color
    public let projectCookieConfirmTextHover: Color
    public let projectCookieShade: Color
    public let projectEditorBackground: Color
    public let projectEditorHeader: Color
    public let projectMarkdownHeading: Color
    public let projectMarkdownCode: Color
    public let projectInstructionText: Color
    // Lines and text
    public let lineSubtle: Color
    public let lineStrong: Color
    public let textPrimary: Color
    public let textSecondary: Color
    public let textTertiary: Color
    public let textOnLantern: Color
    // Brand and state
    public let lantern: Color
    public let lanternText: Color
    public let lanternTint: Color
    public let running: Color
    public let runningTint: Color
    public let textOnRunning: Color
    public let done: Color
    public let doneTint: Color
    public let failed: Color
    public let failedTint: Color
    // Syntax
    public let synKeyword: Color
    public let synType: Color
    public let synString: Color
    public let synNumber: Color
    public let synFunction: Color
    public let synComment: Color
    public let synVariable: Color
    public let synOperator: Color
    public let synPunctuation: Color

    // Derived (not theme roles)
    /// The keyboard focus ring: running at 60% (dark) / 50% (light).
    public let focusRing: Color
    /// A pane divider bordering the focused pane: running at 34% in both appearances.
    public let focusDivider: Color
    /// `.nwPopover()`'s shadow, the only shadow in the system.
    public let popoverShadow: Color
    /// Behind the command palette: black at 30% in both appearances (Composer board).
    public let scrim: Color
    /// Behind the Export sheet: black at 55% in both appearances (DZExport).
    public let sheetScrim: Color
    /// Labels on a `failed` fill (the dangerFill button, the failed count badge).
    public let textOnFailed: Color
    /// The design canvas's selection handles: white squares on a `running` line (NWDesignTool).
    public let selectionHandle: Color
    /// The primary button's fill lifted on hover and sunk while pressed, and the dangerFill
    /// button's sunk fill (the Controls board's hexes; `NWButtonFills`).
    public let lanternHover: Color
    public let lanternPressed: Color
    public let failedPressed: Color
    /// The switch knob, on and off.
    public let knobOn: Color
    public let knobOff: Color
    /// The switch and slider knob's small drop shadow.
    public let knobShadow: Color
    /// The window controls where Shepherd draws them itself (the maximized side pane's rail,
    /// ChangesWide): macOS's close, minimize and zoom colors in both appearances, and the glyph
    /// that shows on them while hovered.
    public let windowClose: Color
    public let windowMinimize: Color
    public let windowZoom: Color
    public let windowControlGlyph: Color
    /// The context split's parts (ContextDetails): the system prompt and tools in
    /// `textTertiary`, instructions, messages, and tool results in the syntax keyword, function,
    /// and type colors. Swatches and bar segments only; never text.
    public let contextSystem: Color
    public let contextInstructions: Color
    public let contextMessages: Color
    public let contextToolResults: Color
    /// The parts a thread's written files, reasoning, screenshots and the rest add (the same
    /// rule: swatches and bar segments, never text): the syntax string and variable colors, the
    /// terminal's cyan, and a `lineStrong` bar for what is not itemized.
    public let contextToolCalls: Color
    public let contextReasoning: Color
    public let contextImages: Color
    public let contextOther: Color

    public init(_ theme: ThemeDefinition) {
        let (l, d) = (theme.light.colors, theme.dark.colors)
        let (ls, ds) = (theme.light.syntax, theme.dark.syntax)
        func role(_ key: KeyPath<ThemeColors, String>) -> Color { Color(light: l[keyPath: key], dark: d[keyPath: key]) }
        func syn(_ key: KeyPath<SyntaxColors, String>) -> Color { Color(light: ls[keyPath: key], dark: ds[keyPath: key]) }
        func mix(_ first: KeyPath<ThemeColors, String>, _ second: KeyPath<ThemeColors, String>, portion: Double, brightness: Double = 1) -> Color {
            func value(_ colors: ThemeColors) -> HexColor {
                let invalid = HexColor(red: 1, green: 0, blue: 1)
                let a = HexColor(colors[keyPath: first]) ?? invalid, b = HexColor(colors[keyPath: second]) ?? invalid
                return HexColor(red: (a.red * portion + b.red * (1 - portion)) * brightness,
                                green: (a.green * portion + b.green * (1 - portion)) * brightness,
                                blue: (a.blue * portion + b.blue * (1 - portion)) * brightness)
            }
            return Color(light: value(l), dark: value(d))
        }

        bgBase = role(\.bgBase)
        bgWindow = role(\.bgWindow)
        bgRaised = role(\.bgRaised)
        bgSunken = role(\.bgSunken)
        bgBubble = role(\.bgBubble)
        bgHover = role(\.bgHover)
        bgSelected = role(\.bgSelected)
        settingsNavSelected = bgSelected
        lineSubtle = role(\.lineSubtle)
        lineStrong = role(\.lineStrong)
        textPrimary = role(\.textPrimary)
        textSecondary = role(\.textSecondary)
        textTertiary = role(\.textTertiary)
        settingsMuted = theme.id == "night-watch" ? Color(light: l.textTertiary, dark: "#767c85") : textTertiary
        projectDivider = theme.id == "night-watch" ? Color(light: l.lineSubtle, dark: "#22262a") : lineSubtle
        projectRowDivider = theme.id == "night-watch" ? Color(light: l.lineSubtle, dark: "#1b1e21") : lineSubtle
        func failedTile(_ colors: ThemeColors) -> HexColor {
            let color = HexColor(colors.failed) ?? HexColor(red: 1, green: 0, blue: 1)
            return HexColor(red: color.red, green: color.green, blue: color.blue, alpha: 0.12)
        }
        subagentFailureTile = Color(light: failedTile(l), dark: failedTile(d))
        subagentFailureBorder = theme.id == "night-watch" ? Color(light: l.failedTint, dark: "#5a2a2a") : mix(\.failed, \.bgWindow, portion: 0.34)
        projectCookieDanger = mix(\.failed, \.textPrimary, portion: 0.8)
        projectCookieConfirm = mix(\.failed, \.textOnLantern, portion: 0.75)
        projectCookieConfirmHover = mix(\.failed, \.textOnLantern, portion: 0.75, brightness: 0.94)
        projectCookieConfirmTextHover = mix(\.textOnRunning, \.textOnRunning, portion: 1, brightness: 0.94)
        let shadeLight = HexColor(l.bgBase) ?? HexColor(red: 1, green: 0, blue: 1)
        let shadeDark = HexColor(d.bgBase) ?? HexColor(red: 1, green: 0, blue: 1)
        projectCookieShade = Color(light: HexColor(red: shadeLight.red, green: shadeLight.green, blue: shadeLight.blue, alpha: 0.65),
                                   dark: HexColor(red: shadeDark.red, green: shadeDark.green, blue: shadeDark.blue, alpha: 0.65))
        projectEditorBackground = theme.id == "night-watch" ? Color(light: l.bgSunken, dark: "#111316") : bgSunken
        projectEditorHeader = theme.id == "night-watch" ? Color(light: l.bgRaised, dark: "#15171a") : bgRaised
        projectMarkdownHeading = theme.id == "night-watch" ? Color(light: ls.type, dark: "#79aaff") : syn(\.type)
        projectMarkdownCode = theme.id == "night-watch" ? Color(light: ls.string, dark: "#efb550") : syn(\.string)
        projectInstructionText = theme.id == "night-watch" ? Color(light: l.textPrimary, dark: "#b7bec7") : textSecondary
        textOnLantern = role(\.textOnLantern)
        lantern = role(\.lantern)
        lanternText = role(\.lanternText)
        lanternTint = role(\.lanternTint)
        running = role(\.running)
        runningTint = role(\.runningTint)
        textOnRunning = role(\.textOnRunning)
        done = role(\.done)
        doneTint = role(\.doneTint)
        failed = role(\.failed)
        failedTint = role(\.failedTint)

        synKeyword = syn(\.keyword)
        synType = syn(\.type)
        synString = syn(\.string)
        synNumber = syn(\.number)
        synFunction = syn(\.function)
        synComment = syn(\.comment)
        synVariable = syn(\.variable)
        synOperator = syn(\.operators)
        synPunctuation = syn(\.punctuation)

        let runningLight = HexColor(l.running) ?? HexColor(red: 0, green: 0, blue: 1)
        let runningDark = HexColor(d.running) ?? HexColor(red: 0, green: 0, blue: 1)
        focusRing = Color(light: HexColor(red: runningLight.red, green: runningLight.green, blue: runningLight.blue, alpha: 0.5),
                          dark: HexColor(red: runningDark.red, green: runningDark.green, blue: runningDark.blue, alpha: 0.6))
        focusDivider = Color(light: HexColor(red: runningLight.red, green: runningLight.green, blue: runningLight.blue, alpha: 0.34),
                             dark: HexColor(red: runningDark.red, green: runningDark.green, blue: runningDark.blue, alpha: 0.34))
        popoverShadow = Color(light: HexColor(red: 20 / 255, green: 20 / 255, blue: 20 / 255, alpha: 0.12),
                              dark: HexColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        let scrimBlack = HexColor(red: 0, green: 0, blue: 0, alpha: 0.3)
        scrim = Color(light: scrimBlack, dark: scrimBlack)
        let sheetBlack = HexColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        sheetScrim = Color(light: sheetBlack, dark: sheetBlack)
        textOnFailed = Color(light: "#ffffff", dark: "#ffffff")
        selectionHandle = Color(light: "#ffffff", dark: "#ffffff")
        lanternHover = Color(light: NWButtonFills.lanternHover.light, dark: NWButtonFills.lanternHover.dark)
        lanternPressed = Color(light: NWButtonFills.lanternPressed.light, dark: NWButtonFills.lanternPressed.dark)
        failedPressed = Color(light: NWButtonFills.failedPressed.light, dark: NWButtonFills.failedPressed.dark)
        knobOn = Color(light: "#ffffff", dark: "#ffffff")
        knobOff = Color(light: "#ffffff", dark: "#c9ccd1")
        knobShadow = Color(light: HexColor(red: 0, green: 0, blue: 0, alpha: 0.2), dark: HexColor(red: 0, green: 0, blue: 0, alpha: 0.3))
        windowClose = Color(light: "#ff5f57", dark: "#ff5f57")
        windowMinimize = Color(light: "#febc2e", dark: "#febc2e")
        windowZoom = Color(light: "#28c840", dark: "#28c840")
        let glyph = HexColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        windowControlGlyph = Color(light: glyph, dark: glyph)
        contextSystem = textTertiary
        contextInstructions = synKeyword
        contextMessages = synFunction
        contextToolResults = synType
        contextToolCalls = synString
        // The syntax blues are taken (messages, and the number color is a blue beside them): the terminal's cyan is the one hue left.
        let (lp, dp) = (theme.light.terminal.palette, theme.dark.terminal.palette)
        contextReasoning = lp.count > 6 && dp.count > 6 ? Color(light: lp[6], dark: dp[6]) : synNumber
        contextImages = synVariable
        contextOther = role(\.lineStrong)
    }
}

/// The filled buttons' hover and pressed fills, as the Controls board draws them (light, dark):
/// primary lifts on hover and sinks while pressed; dangerFill stays put on hover and sinks.
enum NWButtonFills {
    static let lanternHover = (light: "#eca63a", dark: "#f7b84f")
    static let lanternPressed = (light: "#cf8a1c", dark: "#d9922a")
    static let failedPressed = (light: "#bf3a35", dark: "#d24f4b")
}

extension Color {
    /// A color that follows the appearance of the view drawing it. Strings are `#RRGGBB` or
    /// `#RRGGBBAA`; an invalid string renders magenta so it cannot hide.
    public init(light: String, dark: String) {
        let invalid = HexColor(red: 1, green: 0, blue: 1)
        self.init(light: HexColor(light) ?? invalid, dark: HexColor(dark) ?? invalid)
    }

    init(light: HexColor, dark: HexColor) {
        #if canImport(AppKit)
        let lightColor = NSColor(srgbRed: light.red, green: light.green, blue: light.blue, alpha: light.alpha)
        let darkColor = NSColor(srgbRed: dark.red, green: dark.green, blue: dark.blue, alpha: dark.alpha)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } == true ? darkColor : lightColor
        })
        #elseif canImport(UIKit)
        let lightColor = UIColor(red: light.red, green: light.green, blue: light.blue, alpha: light.alpha)
        let darkColor = UIColor(red: dark.red, green: dark.green, blue: dark.blue, alpha: dark.alpha)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
        #endif
    }
}

extension ShapeStyle where Self == Color {
    /// The current theme's resolved palette: `Color.nw.textPrimary`, or `.nw.textSecondary`
    /// wherever a `Color` or `ShapeStyle` is expected.
    @MainActor public static var nw: NWPalette { ThemeStore.shared.palette }
}
