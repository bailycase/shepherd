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
    @State private var limits = NWGoalLimits(seconds: nil, tokens: nil)
    @State private var editedGoal: NativeGoal?
    @FocusState private var focused: Bool

    private var enabled: Bool {
        active && store.ready && store.supportedActions.contains("goal") && !store.busy && store.loadError == nil
    }

    var body: some View {
        if let goal = store.goal {
            VStack(spacing: 0) {
                NWGoalCard(state: goal.cardState, time: goal.timeLabel, meta: goal.metaLabel, text: goal.text, framed: framed,
                           resumeEnabled: store.dialogs.isEmpty,
                           confirmationRequired: goal.confirmationRequired == true, checkedBy: goal.checkedBy,
                           confirmedByUser: goal.confirmedByUser == true, clockStart: goal.clockStart,
                           pause: { act(.pause, goal: goal) }, resume: {
                               act(goal.state == .needsYou && goal.confirmationRequired == true ? .confirm : .resume, goal: goal)
                           }, edit: {
                               text = goal.text
                               limits = NWGoalLimits(seconds: goal.timeLimitSeconds, tokens: goal.tokenLimit)
                               editedGoal = goal
                               editing = true
                               focused = true
                           }, clear: { act(.clear, goal: goal) })
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
                        NWGoalLimitFields(limits: $limits)
                        HStack(spacing: NW.Space.s) {
                            Spacer()
                            Button("Cancel") { editing = false }
                                .buttonStyle(.nw(.ghost, size: .s))
                            Button("Save") {
                                guard let displayed = editedGoal else { return }
                                let action = editAction(displayed)
                                Task { if await store.goalAction(action, displayedGoal: displayed) { editing = false } }
                            }
                            .buttonStyle(.nw(.secondary, size: .s))
                            .disabled(!canSave(goal))
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

    private func canSave(_ goal: NativeGoal) -> Bool {
        guard enabled, goal.state != .met, let displayed = editedGoal,
              displayed.id == goal.id, displayed.revision == goal.revision, displayed.state == goal.state,
              limits.isValid, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return text != displayed.text || limits.seconds != displayed.timeLimitSeconds || limits.tokenLimit != displayed.tokenLimit
    }

    private func editAction(_ goal: NativeGoal) -> NativeGoalAction {
        .edit(text: text,
              timeLimitSeconds: limits.seconds != goal.timeLimitSeconds ? limits.seconds : nil,
              tokenLimit: limits.tokenLimit != goal.tokenLimit ? limits.tokenLimit : nil,
              clearTimeLimit: limits.clearsTime && goal.timeLimitSeconds != nil ? true : nil,
              clearTokenLimit: limits.clearsTokens && goal.tokenLimit != nil ? true : nil)
    }

    private func act(_ action: NativeGoalAction, goal: NativeGoal) {
        guard enabled else { return }
        Task { await store.goalAction(action, displayedGoal: goal) }
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
    let record: NativeGoalRecord

    init(text: String) { record = NativeGoalRecord(text) }

    var body: some View {
        VStack(spacing: NW.Space.s) {
            HStack(spacing: NW.Space.m) {
                NWHairline().frame(minWidth: NW.Space.l)
                Text(record.line).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(record.isClosing ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .layoutPriority(1)
                NWHairline().frame(minWidth: NW.Space.l)
            }
            if let evidence = record.evidence {
                DisclosureGroup {
                    Text(evidence).font(.nw(.mono)).foregroundStyle(Color.nw.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } label: {
                    if record.showsDetails { Text("Details") } else { Text("Evidence") }
                }
                .font(.nw(.caption))
                .foregroundStyle(Color.nw.textTertiary)
                .tint(Color.nw.textSecondary)
            }
        }
        .padding(.vertical, NW.Space.xs)
    }
}

/// Keep the clock's observation out of the toolbar's other controls.
struct ThreadGoalHeader: View {
    let store: NativeThreadStore

    var body: some View {
        if let goal = store.goal, goal.isActive { NWGoalHeaderPill(time: goal.timeLabel, clockStart: goal.clockStart) }
    }
}
