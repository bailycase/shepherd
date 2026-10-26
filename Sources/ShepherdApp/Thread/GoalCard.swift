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
    @State private var editedGoal: NativeGoal?
    @FocusState private var focused: Bool

    private var enabled: Bool {
        active && store.ready && store.supportedActions.contains("goal") && !store.busy && store.loadError == nil
    }

    var body: some View {
        if let goal = store.goal {
            VStack(spacing: 0) {
                SHGoalCard(state: goal.cardState, time: goal.timeLabel, meta: goal.metaLabel, text: goal.text, framed: framed,
                           resumeEnabled: store.dialogs.isEmpty,
                           confirmationRequired: goal.confirmationRequired == true, checkedBy: goal.checkedBy,
                           confirmedByUser: goal.confirmedByUser == true, clockStart: goal.clockStart,
                           pause: { act(.pause, goal: goal) }, resume: {
                               act(goal.state == .needsYou && goal.confirmationRequired == true ? .confirm : .resume, goal: goal)
                           }, edit: {
                               text = goal.text
                               editedGoal = goal
                               editing = true
                               focused = true
                           }, clear: { act(.clear, goal: goal) })
                    .disabled(!enabled)
                if editing {
                    VStack(alignment: .leading, spacing: SH.Space.s) {
                        TextField("Goal condition", text: $text, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.sh(.body))
                            .foregroundStyle(Color.sh.textPrimary)
                            .lineLimit(1...SHComposerMetrics.fieldMaxLines)
                            .focused($focused)
                            .accessibilityLabel("Goal condition")
                        HStack(spacing: SH.Space.s) {
                            Spacer()
                            Button("Cancel") { editing = false }
                                .buttonStyle(.sh(.ghost, size: .s))
                            Button("Save") {
                                guard let displayed = editedGoal else { return }
                                let action = NativeGoalAction.edit(text: text)
                                Task { if await store.goalAction(action, displayedGoal: displayed) { editing = false } }
                            }
                            .buttonStyle(.sh(.secondary, size: .s))
                            .disabled(!canSave(goal))
                        }
                    }
                    .padding(SH.Space.l)
                    .background(Color.sh.bgRaised)
                    .overlay(alignment: .top) { SHHairline() }
                    .onKeyPress(.escape) { editing = false; return .handled }
                }
            }
            .onChange(of: goal.id) { _, _ in editing = false }
        }
    }

    private func canSave(_ goal: NativeGoal) -> Bool {
        guard enabled, goal.state != .met, let displayed = editedGoal,
              displayed.id == goal.id, displayed.revision == goal.revision, displayed.state == goal.state,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return text != displayed.text
    }

    private func act(_ action: NativeGoalAction, goal: NativeGoal) {
        guard enabled else { return }
        Task { await store.goalAction(action, displayedGoal: goal) }
    }
}

extension NativeGoal {
    var cardState: SHGoalState {
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
    let record: NativeGoalRecord

    init(text: String) { record = NativeGoalRecord(text) }

    var body: some View {
        VStack(spacing: SH.Space.s) {
            HStack(spacing: SH.Space.m) {
                SHHairline().frame(minWidth: SH.Space.l)
                Text(record.line).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(record.isClosing ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .layoutPriority(1)
                SHHairline().frame(minWidth: SH.Space.l)
            }
            if let evidence = record.evidence {
                DisclosureGroup {
                    Text(evidence).font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } label: {
                    if record.showsDetails { Text("Details") } else { Text("Evidence") }
                }
                .font(.sh(.caption))
                .foregroundStyle(Color.sh.textTertiary)
                .tint(Color.sh.textSecondary)
            }
        }
        .padding(.vertical, SH.Space.xs)
    }
}

/// Keep the clock's observation out of the toolbar's other controls.
struct ThreadGoalHeader: View {
    let store: NativeThreadStore

    var body: some View {
        if let goal = store.goal, goal.isActive { SHGoalHeaderPill(time: goal.timeLabel, clockStart: goal.clockStart) }
    }
}
