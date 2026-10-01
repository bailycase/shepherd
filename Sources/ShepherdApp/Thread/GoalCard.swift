import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The goal remains above the composer, including while a question takes the field's place.
struct ThreadGoalCard: View {
    let store: NativeThreadStore
    let active: Bool
    var framed = true
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var enabled: Bool {
        active && store.ready && store.supportedActions.contains("goal") && !store.busy && store.loadError == nil
    }

    var body: some View {
        if let goal = store.goal {
            VStack(spacing: 0) {
                NWGoalCard(state: goal.cardState, time: goal.timeLabel, meta: goal.metaLabel, text: goal.text, framed: framed,
                           pause: { act(.pause) }, resume: { act(.resume) }, edit: {
                               text = goal.text
                               editing = true
                               focused = true
                           }, clear: { act(.clear) })
                    .disabled(!enabled)
                if editing {
                    VStack(alignment: .leading, spacing: NW.Space.s) {
                        TextField("Goal condition", text: $text, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.nw(.body))
                            .foregroundStyle(Color.nw.textPrimary)
                            .lineLimit(1...NWComposerMetrics.fieldMaxLines)
                            .focused($focused)
                            .accessibilityLabel("Goal condition")
                        HStack(spacing: NW.Space.s) {
                            Spacer()
                            Button("Cancel") { editing = false }
                                .buttonStyle(.nw(.ghost, size: .s))
                            Button("Save") {
                                let value = text
                                Task { if await store.goalAction(.edit(text: value)) { editing = false } }
                            }
                            .buttonStyle(.nw(.secondary, size: .s))
                            .disabled(!enabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(NW.Space.l)
                    .background(Color.nw.bgRaised)
                    .overlay(alignment: .top) { NWHairline() }
                    .onKeyPress(.escape) { editing = false; return .handled }
                }
            }
            .onChange(of: goal.id) { _, _ in editing = false }
        }
    }

    private func act(_ action: NativeGoalAction) {
        guard enabled else { return }
        Task { await store.goalAction(action) }
    }
}

extension NativeGoal {
    var cardState: NWGoalState {
        switch state {
        case .working: .working
        case .checking: .checking
        case .met: .met
        case .paused: .paused
        case .needsYou: .needsYou
        }
    }
}

/// A recorded goal condition or check is a quiet break in the conversation, not tool output.
struct GoalRecordLine: View {
    let text: String

    var body: some View {
        HStack(spacing: NW.Space.m) {
            NWHairline().frame(minWidth: NW.Space.l)
            Text(text).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .layoutPriority(1)
            NWHairline().frame(minWidth: NW.Space.l)
        }
        .padding(.vertical, NW.Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Keep the clock's observation out of the toolbar's other controls.
struct ThreadGoalHeader: View {
    let store: NativeThreadStore

    var body: some View {
        if let goal = store.goal { NWGoalHeaderPill(time: goal.timeLabel) }
    }
}
