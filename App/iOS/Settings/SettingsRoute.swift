import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

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
    /// A host's MCP servers and their last known status, read-only.
    case mcp
    /// A host's subagent profiles, read-only; one profile's Markdown.
    case subagents
    case subagent(String)
    /// A host's providers and whether each is signed in, read-only.
    case signIn
    /// A host's spaces by folder, read-only; one space's configuration files and approval.
    case spaces
    case space(String)
    /// The root instructions every session Shepherd starts reads.
    case instructions
    /// One root instruction file in the editor.
    case instructionsFile(InstructionFile)
    /// Every host's agent skills: each on or off, their updates, and a search of skills.sh.
    case skills
    /// One installed skill: how the agent uses it, its version, which hosts have it, its files.
    case skill(String)
    /// A skill on skills.sh before it's installed: what it does, its files, and Install.
    case skillResult(DirectorySkill)
    /// Add skills from a repository, looking up the one given at once.
    case skillsRepo(String?)
    case experiments
    case notifications
    /// Whether this device sends crash and performance reports to Sentry.
    case diagnostics
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
        case .mcp: MCPServersScreen()
        case .subagents: SubagentProfilesScreen()
        case .subagent(let file): SubagentProfileScreen(file: file)
        case .signIn: ProvidersScreen()
        case .spaces: SpacesScreen()
        case .space(let directory): SpaceScreen(directory: directory)
        case .instructions: InstructionsScreen()
        case .instructionsFile(let file): InstructionsEditorScreen(file: file)
        case .skills: SkillsScreen()
        case .skill(let name): SkillDetailScreen(name: name)
        case .skillResult(let skill): SkillResultScreen(skill: skill)
        case .skillsRepo(let repo): AddSkillsScreen(initialRepo: repo)
        case .experiments: ExperimentsScreen()
        case .notifications: NotificationsScreen()
        case .diagnostics: DiagnosticsScreen()
        case .suggestion(let id): SuggestionScreen(id: id)
        }
    }
}

/// A page of Settings: pushed from the list on iPhone, shown beside it on iPad
/// (iPadSettingsInstructions). The iPad's list names two of them as the Mac does ("Agents",
/// "Pi"); the phone's rows say what they hold ("Defaults", "Extensions").
enum SettingsPage: String, CaseIterable, Hashable, Codable {
    case appearance, defaults, worktrees, pi, mcp, subagents, signIn, instructions, skills, hosts, spaces, notifications, experiments, diagnostics

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .defaults: "Defaults"
        case .worktrees: "Worktrees"
        case .pi: "Extensions"
        case .mcp: "MCP"
        case .subagents: "Subagents"
        case .signIn: "Sign-in"
        case .instructions: "Instructions"
        case .skills: "Skills"
        case .hosts: "Hosts"
        case .spaces: "Spaces"
        case .notifications: "Notifications"
        case .experiments: "Experiments"
        case .diagnostics: "Diagnostics"
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
        case .mcp: "server.rack"
        case .subagents: "person.2"
        case .signIn: "person.badge.key"
        case .spaces: "folder"
        case .instructions: "doc.text"
        case .skills: "graduationcap"
        case .hosts: "desktopcomputer"
        case .notifications: "bell"
        case .experiments: "flask"
        case .diagnostics: "stethoscope"
        }
    }

    /// Its screen on its own, as the phone pushes it.
    var route: SettingsRoute {
        switch self {
        case .appearance: .appearance
        case .defaults: .defaults
        case .worktrees: .worktrees
        case .pi: .piExtensions
        case .mcp: .mcp
        case .subagents: .subagents
        case .signIn: .signIn
        case .spaces: .spaces
        case .instructions: .instructions
        case .skills: .skills
        case .hosts: .hosts
        case .notifications: .notifications
        case .experiments: .experiments
        case .diagnostics: .diagnostics
        }
    }
}

extension EnvironmentValues {
    /// A Settings page shown beside the iPad's list rather than on its own: it keeps the bar's
    /// title inline, and opens another page in place.
    @Entry var settingsColumn = false
}
