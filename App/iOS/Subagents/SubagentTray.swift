import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The subagents above the composer (MobileSteer, iPadSteer, iPadSubagents, iPadSplitView
/// boards; SubagentTray › iPad and iPhone): the Mac's tray at touch sizes, in one card with Up
/// next. A row opens its run (pushed on iPhone, in the inspector beside the thread on iPad);
/// touch and hold for Open and the run's controls. A run that asked its parent a question says so
/// quietly on its row: a subagent never asks the user. It stays until your next message once
/// every run has finished. It reads the store's tray itself: a child's tool call redraws this and
/// not the composer around it, which reads only whether the tray shows (`hasTray`).
///
/// While the composer takes the section out, the store's tray is already nil, but a view in its
/// removal transition still runs its body. The last tray is kept for that pass, so the card fades
/// out with its rows as it did when the composer handed it a copy.
struct SubagentTraySection: View {
    let ref: AgentRef
    let store: NativeThreadStore
    let state: ComposerState
    let size: SHSubagentTraySize
    let enabled: Bool
    @Environment(MobileNavigator.self) private var navigator
    @ScaledMetric(relativeTo: .body) private var rowsMaxHeight = MobileLayout.trayRowsMaxHeight
    @Environment(\.composerMaxHeight) private var composerMaxHeight
    @State private var last = LastTray()

    /// The tray this section drew last. A class nobody observes: writing it in `body` costs no render.
    private final class LastTray {
        var value: NativeSubagentTray?
    }

    var body: some View {
        let _ = SHRenderProbe.tick("composer.tray")
        if let tray = remembered(store.tray) {
            card(tray)
        } else {
            let _ = SHRenderProbe.tick("composer.tray.empty")
        }
    }

    private func remembered(_ tray: NativeSubagentTray?) -> NativeSubagentTray? {
        if let tray { last.value = tray }
        return tray ?? last.value
    }

    @ViewBuilder private func card(_ tray: NativeSubagentTray) -> some View {
        let values = SubagentValues.tray(tray)
        let shown = NativeSubagentTray.shownRows
        let long = values.rows.count > shown
        let rows = long && !state.trayExpanded ? Array(values.rows.prefix(shown)) : values.rows
        let waiting = values.rows.filter { if case .asked = $0.line { true } else { false } }
        let byID = Dictionary(store.subagents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let commands = SubagentCommands(store: store, enabled: enabled && store.takesSubagentCommands)
        let selected = SubagentInspection.of(navigator).selected(in: ref)
        VStack(spacing: 0) {
            SHSubagentTray(values.summary, size: size, collapsed: state.trayCollapsed,
                           onToggle: { withSHAnimation(.disclosure) { state.trayCollapsed.toggle() } }) {
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
                        SHSubagentTrayMoreRow(hidden: values.rows.count - shown, expanded: state.trayExpanded) {
                            withSHAnimation(.disclosure) { state.trayExpanded.toggle() }
                        }
                    }
                }
            }
            if store.hasGoal && state.trayCollapsed {
                ForEach(waiting) { value in
                    VStack(spacing: 0) {
                        if let run = byID[value.id] {
                            row(value, run: run, selected: selected == run.runID, commands: commands)
                        }
                    }
                }
            }
        }
        .onChange(of: store.goalID, initial: true) { _, id in
            // A goal folds the tray to its header on iPhone; the iPad draws it in full (GoalStates, iPadGoal).
            if id != nil, size == .phone { state.trayCollapsed = true }
        }
    }

    private func row(_ value: SHSubagentTrayRun, run: NativeSubagent, selected: Bool, commands: SubagentCommands) -> some View {
        SHSubagentTrayRow(value, size: size, selected: selected, enabled: commands.enabled, actions: SHSubagentTrayActions(
            open: { SubagentOpening.open(.run(ref, runID: run.runID), navigator: navigator) }))
            .contextMenu {
                Button("Open", systemImage: "arrow.up.right") { SubagentOpening.open(.run(ref, runID: run.runID), navigator: navigator) }
                SubagentControlItems(run: run, commands: commands)
            }
            .accessibilityActions {
                if commands.enabled {
                    ForEach(nativeRunControls(run), id: \.self) { control in
                        Button(control.title) { commands.control(run.runID, control) }
                    }
                }
            }
    }
}
