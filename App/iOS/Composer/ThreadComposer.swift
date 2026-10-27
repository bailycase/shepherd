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
///   Send inside it. The commands, model, thinking and speed chips remain visible above.
/// - **iPad** (iPadThread, iPadQueue, iPadPortrait boards): the Mac's card, the field over one
///   row of the paperclip, "/ commands", the model and thinking chips, and Send.
/// - **A design's chat on iPad** (iPadDesign): the same card at the compact size, with no "/"
///   (typing / still opens the commands), the model's short name and the thinking level alone.
///
/// Send queues the message while pi works (it goes when the turn ends); hold it for the other way
/// (`NativeSendChoice`): steer now, which stops pi and sends at once. Stop is Send's corner while
/// pi works with nothing to send, and also in the thread's header. The context ring sits just before Send on both (ContextIdeas › A); a tap opens its
/// details as a sheet.
struct ThreadComposer: View {
    let ref: AgentRef
    @Environment(ThreadStores.self) private var threads
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
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
        let goalSize: SHGoalSize = wide && !navigator.padSidebarOverlays ? .desktop : .touch
        VStack(alignment: .leading, spacing: MobileLayout.composerSpacing) {
            if let notice = store.notice {
                banner(notice)
            }
            if state.pendingImports > 0 { banner("Adding images…") }
            if store.running, store.hasDraft || !state.attachments.isEmpty {
                banner("Hold Send to steer now · ⌘↩ Steer now")
            }
            if let error = state.attachmentError {
                banner(error, failed: true)
            }
            ForEach(store.widgets) { widget in
                ComposerWidget(title: widget.title, text: widget.text)
            }
            if store.hasGoal || store.dialogs.isEmpty {
                if store.hasGoal || store.tray != nil {
                    SHDockStack(size: store.hasGoal && goalSize == .desktop ? .pointer : wide ? .pad : .phone, showsTray: true, showsQueue: !state.rows.isEmpty) {
                        VStack(spacing: 0) {
                            if store.hasGoal {
                                ThreadGoalCard(store: store, active: live,
                                               size: goalSize, framed: false)
                            }
                            if let tray = store.tray {
                                SubagentTraySection(ref: ref, tray: tray, store: store, state: state,
                                                    size: wide ? .pad : .phone, enabled: live)
                                    .overlay(alignment: .top) {
                                        if store.hasGoal { SHHairline(color: Color.sh.lineStrong) }
                                    }
                            }
                        }
                    } queue: {
                        QueueSection(store: store, state: state, presentation: presentation, enabled: live, framed: false)
                    }
                    .shTransition(.list)
                } else {
                    QueueSection(store: store, state: state, presentation: presentation, enabled: live)
                }
            }
            if let dialog = store.dialogs.first, let session = store.session {
                let key = session.key + ":" + dialog.id
                let prompt = NativeQuestionPrompt(dialog: dialog)
                if state.questionHiding.isHidden(key) {
                    // Folded to read the thread; it still holds the composer's place.
                    SHQuestionCardHiddenLine(question: prompt.question) {
                        withSHAnimation(.disclosure) { state.questionHiding.show() }
                    }
                    .id(key + ":hidden")
                    .shTransition(.content)
                } else {
                    QuestionPanel(prompt: prompt, count: store.dialogs.count, enabled: live && store.supports("answer"), docked: !wide,
                                  hide: { withSHAnimation(.disclosure) { state.questionHiding.hide(key) } }) { answer in
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
                    .shTransition(.content)
                }
            } else {
                if let matches = state.matches {
                    SHTouchCommandList(commands: matches.commands.map(Self.command), total: matches.total, query: matches.query,
                                       wide: wide) { chosen in
                        store.draft = "/" + chosen.name + " "
                        focused = true
                    }
                    .shTransition(.content)
                }
                if wide || designChat {
                    card(store: store, state: state, host: host, live: live)
                } else {
                    phone(store: store, state: state, host: host, live: live)
                }
            }
        }
        .padding(.horizontal, designChat ? MobileLayout.padDesignComposerInset : wide ? MobileLayout.padThreadGutter : MobileLayout.gutter)
        .padding(.top, designChat ? MobileLayout.padDesignComposerTop : SH.Space.m)
        .padding(.bottom, MobileLayout.composerBottom)
        .background(Color.sh.bgWindow)
        .shAnimation(.content, value: store.dialogs.isEmpty)
        .shAnimation(.list, value: store.tray == nil)
        .shAnimation(.list, value: store.goalID)
        .onAppear { state.restoreDraft(in: store) }
        .task(id: store.draft) {
            do { try await Task.sleep(for: ComposerState.draftSaveDelay) } catch { return }
            state.saveDraft(store.draft)
        }
        .onDisappear { state.saveDraft(store.draft) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { state.saveDraft(store.draft) }
        }
        .onChange(of: store.sentCount) { _, _ in
            focused = false
            state.saveDraft(store.draft)
        }
        .onChange(of: focused) { _, focused in
            if focused { navigator.focusedComposer = ref } else if navigator.focusedComposer == ref { navigator.focusedComposer = nil }
        }
        .task { GoalNotifications.shared.watch(store, hosts: hosts, ref: ref) }
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

    /// Asks the catalog again for a new connection, or once the thread reports a thinking level.
    private struct ModelsAsk: Hashable {
        var session: UUID?
        var thinking: Bool
    }

    // MARK: Phone

    @ViewBuilder private func phone(store: NativeThreadStore, state: ComposerState, host: MobileHost?, live: Bool) -> some View {
        if hasChips(store, state: state) {
            ScrollView(.horizontal) {
                HStack(spacing: SH.Space.xxs) { chips(store: store, state: state, live: live) }
                    .buttonStyle(.sh(.ghost, size: .m))
            }
            .scrollIndicators(.hidden)
            .shTransition(.content)
        }
        if !state.attachments.isEmpty {
            attachments(state)
        }
        let capsuleField = field(store: store, placeholder: store.running ? "Queue a follow-up…" : "Follow up…")
        let capsuleAction = HStack(spacing: 0) {
            contextMeter(store: store, state: state)
            sendButton(store: store, state: state, live: live)
        }
        if acceptsImages(store) {
            SHCapsuleComposer { AttachButton(state: state, enabled: live) } field: { capsuleField } action: { capsuleAction }
        } else {
            SHCapsuleComposer { capsuleField } action: { capsuleAction }
        }
    }

    // MARK: iPad

    private func card(store: NativeThreadStore, state: ComposerState, host: MobileHost?, live: Bool) -> some View {
        SHComposer(isFocused: focused) {
            if !state.attachments.isEmpty { attachmentChips(state) }
        } field: {
            // A command draft shows in mono while its list is open (iPadPortrait).
            field(store: store, placeholder: designChat ? MobileLayout.padDesignComposerPlaceholder : store.running ? "Queue a follow-up…"
                  : store.commands.isEmpty ? "Follow up…" : "Follow up, or / for commands…", command: state.matches != nil)
        } controls: {
            // Where the row outgrows the card (a narrow column, as beside iPhone Duo's fold, or
            // the accessibility sizes) it scrolls rather than truncating every chip, and Send
            // stays put.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SH.Space.xxs) { cardControls(store: store, state: state, live: live) }
                ScrollView(.horizontal) {
                    HStack(spacing: SH.Space.xxs) { cardControls(store: store, state: state, live: live) }
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, SH.Space.m)
            // The ring and Send keep their place whatever the chips do.
            HStack(spacing: 0) {
                contextMeter(store: store, state: state)
                sendButton(store: store, state: state, live: live)
            }
        }
    }

    @ViewBuilder private func cardControls(store: NativeThreadStore, state: ComposerState, live: Bool) -> some View {
        if acceptsImages(store) { AttachButton(state: state, enabled: live, chip: true) }
        chips(store: store, state: state, live: live).buttonStyle(.shComposerChip())
    }

    // MARK: Parts

    private func field(store: NativeThreadStore, placeholder: String, command: Bool = false, style: SHTextStyle = .body) -> some View {
        @Bindable var bindable = store
        return TextField(placeholder, text: $bindable.draft, axis: .vertical)
            .font(command ? .sh(.code) : .sh(style))
            .foregroundStyle(Color.sh.textPrimary)
            .lineLimit(1...SHComposerMetrics.fieldMaxLines)
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

    /// Send: queues the message while pi works, sends at once while it is idle. Held while pi
    /// works, it offers both ways to send (Steer now stops pi, where the host can). ⌘↩ on a
    /// hardware keyboard steers now, as on the Mac. While pi works with nothing to send (no
    /// words, no attachments) the same corner is Stop.
    @ViewBuilder private func sendButton(store: NativeThreadStore, state: ComposerState, live: Bool) -> some View {
        let running = store.running
        if NativeSendChoice.stopsInPlaceOfSend(running: running, hasInput: store.hasDraft || !state.attachments.isEmpty || state.pendingImports > 0) {
            SHComposerActionButton(.stop, enabled: live && store.supports("abort")) { Task { await store.abort() } }
                .accessibilityLabel("Stop agent")
        } else {
            let enabled = live && store.acceptsSend && (store.hasDraft || !state.attachments.isEmpty) && !store.busy && state.pendingImports == 0
            SHComposerActionButton(.send, enabled: enabled) { Self.send(NativeSendChoice.wait.delivery, store: store, state: state) }
                .background {
                    Button("Steer now · ⌘↩") { Self.send(NativeSendChoice.now.delivery, store: store, state: state) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!enabled)
                        .hidden()
                        .accessibilityHidden(true)
                }
                .contextMenu {
                    if running, enabled {
                        ForEach(NativeSendChoice.allCases) { choice in
                            Button(choice.title, systemImage: Self.symbol(choice)) { Self.send(choice.delivery, store: store, state: state) }
                        }
                    }
                }
                .accessibilityLabel(running ? NativeSendChoice.wait.title : "Send")
                .accessibilityHint(running ? NativeSendChoice.wait.detail : "")
                .accessibilityActions {
                    if running, enabled {
                        ForEach(NativeSendChoice.allCases.filter { $0 != .wait }) { choice in
                            Button(choice.title) { Self.send(choice.delivery, store: store, state: state) }
                        }
                    }
                }
        }
    }

    private static func symbol(_ choice: NativeSendChoice) -> String {
        switch choice {
        case .wait: "text.line.first.and.arrowtriangle.forward"
        case .now: "arrow.turn.down.right"
        }
    }

    @MainActor @discardableResult
    static func send(_ delivery: NativeThreadDelivery, store: NativeThreadStore, state: ComposerState) -> Task<Void, Never> {
        guard state.pendingImports == 0 else { return Task {} }
        let images = state.attachments.map(\.image)
        let submitted = state.attachments.map(\.id)
        return Task {
            if await store.send(images: images, delivery: delivery) {
                state.saveDraft(store.draft)
                for id in submitted { state.remove(id) }
                if state.attachments.isEmpty { state.clearAttachments() }
            }
        }
    }

    private func attachments(_ state: ComposerState) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: SH.Space.s) { attachmentChips(state) }
        }
        .scrollIndicators(.hidden)
    }

    private func attachmentChips(_ state: ComposerState) -> some View {
        ForEach(state.attachments) { attachment in
            SHAttachmentChip(attachment.image.name ?? "Image", thumbnail: attachment.thumbnail) { state.remove(attachment.id) }
        }
    }

    private func banner(_ text: String, failed: Bool = false) -> some View {
        Text(text).font(.sh(.caption)).foregroundStyle(failed ? Color.sh.failed : Color.sh.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func command(_ command: NativeCommand) -> SHTouchCommand {
        SHTouchCommand(name: command.name, description: command.description, arguments: command.arguments,
                       tag: NativeSlashMatches.tag(command))
    }
}

/// An extension's text widget above the composer: its title in caps, then its text.
private struct ComposerWidget: View {
    let title: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xxs) {
            if let title { Text(title).shSectionLabel().foregroundStyle(Color.sh.textTertiary) }
            Text(text).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary).lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
