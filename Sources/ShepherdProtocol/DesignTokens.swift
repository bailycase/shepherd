import Foundation

/// A design's tokens as Tweak snaps to them: the CSS custom properties its boards and its
/// project's stylesheets declare (`--accent: #4f46e5`, `--space-6: 24px`), read the way the
/// design agent's `design_check` reads them. A color is always one of these, never a free hex.
public struct DesignTokens: Hashable, Sendable {
    public struct Color: Hashable, Sendable {
        /// The custom property, `--accent`.
        public let name: String
        /// `#rrggbb`, or `#rrggbbaa` when it isn't opaque.
        public let hex: String

        public init(name: String, hex: String) {
            self.name = name
            self.hex = hex
        }

        /// The name without its dashes, as a chip shows it ("accent").
        public var title: String { String(name.drop(while: { $0 == "-" })) }
    }

    public struct Length: Hashable, Sendable {
        public let name: String
        public let px: Double

        public init(name: String, px: Double) {
            self.name = name
            self.px = px
        }
    }

    /// What a length token is for, by its name.
    public enum Role: Sendable, CaseIterable {
        case spacing, radius, text
    }

    /// In the order declared; a name declared twice keeps its first value.
    public private(set) var colors: [Color]
    public private(set) var lengths: [Length]

    public init(colors: [Color] = [], lengths: [Length] = []) {
        self.colors = []
        self.lengths = []
        for color in colors { add(color) }
        for length in lengths { add(length) }
    }

    public var isEmpty: Bool { colors.isEmpty && lengths.isEmpty }

    /// Custom properties declared in `css`: a color for each hex value, a length for each px or
    /// rem value (16px to the rem).
    public static func read(css: String) -> DesignTokens {
        var tokens = DesignTokens()
        tokens.read(css)
        return tokens
    }

    /// Custom properties a board declares in its `<style>` blocks (its helmet's among them).
    public static func read(board source: String) -> DesignTokens {
        var tokens = DesignTokens()
        var rest = source[...]
        while let open = rest.range(of: "<style", options: .caseInsensitive),
              let close = rest[open.upperBound...].range(of: "</style", options: .caseInsensitive) {
            let body = rest[open.upperBound..<close.lowerBound]
            if let tagEnd = body.firstIndex(of: ">") { tokens.read(String(body[body.index(after: tagEnd)...])) }
            rest = rest[close.upperBound...]
        }
        return tokens
    }

    /// Both sets: `self` first, then what `other` adds.
    public func merged(with other: DesignTokens) -> DesignTokens {
        var out = self
        for color in other.colors { out.add(color) }
        for length in other.lengths { out.add(length) }
        return out
    }

    public func declares(_ name: String) -> Bool {
        colors.contains { $0.name == name } || lengths.contains { $0.name == name }
    }

    // MARK: Scales

    /// The lengths for a role, ascending and unique: those named for it (`--space-4`, `--gap-l`,
    /// `--radius-m`, `--text-lg`), else, for spacing, every length not named for another role.
    /// Empty when the design declares none.
    public func scale(_ role: Role) -> [Double] {
        let named = lengths.filter { Self.role(of: $0.name) == role }
        let chosen = !named.isEmpty ? named : role == .spacing ? lengths.filter { Self.role(of: $0.name) == nil } : []
        return Array(Set(chosen.map(\.px))).sorted()
    }

    /// Shepherd's own scales for a design that declares none of a role: a 4pt grid for spacing,
    /// the usual radii, and a type ramp.
    public static let fallback: [Role: [Double]] = [
        .spacing: [0, 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48, 56, 64],
        .radius: [0, 2, 4, 6, 8, 10, 12, 16, 20, 24, 999],
        .text: [11, 12, 13, 14, 15, 16, 18, 20, 24, 28, 32, 40, 48],
    ]

    /// The role's scale, or Shepherd's fallback when the design declares none.
    public func scaleOrFallback(_ role: Role) -> (values: [Double], fromTokens: Bool) {
        let own = scale(role)
        return own.isEmpty ? (Self.fallback[role] ?? [], false) : (own, true)
    }

    static func role(of name: String) -> Role? {
        let lower = name.lowercased()
        if ["radius", "radii", "round", "corner"].contains(where: lower.contains) { return .radius }
        if ["font", "text", "type", "fs-", "leading"].contains(where: lower.contains) { return .text }
        if ["space", "spacing", "gap", "pad", "margin", "gutter", "inset", "sp-"].contains(where: lower.contains) { return .spacing }
        return nil
    }

    /// The value of `scale` nearest `value` (the lower on a tie); `value` when the scale is empty.
    public static func snap(_ value: Double, to scale: [Double]) -> Double {
        scale.min { a, b in
            let da = abs(a - value), db = abs(b - value)
            return da != db ? da < db : a < b
        } ?? value
    }

    /// The length token for `px` in `role`, when one declares it.
    public func length(_ px: Double, role: Role) -> Length? {
        let named = lengths.filter { $0.px == px && Self.role(of: $0.name) == role }
        return named.first ?? lengths.first { $0.px == px && Self.role(of: $0.name) == nil }
    }

    // MARK: Values as written

    /// A CSS length as px: `24px`, `1.5rem`, `0`, or `var(--space-6)` when a token names it.
    public func px(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let name = Self.variable(value) { return lengths.first { $0.name == name }?.px }
        if value == "0" { return 0 }
        if value.hasSuffix("px"), let number = Double(value.dropLast(2)) { return number }
        if value.hasSuffix("rem"), let number = Double(value.dropLast(3)) { return number * 16 }
        return nil
    }

    /// The first length of a shorthand (`20px 24px` → 20).
    public func firstPx(_ text: String) -> Double? {
        text.split(separator: " ").first.flatMap { px(String($0)) }
    }

    /// The color token a written color is: `var(--accent)` by name, a hex by value.
    public func color(_ text: String) -> Color? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if let name = Self.variable(value.lowercased()) { return colors.first { $0.name.lowercased() == name } }
        guard let hex = Self.normalizedHex(value) else { return nil }
        return colors.first { $0.hex == hex }
    }

    /// `--name` when `value` is `var(--name)` (a fallback after a comma is ignored).
    static func variable(_ value: String) -> String? {
        guard value.hasPrefix("var("), value.hasSuffix(")") else { return nil }
        let inner = value.dropFirst(4).dropLast().split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return inner.hasPrefix("--") ? inner : nil
    }

    /// `#abc`, `#aabbcc`, `#aabbccdd` lower-cased and expanded; an opaque alpha dropped.
    public static func normalizedHex(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.hasPrefix("#") else { return nil }
        var hex = String(text.dropFirst())
        guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        if hex.count == 8, hex.hasSuffix("ff") { hex = String(hex.prefix(6)) }
        return "#" + hex
    }

    // MARK: Reading

    private mutating func read(_ css: String) {
        let text = css as NSString
        for match in Self.declaration.matches(in: css, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1))
            let value = text.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let hex = Self.normalizedHex(value) {
                add(Color(name: name, hex: hex))
            } else if let px = px(value), px >= 0, !value.hasPrefix("var(") {
                add(Length(name: name, px: px))
            }
        }
    }

    private static let declaration = try! NSRegularExpression(pattern: "(--[A-Za-z0-9_-]+)\\s*:\\s*([^;{}]+)")

    private mutating func add(_ color: Color) {
        guard !colors.contains(where: { $0.name == color.name }) else { return }
        colors.append(color)
    }

    private mutating func add(_ length: Length) {
        guard !lengths.contains(where: { $0.name == length.name }) else { return }
        lengths.append(length)
    }
}
