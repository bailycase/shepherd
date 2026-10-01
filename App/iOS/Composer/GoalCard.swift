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
    @FocusState private var focused: Bool

    private var enabled: Bool {
        active && store.ready && store.supportedActions.contains("goal") && !store.busy && store.loadError == nil
    }

    var body: some View {
        if let goal = store.goal {
            NWGoalCard(state: goal.cardState, time: goal.timeLabel, meta: goal.metaLabel, text: goal.text,
                       size: size, framed: framed, pause: { act(.pause) }, resume: { act(.resume) }, edit: {
                           text = goal.text
                           editing = true
                       }, clear: { act(.clear) })
                .disabled(!enabled)
                .onChange(of: store.goal?.id) { _, _ in editing = false }
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
                                    let value = text
                                    Task { if await store.goalAction(.edit(text: value)) { editing = false } }
                                }
                                .disabled(!enabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .onAppear { focused = true }
                    }
                    .presentationDetents([.medium, .large])
                }
        }
    }

    private func act(_ action: NativeGoalAction) {
        guard enabled else { return }
        Task { await store.goalAction(action) }
    }
}

/// Structured goal records read as quiet dividers on both the parent and child transcripts.
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
