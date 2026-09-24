import Testing
@testable import ShepherdUI

/// Every built-in theme variant, named for test output. Add new built-ins to `themes`.
struct Variant: Sendable, CustomTestStringConvertible {
    static let themes: [ThemeDefinition] = [.nightWatch]
    static let all: [Variant] = themes.flatMap { [Variant(theme: $0, isDark: false), Variant(theme: $0, isDark: true)] }

    let theme: ThemeDefinition
    let isDark: Bool
    var value: ThemeVariant { theme.variant(dark: isDark) }
    var colors: ThemeColors { value.colors }
    var name: String { isDark ? "dark" : "light" }
    var testDescription: String { "\(theme.id)-\(name)" }

    typealias Role = KeyPath<ThemeColors, String>

    func color(_ role: Role) -> HexColor { HexColor(colors[keyPath: role])! }

    /// `role` as drawn: a translucent role is painted over `base` first.
    func painted(_ role: Role, over base: Role) -> HexColor {
        let color = color(role)
        return color.isOpaque ? color : color.composited(over: self.color(base))
    }

    /// WCAG contrast of `text` on `fill`, with a translucent fill painted over `base`.
    func contrast(_ text: Role, on fill: Role, over base: Role = \.bgWindow) -> Double {
        painted(text, over: base).contrast(with: painted(fill, over: base))
    }
}

extension ThemeDefinition: @retroactive CustomTestStringConvertible {
    public var testDescription: String { id }
}
