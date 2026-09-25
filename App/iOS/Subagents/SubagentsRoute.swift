import SwiftUI
import ShepherdUI
import ShepherdRemote

/// Subagents' screens (subagents track): a thread's runs, and one run's transcript.
enum SubagentsRoute: Hashable, Codable {
    case list(AgentRef)
    case run(AgentRef, runID: String)

    var thread: AgentRef {
        switch self {
        case .list(let ref), .run(let ref, _): ref
        }
    }
}

/// Routes into subagents, for the thread's footer link and options menu.
enum SubagentHooks {
    static func list(thread: AgentRef) -> MobileRoute { .subagents(.list(thread)) }
    static func run(thread: AgentRef, runID: String) -> MobileRoute { .subagents(.run(thread, runID: runID)) }
}

/// iPhone pushes the list (MobileSubagents) and a run (MobileSubagent); iPad keeps the thread and
/// opens either in the inspector beside it (iPadSubagents, iPadSteer).
struct SubagentsDestination: View {
    let route: SubagentsRoute
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if navigator.layout == .pad {
            PadSubagentsScreen(route: route)
        } else {
            switch route {
            case .list(let ref): SubagentListScreen(ref: ref)
            case .run(let ref, let runID): SubagentRunScreen(ref: ref, runID: runID)
            }
        }
    }
}
