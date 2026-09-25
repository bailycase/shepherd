import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The composer slot at the bottom of `ThreadScreen` (thread track): a question in the field's
/// place while pi asks one; otherwise Up next (the host's queue), the slash-command list while
/// the draft is "/…", and the field.
///
/// - **iPhone** (MobileThread, MobileQueue boards): the paperclip beside a capsule field with
///   Send inside it. While the field is in use, the commands, model and thinking chips sit above.
/// - **iPad** (iPadThread, iPadQueue, iPadPortrait boards): the Mac's card, the field over one
///   row of the paperclip, "/ commands", the model and thinking chips, and Send.
///
/// Send queues the message while pi works (it goes when pi settles); hold it to Steer now, which
/// pi reads once its current tool calls finish. Stop lives in the thread's header.
struct ThreadComposer: View {
    let ref: AgentRef
    @Environment(ThreadStores.self) private var threads
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(MobileNavigator.self) private var navigator
    @FocusState private var focused: Bool

    var body: some View {
        let store = threads.store(for: ref)
        let state = ComposerStates.shared.state(for: ref)
        let host = hosts.host(ref.host)
        let live = store.isLive && host?.phase.isConnected == true
        let wide = sizeClass == .regular
        VStack(alignment: .leading, spacing: MobileLayout.composerSpacing) {
            if let notice = store.notice {
                banner(notice)
            }
            if let error = state.attachmentError {
                banner(error, failed: true)
            }
            ForEach(store.widgets) { widget in
                ComposerWidget(title: widget.title, text: widget.text)
            }
            if let dialog = store.dialogs.first, let session = store.session {
                QuestionPanel(dialog: dialog, count: store.dialogs.count, enabled: live && store.supports("answer"), docked: !wide) { answer in
                    Task {
                        await store.answer(dialogID: dialog.id, sessionID: session.piSessionID, generation: session.generation,
                                           answer: answer)
                    }
                }
                .id(session.key + ":" + dialog.id)
                // Docked on a phone, the panel runs to the screen's edges.
                .padding(.horizontal, wide ? 0 : -MobileLayout.gutter)
                .padding(.bottom, wide ? 0 : -MobileLayout.composerBottom)
                .nwTransition(.content)
            } else {
                QueueSection(store: store, state: state, enabled: live)
                if let matches = state.matches {
                    NWTouchCommandList(commands: matches.commands.map(Self.command), total: matches.total, query: matches.query,
                                       wide: wide) { chosen in
                        store.draft = "/" + chosen.name + " "
                        focused = true
                    }
                    .nwTransition(.content)
                }
                if wide {
                    card(store: store, state: state, host: host, live: live)
                } else {
                    phone(store: store, state: state, host: host, live: live)
                }
            }
        }
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.top, NW.Space.m)
        .padding(.bottom, MobileLayout.composerBottom)
        .background(Color.nw.bgWindow)
        .nwAnimation(.content, value: store.dialogs.isEmpty)
        .onChange(of: store.sentCount) { _, _ in focused = false }
        .onChange(of: focused) { _, focused in
            if focused { navigator.focusedComposer = ref } else if navigator.focusedComposer == ref { navigator.focusedComposer = nil }
        }
        .task {
            guard navigator.refocusComposer == ref else { return }
            navigator.refocusComposer = nil
            focused = true
        }
        .onChange(of: store.queue, initial: true) { _, queue in state.update(queue: queue) }
        .onChange(of: store.draft, initial: true) { _, draft in state.update(draft: draft, commands: store.commands) }
        .onChange(of: store.commands) { _, commands in state.update(draft: store.draft, commands: commands) }
        // Whether the thread's model takes a thinking level: the host's catalog, once per connection.
        .task(id: ModelsAsk(session: host?.session, thinking: store.thinking != nil && store.supportedActions.contains("setThinking"))) {
            if store.thinking != nil && store.supportedActions.contains("setThinking") { await state.loadModels(host: host) }
        }
        .sheet(isPresented: Binding(get: { state.choosingModel }, set: { state.choosingModel = $0 })) {
            ModelPickerSheet(host: host, current: store.model, currentLevels: { store.snapshot?.thinkingLevels }) { model in
                Task { await store.setModel(model) }
            }
        }
    }

    /// Asks the catalog again for a new connection, or once the thread reports a thinking level.
    private struct ModelsAsk: Hashable {
        var session: UUID?
        var thinking: Bool
    }

    // MARK: Phone

    @ViewBuilder private func phone(store: NativeThreadStore, state: ComposerState, host: MobileHost?, live: Bool) -> some View {
        let inUse = focused || !store.draft.isEmpty || !state.attachments.isEmpty
        if inUse, hasChips(store, state: state) {
            ScrollView(.horizontal) {
                HStack(spacing: NW.Space.xxs) { chips(store: store, state: state, live: live) }
                    .buttonStyle(.nw(.ghost, size: .m))
            }
            .scrollIndicators(.hidden)
            .nwTransition(.content)
        }
        if !state.attachments.isEmpty {
            attachments(state)
        }
        HStack(alignment: .bottom, spacing: NW.Space.s) {
            if acceptsImages(store) {
                AttachButton(state: state, enabled: live)
            }
            NWCapsuleComposer(isFocused: focused) {
                field(store: store, placeholder: store.running ? "Queue a follow-up…" : "Follow up…")
            } action: {
                sendButton(store: store, state: state, live: live)
            }
        }
    }

    // MARK: iPad

    private func card(store: NativeThreadStore, state: ComposerState, host: MobileHost?, live: Bool) -> some View {
        NWComposer(isFocused: focused) {
            if !state.attachments.isEmpty { attachmentChips(state) }
        } field: {
            field(store: store, placeholder: store.running ? "Queue a follow-up…"
                  : store.commands.isEmpty ? "Follow up…" : "Follow up, or / for commands…")
        } controls: {
            if typeSize.isAccessibilitySize {
                // At the accessibility sizes the row outgrows the card: it scrolls rather than
                // truncating every chip, and Send stays put.
                ScrollView(.horizontal) {
                    HStack(spacing: NW.Space.xxs) { cardControls(store: store, state: state, live: live) }
                }
                .scrollIndicators(.hidden)
            } else {
                cardControls(store: store, state: state, live: live)
                Spacer(minLength: NW.Space.m)
            }
            sendButton(store: store, state: state, live: live)
        }
    }

    @ViewBuilder private func cardControls(store: NativeThreadStore, state: ComposerState, live: Bool) -> some View {
        if acceptsImages(store) { AttachButton(state: state, enabled: live, chip: true) }
        chips(store: store, state: state, live: live).buttonStyle(.nwComposerChip())
    }

    // MARK: Parts

    private func field(store: NativeThreadStore, placeholder: String) -> some View {
        @Bindable var bindable = store
        return TextField(placeholder, text: $bindable.draft, axis: .vertical)
            .font(.nw(.body))
            .foregroundStyle(Color.nw.textPrimary)
            .lineLimit(1...NWComposerMetrics.fieldMaxLines)
            .focused($focused)
            .accessibilityLabel("Message to agent")
    }

    @ViewBuilder private func chips(store: NativeThreadStore, state: ComposerState, live: Bool) -> some View {
        if !store.commands.isEmpty {
            CommandsChip {
                if store.draft.isEmpty { store.draft = "/" }
                focused = true
            }
        }
        if store.model != nil || store.supportedActions.contains("setModel") {
            ModelChip(model: store.model, canChange: live && store.supportedActions.contains("setModel")) { state.choosingModel = true }
        }
        if NativeThinkingLevel.offered(thinking: store.thinking, supportedActions: store.supportedActions, model: store.model,
                                       listing: state.models, levels: store.thinkingLevels) {
            ThinkingChip(level: store.thinking, levels: store.thinkingLevels, enabled: live) { level in Task { await store.setThinking(level) } }
        }
    }

    private func hasChips(_ store: NativeThreadStore, state: ComposerState) -> Bool {
        !store.commands.isEmpty || store.model != nil || store.supportedActions.contains("setModel")
            || NativeThinkingLevel.offered(thinking: store.thinking, supportedActions: store.supportedActions, model: store.model,
                                           listing: state.models, levels: store.thinkingLevels)
    }

    private func acceptsImages(_ store: NativeThreadStore) -> Bool {
        store.supportedActions.contains("sendImages")
    }

    /// Send: queues while pi works, sends at once while it is idle. Held while pi works, it
    /// offers Steer now.
    private func sendButton(store: NativeThreadStore, state: ComposerState, live: Bool) -> some View {
        let hasDraft = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let enabled = live && store.acceptsSend && hasDraft && !store.busy
        let running = store.running
        return NWComposerActionButton(.send, enabled: enabled) { send(.followUp, store: store, state: state) }
            .keyboardShortcut(.return, modifiers: .command)
            .contextMenu {
                if running, enabled {
                    Button("Queue", systemImage: "text.line.first.and.arrowtriangle.forward") { send(.followUp, store: store, state: state) }
                    Button("Steer now", systemImage: "arrow.turn.down.right") { send(.steer, store: store, state: state) }
                }
            }
            .accessibilityLabel(running ? "Queue message" : "Send")
            .accessibilityHint(running ? "Goes when the agent finishes this turn" : "")
            .accessibilityActions {
                if running, enabled {
                    Button("Steer now") { send(.steer, store: store, state: state) }
                }
            }
    }

    private func send(_ delivery: NativeThreadDelivery, store: NativeThreadStore, state: ComposerState) {
        let images = state.attachments.map(\.image)
        Task {
            let before = store.sentCount
            await store.send(images: images, delivery: delivery)
            if store.sentCount > before { state.clearAttachments() }
        }
    }

    private func attachments(_ state: ComposerState) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: NW.Space.s) { attachmentChips(state) }
        }
        .scrollIndicators(.hidden)
    }

    private func attachmentChips(_ state: ComposerState) -> some View {
        ForEach(state.attachments) { attachment in
            NWAttachmentChip(attachment.image.name ?? "Image", thumbnail: attachment.thumbnail) { state.remove(attachment.id) }
        }
    }

    private func banner(_ text: String, failed: Bool = false) -> some View {
        Text(text).font(.nw(.caption)).foregroundStyle(failed ? Color.nw.failed : Color.nw.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func command(_ command: NativeCommand) -> NWTouchCommand {
        NWTouchCommand(name: command.name, description: command.description, tag: NativeSlashMatches.tag(command))
    }
}

/// An extension's text widget above the composer: its title in caps, then its text.
private struct ComposerWidget: View {
    let title: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.xxs) {
            if let title { Text(title).nwSectionLabel().foregroundStyle(Color.nw.textTertiary) }
            Text(text).font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary).lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
