import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// Projects' screens (the Mac's ProjectLead behavior on iPhone, iPad and iPhone Duo). A Project is
/// always owned by a paired host: every route names it through `LogicalProjectRef.home`.
enum ProjectsRoute: Hashable, Codable {
    case list
    /// The Project's conversation; on a wide window its tasks beside it.
    case project(LogicalProjectRef)
    /// The task list (pushed where the conversation has no room beside it).
    case tasks(LogicalProjectRef)
    /// One task's worker thread, read and steered through the owner.
    case task(LogicalProjectRef, ProjectTaskID)
    case files(LogicalProjectRef, path: String)
    case settings(LogicalProjectRef)
    /// Presented: New project on `host` (nil: the first owner that takes one).
    case create(host: UUID?)
    /// Presented: a new task for the Project's coordinator-free assignment.
    case assign(LogicalProjectRef)

    var host: UUID? {
        let ref: LogicalProjectRef?
        switch self {
        case .list: return nil
        case .create(let host): return host
        case .project(let r), .tasks(let r), .task(let r, _), .files(let r, _), .settings(let r), .assign(let r): ref = r
        }
        if case .host(let id)? = ref?.home { return id }
        return nil
    }
}

struct ProjectsDestination: View {
    let route: ProjectsRoute

    var body: some View {
        switch route {
        case .list: ProjectsScreen()
        case .project(let ref): ProjectScreen(ref: ref)
        case .tasks(let ref): ProjectTasksScreen(ref: ref)
        case .task(let ref, let task): ProjectTaskScreen(ref: ref, task: task)
        case .files(let ref, let path): ProjectFilesScreen(ref: ref, path: path)
        case .settings(let ref): ProjectSettingsScreen(ref: ref)
        case .create(let host): NewProjectScreen(host: host)
        case .assign(let ref): AssignProjectTaskScreen(ref: ref)
        }
    }
}

extension MobileLayout {
    /// iPad: the task list beside the Project's conversation (the Mac pane's minimum).
    static let projectTasksWidth: CGFloat = 380
    /// The Memory section's instructions editor.
    static let projectInstructionsMinHeight: CGFloat = 160
    static let projectPromptMinHeight: CGFloat = 120
    /// The most pixels a Files preview decodes an image to: an iPad's full-width List at 2x.
    static let projectFilePreviewPixels = CGSize(width: 2048, height: 2048)
}

/// A thread's turns as the transcript draws them for a Project: a key no ordinary-thread route
/// knows, so nothing a turn offers (review, undo, subagents) reaches an agent through the
/// ordinary transport.
extension AgentRef {
    static func project(_ ref: LogicalProjectRef, task: ProjectTaskID?) -> AgentRef? {
        guard case .host(let host) = ref.home else { return nil }
        return AgentRef(host: host, agent: AgentID(rawValue: "project:\(ref.id.rawValue):\(task?.rawValue ?? "conversation")"))
    }
}

extension EnvironmentValues {
    /// Set around a Project's transcript: its turns offer no ordinary-thread actions.
    @Entry var projectTranscript = false
}

/// Ages as the Mac's pane says them: "29m", "2h", "3d".
enum ProjectAge {
    static func text(_ milliseconds: Double) -> String {
        let seconds = max(0, Date().timeIntervalSince1970 - milliseconds / 1000)
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

extension ProjectTaskRow {
    /// The row's leading dot, by what the task needs.
    var mobileState: AgentState {
        switch group {
        case .waiting: .attention
        case .working: .running
        case .stopped: .idle
        case .resolved: .done
        }
    }

    var line: String? { [lead, detail].compactMap { $0 }.joined(separator: " · ").nilIfEmpty }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension MobileRoute {
    /// Any Projects screen, for the iPad sidebar's row.
    var isProjects: Bool {
        if case .projects = self { return true }
        return false
    }
}

extension MobileProjects {
    /// Where an item waiting on you opens: a Project's worker opens its task, a coordinator its
    /// Project, through the owner; any other agent its ordinary thread.
    func route(_ item: FleetAttention) -> MobileRoute {
        let thread = item.ref.agentRef
        let home = LogicalProjectHome.host(thread.host)
        guard let agent = hosts.host(thread.host)?.state.agents.first(where: { $0.id == thread.agent }) else { return item.route }
        if let id = agent.coordinatorFor { return .projects(.project(LogicalProjectRef(home: home, id: id))) }
        if let id = agent.projectWorkerFor {
            let ref = LogicalProjectRef(home: home, id: id)
            if let task = model.project(ref)?.tasks.first(where: { $0.workerAgentID == thread.agent }) {
                return .projects(.task(ref, task.id))
            }
            return .projects(.project(ref))
        }
        return item.route
    }
}
