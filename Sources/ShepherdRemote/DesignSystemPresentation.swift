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

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
