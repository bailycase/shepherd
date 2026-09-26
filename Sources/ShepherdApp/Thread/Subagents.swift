import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// Subagents (SubagentTray, Subagents, SubagentsDone, SubagentsQueue boards): while a turn's
// subagents run they dock above the composer in the tray, one row each, sharing one card with
// Up next; the thread keeps a line where they started and one where they finished, and both
// open the inspector. The tray stays until your next message once every run has finished.

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
    /// Whether the thread takes commands from its tray (Stop, an answer): its agent is on screen
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
    let answer: (ChildRun) -> Void

    var body: some View {
        let values = SubagentPresentation.tray(tray)
        let items = SubagentTrayLayout.items(values.rows, expanded: state.expanded)
        let byID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
                    SubagentTrayRow(value: value, run: run, selected: run.runID == actions.inspectedRunID, actions: actions,
                                    answer: answer)
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
    let answer: (ChildRun) -> Void
    @Environment(\.threadActionsEnabled) private var enabled

    nonisolated static func == (a: SubagentTrayRow, b: SubagentTrayRow) -> Bool {
        a.value == b.value && a.selected == b.selected && a.run.paused == b.run.paused && a.run.state == b.run.state
    }

    var body: some View {
        let live = !run.isTerminal
        let phase = nativeRunPhase(run)
        NWSubagentTrayRow(value, selected: selected, enabled: enabled, actions: NWSubagentTrayActions(
            open: { actions.inspect(run) },
            answer: phase == .needsYou ? { answer(run) } : nil,
            steer: live && phase != .needsYou ? { (actions.steer ?? actions.inspect)(run) } : nil,
            stop: live ? { actions.command(run, .cancel, nil, nil) } : nil))
            .contextMenu {
                Button(selected ? "Close the Inspector" : "Open") { actions.inspect(run) }
                if phase == .needsYou { Button("Answer…") { answer(run) }.disabled(!enabled) }
                ForEach(nativeRunControls(run), id: \.self) { control in
                    Button(control.title, role: control == .stop ? .destructive : nil) {
                        actions.command(run, control.action, nil, nil)
                    }
                    .disabled(!enabled)
                }
            }
            .accessibilityActions {
                if phase == .needsYou { Button("Answer") { answer(run) } }
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
    let answer: (ChildRun) -> Void
    let showsQueue: Bool
    @ViewBuilder let queue: () -> Queue

    var body: some View {
        if let tray, let actions {
            NWDockStack(showsTray: true, showsQueue: showsQueue) {
                SubagentTrayView(tray: tray, state: trayState, runs: runs, actions: actions, answer: answer)
            } queue: {
                queue()
            }
        } else {
            // Up next alone draws its own card.
            queue()
        }
    }
}

/// A subagent's question in the composer's place, from its row's Answer (SubagentTray ›
/// Answer → question dock): the question dock, labelled with the subagent. The answer steers
/// only that run; hiding it (Hide the question, Esc) closes the dock, and its row's Answer
/// opens it again.
struct SubagentQuestion: View {
    let run: ChildRun
    let enabled: Bool
    /// The thread has the keyboard: the dock takes its keys.
    let focused: Bool
    let actions: SubagentActions
    let hide: () -> Void

    var body: some View {
        let prompt = NativeQuestionPrompt(runID: run.runID, name: nativeRunNames(run).name,
                                          question: run.question?.text ?? run.attentionText ?? "", options: run.question?.options)
        QuestionDock(prompt: prompt, enabled: enabled, hidden: false, focused: focused) { answer in
            guard let reply = prompt.messageReply(answer) else { return }
            actions.command(run, .message, reply, .steer)
            hide()
        } setHidden: { hidden in
            if hidden { hide() }
        }
    }
}
