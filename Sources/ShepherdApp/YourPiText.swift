import Foundation
import ShepherdSessions

/// The words Settings ▸ Pi ▸ From your pi uses for what came from the user's pi (docs/design/settings-pi.md › Pi ▸
/// From your pi). They name files and counts, never a credential's value.
enum YourPiText {
    /// Settings ▸ Pi ▸ Copied's instructions row: "`AGENTS.md` · 38 lines · no `APPEND_SYSTEM.md`".
    static func instructions(_ survey: YourPiSurvey) -> String {
        let copies = survey.copies(.instructions)
        guard !copies.isEmpty else { return "None copied: your pi has no `AGENTS.md` or `CLAUDE.md`." }
        var parts: [String] = []
        if let context = copies.first(where: { YourPiFiles.contextFileNames.contains($0.name) }) {
            parts.append("`\(context.name)`")
            if let lines = survey.instructionLines { parts.append(count(lines, "line")) }
        }
        for name in ["SYSTEM.md", "APPEND_SYSTEM.md"] {
            parts.append(copies.contains { $0.name == name } ? "`\(name)`" : "no `\(name)`")
        }
        return parts.joined(separator: " · ")
    }

    /// Settings ▸ Pi ▸ Copied's skills row.
    static func skills(_ copies: [YourPiCopy]) -> String {
        copies.isEmpty ? "None copied." : "\(count(copies.count, "skill")), listed with the rest in Skills."
    }

    /// Up to six names ("/review /triage"), then how many more.
    static func names(_ copies: [YourPiCopy], prefix: String, none: String) -> String {
        guard !copies.isEmpty else { return none }
        let shown = copies.prefix(6).map { "`\(prefix)\($0.name)`" }.joined(separator: " ")
        return copies.count > 6 ? "\(shown) and \(copies.count - 6) more" : shown
    }

    /// Where one of the user's extensions came from, short: "extensions/web-search/" for a file or
    /// folder in their pi's `extensions/`, else the path with `~`, or a package's source.
    static func extensionPath(_ item: YourPiExtensionRow) -> String {
        let source = item.copy.source
        if let range = source.range(of: "/extensions/") {
            let rest = String(source[range.lowerBound...].dropFirst())
            return (rest as NSString).pathExtension.isEmpty && !rest.hasSuffix("/") ? rest + "/" : rest
        }
        return (source as NSString).abbreviatingWithTildeInPath
    }

    /// "1 folder", "3 folders".
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
