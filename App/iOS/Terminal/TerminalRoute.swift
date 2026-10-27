import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The terminal's screens (terminal track).
enum TerminalRoute: Hashable, Codable {
    /// iPhone: a thread's terminals, full screen; on regular width the side pane's Terminal tab.
    /// (The case keeps its stored name, so a saved route still restores.)
    case panes(AgentRef)

    var thread: AgentRef {
        switch self {
        case .panes(let ref): ref
        }
    }
}

struct TerminalDestination: View {
    let route: TerminalRoute

    var body: some View {
        switch route {
        case .panes(let ref): TerminalScreen(ref: ref)
        }
    }
}
