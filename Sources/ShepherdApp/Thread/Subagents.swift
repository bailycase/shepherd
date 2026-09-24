import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// Subagents (Agents board): a subagent is a turn inside a turn. Its card sits where its spawn
// call was; more than three live siblings fold into a runs strip (each of its segments opens its
// run); once every run in the group has finished, the cards become one run ledger. Pause waits
// at the child's next model-request boundary; Continue releases it.

/// What a card can ask the thread to do. `inspect` opens the inspector for the run.
struct SubagentActions {
    var inspect: (ChildRun) -> Void
    var command: (ChildRun, NativeSubagentAction, String?, NativeThreadDelivery?) -> Void
    /// The run open in the inspector: its card wears the running ring, its ledger row the tint.
    var inspectedRunID: String? = nil
}

extension EnvironmentValues {
    /// Whether the thread takes commands from its subagent cards (Pause, Stop, Re-run, an
    /// answer): its agent is on screen and its host supports them. An environment value the
    /// cards read, so switching agents redraws the cards and not the turns around them.
    @Entry var threadActionsEnabled = true
}

/// The subagents for one turn: cards where few, the strip (plus the cards that need you) when
/// many, the ledger once every run in the group has finished.
struct SubagentStack: View {
    let runs: [ChildRun]
    /// Whether any sibling in the turn is still live; the ledger waits for all of them.
    var turnLive = false
    let actions: SubagentActions

    var body: some View {
        SubagentGroup(runs: runs, turnLive: turnLive, inspectedRunID: actions.inspectedRunID,
                      inspect: actions.inspect, command: actions.command)
            .equatable()
    }
}

/// The stack's content, compared by value: a thread refresh that leaves these runs alone
/// skips the ledger and strip projections entirely.
private struct SubagentGroup: View, Equatable {
    let runs: [ChildRun]
    let turnLive: Bool
    let inspectedRunID: String?
    let inspect: (ChildRun) -> Void
    let command: (ChildRun, NativeSubagentAction, String?, NativeThreadDelivery?) -> Void
    @State private var stripExpanded = false
    @State private var shown = NWShownFlag()

    nonisolated static func == (a: SubagentGroup, b: SubagentGroup) -> Bool {
        a.runs == b.runs && a.turnLive == b.turnLive && a.inspectedRunID == b.inspectedRunID
    }

    var body: some View {
        let ordered = SubagentPresentation.ordered(runs)
        let layout = SubagentPresentation.layout(ordered, turnLive: turnLive)
        let cards = switch layout {
        case .ledger: [ChildRun]()
        case .strip: ordered.filter { stripExpanded || $0.needsAttention }
        case .cards: ordered
        }
        // One list of cards in every layout, so a card keeps its identity when the group folds
        // into the strip. The group reshapes at once, since the rest of its turn (the next
        // card, "Working…") moves at once too: the cards that fold away leave, and what arrives
        // while the group is on screen (a strip, a ledger in place of the cards, a card that
        // needs you, the cards the strip shows) fades in where it lands.
        VStack(alignment: .leading, spacing: AppLayout.subagentStackSpacing) {
            if layout == .ledger {
                NWRunLedger(SubagentPresentation.ledger(ordered), selection: selection(ordered)).equatable()
                    .nwRunArrival(shown.appeared)
            }
            if layout == .strip {
                NWRunsStrip(SubagentPresentation.strip(ordered), isExpanded: $stripExpanded) { id in
                    // A segment opens its run as the run's card does.
                    if let run = ordered.first(where: { $0.id == id }) { inspect(run) }
                }
                .equatable()
                .nwRunArrival(shown.appeared)
            }
            ForEach(cards, id: \.id, content: card)
        }
        .onAppear { shown.appeared = true }
    }

    private func card(_ run: ChildRun) -> some View {
        SubagentCard(run: run, selected: run.runID == inspectedRunID, inspect: inspect, command: command)
            .equatable()
            .nwRunArrival(shown.appeared, .list)
    }

    /// The ledger row of the inspected run; choosing a row inspects it (again closes it).
    private func selection(_ ordered: [ChildRun]) -> Binding<String?> {
        Binding(
            get: { ordered.first { $0.runID == inspectedRunID }?.id },
            set: { id in if let run = ordered.first(where: { $0.id == id }) { inspect(run) } }
        )
    }
}

/// One run's card: `NWSubagentCard` over a child run. Its live controls (pause, stop) sit in
/// the context menu and the accessibility actions; the inspector carries them visibly.
struct SubagentCard: View, Equatable {
    let run: ChildRun
    let selected: Bool
    let inspect: (ChildRun) -> Void
    let command: (ChildRun, NativeSubagentAction, String?, NativeThreadDelivery?) -> Void
    @Environment(\.threadActionsEnabled) private var enabled

    nonisolated static func == (a: SubagentCard, b: SubagentCard) -> Bool {
        a.run == b.run && a.selected == b.selected
    }

    var body: some View {
        let state = SubagentPresentation.state(run)
        NWSubagentCard(
            SubagentPresentation.card(run), isSelected: selected, isEnabled: enabled,
            inspect: { inspect(run) },
            answer: { command(run, .message, $0, .steer) },
            rerun: { command(run, .resume, nil, nil) }
        )
        .contextMenu {
            Button("Inspect") { inspect(run) }
            if !run.isTerminal {
                if state == .running || state == .queued { pauseButton }
                Button("Stop", role: .destructive) { command(run, .cancel, nil, nil) }.disabled(!enabled)
            } else if state == .failed {
                Button("Re-run") { command(run, .resume, nil, nil) }.disabled(!enabled)
            }
        }
        .accessibilityAction(named: "Inspect") { inspect(run) }
        .accessibilityActions {
            if enabled, !run.isTerminal {
                if state == .running || state == .queued { pauseButton }
                Button("Stop") { command(run, .cancel, nil, nil) }
            }
        }
    }

    private var pauseButton: some View {
        Button(run.paused == true ? "Continue" : "Pause") {
            command(run, run.paused == true ? .continue : .pause, nil, nil)
        }
        .disabled(!enabled)
        .help("Pause before the next model request; current tools finish normally")
    }
}
