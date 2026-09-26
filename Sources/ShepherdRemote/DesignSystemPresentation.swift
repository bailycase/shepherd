import Foundation
import ShepherdProtocol

/// A design system's words as its page and cards show them (DZSystem), for the Mac and iOS.
public enum DesignSystemPresentation {
    /// "synced 4m ago", "synced just now", "synced Sep 19"; nil for a system never read from a
    /// project (a built-in, or one written without stylesheets). Re-sync is manual, so this is
    /// all that says how fresh it is.
    public static func synced(_ info: DesignSystemInfo, now: Date = Date(), locale: Locale = .current,
                              timeZone: TimeZone = .current) -> String? {
        guard let syncedAt = info.syncedAt else { return nil }
        return "synced " + InstructionsPresentation.age(syncedAt / 1000, now: now, locale: locale, timeZone: timeZone)
    }

    /// "11 colors, 4 type styles, 7 spacing and radius steps, 9 components".
    public static func counts(_ counts: DesignSystemCounts) -> String {
        [
            count(counts.colors, "color"),
            count(counts.type, "type style"),
            count(counts.lengths, "spacing and radius step"),
            count(counts.components, "component"),
        ].joined(separator: ", ")
    }

    /// A color's line under its name: "#4f46e5 · tokens.css:8", its value alone when nothing
    /// says where it came from.
    public static func detail(_ color: DesignSystemTokens.Color) -> String {
        color.value + (color.source.map { " · " + $0.label } ?? "")
    }

    /// A type style's size and weight: "26/700", "14".
    public static func detail(_ style: DesignSystemTokens.TypeStyle) -> String {
        number(style.size) + (style.weight.map { "/\($0)" } ?? "")
    }

    /// A step's value: "16px · tokens.css:20".
    public static func detail(_ step: DesignSystemTokens.Length) -> String {
        number(step.px) + "px" + (step.source.map { " · " + $0.label } ?? "")
    }

    // MARK: Colors

    /// A color as a card, a chip or a page draws it: its value and its dark variant, each a
    /// `#rrggbb` or `#rrggbbaa` hex.
    public struct Swatch: Hashable, Sendable {
        public var light: String
        public var dark: String

        public init(light: String, dark: String) {
            self.light = light
            self.dark = dark
        }

        /// The token's colors as hexes; nil when its value isn't a hex or an `rgb()` color.
        public init?(_ color: DesignSystemTokens.Color) {
            guard let light = DesignSystemPresentation.hex(color.value) else { return nil }
            self.light = light
            dark = color.dark.flatMap(DesignSystemPresentation.hex) ?? light
        }
    }

    /// The colors that stand for a system on its card and chip (NavDesigns, DZCanvas), at most
    /// `count`: its accent, its text, its background and a status color when it names them
    /// (`--accent`, `--text`, `--bg`, `--success`; the shortest name of each), then the rest in
    /// order. Colors that aren't a hex or `rgb()` are left out.
    public static func swatches(_ tokens: DesignSystemTokens?, count: Int) -> [Swatch] {
        guard let tokens, count > 0 else { return [] }
        let colors = tokens.colors.filter { Swatch($0) != nil }
        var picked: [DesignSystemTokens.Color] = []
        for role in roles {
            guard let found = colors.filter({ color in !picked.contains(color) && role.contains { words(color.name).contains($0) } })
                .min(by: { $0.name.count < $1.name.count }) else { continue }
            picked.append(found)
        }
        picked += colors.filter { !picked.contains($0) }
        return picked.prefix(count).compactMap(Swatch.init)
    }

    /// The color a system's specimens draw on (DZSystem's tiles): its background (`--bg`,
    /// `--background`, `--surface`, …), else its first light color; nil when it has none.
    public static func background(_ tokens: DesignSystemTokens?) -> Swatch? {
        guard let tokens else { return nil }
        let colors = tokens.colors.filter { Swatch($0) != nil }
        let named = colors.filter { color in roles[2].contains { words(color.name).contains($0) } }
            .min(by: { $0.name.count < $1.name.count })
        return named.flatMap(Swatch.init)
    }

    /// Accent, text, background, status: the words a token's name says its role in.
    private static let roles: [[String]] = [
        ["accent", "primary", "brand", "lantern"],
        ["text", "fg", "foreground", "ink"],
        ["bg", "background", "canvas", "base", "surface", "page"],
        ["success", "running", "positive", "info", "link"],
    ]

    /// A token's name as its words: `--bg-canvas` → ["bg", "canvas"].
    private static func words(_ name: String) -> [String] {
        name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// A CSS color as a hex: `#abc`, `#aabbcc`, `#aabbccdd`, or `rgb()`/`rgba()` with numbers
    /// (commas or spaces, a percent or fraction alpha). Nil for anything else (`hsl()`, a named
    /// color, `var()`).
    public static func hex(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hex = DesignTokens.normalizedHex(text) { return hex }
        guard text.hasPrefix("rgb"), let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
        let name = text[..<open]
        guard name == "rgb" || name == "rgba" else { return nil }
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
        let parts = inner.split { $0 == "," || $0 == " " || $0 == "/" }.map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        var bytes: [Int] = []
        for part in parts.prefix(3) {
            guard let number = Double(part), number.isFinite, (0...255).contains(number) else { return nil }
            bytes.append(Int(number.rounded()))
        }
        var alpha = 1.0
        if parts.count == 4 {
            let raw = parts[3]
            guard let number = raw.hasSuffix("%") ? Double(raw.dropLast()).map({ $0 / 100 }) : Double(raw),
                  number.isFinite, (0...1).contains(number) else { return nil }
            alpha = number
        }
        var hex = "#" + bytes.map { String(format: "%02x", $0) }.joined()
        let a = Int((alpha * 255).rounded())
        if a < 255 { hex += String(format: "%02x", a) }
        return hex
    }

    // MARK: Where it came from

    /// A system card's source line (NavDesigns): "dashboard-web · tokens.css", the project it was
    /// read from and its first stylesheet's name; the project alone, or the stylesheet alone.
    public static func source(project: String?, sources: [String]) -> String? {
        let file = sources.first.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        let parts = [project, file].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
