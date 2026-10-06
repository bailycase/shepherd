import Foundation
import ShepherdProtocol

// Settings ▸ Pi ▸ Slash commands: the commands pi lists for the `/` menu on this Mac, grouped by
// where each comes from, each with a switch. The catalog is every command a pi here has listed
// (`SessionServer.slashCommandCatalog`), hidden or not, so a hidden one can be switched back on;
// the switches are `AppSettings.hiddenSlashCommands`. The rows are derived once per change, here,
// so the page's body does no filtering or grouping.

/// What the page knows: the commands pi has listed on this Mac, kept current by the server, the
/// switches, and the page's search. It derives the groups once per change, so the page's body only
/// draws them.
@MainActor
@Observable
final class SlashCommandsModel {
    /// Every command a pi on this Mac has listed since the app started, by name.
    var catalog: [NativeCommand] { didSet { derive() } }
    /// The page's own search.
    var query = "" { didSet { derive() } }
    private(set) var hidden: Set<String> = []
    private(set) var presentation: SlashCommandsPresentation

    init(catalog: [NativeCommand] = [], hidden: Set<String> = []) {
        self.catalog = catalog
        self.hidden = hidden
        presentation = SlashCommandsPresentation(catalog: catalog, hidden: hidden, query: "")
    }

    /// The names switched off (`AppSettings.hiddenSlashCommands`).
    func setHidden(_ names: Set<String>) {
        guard names != hidden else { return }
        hidden = names
        derive()
    }

    private func derive() {
        let next = SlashCommandsPresentation(catalog: catalog, hidden: hidden, query: query)
        if next != presentation { presentation = next }
    }
}

/// One command's row: what it is and whether the menu lists it.
struct SlashCommandRow: Equatable, Identifiable {
    var id: String { name }
    /// Without the slash.
    var name: String
    var description: String?
    /// "[tag]": what the command takes after its name.
    var arguments: String?
    var isOn: Bool
    /// Switched off and listed by no pi right now (it was hidden before this launch, or its pi has
    /// stopped): the page can still switch it on.
    var unlisted: Bool
}

/// A group of rows by where the commands come from.
struct SlashCommandGroup: Equatable, Identifiable {
    enum Source: String, CaseIterable {
        case extensions, prompts, skills, other

        init(_ source: String?) {
            switch source {
            case "extension": self = .extensions
            case "prompt": self = .prompts
            case "skill": self = .skills
            default: self = .other
            }
        }

        var title: String {
            switch self {
            case .extensions: "Extensions"
            case .prompts: "Prompt templates"
            case .skills: "Skills"
            case .other: "Unreported commands"
            }
        }
    }

    var id: String { source.rawValue }
    var source: Source
    var rows: [SlashCommandRow]
    var title: String { source.title }
}

/// The page's groups and counts for a query.
struct SlashCommandsPresentation: Equatable {
    var groups: [SlashCommandGroup]
    /// Every command, not only the ones the query leaves.
    var total: Int
    var hidden: Int
    /// How many the query leaves.
    var shown: Int { groups.reduce(0) { $0 + $1.rows.count } }

    /// The commands of `catalog` plus the names hidden that no pi lists now, grouped Extensions,
    /// Prompt templates, Skills, Other, each by name, with the ones `query` matches by name or
    /// description (a leading slash is ignored).
    init(catalog: [NativeCommand], hidden: Set<String>, query: String) {
        let known = Set(catalog.map(\.name))
        var rows = catalog.map { command in
            (SlashCommandGroup.Source(command.source),
             SlashCommandRow(name: command.name, description: command.description, arguments: command.arguments,
                             isOn: !hidden.contains(command.name), unlisted: false))
        }
        rows += hidden.subtracting(known).map { name in
            (.other, SlashCommandRow(name: name, description: nil, arguments: nil, isOn: false, unlisted: true))
        }
        total = rows.count
        self.hidden = rows.filter { !$0.1.isOn }.count
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "/" }.lowercased()
        groups = SlashCommandGroup.Source.allCases.compactMap { source in
            let matching = rows.filter { $0.0 == source }.map(\.1).filter { row in
                needle.isEmpty || row.name.lowercased().contains(needle) || row.description?.lowercased().contains(needle) == true
            }.sorted { $0.name < $1.name }
            return matching.isEmpty ? nil : SlashCommandGroup(source: source, rows: matching)
        }
    }

    /// "41 commands · 3 disabled", "No commands yet".
    var summary: String {
        guard total > 0 else { return "No commands yet" }
        let count = total == 1 ? "1 command" : "\(total) commands"
        return hidden == 0 ? count : "\(count) · \(hidden) disabled"
    }
}
