import SwiftUI
import ShepherdUI

/// Search's screens (search track): threads and snippets across every host, and the agent
/// actions' sheets.
enum SearchRoute: Hashable, Codable {
    /// iPhone (and an iPad window as narrow as one): the search screen, pushed.
    case search(query: String)
    case rename(AgentRef)
    /// Delete, or Delete Worktree Agent for a worktree agent.
    case delete(AgentRef)
    /// An action from a menu or the palette failed.
    case problem(title: String, message: String)
}

/// Where other screens open search (Home's search button, the iPad sidebar).
@MainActor
enum SearchHooks {
    static func open(query: String = "", navigator: MobileNavigator) {
        navigator.open(.search(.search(query: query)))
    }
}

struct SearchDestination: View {
    let route: SearchRoute

    var body: some View {
        switch route {
        case .search(let query): MobileSearchScreen(initialQuery: query)
        case .rename(let ref): RenameAgentSheet(ref: ref)
        case .delete(let ref): DeleteAgentSheet(ref: ref)
        case .problem(let title, let message): ActionProblemSheet(title: title, message: message)
        }
    }
}
