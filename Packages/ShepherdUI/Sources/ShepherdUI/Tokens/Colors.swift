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
    /// `.nwPopover()`'s shadow, the only shadow in the system.
    public let popoverShadow: Color
    /// Behind the command palette: black at 30% in both appearances (Composer board).
    public let scrim: Color
    /// Labels on a `failed` fill (the dangerFill button, the failed count badge).
    public let textOnFailed: Color
    /// The switch knob, on and off.
    public let knobOn: Color
    public let knobOff: Color
    /// The switch and slider knob's small drop shadow.
    public let knobShadow: Color

    public init(_ theme: ThemeDefinition) {
        let (l, d) = (theme.light.colors, theme.dark.colors)
        let (ls, ds) = (theme.light.syntax, theme.dark.syntax)
        func role(_ key: KeyPath<ThemeColors, String>) -> Color { Color(light: l[keyPath: key], dark: d[keyPath: key]) }
        func syn(_ key: KeyPath<SyntaxColors, String>) -> Color { Color(light: ls[keyPath: key], dark: ds[keyPath: key]) }

        bgBase = role(\.bgBase)
        bgWindow = role(\.bgWindow)
        bgRaised = role(\.bgRaised)
        bgSunken = role(\.bgSunken)
        bgBubble = role(\.bgBubble)
        bgHover = role(\.bgHover)
        bgSelected = role(\.bgSelected)
        lineSubtle = role(\.lineSubtle)
        lineStrong = role(\.lineStrong)
        textPrimary = role(\.textPrimary)
        textSecondary = role(\.textSecondary)
        textTertiary = role(\.textTertiary)
        textOnLantern = role(\.textOnLantern)
        lantern = role(\.lantern)
        lanternText = role(\.lanternText)
        lanternTint = role(\.lanternTint)
        running = role(\.running)
        runningTint = role(\.runningTint)
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
        popoverShadow = Color(light: HexColor(red: 20 / 255, green: 20 / 255, blue: 20 / 255, alpha: 0.12),
                              dark: HexColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        let scrimBlack = HexColor(red: 0, green: 0, blue: 0, alpha: 0.3)
        scrim = Color(light: scrimBlack, dark: scrimBlack)
        textOnFailed = Color(light: "#ffffff", dark: "#ffffff")
        knobOn = Color(light: "#ffffff", dark: "#ffffff")
        knobOff = Color(light: "#ffffff", dark: "#c9ccd1")
        knobShadow = Color(light: HexColor(red: 0, green: 0, blue: 0, alpha: 0.2), dark: HexColor(red: 0, green: 0, blue: 0, alpha: 0.3))
    }
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
