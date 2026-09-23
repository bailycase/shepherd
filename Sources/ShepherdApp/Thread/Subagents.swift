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
    var enabled: Bool
    /// The run open in the inspector: its card wears the running ring, its ledger row the tint.
    var inspectedRunID: String? = nil
}

/// The subagents for one turn: cards where few, the strip (plus the cards that need you) when
/// many, the ledger once every run in the group has finished.
struct SubagentStack: View {
    let runs: [ChildRun]
    /// Whether any sibling in the turn is still live; the ledger waits for all of them.
    var turnLive = false
    let actions: SubagentActions

    var body: some View {
        SubagentGroup(runs: runs, turnLive: turnLive, enabled: actions.enabled, inspectedRunID: actions.inspectedRunID,
                      inspect: actions.inspect, command: actions.command)
            .equatable()
    }
}

/// The stack's content, compared by value: a thread refresh that leaves these runs alone
/// skips the ledger and strip projections entirely.
private struct SubagentGroup: View, Equatable {
    let runs: [ChildRun]
    let turnLive: Bool
    let enabled: Bool
    let inspectedRunID: String?
    let inspect: (ChildRun) -> Void
    let command: (ChildRun, NativeSubagentAction, String?, NativeThreadDelivery?) -> Void
    @State private var stripExpanded = false

    nonisolated static func == (a: SubagentGroup, b: SubagentGroup) -> Bool {
        a.runs == b.runs && a.turnLive == b.turnLive && a.enabled == b.enabled && a.inspectedRunID == b.inspectedRunID
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
        // into the strip: the cards that fold away leave, the strip arrives, and the ledger
        // replaces them all in place once the group finishes.
        VStack(alignment: .leading, spacing: AppLayout.subagentStackSpacing) {
            if layout == .ledger {
                NWRunLedger(SubagentPresentation.ledger(ordered), selection: selection(ordered)).equatable()
                    .nwTransition(.content)
            }
            if layout == .strip {
                NWRunsStrip(SubagentPresentation.strip(ordered), isExpanded: $stripExpanded) { id in
                    // A segment opens its run as the run's card does.
                    if let run = ordered.first(where: { $0.id == id }) { inspect(run) }
                }
                .equatable()
                .nwTransition(.content)
            }
            ForEach(cards, id: \.id, content: card)
        }
        .nwAnimation(.list, value: Arrangement(layout: layout, cards: cards.map { CardPhase($0) }))
    }

    /// What moves the group's rows: its layout, which cards show, and each card's state (a card
    /// that grows a question pushes the cards under it down with it).
    private struct Arrangement: Equatable {
        let layout: SubagentPresentation.Layout
        let cards: [CardPhase]
    }

    private struct CardPhase: Equatable {
        let id: String
        let state: AgentState

        init(_ run: ChildRun) {
            id = run.id
            state = SubagentPresentation.state(run)
        }
    }

    private func card(_ run: ChildRun) -> some View {
        SubagentCard(run: run, selected: run.runID == inspectedRunID, enabled: enabled, inspect: inspect, command: command)
            .equatable()
            .nwTransition(.list)
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
    let enabled: Bool
    let inspect: (ChildRun) -> Void
    let command: (ChildRun, NativeSubagentAction, String?, NativeThreadDelivery?) -> Void

    nonisolated static func == (a: SubagentCard, b: SubagentCard) -> Bool {
        a.run == b.run && a.selected == b.selected && a.enabled == b.enabled
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
