import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

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
