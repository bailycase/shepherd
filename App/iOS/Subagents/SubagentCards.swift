import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Subagent cards in a thread, where a turn spawned them (MobileSteer board). One run is a card
/// that answers its question in place; several are one group card (a line per run while any is
/// live, the finished ledger once all are done), ending while the turn waits on them with
/// "Waiting on worker and reviewer". A card or row opens its run; Open opens the thread's runs.
struct SubagentCards: View, Equatable {
    let thread: AgentRef
    let runs: [NativeSubagent]
    /// The turn that spawned them is still running.
    let turnLive: Bool
    @Environment(MobileNavigator.self) private var navigator
    @Environment(ThreadStores.self) private var threads

    static func == (lhs: SubagentCards, rhs: SubagentCards) -> Bool {
        lhs.thread == rhs.thread && lhs.runs == rhs.runs && lhs.turnLive == rhs.turnLive
    }

    var body: some View {
        let store = threads.store(for: thread)
        let commands = SubagentCommands(store: store, enabled: store.takesSubagentCommands)
        let selected = SubagentInspection.of(navigator).selected(in: thread)
        VStack(alignment: .leading, spacing: MobileLayout.turnItemSpacing) {
            if runs.count == 1, let run = runs.first {
                single(run, selected: selected == run.runID, commands: commands)
            } else if !runs.isEmpty {
                group(selected: selected)
            }
        }
    }

    private func single(_ run: NativeSubagent, selected: Bool, commands: SubagentCommands) -> some View {
        let summary = nativeRunSummary(run)
        return NWRunCard(SubagentValues.card(summary), isSelected: selected, isEnabled: commands.enabled,
                         open: { open(.run(thread, runID: run.runID)) },
                         answer: summary.phase == .needsYou ? commands.answer(run.runID) : nil,
                         rerun: summary.phase == .failed ? { commands.control(run.runID, .rerun) } : nil)
            .equatable()
            .contextMenu {
                Button("Open", systemImage: "arrow.up.right") { open(.run(thread, runID: run.runID)) }
                SubagentControlItems(run: run, commands: commands)
            }
            .accessibilityActions {
                // As on the Mac, VoiceOver offers only the controls that would act.
                if commands.enabled {
                    ForEach(nativeRunControls(run), id: \.self) { control in
                        Button(control.title) { commands.control(run.runID, control) }
                    }
                }
            }
    }

    private func group(selected: String?) -> some View {
        let ordered = runs.sorted { ($0.startedAt ?? 0, $0.id) < ($1.startedAt ?? 0, $1.id) }
        let summaries = ordered.map(nativeRunSummary)
        let status = nativeRunGroupStatus(ordered)
        let state: AgentState = status == nil ? .running : summaries.contains { $0.phase == .failed } ? .failed : .done
        return NWRunGroupCard(
            title: nativeCount(runs.count, "subagent"), state: state, status: status,
            rows: summaries.prefix(MobileLayout.subagentGroupMaxRows).map(SubagentValues.groupRow),
            footer: turnLive ? nativeRunWaitingLabel(ordered) : nil,
            selectedID: summaries.first { $0.runID == selected }?.id,
            openAll: { open(.list(thread)) },
            select: { id in
                if let run = ordered.first(where: { $0.id == id }) { open(.run(thread, runID: run.runID)) }
            })
            .equatable()
    }

    private func open(_ route: SubagentsRoute) {
        SubagentOpening.open(route, navigator: navigator)
    }
}
