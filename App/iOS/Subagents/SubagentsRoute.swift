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

/// The phone pushes the list (MobileSubagents) and a run (MobileSubagent); on regular width the
/// navigator shows either in the side pane's Subagents tab instead (`PadSubagentInspector`).
struct SubagentsDestination: View {
    let route: SubagentsRoute

    var body: some View {
        switch route {
        case .list(let ref): SubagentListScreen(ref: ref)
        case .run(let ref, let runID): SubagentRunScreen(ref: ref, runID: runID)
        }
    }
}
