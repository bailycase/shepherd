import SwiftUI
import Observation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The selected theme and the user's text scale and density. Views read colors, fonts, and
/// sizes through `Tokens`, `Fonts`, and `Metrics`, which read this store, so a change here
/// re-renders exactly the views that used it. Light/dark is not stored: every color is dynamic
/// and resolves against the view's own appearance.
@MainActor @Observable
public final class ThemeStore {
    public static let shared = ThemeStore()

    public private(set) var theme: ThemeDefinition
    /// Settings ▸ Appearance ▸ Text size; multiplies every font size.
    public var textScale: CGFloat = 1
    /// Settings ▸ Appearance ▸ Density; multiplies row heights.
    public var density: CGFloat = 1

    @ObservationIgnored private var colors: [KeyPath<ThemeColors, String>: Color] = [:]
    @ObservationIgnored private var syntaxColors: [KeyPath<SyntaxColors, String>: Color] = [:]

    public init(theme: ThemeDefinition = .basalt) {
        self.theme = theme
    }

    public func select(_ theme: ThemeDefinition) {
        guard theme != self.theme else { return }
        colors = [:]
        syntaxColors = [:]
        self.theme = theme
    }

    func color(_ role: KeyPath<ThemeColors, String>) -> Color {
        let theme = self.theme
        if let cached = colors[role] { return cached }
        let color = Color(light: theme.light.colors[keyPath: role], dark: theme.dark.colors[keyPath: role])
        colors[role] = color
        return color
    }

    func syntax(_ role: KeyPath<SyntaxColors, String>) -> Color {
        let theme = self.theme
        if let cached = syntaxColors[role] { return cached }
        let color = Color(light: theme.light.syntax[keyPath: role], dark: theme.dark.syntax[keyPath: role])
        syntaxColors[role] = color
        return color
    }
}

extension Color {
    /// A solid `#RRGGBB` color; invalid strings render as magenta so they cannot hide.
    public init(hex: String) {
        let parsed = HexColor(hex)
        self.init(.sRGB, red: parsed?.red ?? 1, green: parsed?.green ?? 0, blue: parsed?.blue ?? 1, opacity: 1)
    }

    /// A color that follows the appearance of the view drawing it.
    public init(light: String, dark: String) {
        self.init(lightRGBA: Self.rgba(light, 1), darkRGBA: Self.rgba(dark, 1))
    }

    /// Dynamic color from explicit components (used for shadows and scrims, which differ in
    /// strength between light and dark rather than in hue).
    init(lightRGBA light: (Double, Double, Double, Double), darkRGBA dark: (Double, Double, Double, Double)) {
        #if canImport(AppKit)
        let lightColor = NSColor(srgbRed: light.0, green: light.1, blue: light.2, alpha: light.3)
        let darkColor = NSColor(srgbRed: dark.0, green: dark.1, blue: dark.2, alpha: dark.3)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } == true ? darkColor : lightColor
        })
        #elseif canImport(UIKit)
        let lightColor = UIColor(red: light.0, green: light.1, blue: light.2, alpha: light.3)
        let darkColor = UIColor(red: dark.0, green: dark.1, blue: dark.2, alpha: dark.3)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
        #endif
    }

    private static func rgba(_ hex: String, _ alpha: Double) -> (Double, Double, Double, Double) {
        let parsed = HexColor(hex)
        return (parsed?.red ?? 1, parsed?.green ?? 0, parsed?.blue ?? 1, alpha)
    }
}
