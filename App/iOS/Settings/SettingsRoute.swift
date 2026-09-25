import SwiftUI
import ShepherdUI
import ShepherdProtocol

/// Settings' screens (home track). `open` shows them in the Settings tab on iPhone and over
/// the detail on iPad, where Settings' own pages show beside its list instead (`SettingsPage`).
enum SettingsRoute: Hashable, Codable {
    case root
    case hosts
    /// A host's form; nil adds one.
    case host(UUID?)
    case appearance
    /// What a host's new threads start with: the model, thinking, and how the queue goes.
    case defaults
    /// How a host creates and finalizes worktrees.
    case worktrees
    /// The pi extensions a host loads, and its daily updates.
    case piExtensions
    /// The root instructions every pi session Shepherd starts reads.
    case instructions
    /// One root instruction file in the editor.
    case instructionsFile(InstructionFile)
    case experiments
    /// A suggested line waiting on a host: edit it, choose its file, add it or dismiss it.
    case suggestion(UUID)
}

struct SettingsDestination: View {
    let route: SettingsRoute

    var body: some View {
        switch route {
        case .root: SettingsScreen()
        case .hosts: HostsScreen()
        case .host(let id): HostEditorScreen(hostID: id)
        case .appearance: AppearanceScreen()
        case .defaults: DefaultsScreen()
        case .worktrees: WorktreesScreen()
        case .piExtensions: PiExtensionsScreen()
        case .instructions: InstructionsScreen()
        case .instructionsFile(let file): InstructionsEditorScreen(file: file)
        case .experiments: ExperimentsScreen()
        case .suggestion(let id): SuggestionScreen(id: id)
        }
    }
}

/// A page of Settings: pushed from the list on iPhone, shown beside it on iPad
/// (iPadSettingsInstructions). The iPad's list names two of them as the Mac does ("Agents",
/// "Pi"); the phone's rows say what they hold ("Defaults", "Pi extensions").
enum SettingsPage: String, CaseIterable, Hashable, Codable {
    case appearance, defaults, worktrees, pi, instructions, hosts, experiments

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .defaults: "Defaults"
        case .worktrees: "Worktrees"
        case .pi: "Pi extensions"
        case .instructions: "Instructions"
        case .hosts: "Hosts"
        case .experiments: "Experiments"
        }
    }

    /// Its name in the iPad's list.
    var listTitle: String {
        switch self {
        case .defaults: "Agents"
        case .pi: "Pi"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "circle.lefthalf.filled"
        case .defaults: "sparkles"
        case .worktrees: "arrow.branch"
        case .pi: "puzzlepiece.extension"
        case .instructions: "doc.text"
        case .hosts: "desktopcomputer"
        case .experiments: "flask"
        }
    }

    /// Its screen on its own, as the phone pushes it.
    var route: SettingsRoute {
        switch self {
        case .appearance: .appearance
        case .defaults: .defaults
        case .worktrees: .worktrees
        case .pi: .piExtensions
        case .instructions: .instructions
        case .hosts: .hosts
        case .experiments: .experiments
        }
    }
}

extension EnvironmentValues {
    /// A Settings page shown beside the iPad's list rather than on its own: it keeps the bar's
    /// title inline, and opens another page in place.
    @Entry var settingsColumn = false
}
