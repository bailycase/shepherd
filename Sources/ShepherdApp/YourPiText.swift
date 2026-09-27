import Foundation
import ShepherdSessions

/// The words Settings ▸ Pi and the welcome step use for a sign-in and what came from the user's
/// pi (DESIGN.md › Settings ▸ Pi). They name a provider, a kind and a variable, never a
/// credential's value.
enum YourPiText {
    /// The trailing state word of a provider's row.
    static func state(_ login: YourPiSurvey.Login) -> String {
        switch login.shepherd {
        case .subscription?, .other?: "Signed in"
        case .apiKey?: "API key"
        case nil: login.environment.isEmpty ? "Not signed in" : "From your environment"
        }
    }

    /// A provider row's description (inline markup: `code`).
    static func description(_ login: YourPiSurvey.Login) -> String {
        switch login.shepherd {
        case .subscription?:
            login.yours == .subscription
                ? "Subscription sign-in, copied from your pi. When one side refreshes it, the other may be signed out: sign in again there."
                : "Subscription sign-in."
        case .apiKey(let source)?:
            key(source, markup: true) + "."
        case .other(let type)?:
            "Signed in (\(type))."
        case nil:
            if let name = login.environment.first { "`\(name)` in your shell's environment." }
            else if login.yours != nil { "Your pi is signed in; Shepherd's pi isn't." }
            else { "Not signed in." }
        }
    }

    /// An API key by where its value comes from.
    static func key(_ source: PiKeySource, markup: Bool = false) -> String {
        switch source {
        case .literal: "API key"
        case .environment(let names):
            "API key from " + names.map { markup ? "`$\($0)`" : "$\($0)" }.joined(separator: ", ")
        case .command: "API key that runs a command"
        }
    }

    /// A copied login in the welcome step.
    static func detail(_ kind: PiLogin.Kind) -> String {
        switch kind {
        case .subscription, .other: "Signed in"
        case .apiKey(let source): key(source)
        }
    }

    /// What came over as files, for the welcome step: "AGENTS.md · 12 skills · 5 prompts · 1
    /// theme" (the instructions file pi picks, then counts); nil when none did. Extensions have a
    /// row of their own.
    static func copiedFiles(_ copies: [YourPiCopy]) -> String? {
        var parts: [String] = []
        if let context = copies.first(where: { $0.kind == .instructions && YourPiFiles.contextFileNames.contains($0.name) }) {
            parts.append(context.name)
        } else if let other = copies.first(where: { $0.kind == .instructions }) {
            parts.append(other.name)
        }
        for (kind, noun) in [(YourPiResourceKind.skills, "skill"), (.prompts, "prompt"), (.themes, "theme")] {
            let n = copies.filter { $0.kind == kind }.count
            if n > 0 { parts.append(count(n, noun)) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

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

    /// One of the user's extensions: where it came from, what it does, and, while it is on, that
    /// it runs with full access.
    static func extensionDescription(_ item: YourPiExtensionRow) -> String {
        var text = "`\((item.copy.source as NSString).abbreviatingWithTildeInPath)`"
        if let summary = item.summary, !summary.isEmpty { text += " · \(summary)" }
        if item.on {
            text += "\nRuns with full access to your files, shell and network, like it does in your terminal. "
                + "New agents load it; running ones on /reload."
        }
        return text
    }

    /// Where one of the user's extensions came from, short: "extensions/web-search/" for a file or
    /// folder in their pi's `extensions/`, else the path with `~`, or a package's source.
    static func extensionPath(_ item: YourPiExtensionRow) -> String {
        let source = item.copy.source
        if let range = source.range(of: "/extensions/") {
            let rest = String(source[range.lowerBound...].dropFirst())
            let folder = item.copy.entries != nil || !(rest as NSString).pathExtension.isEmpty ? rest : rest + "/"
            return folder
        }
        return (source as NSString).abbreviatingWithTildeInPath
    }

    /// "1 folder", "3 folders".
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
