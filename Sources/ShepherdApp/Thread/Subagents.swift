import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// Subagents (SubagentTray, Subagents, SubagentsDone, SubagentsQueue boards): while a turn's
// subagents run they dock above the composer in the tray, one row each, sharing one card with
// Up next; the thread keeps a line where they started and one where they finished, and both
// open the inspector. The tray stays until your next message once every run has finished. A
// subagent never asks the user: one that has a question says so quietly on its row, and its
// parent answers it or asks the user in its own thread.

/// What the tray and the thread's record ask the thread to do. `inspect` opens (or closes) the
/// inspector for a run; `steer` opens it with its Steer field focused.
struct SubagentActions {
    var inspect: (ChildRun) -> Void
    var command: (ChildRun, NativeSubagentAction, String?, NativeThreadDelivery?) -> Void
    var steer: ((ChildRun) -> Void)? = nil
    /// The run open in the inspector: its tray row wears the selection.
    var inspectedRunID: String? = nil
}

extension EnvironmentValues {
    /// Whether the thread takes commands from its tray (Steer, Stop): its agent is on screen
    /// and its host supports them. An environment value the rows read, so switching agents
    /// redraws the rows and not the turns around them.
    @Entry var threadActionsEnabled = true
}

/// The tray's own view state: collapsed, and whether a long tray shows every run.
@MainActor
@Observable
final class SubagentTrayState {
    var collapsed = false
    var expanded = false
}

/// The tray's rows as the dock draws them: the first `shownRows` and "Show N more" for a long
/// tray, every row once expanded (scrolling past `AppLayout.trayExpandedMaxRows`).
enum SubagentTrayLayout {
    enum Item: Equatable, Identifiable {
        case run(NWSubagentTrayRun)
        case more(hidden: Int, expanded: Bool)

        var id: String {
            switch self {
            case .run(let run): run.id
            case .more: "tray.more"
            }
        }
    }

    static func items(_ runs: [NWSubagentTrayRun], expanded: Bool) -> [Item] {
        let shown = NativeSubagentTray.shownRows
        guard runs.count > shown else { return runs.map(Item.run) }
        if expanded { return runs.map(Item.run) + [.more(hidden: 0, expanded: true)] }
        return runs.prefix(shown).map(Item.run) + [.more(hidden: runs.count - shown, expanded: false)]
    }
}

/// The tray section of the composer's dock.
struct SubagentTrayView: View {
    let tray: NativeSubagentTray
    let state: SubagentTrayState
    let runs: [ChildRun]
    let actions: SubagentActions
    var goalPresent = false

    var body: some View {
        let values = SubagentPresentation.tray(tray)
        let items = SubagentTrayLayout.items(values.rows, expanded: state.expanded)
        let byID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: 0) {
            NWSubagentTray(values.summary, collapsed: state.collapsed,
                           onToggle: { withNWAnimation(.disclosure) { state.collapsed.toggle() } }) {
                if state.expanded, values.rows.count > AppLayout.trayExpandedMaxRows {
                    // A workflow of hundreds of runs scrolls inside, building only the rows on screen.
                    ScrollView {
                        LazyVStack(spacing: 0) { list(items.dropLast(), byID) }
                    }
                    .frame(height: CGFloat(AppLayout.trayExpandedMaxRows) * NWSubagentTrayMetrics.pointer.rowHeight)
                    if let last = items.last { item(last, byID) }
                } else {
                    VStack(spacing: 0) { list(items[...], byID) }
                }
            }
            // A goal folds the busywork, but keeps a child's question to its parent visible.
            if goalPresent && state.collapsed {
                let waiting = values.rows.filter { if case .asked = $0.line { true } else { false } }.map(SubagentTrayLayout.Item.run)
                list(waiting[...], byID)
            }
        }
        .onChange(of: goalPresent, initial: true) { _, present in
            if present { state.collapsed = true }
        }
    }

    private func list(_ items: ArraySlice<SubagentTrayLayout.Item>, _ byID: [String: ChildRun]) -> some View {
        ForEach(items) { item($0, byID) }
    }

    @ViewBuilder private func item(_ item: SubagentTrayLayout.Item, _ byID: [String: ChildRun]) -> some View {
        // One view per element: a container whatever the item is.
        VStack(spacing: 0) {
            switch item {
            case .run(let value):
                if let run = byID[value.id] {
                    SubagentTrayRow(value: value, run: run, selected: run.runID == actions.inspectedRunID, actions: actions)
                        .equatable()
                }
            case .more(let hidden, let expanded):
                NWSubagentTrayMoreRow(hidden: hidden, expanded: expanded) {
                    withNWAnimation(.disclosure) { state.expanded.toggle() }
                }
            }
        }
    }
}

/// One run's row: it compares by what it draws, so a poll that leaves a run alone skips it.
/// Its live controls sit on hover and in its context menu and accessibility actions.
struct SubagentTrayRow: View, Equatable {
    let value: NWSubagentTrayRun
    let run: ChildRun
    let selected: Bool
    let actions: SubagentActions
    @Environment(\.threadActionsEnabled) private var enabled

    nonisolated static func == (a: SubagentTrayRow, b: SubagentTrayRow) -> Bool {
        a.value == b.value && a.selected == b.selected && a.run.paused == b.run.paused && a.run.state == b.run.state
    }

    var body: some View {
        // A run waiting on its parent's answer has finished its process, but it is still going: the
        // user can steer it (speaking over its parent) and stop it (closing its question).
        let live = nativeRunPhase(run).isLive
        NWSubagentTrayRow(value, selected: selected, enabled: enabled, actions: NWSubagentTrayActions(
            open: { actions.inspect(run) },
            steer: live ? { (actions.steer ?? actions.inspect)(run) } : nil,
            stop: live ? { actions.command(run, .cancel, nil, nil) } : nil))
            .contextMenu {
                Button(selected ? "Close the Inspector" : "Open") { actions.inspect(run) }
                ForEach(nativeRunControls(run), id: \.self) { control in
                    Button(control.title, role: control == .stop ? .destructive : nil) {
                        actions.command(run, control.action, nil, nil)
                    }
                    .disabled(!enabled)
                }
            }
            .accessibilityActions {
                if enabled {
                    ForEach(nativeRunControls(run), id: \.self) { control in
                        Button(control.title) { actions.command(run, control.action, nil, nil) }
                    }
                }
            }
    }
}

/// The card above the composer: the tray, then Up next, in one card (SubagentsQueue).
struct ComposerDock<Queue: View>: View {
    let tray: NativeSubagentTray?
    let trayState: SubagentTrayState
    let runs: [ChildRun]
    let actions: SubagentActions?
    let showsQueue: Bool
    var goalStore: NativeThreadStore? = nil
    var goalActive = true
    @ViewBuilder let queue: () -> Queue

    var body: some View {
        if goalStore?.goal != nil || (tray != nil && actions != nil) {
            NWDockStack(showsTray: true, showsQueue: showsQueue) {
                VStack(spacing: 0) {
                    if let goalStore, goalStore.goal != nil {
                        ThreadGoalCard(store: goalStore, active: goalActive, framed: false)
                    }
                    if let tray, let actions {
                        SubagentTrayView(tray: tray, state: trayState, runs: runs, actions: actions,
                                         goalPresent: goalStore?.goal != nil)
                            .overlay(alignment: .top) {
                                if goalStore?.goal != nil { NWHairline(color: Color.nw.lineStrong) }
                            }
                    }
                }
            } queue: {
                queue()
            }
        } else {
            // Up next alone draws its own card.
            queue()
        }
    }
}
