import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The composer slot at the bottom of `ThreadScreen` (thread track): a question in the field's
/// place while pi asks one (or a subagent's, once its row's Answer is tapped); otherwise the
/// subagents and Up next in one card (`SubagentTraySection`, the host's queue), the
/// slash-command list while the draft is "/…", and the field.
///
/// - **iPhone** (MobileThread, MobileQueue boards): the paperclip beside a capsule field with
///   Send inside it. While the field is in use, the commands, model and thinking chips sit above.
/// - **iPad** (iPadThread, iPadQueue, iPadPortrait boards): the Mac's card, the field over one
///   row of the paperclip, "/ commands", the model and thinking chips, and Send.
/// - **A design's chat on iPad** (iPadDesign): the same card at the compact size, with no "/"
///   (typing / still opens the commands), the model's short name and the thinking level alone.
///
/// Send steers the message in while pi works (pi reads it once its current tool calls finish,
/// before its next step); hold it for the other two ways (`NativeSendChoice`): wait for the turn
/// to end, or steer now, which stops pi and sends at once. Stop lives in the thread's header. The context
/// ring sits just before Send on both (ContextIdeas › A); a tap opens its details as a sheet.
struct ThreadComposer: View {
    let ref: AgentRef
    @Environment(ThreadStores.self) private var threads
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(MobileNavigator.self) private var navigator
    /// A design's chat (iPadDesign): the card without "/", the model's short name (DesignPad/).
    @Environment(\.composerDesignChat) private var designChat
    @FocusState private var focused: Bool

    private var presentation: ComposerPresentation { navigator.composerPresentation.state(for: ref) }

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
                let key = session.key + ":" + dialog.id
                let prompt = NativeQuestionPrompt(dialog: dialog)
                if state.questionHiding.isHidden(key) {
                    // Folded to read the thread; it still holds the composer's place.
                    NWQuestionCardHiddenLine(question: prompt.question) {
                        withNWAnimation(.disclosure) { state.questionHiding.show() }
                    }
                    .id(key + ":hidden")
                    .nwTransition(.content)
                } else {
                    QuestionPanel(prompt: prompt, count: store.dialogs.count, enabled: live && store.supports("answer"), docked: !wide,
                                  hide: { withNWAnimation(.disclosure) { state.questionHiding.hide(key) } }) { answer in
                        guard let reply = prompt.dialogAnswer(answer) else { return }
                        Task {
                            await store.answer(dialogID: dialog.id, sessionID: session.piSessionID, generation: session.generation,
                                               answer: reply)
                        }
                    }
                    .id(key)
                    // Docked on a phone, the panel runs to the screen's edges.
                    .padding(.horizontal, wide ? 0 : -MobileLayout.gutter)
                    .padding(.bottom, wide ? 0 : -MobileLayout.composerBottom)
                    .nwTransition(.content)
                }
            } else if let run = answering(store, state: state), let prompt = nativeSubagentQuestionPrompt(run) {
                // A subagent's question, from its row's Answer: hiding it returns to the tray.
                QuestionPanel(prompt: prompt, enabled: live && store.takesSubagentCommands, docked: !wide,
                              hide: { withNWAnimation(.content) { state.answeringRun = nil } }) { answer in
                    guard let reply = prompt.messageReply(answer) else { return }
                    SubagentCommands(store: store, enabled: live && store.takesSubagentCommands).send(run.runID, .answer(reply))
                    withNWAnimation(.content) { state.answeringRun = nil }
                }
                .id("subagent:" + run.id)
                .padding(.horizontal, wide ? 0 : -MobileLayout.gutter)
                .padding(.bottom, wide ? 0 : -MobileLayout.composerBottom)
                .nwTransition(.content)
            } else {
                if let tray = store.tray {
                    NWDockStack(size: wide ? .pad : .phone, showsTray: true, showsQueue: !state.rows.isEmpty) {
                        SubagentTraySection(ref: ref, tray: tray, store: store, state: state, size: wide ? .pad : .phone, enabled: live)
                    } queue: {
                        QueueSection(store: store, state: state, presentation: presentation, enabled: live, framed: false)
                    }
                    .nwTransition(.list)
                } else {
                    QueueSection(store: store, state: state, presentation: presentation, enabled: live)
                }
                if let matches = state.matches {
                    NWTouchCommandList(commands: matches.commands.map(Self.command), total: matches.total, query: matches.query,
                                       wide: wide) { chosen in
                        store.draft = "/" + chosen.name + " "
                        focused = true
                    }
                    .nwTransition(.content)
                }
                if wide || designChat {
                    card(store: store, state: state, host: host, live: live)
                } else {
                    phone(store: store, state: state, host: host, live: live)
                }
            }
        }
        .padding(.horizontal, designChat ? MobileLayout.padDesignComposerInset : wide ? MobileLayout.padThreadGutter : MobileLayout.gutter)
        .padding(.top, designChat ? MobileLayout.padDesignComposerTop : NW.Space.m)
        .padding(.bottom, MobileLayout.composerBottom)
        .background(Color.nw.bgWindow)
        .nwAnimation(.content, value: store.dialogs.isEmpty)
        .nwAnimation(.list, value: store.tray == nil)
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
        .sheet(isPresented: Binding(get: { presentation.showingContext }, set: { presentation.showingContext = $0 })) {
            ContextDetailsSheet(store: store, live: live) { id in presentation.find(id) }
        }
        .sheet(isPresented: Binding(get: { presentation.choosingModel }, set: { presentation.choosingModel = $0 })) {
            ModelPickerSheet(host: host, current: store.model, currentLevels: { store.snapshot?.thinkingLevels }) { model in
                Task { await store.setModel(model) }
            }
        }
    }

    /// The run whose question is open from its row's Answer, while it still asks.
    private func answering(_ store: NativeThreadStore, state: ComposerState) -> NativeSubagent? {
        guard let id = state.answeringRun else { return nil }
        return store.subagents.first { $0.runID == id && nativeRunPhase($0) == .needsYou }
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
                HStack(spacing: 0) {
                    contextMeter(store: store, state: state)
                    sendButton(store: store, state: state, live: live)
                }
            }
        }
    }

    // MARK: iPad

    private func card(store: NativeThreadStore, state: ComposerState, host: MobileHost?, live: Bool) -> some View {
        NWComposer(isFocused: focused) {
            if !state.attachments.isEmpty { attachmentChips(state) }
        } field: {
            // A command draft shows in mono while its list is open (iPadPortrait).
            field(store: store, placeholder: designChat ? MobileLayout.padDesignComposerPlaceholder : store.running ? "Queue a follow-up…"
                  : store.commands.isEmpty ? "Follow up…" : "Follow up, or / for commands…", command: state.matches != nil)
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
            // The ring and Send keep their place whatever the chips do.
            HStack(spacing: 0) {
                contextMeter(store: store, state: state)
                sendButton(store: store, state: state, live: live)
            }
        }
    }

    @ViewBuilder private func cardControls(store: NativeThreadStore, state: ComposerState, live: Bool) -> some View {
        if acceptsImages(store) { AttachButton(state: state, enabled: live, chip: true) }
        chips(store: store, state: state, live: live).buttonStyle(.nwComposerChip())
    }

    // MARK: Parts

    private func field(store: NativeThreadStore, placeholder: String, command: Bool = false, style: NWTextStyle = .body) -> some View {
        @Bindable var bindable = store
        return TextField(placeholder, text: $bindable.draft, axis: .vertical)
            .font(command ? .nw(.code) : .nw(style))
            .foregroundStyle(Color.nw.textPrimary)
            .lineLimit(1...NWComposerMetrics.fieldMaxLines)
            .focused($focused)
            .accessibilityLabel("Message to agent")
    }

    @ViewBuilder private func chips(store: NativeThreadStore, state: ComposerState, live: Bool) -> some View {
        if !store.commands.isEmpty, !designChat {
            CommandsChip {
                if store.draft.isEmpty { store.draft = "/" }
                focused = true
            }
        }
        if store.model != nil || store.supportedActions.contains("setModel") {
            ModelChip(model: store.model, canChange: live && store.supportedActions.contains("setModel"), short: designChat) {
                presentation.choosingModel = true
            }
        }
        if NativeThinkingLevel.offered(thinking: store.thinking, supportedActions: store.supportedActions, model: store.model,
                                       listing: state.models, levels: store.thinkingLevels) {
            ThinkingChip(level: store.thinking, levels: store.thinkingLevels, enabled: live) { level in Task { await store.setThinking(level) } }
        }
        if store.offersServiceTier {
            SpeedChip(tier: store.serviceTier, tiers: store.serviceTiers, enabled: live) { tier in Task { await store.setServiceTier(tier) } }
        }
    }

    private func hasChips(_ store: NativeThreadStore, state: ComposerState) -> Bool {
        !store.commands.isEmpty || store.model != nil || store.supportedActions.contains("setModel") || store.offersServiceTier
            || NativeThinkingLevel.offered(thinking: store.thinking, supportedActions: store.supportedActions, model: store.model,
                                           listing: state.models, levels: store.thinkingLevels)
    }

    /// The context ring (no ring from a host that reports no context). Its own equatable view:
    /// a keystroke or a streamed chunk never redraws it.
    private func contextMeter(store: NativeThreadStore, state: ComposerState) -> some View {
        ContextMeterButton(store: store, expanded: presentation.showingContext) { presentation.showingContext = true }
            .equatable()
    }

    private func acceptsImages(_ store: NativeThreadStore) -> Bool {
        store.supportedActions.contains("sendImages")
    }

    /// Send: steers at the next step while pi works (a message that begins with "/" waits for the
    /// turn to end instead), sends at once while it is idle. Held while pi works, it offers all
    /// three ways to send.
    private func sendButton(store: NativeThreadStore, state: ComposerState, live: Bool) -> some View {
        let hasDraft = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let enabled = live && store.acceptsSend && hasDraft && !store.busy
        let running = store.running
        return NWComposerActionButton(.send, enabled: enabled) { Self.send(NativeSendChoice.nextStep.delivery, store: store, state: state) }
            .keyboardShortcut(.return, modifiers: .command)
            .contextMenu {
                if running, enabled {
                    ForEach(NativeSendChoice.allCases) { choice in
                        Button(choice.title, systemImage: Self.symbol(choice)) { Self.send(choice.delivery, store: store, state: state) }
                    }
                }
            }
            .accessibilityLabel(running ? NativeSendChoice.nextStep.title : "Send")
            .accessibilityHint(running ? NativeSendChoice.nextStep.detail : "")
            .accessibilityActions {
                if running, enabled {
                    ForEach(NativeSendChoice.allCases.filter { $0 != .nextStep }) { choice in
                        Button(choice.title) { Self.send(choice.delivery, store: store, state: state) }
                    }
                }
            }
    }

    private static func symbol(_ choice: NativeSendChoice) -> String {
        switch choice {
        case .wait: "text.line.first.and.arrowtriangle.forward"
        case .nextStep: "arrow.right.to.line"
        case .now: "arrow.turn.down.right"
        }
    }

    @MainActor @discardableResult
    static func send(_ delivery: NativeThreadDelivery, store: NativeThreadStore, state: ComposerState) -> Task<Void, Never> {
        let images = state.attachments.map(\.image)
        let submitted = state.attachments.map(\.id)
        return Task {
            if await store.send(images: images, delivery: delivery) {
                for id in submitted { state.remove(id) }
            }
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
        NWTouchCommand(name: command.name, description: command.description, arguments: command.arguments,
                       tag: NativeSlashMatches.tag(command))
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
