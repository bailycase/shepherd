import Testing
@testable import ShepherdDesign

/// Every built-in theme variant, named for test output. Add new built-ins to `themes`.
struct Variant: Sendable, CustomTestStringConvertible {
    static let themes: [ThemeDefinition] = [.basalt]
    static let all: [Variant] = themes.flatMap { [Variant(theme: $0, isDark: false), Variant(theme: $0, isDark: true)] }

    let theme: ThemeDefinition
    let isDark: Bool
    var value: ThemeVariant { theme.variant(dark: isDark) }
    var colors: ThemeColors { value.colors }
    var testDescription: String { "\(theme.id)-\(isDark ? "dark" : "light")" }

    func contrast(_ a: KeyPath<ThemeColors, String>, on b: KeyPath<ThemeColors, String>) -> Double {
        HexColor(colors[keyPath: a])!.contrast(with: HexColor(colors[keyPath: b])!)
    }
}

extension ThemeDefinition: CustomTestStringConvertible {
    public var testDescription: String { id }
}
