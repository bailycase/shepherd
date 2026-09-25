import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The composer slot at the bottom of `ThreadScreen` (thread track). The foundation's version:
/// a question takes the field's place, else a field with Send, and Stop while the agent runs.
/// The thread track adds the queue and steer stack, model and thinking, images and slash
/// commands here.
struct ThreadComposer: View {
    let ref: AgentRef
    @Environment(ThreadStores.self) private var threads
    @Environment(MobileHosts.self) private var hosts
    @FocusState private var focused: Bool

    var body: some View {
        let store = threads.store(for: ref)
        @Bindable var bindable = store
        let live = store.isLive && hosts.host(ref.host)?.phase.isConnected == true
        let draftEmpty = store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: NW.Space.s) {
            if let notice = store.notice {
                Text(notice).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let dialog = store.dialogs.first, let session = store.session {
                QuestionPanel(dialog: dialog, enabled: live && store.supports("answer")) { answer in
                    Task {
                        await store.answer(dialogID: dialog.id, sessionID: session.piSessionID, generation: session.generation,
                                           answer: answer)
                    }
                }
                .id(session.key + ":" + dialog.id)
            } else {
                NWComposer(isFocused: focused) {
                    TextField(store.running ? "Queue a follow-up…" : "Message the agent", text: $bindable.draft, axis: .vertical)
                        .font(.nw(.body))
                        .lineLimit(1...NWComposerMetrics.fieldMaxLines)
                        .focused($focused)
                        .accessibilityLabel("Message to agent")
                } controls: {
                    Spacer(minLength: 0)
                    if store.running, store.supports("abort") {
                        NWComposerActionButton(.stop, outlined: !draftEmpty, enabled: live) { Task { await store.abort() } }
                    }
                    if !store.running || !draftEmpty {
                        NWComposerActionButton(.send, enabled: live && store.acceptsSend && !draftEmpty && !store.busy) {
                            Task { await store.send() }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.vertical, NW.Space.m)
        .background(Color.nw.bgWindow)
        .onChange(of: store.sentCount) { _, _ in focused = false }
    }
}
