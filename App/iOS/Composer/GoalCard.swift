import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

struct ThreadGoalCard: View {
    let store: NativeThreadStore
    let active: Bool
    var size: NWGoalSize = .touch
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
            NWGoalCard(state: goal.cardState, time: goal.timeLabel, meta: goal.metaLabel, text: goal.text,
                       size: size, framed: framed, resumeEnabled: store.dialogs.isEmpty,
                       confirmationRequired: goal.confirmationRequired == true, checkedBy: goal.checkedBy,
                       confirmedByUser: goal.confirmedByUser == true, clockStart: goal.clockStart,
                       pause: { act(.pause, goal: goal) }, resume: {
                           act(goal.state == .needsYou && goal.confirmationRequired == true ? .confirm : .resume, goal: goal)
                       }, edit: {
                           text = goal.text
                           editedGoal = goal
                           editing = true
                       }, clear: { act(.clear, goal: goal) })
                .disabled(!enabled)
                .onChange(of: store.goalID) { _, _ in editing = false }
                .sheet(isPresented: $editing) {
                    NavigationStack {
                        VStack(alignment: .leading, spacing: NW.Space.m) {
                            TextField("Goal condition", text: $text, axis: .vertical)
                                .font(.nw(.body))
                                .foregroundStyle(Color.nw.textPrimary)
                                .focused($focused)
                                .accessibilityLabel("Goal condition")
                            if let notice = store.notice {
                                Text(notice).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                            }
                            Spacer()
                        }
                        .padding(MobileLayout.gutter)
                        .background(Color.nw.bgWindow)
                        .navigationTitle("Edit goal")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = false } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Save") {
                                    guard let displayed = editedGoal else { return }
                                    let action = NativeGoalAction.edit(text: text)
                                    Task { if await store.goalAction(action, displayedGoal: displayed) { editing = false } }
                                }
                                .disabled(!canSave(store.goal))
                            }
                        }
                        .onAppear { focused = true }
                    }
                    .presentationDetents([.medium, .large])
                }
        }
    }

    private func canSave(_ goal: NativeGoal?) -> Bool {
        guard enabled, let goal, goal.state != .met, let displayed = editedGoal,
              displayed.id == goal.id, displayed.revision == goal.revision, displayed.state == goal.state,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return text != displayed.text
    }

    private func act(_ action: NativeGoalAction, goal: NativeGoal) {
        guard enabled else { return }
        Task { await store.goalAction(action, displayedGoal: goal) }
    }
}

/// Structured goal records read as quiet dividers on both the parent and child transcripts.
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
