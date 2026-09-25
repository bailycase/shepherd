import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Subagent cards in a thread, where a turn spawned them (subagents track). The foundation's
/// version: one row per run with its state, opening the run.
struct SubagentCards: View, Equatable {
    let thread: AgentRef
    let runs: [NativeSubagent]
    /// The turn that spawned them is still running.
    let turnLive: Bool
    @Environment(MobileNavigator.self) private var navigator

    static func == (lhs: SubagentCards, rhs: SubagentCards) -> Bool {
        lhs.thread == rhs.thread && lhs.runs == rhs.runs && lhs.turnLive == rhs.turnLive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.activitySpacing) {
            ForEach(runs) { run in
                Button { navigator.open(SubagentHooks.run(thread: thread, runID: run.runID)) } label: {
                    HStack(spacing: NW.Space.m) {
                        NWStatusDot(AgentState(nativeSubagentState(run)))
                        Text(run.label).font(.nw(.ui)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(AgentState(nativeSubagentState(run)).label).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                    }
                    .frame(minHeight: NW.Height.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
