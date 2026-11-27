import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The composer slot at the bottom of `ThreadScreen` (thread track): a question in the field's
/// place while pi asks one (or a subagent's, once its row's Answer is tapped); otherwise the
/// subagents and Up next in one card (`SubagentTraySection`, the host's queue), the
/// slash-command list while the draft is "/…", and the field.
///
/// - **Every size** (the Mobile, iPad and Duo thread boards): one pill, the + beside the field, the
///   model chip (and its thinking level where there is room), the context ring and Send. The + opens
///   Photos, Files and Commands; the model chip opens the model picker, which also holds the thinking
///   level and the speed. On iPhone Duo's narrow column the chip steps aside while a draft is typed.
/// - **A design's chat on iPad** (iPadDesign): the same pill with no "/" (typing / still opens the
///   commands), the model's name and thinking level kept whole, no context ring, and no goal or
///   subagents card above it.
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
    /// A thread iPad keeps mounted behind the selected one presents nothing (`threadDetailActive`).
    @Environment(\.threadDetailActive) private var detailActive
    /// A design's chat (iPadDesign): the card without "/", the ring or the goal and subagents cards (DesignPad/).
    @Environment(\.composerDesignChat) private var designChat
    /// Whether the field has the keyboard (`ComposerTextView` follows and reports it).
    @State private var focused = false
    /// The @ picker for the host's designs (`design.references.v1`), the Mac's picker rules.
    @State private var mentions = MentionPickerState()
    /// The threads the picker links on "#" (ThreadLinkA): the thread's own host's.
    @Environment(\.shThreadLinks) private var threadLinks
    /// Something is being dragged over the composer.
    @State private var dropTargeted = false
    /// The pill is narrower than `MobileLayout.narrowPillWidth`.
    @State private var narrow = false
    /// The pill is narrower than `MobileLayout.thinkingPillWidth`.
    @State private var compact = false

    private var presentation: ComposerPresentation { navigator.composerPresentation.state(for: ref) }

    var body: some View {
        let _ = SHRenderProbe.tick("composer.body")
        let store = threads.store(for: ref)
        let state = ComposerStates.shared.state(for: ref)
        let host = hosts.host(ref.host)
        let live = store.isLive && host?.phase.isConnected == true
        let wide = sizeClass == .regular
        let goalSize: SHGoalSize = wide && !navigator.padSidebarOverlays ? .desktop : .touch
        VStack(alignment: .leading, spacing: MobileLayout.composerSpacing) {
            if let banner = NativeStartBanner(store: store, offered: restartOffered(host), connected: host?.connectedClient != nil,
                                              host: host?.name ?? "the host") {
                StartProblemBanner(banner: banner, perform: restartAgent).equatable()
                    .shTransition(.list, edge: .bottom)
            }
            if let notice = store.notice {
                banner(notice)
            }
            if state.pendingImports > 0 { banner("Adding images…") }
            if threads.setAside.contains(ref) {
                banner("Not every unsent message saved on this device is shown here: the ones below fit; the full set is kept aside on this device, unchanged.", failed: true)
            }
            // Sends an earlier launch kept: their text only.
            ForEach(threads.recovered[ref] ?? []) { record in
                SubmissionBanner(typed: record.typed, refused: record.state == .failed, images: record.images, imagesKept: false,
                                 canRestore: state.canRestore(into: store), canDiscard: true) {
                    guard state.canRestore(into: store) else { return }
                    threads.restoreRecovered(record.id, for: ref)
                } discard: {
                    threads.discardRecovered(record.id, for: ref)
                }
            }
            ForEach(store.submissions.filter { $0.state != .sending }) { submission in
                SubmissionBanner(typed: submission.typed, refused: submission.state == .failed, images: submission.images.count,
                                 imagesKept: true, canRestore: state.canRestore(into: store),
                                 canDiscard: store.canDiscardSubmission(submission.id)) {
                    guard state.canRestore(into: store), let restored = store.restoreSubmission(submission.id) else { return }
                    Task { await state.restore(restored.images) }
                    state.saveDraft(store)
                } discard: {
                    guard store.discardSubmission(submission.id) else { return }
                    state.saveDraft(store)
                }
            }
            if let error = state.attachmentError {
                banner(error, failed: true)
            }
            ForEach(store.widgets) { widget in
                ComposerWidget(title: widget.title, text: widget.text)
            }
            if store.hasGoal || store.dialogs.isEmpty {
                // A design's chat draws the pill alone (iPadDesign): the goal and the subagents are on the thread's own screen.
                if !designChat, store.hasGoal || store.hasTray {
                    SHDockStack(size: store.hasGoal && goalSize == .desktop ? .pointer : wide ? .pad : .phone, showsTray: true, showsQueue: !state.rows.isEmpty) {
                        VStack(spacing: 0) {
                            if store.hasGoal {
                                ThreadGoalCard(store: store, active: live,
                                               size: goalSize, framed: false)
                            }
                            if store.hasTray {
                                SubagentTraySection(ref: ref, store: store, state: state, size: wide ? .pad : .phone, enabled: live)
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
                    QuestionPanel(prompt: prompt, count: store.dialogs.count, enabled: live && store.supports("answer"),
                                  hide: { withSHAnimation(.disclosure) { state.questionHiding.hide(key) } }) { answer in
                        guard let reply = prompt.dialogAnswer(answer) else { return }
                        Task {
                            await store.answer(dialogID: dialog.id, sessionID: session.piSessionID, generation: session.generation,
                                               answer: reply)
                        }
                    }
                    .id(key)
                    .shTransition(.content)
                }
            } else {
                if mentions.isOpen {
                    mentionPicker(store: store)
                        .shTransition(.content)
                }
                if let matches = state.matches {
                    SHTouchCommandList(commands: matches.commands.map(Self.command), total: matches.total, query: matches.query,
                                       title: matches.title,
                                       wide: wide) { chosen in
                        if let command = matches.commands.first(where: { $0.name == chosen.name }) {
                            // A skill takes the place of its "$de" (replacing any other skill in the draft).
                            if command.source == "skill" {
                                store.draft = ComposerSkillToken.draft(picking: command.name, for: matches.token)
                            } else {
                                store.draft = matches.completion(command)
                            }
                        }
                        focused = true
                    }
                    .shTransition(.content)
                }
                pill(store: store, state: state, host: host, live: live, wide: wide)
            }
        }
        .padding(.horizontal, designChat ? MobileLayout.padDesignComposerInset : wide ? MobileLayout.padThreadGutter : MobileLayout.gutter)
        .padding(.top, designChat ? MobileLayout.padDesignComposerTop : SH.Space.m)
        .padding(.bottom, MobileLayout.composerBottom)
        .background(Color.sh.bgWindow)
        .modifier(ComposerImageDrop(state: state, enabled: live && acceptsImages(store), targeted: $dropTargeted))
        .shAnimation(.content, value: store.dialogs.isEmpty)
        .shAnimation(.list, value: store.hasTray)
        .shAnimation(.list, value: store.goalID)
        .onAppear { state.restoreDraft(in: store) }
        .task(id: store.draft) {
            do { try await Task.sleep(for: ComposerState.draftSaveDelay) } catch { return }
            state.saveDraft(store)
        }
        .onDisappear { state.saveDraft(store) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { state.saveDraft(store) }
        }
        .onChange(of: store.sentCount) { _, _ in
            focused = false
            state.saveDraft(store)
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
        // A pasted design reference to this host's own design becomes a chip (RefPasted), pinned by the host.
        .onChange(of: store.draft) { old, new in
            pasteReferences(store: store, state: state, from: old, to: new)
            updateMentions(store: store)
        }
        // The picker's rows follow the host's listing, a design opened in it, and pictures landing.
        .onChange(of: MobileDesigns.of(hosts).library(ref.host)?.listing) { _, _ in updateMentions(store: store) }
        .onChange(of: MobileDesigns.of(hosts).library(ref.host)?.mentionsRevision) { _, _ in updateMentions(store: store) }
        .onChange(of: MobileDesigns.of(hosts).mentionPicturesVersion) { _, _ in if mentions.isOpen { updateMentions(store: store) } }
        .onChange(of: store.commands) { _, commands in state.update(draft: store.draft, commands: commands) }
        // Whether the thread's model takes a thinking level: the host's catalog, once per connection.
        .task(id: ModelsAsk(session: host?.session, thinking: store.thinking != nil && store.supportedActions.contains("setThinking"))) {
            if store.thinking != nil && store.supportedActions.contains("setThinking") { await state.loadModels(host: host) }
        }
        .sheet(isPresented: Binding(get: { presentation.showingContext }, set: { presentation.showingContext = $0 }).whenActive(detailActive)) {
            ContextDetailsSheet(store: store, live: live) { id in presentation.find(id) }
        }
        .sheet(isPresented: Binding(get: { presentation.choosingModel }, set: { presentation.choosingModel = $0 }).whenActive(detailActive)) {
            ModelPickerSheet(host: host, current: store.model, currentLevels: { store.snapshot?.thinkingLevels }, choose: { model in
                Task { await store.setModel(model) }
            }) {
                ModelSettingsSections(store: store, state: state, live: live)
            }
        }
    }

    /// Asks the catalog again for a new connection, or once the thread reports a thinking level.
    private struct ModelsAsk: Hashable {
        var session: UUID?
        var thinking: Bool
    }

    // MARK: Pill

    /// A tap on the Can't start banner's button: asks the agent's host to start pi again (the store keeps the progress and any refusal).
    private func restartAgent(_ action: NativeStartAction) {
        let host = hosts.host(ref.host)
        guard let client = host?.connectedClient else { return }
        let store = threads.store(for: ref), agent = ref.agent, offered = restartOffered(host)
        Task {
            await NativeStartRestart.perform(action, store: store, offered: offered, connected: true) {
                try await client.agentAction(agentID: agent, action: $0)
            }
        }
    }

    private func restartOffered(_ host: MobileHost?) -> Bool { host.map { NativeStartRestart.isOffered(by: $0.capabilities) } ?? false }

    /// The one-line pill (the boards' `.gt-cmp`), on every size; its attachments wait in a row above.
    @ViewBuilder private func pill(store: NativeThreadStore, state: ComposerState, host: MobileHost?, live: Bool, wide: Bool) -> some View {
        if !store.attachedReferences.isEmpty || !store.attachedElements.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: SH.Space.s) {
                    referenceChips(store)
                    elementChips(store)
                }
            }
            .scrollIndicators(.hidden)
        }
        if !state.attachments.isEmpty {
            attachments(state)
        }
        let placeholder = designChat ? MobileLayout.padDesignComposerPlaceholder
            : store.running ? "Queue a follow-up…"
            : !wide || store.commands.isEmpty ? "Follow up…"
            : store.commands.contains(where: { $0.source == "skill" }) ? "Follow up, / for commands, $ for skills…"
            : "Follow up, or / for commands…"
        let offersCommands = !store.commands.isEmpty && !designChat
        let offersImages = acceptsImages(store)
        // A narrow column (iPhone Duo's, beside its rail, or beside its side pane) keeps the model's name whole and drops the thinking level
        // (DuoOpenSidePane's "claude-opus"), and gives a typed draft the chip's room.
        let showsModel = !(narrow && store.hasDraft)
        // A command draft shows in mono while its list is open (iPadPortrait).
        let fieldView = field(store: store, state: state, live: live, placeholder: placeholder, command: state.matches != nil)
        let trailingView = HStack(spacing: 0) {
            if showsModel, store.model != nil || store.supportedActions.contains("setModel") {
                // The thinking level shows where the pill has room (480pt and wider), in a design's chat too (iPadDesign).
                ModelChip(model: store.model, thinking: wide && !compact ? store.thinking.map(NativeThinkingLevel.title) : nil,
                          canChange: live && store.supportedActions.contains("setModel")) {
                    presentation.choosingModel = true
                }
                // A design's chat keeps its model whole ("claude-opus Medium"): the field gives way first.
                .fixedSize(horizontal: designChat, vertical: false)
            }
            // The design chat's pill has no ring (iPadDesign): the context sheet is the thread's.
            if !designChat { contextMeter(store: store, state: state) }
        }
        let actionView = sendButton(store: store, state: state, live: live)
        Group {
            if offersImages || offersCommands {
                SHCapsuleComposer {
                    AttachButton(state: state, enabled: live, offersImages: offersImages, commands: offersCommands ? {
                        if store.draft.isEmpty { store.draft = "/" }
                        focused = true
                    } : nil)
                } field: { fieldView } trailing: { trailingView } action: { actionView }
            } else {
                SHCapsuleComposer { fieldView } trailing: { trailingView } action: { actionView }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < MobileLayout.narrowPillWidth } action: { narrow = $0 }
        .onGeometryChange(for: Bool.self) { $0.size.width < MobileLayout.thinkingPillWidth } action: { compact = $0 }
        .overlay {
            Capsule().strokeBorder(Color.sh.textTertiary, lineWidth: 1).opacity(dropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    // MARK: Parts

    private func field(store: NativeThreadStore, state: ComposerState, live: Bool, placeholder: String, command: Bool = false,
                       style: SHTextStyle = .body) -> some View {
        @Bindable var bindable = store
        let paste: (([NSItemProvider]) -> Void)? = live && acceptsImages(store) ? { providers in state.attach(providers: providers) } : nil
        return ComposerTextView(text: $bindable.draft, placeholder: placeholder, focused: $focused, style: command ? .code : style,
                                label: "Message to agent", pasteImages: paste)
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
                        .keyboardShortcut(MobileShortcut.alternateSend.shortcut)
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
            // Let go of the images as soon as the store owns them, not after the host answers. New attachments stay.
            _ = await store.send(images: images, delivery: delivery) {
                // The synchronous callback follows appending this send's record. A host without image support captures only text.
                if store.submissions.last?.images.isEmpty == false { for id in submitted { state.remove(id) } }
                if state.attachments.isEmpty { state.clearAttachments() }
            }
            state.saveDraft(store)
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

    /// The design references waiting beside the draft, first among the attachments (DesignRefStates' chip).
    private func referenceChips(_ store: NativeThreadStore) -> some View {
        ForEach(store.attachedReferences) { attached in
            MobileReferenceChip(host: ref.host, reference: attached.reference, crumbs: DesignReferencePresentation.crumbs(label: attached.label),
                                version: DesignReferencePresentation.version(attached.reference.revision)) {
                store.detachReference(attached.id)
            }
        }
    }

    /// The page elements picked in the thread's Browser, waiting beside the draft (iPadPaneBrowser's chip).
    private func elementChips(_ store: NativeThreadStore) -> some View {
        ForEach(store.attachedElements) { attached in
            SHElementChip(attached.element.label, source: attached.element.sourceShort) { store.detachElement(attached.id) }
        }
    }

    // MARK: The @ picker

    /// The picker over the composer: the host's designs at once, a design's pages and boards and a
    /// board's elements once it is opened (read from the files this device synced). A tap drills
    /// into a design or board, or picks the piece; Back goes up a level. Touch has no highlight.
    private func mentionPicker(store: NativeThreadStore) -> some View {
        let content = mentions.content
        let designs = MobileDesigns.of(hosts)
        let host = ref.host
        return SHMentionPicker(sections: content.sections, crumbs: content.crumbs, empty: content.empty, highlighted: nil,
                               maxHeight: MobileDesignLayout.mentionPickerMaxHeight,
                               choose: { chooseMention($0, store: store) }, drill: { chooseMention($0, store: store) },
                               back: { if let draft = mentions.back() { store.draft = draft } },
                               appear: { id in if let item = mentions.content.items[id] { designs.wantMentionPicture(item, host: host) } })
    }

    /// Follows the draft: open while it ends in a "#" mention, on the host's threads to link, or an "@"
    /// mention where the host takes references to its designs (never in a design's own chat).
    private func updateMentions(store: NativeThreadStore) {
        let designs = MobileDesigns.of(hosts)
        let threads = threadLinks.map { Array($0.links.values) } ?? []
        guard store.supports("designReferences"), !designChat, let library = designs.library(ref.host) else {
            if !designChat, threadLinks != nil {
                mentions.update(draft: store.draft, catalog: nil, threads: threads, excluding: ref.agent.rawValue, designs: false)
            } else if mentions.isOpen {
                mentions.close()
            }
            return
        }
        let opening = mentions.opens(for: store.draft)
        if opening, library.listing == nil, ComposerMention.token(in: store.draft)?.trigger == "@" { Task { await library.refresh() } }
        let scope = mentions.scope
        let host = ref.host
        let version = designs.mentionPicturesVersion
        mentions.update(draft: store.draft, catalog: library.listing == nil ? nil : library.mentionCatalog(),
                        place: hosts.host(host)?.name ?? "the host", threads: threads,
                        excluding: ref.agent.rawValue) { item in
            designs.mentionPicture(item, host: host).map { SHReferenceImage(id: item.id + "@\(version)", image: Image(uiImage: $0)) }
        }
        guard mentions.isOpen, opening || mentions.scope != scope else { return }
        switch mentions.scope {
        case .designs: break
        case .design(let id, _): Task { await library.openMentions(id) }
        case .board(let reference, _, _): Task { await library.openMentions(reference.designID) }
        }
    }

    /// A row tapped: a design or board drills in (the draft spells the way), anything else is
    /// pinned by the host and joins the composer as a chip.
    private func chooseMention(_ row: SHMentionRow, store: NativeThreadStore) {
        switch mentions.choose(row) {
        case .drill(let draft)?:
            store.draft = draft
        case .pick(let reference, let draft)?:
            store.draft = draft
            let designs = MobileDesigns.of(hosts)
            let state = ComposerStates.shared.state(for: ref)
            let host = ref.host
            Task {
                do { try await designs.attachReference(reference, to: store, host: host) } catch {
                    state.attachmentError = "That design reference didn't attach: \(MobileDesignsError.words(error))"
                }
            }
        case .link(let draft)?:
            store.draft = draft
        case nil:
            break
        }
    }

    /// A paste that brought `shepherd-design-ref://` words: each becomes a chip (the words around
    /// it stay), where the thread's host takes references to its designs.
    private func pasteReferences(store: NativeThreadStore, state: ComposerState, from old: String, to new: String) {
        guard store.supports("designReferences"), let pasted = ComposerReferencePaste.extract(new, previous: old) else { return }
        store.draft = pasted.draft
        let designs = MobileDesigns.of(hosts)
        let host = ref.host
        Task {
            for reference in pasted.references {
                do { try await designs.attachReference(reference, to: store, host: host) } catch {
                    state.attachmentError = "That design reference didn't attach: \(MobileDesignsError.words(error))"
                }
            }
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

/// A send that did not go through (UX-02): refused by the host, with Restore back into an empty
/// composer, or of unknown outcome, shown whole to check against the thread and never resent or
/// restored by the app. Discard (after a confirmation: the text goes) only lets go of this
/// device's copy; it asks the host nothing.
private struct SubmissionBanner: View {
    let typed: String
    let refused: Bool
    let images: Int
    /// False for an earlier launch's send: only its text was kept.
    let imagesKept: Bool
    let canRestore: Bool
    let canDiscard: Bool
    let restore: () -> Void
    let discard: () -> Void
    @State private var confirming = false
    /// A thread iPad keeps mounted behind the selected one presents nothing (`threadDetailActive`).
    @Environment(\.threadDetailActive) private var detailActive

    var body: some View {
        let extra = images == 0 ? "" : " · \(images) image\(images == 1 ? "" : "s")" + (imagesKept ? "" : " not kept")
        Group {
            if refused {
                SHBanner(.failed, title: "Not sent" + extra,
                         message: typed.isEmpty ? nil : typed + (canRestore ? "" : "\nClear the composer to restore it.")) {
                    discardButton
                    Button("Restore") { restore() }
                        .buttonStyle(.sh(.secondary))
                        .disabled(!canRestore)
                }
                .lineLimit(4)
            } else {
                SHBanner(.attention, title: "Delivery unknown" + extra,
                         message: (typed.isEmpty ? "" : typed + "\n")
                            + "It may have reached the agent. Check the thread before sending it again.") {
                    discardButton
                }
                .lineLimit(8)
            }
        }
        .confirmationDialog(refused ? "Discard this unsent message?" : "Discard this message's copy?",
                            isPresented: $confirming.whenActive(detailActive), titleVisibility: .visible) {
            Button("Discard", role: .destructive) { discard() }
        } message: {
            Text(refused
                 ? "Its text and images are removed from this device. Nothing is sent."
                 : "This only removes the copy kept on this device. It doesn't cancel or recall the message if the agent already received it.")
        }
    }

    private var discardButton: some View {
        Button("Discard") { confirming = true }
            .buttonStyle(.sh(.ghost))
            .disabled(!canDiscard)
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
