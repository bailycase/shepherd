import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI

/// The shared phone and iPad composer, without an ordinary agent's queue or review controls.
struct ProjectComposer: View {
    let ref: LogicalProjectRef
    var task: ProjectTaskID?
    @Environment(MobileProjects.self) private var projects
    @Environment(\.horizontalSizeClass) private var sizeClass
    @FocusState private var focused: Bool
    @State private var sending = false

    private var target: MobileProjectThread { projects.thread(ref, task: task) }
    private var state: ComposerState { target.composer }
    private var canSend: Bool {
        (target.store.hasDraft || !state.attachments.isEmpty) && projects.canRun(ref) && !sending
            && (task == nil || (target.store.supports("send")
                && (state.attachments.isEmpty || target.store.supports("sendImages"))))
    }

    private var canAttach: Bool {
        projects.canRun(ref) && !sending && (task == nil || target.store.supports("sendImages"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.composerSpacing) {
            if let message = projects.model.failure?.message ?? state.attachmentError ?? target.store.notice {
                Text(message).font(.nw(.caption)).foregroundStyle(Color.nw.failed)
                    .accessibilityIdentifier("project-send-error")
            }
            if let dialog = target.store.dialogs.first, let session = target.store.session {
                let prompt = NativeQuestionPrompt(dialog: dialog)
                QuestionPanel(prompt: prompt, count: target.store.dialogs.count,
                              enabled: projects.canRun(ref) && target.store.supports("answer") && !target.store.offline) { answer in
                    guard let reply = prompt.dialogAnswer(answer) else { return }
                    Task {
                        await target.store.answer(dialogID: dialog.id, sessionID: session.piSessionID,
                                                  generation: session.generation, answer: reply)
                    }
                }
            } else if sizeClass == .regular {
                NWComposer(isFocused: focused) { attachments } field: { field } controls: {
                    AttachButton(state: state, enabled: canAttach, chip: true)
                    Spacer(minLength: NW.Space.m)
                    action
                }
            } else {
                if !state.attachments.isEmpty { attachments }
                NWCapsuleComposer {
                    AttachButton(state: state, enabled: canAttach)
                } field: { field } action: { action }
            }
        }
        .padding(.horizontal, sizeClass == .regular ? MobileLayout.padThreadGutter : MobileLayout.gutter)
        .padding(.top, NW.Space.m)
        .padding(.bottom, MobileLayout.composerBottom)
        .background(Color.nw.bgWindow)
        .accessibilityIdentifier("project-composer")
    }

    private var field: some View {
        @Bindable var store = target.store
        return TextField(task == nil ? "Message the project owner…" : "Steer this thread…", text: $store.draft, axis: .vertical)
            .font(.nw(.body)).foregroundStyle(Color.nw.textPrimary)
            .lineLimit(1...NWComposerMetrics.fieldMaxLines)
            .focused($focused)
            .accessibilityLabel("Message to project")
    }

    private var attachments: some View {
        ScrollView(.horizontal) {
            HStack(spacing: NW.Space.s) {
                ForEach(state.attachments) { item in
                    NWAttachmentChip(item.image.name ?? "Image", thumbnail: item.thumbnail, remove: { state.remove(item.id) })
                }
            }
        }.scrollIndicators(.hidden)
    }

    private var action: some View {
        NWComposerActionButton(.send, enabled: canSend, action: send)
            .accessibilityLabel("Send")
    }

    private func send() {
        guard canSend else { return }
        let thread = target
        let text = thread.store.draft
        let images = thread.composer.attachments.map(\.image)
        let submitted = thread.composer.attachments.map(\.id)
        sending = true
        Task { @MainActor in
            defer { sending = false }
            let sent: Bool
            if task == nil {
                sent = await projects.model.sendMessage(ref, text: text, images: images)
            } else {
                sent = await thread.store.send(images: images, delivery: .followUp)
            }
            if sent {
                if thread.store.draft == text { thread.store.draft = "" }
                for id in submitted { thread.composer.remove(id) }
                focused = false
            }
        }
    }
}
