import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The subagents above the composer (MobileSteer, iPadSteer, iPadSubagents, iPadSplitView
/// boards; SubagentTray › iPad and iPhone): the Mac's tray at touch sizes, in one card with Up
/// next. A row opens its run (pushed on iPhone, in the inspector beside the thread on iPad);
/// Answer opens its question in the composer's place; touch and hold for Open, Answer, and the
/// run's controls. It stays until your next message once every run has finished.
struct SubagentTraySection: View {
    let ref: AgentRef
    let tray: NativeSubagentTray
    let store: NativeThreadStore
    let state: ComposerState
    let size: NWSubagentTraySize
    let enabled: Bool
    @Environment(MobileNavigator.self) private var navigator
    @ScaledMetric(relativeTo: .body) private var rowsMaxHeight = MobileLayout.trayRowsMaxHeight
    @Environment(\.composerMaxHeight) private var composerMaxHeight

    var body: some View {
        let values = SubagentValues.tray(tray)
        let shown = NativeSubagentTray.shownRows
        let long = values.rows.count > shown
        let rows = long && !state.trayExpanded ? Array(values.rows.prefix(shown)) : values.rows
        let byID = Dictionary(store.subagents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let commands = SubagentCommands(store: store, enabled: enabled && store.takesSubagentCommands)
        let selected = SubagentInspection.of(navigator).selected(in: ref)
        NWSubagentTray(values.summary, size: size, collapsed: state.trayCollapsed,
                       onToggle: { withNWAnimation(.disclosure) { state.trayCollapsed.toggle() } }) {
            VStack(spacing: 0) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { value in
                        // One view per element: a container whatever the run is.
                        VStack(spacing: 0) {
                            if let run = byID[value.id] {
                                row(value, run: run, selected: selected == run.runID, commands: commands)
                            }
                        }
                    }
                }
                .fittedScroll(maxHeight: min(rowsMaxHeight, composerMaxHeight * MobileLayout.trayShare))
                if long {
                    NWSubagentTrayMoreRow(hidden: values.rows.count - shown, expanded: state.trayExpanded) {
                        withNWAnimation(.disclosure) { state.trayExpanded.toggle() }
                    }
                }
            }
        }
    }

    private func row(_ value: NWSubagentTrayRun, run: NativeSubagent, selected: Bool, commands: SubagentCommands) -> some View {
        let asks = nativeRunPhase(run) == .needsYou
        return NWSubagentTrayRow(value, size: size, selected: selected, enabled: commands.enabled, actions: NWSubagentTrayActions(
            open: { SubagentOpening.open(.run(ref, runID: run.runID), navigator: navigator) },
            answer: asks ? { answer(run) } : nil))
            .contextMenu {
                Button("Open", systemImage: "arrow.up.right") { SubagentOpening.open(.run(ref, runID: run.runID), navigator: navigator) }
                if asks { Button("Answer", systemImage: "arrowshape.turn.up.left") { answer(run) } }
                SubagentControlItems(run: run, commands: commands)
            }
            .accessibilityActions {
                if asks { Button("Answer") { answer(run) } }
                if commands.enabled {
                    ForEach(nativeRunControls(run), id: \.self) { control in
                        Button(control.title) { commands.control(run.runID, control) }
                    }
                }
            }
    }

    private func answer(_ run: NativeSubagent) {
        withNWAnimation(.content) { state.answeringRun = run.runID }
    }
}
