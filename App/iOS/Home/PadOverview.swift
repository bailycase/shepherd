import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// The iPad detail with no thread selected: the sidebar lists every thread, so this only
/// points there and offers a new one.
struct PadOverview: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        Group {
            if hosts.hosts.isEmpty {
                NoHostsState()
            } else {
                NWEmptyState(Text("No thread selected"), message: "Pick a thread in the sidebar, or start a new one.") {
                    Button("New thread") { NewThreadHooks.open(navigator: navigator) }.buttonStyle(.nw(.primary))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nw.bgWindow)
    }
}

/// A running thread's glyph (iPadOverview, iPadHosts): the spinner, the branch while its
/// subagents work, or its state's dot while it waits on you.
enum RunningGlyph {
    static func of(_ row: FleetThreadRow) -> NWListRow.Leading {
        guard row.status == .working else { return .state(AgentState(row.status)) }
        return row.subagents > 0 ? .symbol(NWGlyph.gitBranch.symbolName, .running) : .glyph(.running)
    }
}
