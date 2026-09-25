import SwiftUI
import ShepherdUI

/// Search's screens (search track): threads and snippets across every host, the iPad palette,
/// and the agent actions' sheets.
enum SearchRoute: Hashable, Codable {
    /// iPhone (and an iPad window as narrow as one): the search screen, pushed.
    case search(query: String)
    /// iPad: the ⌘K palette over search and actions, presented.
    case palette(query: String)
    case rename(AgentRef)
    /// Delete, or Delete Worktree Agent for a worktree agent.
    case delete(AgentRef)
    /// An action from a menu or the palette failed.
    case problem(title: String, message: String)
}

/// Where other screens open search (Home's search button, the iPad sidebar, ⌘K): the palette
/// on iPad, the search screen on iPhone.
@MainActor
enum SearchHooks {
    static func open(query: String = "", navigator: MobileNavigator) {
        switch navigator.layout {
        case .pad: navigator.present(.search(.palette(query: query)))
        case .phone: navigator.open(.search(.search(query: query)))
        }
    }

    /// ⌘K: opens search, or closes the palette when it is already up. Another sheet (a new
    /// thread's draft, a delete in progress) is never replaced by it.
    static func toggle(navigator: MobileNavigator) {
        switch navigator.presented?.route {
        case .search(.palette)?: navigator.dismissPresented()
        case nil: open(navigator: navigator)
        default: break
        }
    }
}

struct SearchDestination: View {
    let route: SearchRoute

    var body: some View {
        switch route {
        case .search(let query): MobileSearchScreen(initialQuery: query)
        case .palette(let query): SearchPalette(initialQuery: query)
        case .rename(let ref): RenameAgentSheet(ref: ref)
        case .delete(let ref): DeleteAgentSheet(ref: ref)
        case .problem(let title, let message): ActionProblemSheet(title: title, message: message)
        }
    }
}

/// ⌘K, in the menu bar and the keyboard shortcuts overlay (the app's scene adds it), for the
/// focused window's navigator; nil (no window focused) disables it.
struct SearchCommands: Commands {
    let navigator: MobileNavigator?

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search Threads…") {
                if let navigator { SearchHooks.toggle(navigator: navigator) }
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(navigator == nil)
        }
    }
}
