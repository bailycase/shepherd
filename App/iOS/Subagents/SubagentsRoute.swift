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

struct SubagentsDestination: View {
    let route: SubagentsRoute

    var body: some View {
        switch route {
        case .list:
            NWEmptyState(Text("Subagents"), message: "This thread's runs, from this turn and earlier ones.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.nw.bgWindow)
                .navigationTitle("Subagents")
                .navigationBarTitleDisplayMode(.inline)
        case .run(_, let runID):
            NWEmptyState(Text("Subagent"), message: "Run \(runID): its goal, transcript and steer field.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.nw.bgWindow)
                .navigationTitle("Subagent")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
