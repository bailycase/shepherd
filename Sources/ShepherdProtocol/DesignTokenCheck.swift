import Foundation

// Token enforcement on a board write (docs/designs.md › Token enforcement): the colors and px
// sizes a board writes that the design's installed systems don't hold, found the way the design
// agent's `design_check` finds them, narrowed to what one write introduced, and snapped to the
// nearest token on request.

/// What a write does about off-system values it introduces.
public enum DesignTokenMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// Succeed, and list the values this write introduced (the default).
    case warn
    /// Replace each introduced value that has a nearest token with `var(--token)`, and list each replacement.
    case snap
    /// Refuse the write, listing the values.
    case strict
}

/// The tokens a board is checked against: the colors (and dark values) and px lengths of the
/// design's installed systems, each by the custom property its tokens.css declares.
public struct DesignTokenSet: Hashable, Sendable {
    public struct Color: Hashable, Sendable {
        public let name: String
        /// `#rrggbb`, or `#rrggbbaa` when it isn't opaque.
        public let hex: String
        /// A dark variant's value: on-system, but never what a snap picks.
        public let dark: Bool

        public init(name: String, hex: String, dark: Bool = false) {
            self.name = name
            self.hex = hex
            self.dark = dark
        }
    }

    public struct Length: Hashable, Sendable {
        public let name: String
        public let px: Double
        public let role: DesignTokens.Role?

        public init(name: String, px: Double, role: DesignTokens.Role?) {
            self.name = name
            self.px = px
            self.role = role
        }
    }

    public let colors: [Color]
    public let lengths: [Length]
    /// "night-watch", or "night-watch + acme-web": what the report says it checked against.
    public let source: String

    public init(colors: [Color], lengths: [Length], source: String) {
        self.colors = colors
        self.lengths = lengths
        self.source = source
    }

    /// The tokens of the systems a design has installed (`system_read`'s "installed").
    public init(systems: [DesignSystemInstalled]) {
        var colors: [Color] = []
        var lengths: [Length] = []
        var names: [String] = []
        for system in systems {
            guard let tokens = system.tokens else { continue }
            names.append(system.namespace)
            let read = tokens.designTokens
            colors += read.colors.map { Color(name: $0.name, hex: $0.hex) }
            for color in tokens.colors {
                if let dark = color.dark.flatMap(DesignTokens.normalizedHex) {
                    colors.append(Color(name: DesignSystemTokens.cssName(color.name), hex: dark, dark: true))
                }
            }
            lengths += read.lengths.map { Length(name: $0.name, px: $0.px, role: DesignTokens.role(of: $0.name)) }
        }
        self.init(colors: colors, lengths: lengths, source: names.joined(separator: " + "))
    }

    public var isEmpty: Bool { colors.isEmpty && lengths.isEmpty }

    func holds(hex: String) -> Bool { colors.contains { $0.hex == hex } }
    func holds(px: Double) -> Bool { lengths.contains { abs($0.px) == px } }

    /// The color token nearest `hex` by RGB distance among the light values, "--accent #4f46e5".
    func nearestColor(to hex: String) -> Color? {
        guard let target = DesignTokenCheck.rgb(hex) else { return nil }
        var best: (color: Color, distance: Int)?
        for color in colors where !color.dark {
            guard let other = DesignTokenCheck.rgb(color.hex) else { continue }
            let d = (target.0 - other.0) * (target.0 - other.0) + (target.1 - other.1) * (target.1 - other.1)
                + (target.2 - other.2) * (target.2 - other.2)
            if best == nil || d < best!.distance { best = (color, d) }
        }
        return best?.color
    }

    /// The length token nearest `px` for a property's role: those named for it, else (spacing
    /// only) the ones named for no role; the lower on a tie.
    func nearestLength(to px: Double, role: DesignTokens.Role?) -> Length? {
        guard let role else { return nil }
        let named = lengths.filter { $0.role == role }
        let pool = !named.isEmpty ? named : role == .spacing ? lengths.filter { $0.role == nil } : []
        return pool.min { a, b in
            let da = abs(a.px - px), db = abs(b.px - px)
            return da != db ? da < db : a.px < b.px
        }
    }

    /// A token as the report says its nearest: "--accent #4f46e5", "--space-3 12px".
    func described(_ color: Color) -> String { "\(color.name) \(color.hex)" }
    func described(_ length: Length) -> String { "\(length.name) \(DesignTokenCheck.number(length.px))px" }
}

/// One off-system value in a board: where it is and what it is.
public struct DesignTokenOccurrence: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case color, size }

    public var kind: Kind
    /// A color's normalized hex, or a size as written ("13px").
    public var value: String
    /// The size, in px.
    public var px: Double?
    /// Where the literal is, in UTF-16 units of the source, and how long it is.
    public var location: Int
    public var length: Int
    /// The board's line (from 1).
    public var line: Int
    /// The CSS property a size is in; nil for a color.
    public var property: String?
    /// Whether it is in CSS (a style attribute or block), where `var(--token)` works.
    public var inCSS: Bool
}

/// An off-system value a write introduced, as the report lists it.
public struct DesignTokenFinding: Hashable, Sendable, Codable {
    public var value: String
    public var count: Int
    public var lines: [Int]
    public var nearest: String?

    public init(value: String, count: Int, lines: [Int], nearest: String? = nil) {
        self.value = value
        self.count = count
        self.lines = lines
        self.nearest = nearest
    }
}

/// A value a snap replaced.
public struct DesignTokenReplacement: Hashable, Sendable, Codable {
    public var from: String
    public var to: String
    public var line: Int
    /// The token's own value, "#4f46e5" or "12px".
    public var token: String

    public init(from: String, to: String, line: Int, token: String) {
        self.from = from
        self.to = to
        self.line = line
        self.token = token
    }
}

public enum DesignTokenCheck {
    // MARK: Finding

    private static let hex = try! NSRegularExpression(
        pattern: #"(^|[^&\w#])#([0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})(?![0-9A-Za-z_-])"#)
    private static let sized = try! NSRegularExpression(
        pattern: #"(?:^|[;{\s"'])((?:font-size|gap|row-gap|column-gap|padding(?:-[a-z]+)?|margin(?:-[a-z]+)?|border(?:-[a-z]+)*-radius|letter-spacing)\s*:\s*)([^;"'}]+)"#,
        options: [.caseInsensitive])
    private static let pixels = try! NSRegularExpression(pattern: #"(-?\d*\.?\d+)px\b"#)

    /// The regions of a board that say a color or a size, as `design_check` reads them.
    private static let regions: [(pattern: NSRegularExpression, css: Bool)] = [
        (try! NSRegularExpression(pattern: #"\sstyle\s*=\s*"([^"]*)""#, options: [.caseInsensitive]), true),
        (try! NSRegularExpression(pattern: #"\sstyle\s*=\s*'([^']*)'"#, options: [.caseInsensitive]), true),
        (try! NSRegularExpression(pattern: #"<style\b[^>]*>([\s\S]*?)</style>"#, options: [.caseInsensitive]), true),
        (try! NSRegularExpression(pattern: #"<script\b[^>]*>([\s\S]*?)</script>"#, options: [.caseInsensitive]), false),
        (try! NSRegularExpression(pattern: #"\sdata-props\s*=\s*'([^']*)'"#, options: [.caseInsensitive]), false),
        (try! NSRegularExpression(pattern: #"\s(?:fill|stroke|stop-color|flood-color|lighting-color|color)\s*=\s*"([^"]*)""#,
                                  options: [.caseInsensitive]), false),
    ]

    /// Every color and px size in `source` that `tokens` don't hold, in source order. A size is
    /// checked only in the properties of spacing, radius and type, never `1px` or less, never a
    /// value with a hole in it, and only when the tokens declare any length at all.
    public static func occurrences(in source: String, tokens: DesignTokenSet) -> [DesignTokenOccurrence] {
        let text = source as NSString
        let lines = LineIndex(text)
        var found: [Int: DesignTokenOccurrence] = [:]
        for region in regions {
            for match in region.pattern.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                let body = match.range(at: 1)
                guard body.location != NSNotFound else { continue }
                let chunk = text.substring(with: body)
                let chunkText = chunk as NSString
                let whole = NSRange(location: 0, length: chunkText.length)
                for color in hex.matches(in: chunk, range: whole) {
                    let digits = color.range(at: 2)
                    guard let normalized = DesignTokens.normalizedHex("#" + chunkText.substring(with: digits)),
                          !tokens.holds(hex: normalized) else { continue }
                    let at = body.location + digits.location - 1
                    found[at] = DesignTokenOccurrence(kind: .color, value: normalized, px: nil, location: at, length: digits.length + 1,
                                                      line: lines.line(at), property: nil, inCSS: region.css)
                }
                guard !tokens.lengths.isEmpty else { continue }
                for declaration in sized.matches(in: chunk, range: whole) {
                    let property = chunkText.substring(with: declaration.range(at: 1))
                        .replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces).lowercased()
                    let valueRange = declaration.range(at: 2)
                    let value = chunkText.substring(with: valueRange)
                    if value.contains("{{") { continue }
                    let valueText = value as NSString
                    for size in pixels.matches(in: value, range: NSRange(location: 0, length: valueText.length)) {
                        guard let signed = Double(valueText.substring(with: size.range(at: 1))) else { continue }
                        let px = abs(signed)
                        if px <= 1 || tokens.holds(px: px) { continue }
                        let at = body.location + valueRange.location + size.range.location
                        found[at] = DesignTokenOccurrence(kind: .size, value: "\(number(px))px", px: signed, location: at,
                                                          length: size.range.length, line: lines.line(at), property: property,
                                                          inCSS: region.css)
                    }
                }
            }
        }
        return found.values.sorted { $0.location < $1.location }
    }

    // MARK: What a write introduced

    /// The result of holding a write to the design's tokens.
    public struct Enforcement: Hashable, Sendable {
        /// The source to write: with `snap`, the introduced values replaced where a token fits.
        public var source: String
        /// Off-system values the write introduced and left in the board, grouped by value.
        public var remaining: [DesignTokenFinding]
        /// What a snap replaced.
        public var replacements: [DesignTokenReplacement]
    }

    /// Works out the off-system values `new` introduces over `old` (every one in a new board),
    /// and under `.snap` replaces each that has a nearest token. A value counts as introduced
    /// when it sits on a line the write added and is not matched by one of the same value on a
    /// line it removed, so a line merely touched keeps the values it already had. With `all`,
    /// every off-system value in `new` counts (`design_check`'s snap).
    public static func enforce(_ mode: DesignTokenMode, tokens: DesignTokenSet, old: String?, new: String,
                               all: Bool = false) -> Enforcement {
        let found = occurrences(in: new, tokens: tokens)
        var introduced: [DesignTokenOccurrence]
        if all || old == nil {
            introduced = found
        } else {
            let changed = DesignTextDiff.changedLines(old: old ?? "", new: new)
            var allowance: [String: Int] = [:]
            for occurrence in occurrences(in: old ?? "", tokens: tokens) where changed.removed.contains(occurrence.line) {
                allowance[occurrence.value, default: 0] += 1
            }
            introduced = []
            for occurrence in found where changed.inserted.contains(occurrence.line) {
                if let left = allowance[occurrence.value], left > 0 {
                    allowance[occurrence.value] = left - 1
                } else {
                    introduced.append(occurrence)
                }
            }
        }
        guard mode == .snap, !introduced.isEmpty else {
            return Enforcement(source: new, remaining: findings(introduced, tokens: tokens), replacements: [])
        }
        let text = NSMutableString(string: new)
        var replacements: [DesignTokenReplacement] = []
        var left: [DesignTokenOccurrence] = []
        for occurrence in introduced.sorted(by: { $0.location > $1.location }) {
            guard let swap = snap(occurrence, tokens: tokens) else { left.append(occurrence); continue }
            text.replaceCharacters(in: NSRange(location: occurrence.location, length: occurrence.length), with: swap.to)
            replacements.append(DesignTokenReplacement(from: occurrence.value, to: swap.to, line: occurrence.line, token: swap.token))
        }
        return Enforcement(source: text as String, remaining: findings(left.sorted { $0.location < $1.location }, tokens: tokens),
                           replacements: replacements.reversed())
    }

    /// `var(--token)` for an occurrence, and the token's value; nil when nothing fits: outside
    /// CSS, a color with transparency, a negative size, or no token for its role.
    private static func snap(_ occurrence: DesignTokenOccurrence, tokens: DesignTokenSet) -> (to: String, token: String)? {
        guard occurrence.inCSS else { return nil }
        switch occurrence.kind {
        case .color:
            guard occurrence.value.count == 7, let color = tokens.nearestColor(to: occurrence.value), isCustomProperty(color.name) else { return nil }
            return ("var(\(color.name))", color.hex)
        case .size:
            guard let px = occurrence.px, px > 0, let property = occurrence.property,
                  let length = tokens.nearestLength(to: px, role: role(of: property)), isCustomProperty(length.name) else { return nil }
            return ("var(\(length.name))", "\(number(length.px))px")
        }
    }

    /// What a CSS property's lengths are for; nil where no token fits (letter-spacing).
    static func role(of property: String) -> DesignTokens.Role? {
        if property.contains("radius") { return .radius }
        if property == "font-size" { return .text }
        if property == "letter-spacing" { return nil }
        return .spacing
    }

    private static func isCustomProperty(_ name: String) -> Bool {
        name.hasPrefix("--") && name.count > 2 && name.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D
        }
    }

    /// Occurrences grouped by value, in the order each first appears.
    static func findings(_ occurrences: [DesignTokenOccurrence], tokens: DesignTokenSet) -> [DesignTokenFinding] {
        var order: [String] = []
        var groups: [String: [DesignTokenOccurrence]] = [:]
        for occurrence in occurrences {
            if groups[occurrence.value] == nil { order.append(occurrence.value) }
            groups[occurrence.value, default: []].append(occurrence)
        }
        return order.map { value in
            let group = groups[value] ?? []
            let nearest: String?
            if let first = group.first, first.kind == .color {
                nearest = tokens.nearestColor(to: value).map(tokens.described)
            } else if let first = group.first, let px = first.px {
                nearest = tokens.nearestLength(to: abs(px), role: first.property.flatMap(role(of:))).map(tokens.described)
            } else {
                nearest = nil
            }
            return DesignTokenFinding(value: value, count: group.count, lines: Array(Set(group.map(\.line))).sorted(), nearest: nearest)
        }
    }

    // MARK: Helpers

    static func rgb(_ hex: String) -> (Int, Int, Int)? {
        let digits = Array(hex.dropFirst())
        guard digits.count >= 6 else { return nil }
        func part(_ at: Int) -> Int? { Int(String(digits[at..<(at + 2)]), radix: 16) }
        guard let r = part(0), let g = part(2), let b = part(4) else { return nil }
        return (r, g, b)
    }

    static func number(_ value: Double) -> String {
        Int(exactly: value).map(String.init) ?? String(value)
    }

    /// Lines by UTF-16 offset.
    struct LineIndex {
        private let starts: [Int]

        init(_ text: NSString) {
            var starts = [0]
            var i = 0
            while i < text.length {
                if text.character(at: i) == 0x0A { starts.append(i + 1) }
                i += 1
            }
            self.starts = starts
        }

        func line(_ offset: Int) -> Int {
            var low = 0
            var high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) >> 1
                if starts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return low + 1
        }
    }
}
