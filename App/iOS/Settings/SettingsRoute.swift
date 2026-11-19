import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Settings' screens (home track). `open` shows them in the Settings tab on iPhone and over
/// the detail on iPad, where Settings' own pages show beside its list instead (`SettingsPage`).
enum SettingsRoute: Hashable, Codable {
    case root
    /// The Macs this device is paired with, their room and the Dispatches log; Add a Mac, and Forget.
    case fleet
    /// A host's form; nil adds one (Add a Mac). A paired host's form is no longer reachable: Fleet lists it.
    case host(UUID?)
    case appearance
    /// Sign-in, and what a host's new threads, text generation and image reading use.
    case models
    /// The queue, context, the threads a thread starts, and subagents; Profiles opens `subagents`.
    case agents
    /// How a host creates worktrees and handles them when the work is done (Git).
    case worktrees
    /// A host's MCP servers and its extensions, slash commands and daily updates.
    case tools
    /// Every slash command the host's pi lists, each with a switch. Opened from Tools.
    case slashCommands
    /// The fleet's subagent profiles; one profile's Markdown. Opened from Agents.
    case subagents
    case subagent(String)
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
    /// One host's hooks by event, each with its switch; Add and Edit open as a sheet.
    case hooks
    /// The files that host reads hooks from, and the Claude Code and Codex readers.
    case hookSources
    case experiments
    /// General: what to send, to which device, and from which hosts. Named for what it was; the
    /// thread menu's link to background alerts opens it.
    case notifications
    /// Advanced: whether this device sends crash and performance reports to Sentry.
    case diagnostics
    /// A suggested line waiting on a host: edit it, choose its file, add it or dismiss it.
    case suggestion(UUID)
}

struct SettingsDestination: View {
    let route: SettingsRoute

    var body: some View {
        switch route {
        case .root: SettingsScreen()
        case .fleet: FleetScreen()
        case .host(let id): HostEditorScreen(hostID: id)
        case .appearance: AppearanceScreen()
        case .models: ModelsScreen()
        case .agents: AgentsScreen()
        case .worktrees: WorktreesScreen()
        case .tools: ToolsScreen()
        case .slashCommands: SlashCommandsScreen()
        case .subagents: SubagentProfilesScreen()
        case .subagent(let file): SubagentProfileScreen(file: file)
        case .spaces: SpacesScreen()
        case .space(let directory): SpaceScreen(directory: directory)
        case .instructions: InstructionsScreen()
        case .instructionsFile(let file): InstructionsEditorScreen(file: file)
        case .skills: SkillsScreen()
        case .skill(let name): SkillDetailScreen(name: name)
        case .skillResult(let skill): SkillResultScreen(skill: skill)
        case .skillsRepo(let repo): AddSkillsScreen(initialRepo: repo)
        case .hooks: HooksScreen()
        case .hookSources: HookSourcesScreen()
        case .experiments: ExperimentsScreen()
        case .notifications: NotificationsScreen()
        case .diagnostics: DiagnosticsScreen()
        case .suggestion(let id): SuggestionScreen(id: id)
        }
    }
}

/// A page of Settings, named and grouped as the Mac's: pushed from the list on iPhone, shown
/// beside it on iPad (iPadSettingsInstructions). General, Appearance | Agents: Models, Agents,
/// Instructions, Skills, Tools, Hooks | Work: Spaces, Git, Fleet | Advanced, Experiments.
/// The Mac's Keyboard and Apps have no phone page.
enum SettingsPage: String, CaseIterable, Hashable, Codable {
    case general, appearance, models, agents, instructions, skills, tools, hooks, spaces, git, fleet, advanced, experiments

    /// The list's groups, in order: a nil title is a group with no label.
    static let groups: [(title: String?, pages: [SettingsPage])] = [
        (nil, [.general, .appearance]),
        ("Agents", [.models, .agents, .instructions, .skills, .tools, .hooks]),
        ("Work", [.spaces, .git, .fleet]),
        (nil, [.advanced, .experiments]),
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .models: "Models"
        case .agents: "Agents"
        case .instructions: "Instructions"
        case .skills: "Skills"
        case .tools: "Tools"
        case .hooks: "Hooks"
        case .spaces: "Spaces"
        case .git: "Git"
        case .fleet: "Fleet"
        case .advanced: "Advanced"
        case .experiments: "Experiments"
        }
    }

    /// Its screen on its own, as the phone pushes it.
    var route: SettingsRoute {
        switch self {
        case .general: .notifications
        case .appearance: .appearance
        case .models: .models
        case .agents: .agents
        case .instructions: .instructions
        case .skills: .skills
        case .tools: .tools
        case .hooks: .hooks
        case .spaces: .spaces
        case .git: .worktrees
        case .fleet: .fleet
        case .advanced: .diagnostics
        case .experiments: .experiments
        }
    }
}

extension EnvironmentValues {
    /// A Settings page shown beside the iPad's list rather than on its own: it keeps the bar's
    /// title inline, and opens another page in place.
    @Entry var settingsColumn = false
}
