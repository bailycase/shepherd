import Foundation

/// A parsed `#RRGGBB` or `#RRGGBBAA` color, with the WCAG math the contrast rules are written in.
/// Translucent roles (hover, selection, the state tints) carry their alpha in the last byte.
public struct HexColor: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(_ string: String) {
        var hex = Substring(string)
        if hex.hasPrefix("#") { hex = hex.dropFirst() }
        // Digits only: UInt64(_:radix:) would also take a leading "+" or "-".
        guard hex.count == 6 || hex.count == 8, hex.allSatisfy(\.isHexDigit),
              var value = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 6 { value = value << 8 | 0xFF }
        red = Double((value >> 24) & 0xFF) / 255
        green = Double((value >> 16) & 0xFF) / 255
        blue = Double((value >> 8) & 0xFF) / 255
        alpha = Double(value & 0xFF) / 255
    }

    public var isOpaque: Bool { alpha >= 1 }

    /// `#RRGGBB` (opaque) or `#RRGGBBAA`, lowercase.
    public var hexString: String {
        func byte(_ c: Double) -> String { String(format: "%02x", Int((c * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue) + (isOpaque ? "" : byte(alpha))
    }

    /// This color painted over an opaque `background` (source-over), as an opaque color.
    public func composited(over background: HexColor) -> HexColor {
        let a = alpha
        return HexColor(red: red * a + background.red * (1 - a),
                        green: green * a + background.green * (1 - a),
                        blue: blue * a + background.blue * (1 - a))
    }

    /// WCAG 2 relative luminance of the color's own components (alpha ignored; composite first).
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio, 1...21, of two opaque colors.
    public func contrast(with other: HexColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
