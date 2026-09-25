import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// A menu the command center asks the composer to open (⇧⌘M's model picker).
struct ComposerMenuRequest: Equatable {
    enum Menu: Equatable { case models, thinking }
    let menu: Menu
    let id = UUID()
}

/// The composer (NWComposer board): pinned under the thread in the same 820pt column, a fade
/// above it, the `NWComposer` card with the field (or a pending question) and one row of
/// controls: attach · / commands · model · thinking · Send or Stop. Menus float over the thread
/// above the card, so opening one never moves the thread or changes the composer's height.
/// Messages sent while pi works wait in "Up next" above the card (`QueueStackView`); ↩ queues
/// or steers per Settings, ⌘↩ does the other, and the Send menu offers both.
struct Composer: View {
    /// The thread's coordinate space: the menus measure the room above the card in it.
    static let threadSpace = "composer.thread"

    @Bindable var store: NativeThreadStore
    let active: Bool
    /// The thread is the focused pane: the field takes the keyboard while it is on screen.
    let isFocused: Bool
    let agentName: String?
    let hasTurns: Bool
    let gutter: CGFloat
    var listModels: (() async -> [PiModelCatalog.Entry])?
    /// Set by the command center: open that menu.
    var menuRequest: ComposerMenuRequest?
    /// Set while the thread is detached from its tail: what "Jump to latest" does.
    var jumpToLatest: (() -> Void)? = nil
    /// The "Up next" stack's state, from a test or preview that drives it; else the composer's own.
    var queueState: QueueStackState? = nil
    @State private var attachments: [ImageAttachment] = []
    @State private var attachmentError: String?
    @State private var dropTargeted = false
    @State private var commandIndex = 0
    /// Esc closes the slash menu for the draft as typed; typing more reopens it.
    @State private var dismissedQuery: String?
    @State private var menu: Menu?
    /// The models this agent's host offers, derived for the picker; nil until loaded.
    @State private var catalog: ModelCatalog?
    /// The open (or last) model picker.
    @State private var picker: ModelPickerState?
    @State private var confirmingStopAll = false
    @State private var picking = false
    /// The card's top edge in the thread, once laid out: a menu takes at most the room above it.
    @State private var cardTop: CGFloat?
    /// The thread has room after the card's trailing edge for the Send menu (`sendMenuBeside`).
    /// Kept as the answer, not the room, so a live resize redraws the composer only when the
    /// menu would change sides.
    @State private var sendMenuFitsBeside = false
    @State private var dismissal = ComposerMenuDismissal()
    /// Owned here, not by the thread: claiming the keyboard redraws the composer alone.
    @FocusState private var composing: Bool
    /// "Up next": what the stack shows of the store's queue, and its own view state.
    @State private var ownQueueStack = QueueStackState()
    private var queueStack: QueueStackState { queueState ?? ownQueueStack }
    /// The queued message with keyboard focus, if one has it.
    @FocusState private var focusedRow: String?
    /// ⌘↩ reaches the composer before any key equivalent in its window.
    @State private var keyMonitor = ComposerKeyMonitor()
    /// Holding Send opened its menu: the press that did is not a send.
    @State private var sendHeld = false
    /// Motion starts once the thread has caught up since it came on screen: what arrives with
    /// that pull (a widget, a waiting question, the model) is simply there, whether the thread
    /// just opened or an agent switched back to is catching up.
    @State private var catchUp = CatchUpGate()
    /// pi has kept the thread waiting past `threadStartingDelay`: the control row says so.
    @State private var startingShown = false
    @Environment(\.threadStartingDelay) private var startingDelay

    /// What the starting indicator's wait restarts on: a thread that begins waiting, or one
    /// whose first content (history from disk) arrives while it waits.
    private struct StartingWait: Equatable {
        var awaiting: Bool
        var blank: Bool
    }

    /// How long pi may keep the thread waiting before the composer says it is starting: `delay`
    /// over a thread that draws something, no more than `AppLayout.blankStartingIndicatorDelay`
    /// over one that is still blank.
    static func startingDelay(blank: Bool, delay: Duration) -> Duration {
        blank ? min(delay, AppLayout.blankStartingIndicatorDelay) : delay
    }

    private enum Menu: Equatable { case models, thinking, send }

    /// The menu over the card, whichever path opened it (typing "/", a chip, ⇧⌘M, Esc, holding
    /// Send).
    private enum OpenMenu: Equatable { case none, slash, models, thinking, send }

    // One effective state: a lost connection wins over a cached running snapshot (error maps
    // to Send + an inline error, never Stop).
    // Each reads the store's own property for it, never the snapshot, so a streamed chunk
    // leaves the composer alone.
    private var errored: Bool { store.loadError != nil }
    private var running: Bool { store.running }
    private var dialogs: [NativeThreadDialog] { errored ? [] : store.dialogs }
    /// While pi starts, a send waits for it behind the spinner.
    private var canSend: Bool {
        active && store.acceptsSend && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canAttach: Bool { store.supportedActions.contains("sendImages") }
    /// pi answers `/name` prompts itself; the list comes from its command registry.
    private var commands: [NativeCommand] { store.commands }
    private var commandQuery: String? {
        guard !commands.isEmpty, store.draft.hasPrefix("/"), !store.draft.contains(where: \.isWhitespace),
              store.draft != dismissedQuery else { return nil }
        return String(store.draft.dropFirst()).lowercased()
    }
    private var commandMatches: [NativeCommand] {
        guard let query = commandQuery else { return [] }
        guard !query.isEmpty else { return commands }
        let prefix = commands.filter { $0.name.lowercased().hasPrefix(query) }
        let rest = commands.filter { !$0.name.lowercased().hasPrefix(query) }
            .filter { $0.name.lowercased().contains(query) || ($0.description ?? "").lowercased().contains(query) }
        return prefix + rest
    }
    private var menuOpen: Bool { commandQuery != nil || menu != nil }

    private var openMenu: OpenMenu {
        if commandQuery != nil { return .slash }
        return switch menu {
        case .models: .models
        case .thinking: .thinking
        case .send: .send
        case nil: .none
        }
    }

    /// What sits above the card: a banner, the notice, extension widgets, the queue.
    private var accessories: [String] {
        let banner = store.loadError != nil ? "lost" : attachmentError != nil ? "attachment" : store.notice != nil ? "notice" : nil
        return [banner].compactMap { $0 } + store.widgets.map(\.id) + (queueStack.isVisible ? ["queue"] : [])
    }

    /// The question in place of the field, by the identity its panel takes.
    private var questionKey: String? {
        guard let dialog = dialogs.first, let session = store.session else { return nil }
        return session.key + ":" + dialog.id
    }

    /// Everything here is anchored to the bottom of the thread: what opens above the card grows
    /// up from it while the card stays put. Menus float over the thread from the card's corner
    /// and take no room in the composer; a question replaces the field and the card eases to its
    /// height; banners, widgets, and attachments nudge in. Each is keyed on its own state, so
    /// typing and filtering stay instant.
    var body: some View {
        let _ = NWRenderProbe.tick("composer.body")
        let catchingUp = catchUp.catchingUp(caughtUpAt: store.catchUp?.chrome, version: store.chromeVersion)
        let widgets = store.widgets
        let query = commandQuery
        VStack(alignment: .leading, spacing: AppLayout.menuGap) {
            if !widgets.isEmpty {
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    ForEach(widgets) { WidgetRow(widget: $0).nwTransition(.list, edge: .bottom) }
                }
                .padding(.horizontal, NW.Space.xs)
                .nwTransition(.list, edge: .bottom)
            }
            if let error = store.loadError {
                NWBanner(.failed, title: "Lost connection to the agent process.", message: error) {
                    Button("Reconnect") { Task { await store.refresh(fresh: true) } }
                        .buttonStyle(.nw(.secondary, size: .s))
                }
                .nwTransition(.list, edge: .bottom)
            } else if let attachmentError {
                NWBanner(.failed, title: attachmentError)
                    .nwTransition(.list, edge: .bottom)
            } else if let notice = store.notice {
                Text(notice).font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary).textSelection(.enabled)
                    .padding(.horizontal, NW.Space.xs)
                    .nwTransition(.list, edge: .bottom)
            }
            // "Up next" grows upward from the card, which never moves.
            if queueStack.isVisible {
                QueueStackView(state: queueStack, store: store, running: running, animated: !catchingUp, focusedRow: $focusedRow,
                               focusComposer: { composing = true })
                    // A lifted row floats over the card too.
                    .zIndex(queueStack.dragging == nil ? 0 : 1)
                    .nwTransition(.list, edge: .bottom)
            }
            card
                .background { ComposerMenuRegion(dismissal: dismissal) }
                .background { ComposerWindowReader(monitor: keyMonitor) }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.threadSpace)).minY } action: { cardTop = $0 }
                .onGeometryChange(for: Bool.self) { proxy in
                    Self.sendMenuBeside(room: (proxy.bounds(of: .named(Self.threadSpace))?.maxX ?? proxy.size.width) - proxy.size.width)
                } action: { sendMenuFitsBeside = $0 }
                .overlay(alignment: .topLeading) { menus(query: query) }
                .overlay(alignment: sendMenuFitsBeside ? .bottomTrailing : .topTrailing) {
                    sendMenu(beside: sendMenuFitsBeside)
                }
        }
        .nwAnimation(.list, value: accessories)
        .nwAnimation(.list, value: attachments.map(\.id))
        .nwAnimation(.disclosure, value: questionKey)
        // What a catch-up brings lands at once, however it changes the composer; keyed on what
        // the render drew, so a menu or a chip's own later motion still runs.
        .transaction(value: CatchUpGate.Key(version: store.chromeVersion, active: active)) {
            if catchingUp { $0.disablesAnimations = true }
        }
        .onChange(of: openMenu, initial: true) { _, open in
            dismissal.dismiss = closeMenu(open)
            dismissal.watch(open != .none)
        }
        .onChange(of: store.queue, initial: true) { _, queue in
            // The stack takes the queue a render later, outside the catch-up's transaction: a
            // queue that changed while the thread was away lands without motion all the same.
            guard catchingUp else { return queueStack.update(queue, images: store.queuedImages) }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { queueStack.update(queue, images: store.queuedImages) }
        }
        // ⌘↩ is watched only while this composer (or one of its queued messages) has focus.
        .onChange(of: composing || focusedRow != nil, initial: true) { _, focused in
            // Only a press it can use: a focused message, or a draft ready to send. Anything
            // else is left to the window (the review pane's ⌘⏎).
            keyMonitor.accepts = { [store, focusedRow = $focusedRow] in
                focusedRow.wrappedValue != nil
                    || (!store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.acceptsSend && !store.busy
                        && store.dialogs.isEmpty)
            }
            keyMonitor.watch(focused)
        }
        .onChange(of: keyMonitor.presses) { _, _ in sendTheOtherWay() }
        // A hold that opened the Send menu and let go elsewhere leaves the next click a send.
        .onChange(of: menu) { _, menu in if menu != .send { sendHeld = false } }
        .onDisappear {
            dismissal.watch(false)
            keyMonitor.watch(false)
        }
        // Let any deferred AppKit focus release finish before claiming the field.
        .task(id: active && isFocused) {
            composing = false
            guard active && isFocused else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            composing = true
        }
        // A normal start is over before the delay: only a slow pi is ever said to be starting.
        .task(id: StartingWait(awaiting: active && store.awaitingPi, blank: store.session == nil)) {
            guard active && store.awaitingPi else {
                startingShown = false
                return
            }
            try? await Task.sleep(for: Self.startingDelay(blank: store.session == nil, delay: startingDelay))
            if !Task.isCancelled { startingShown = true }
        }
        .frame(maxWidth: AppLayout.threadMaxWidth)
        .padding(.horizontal, gutter)
        .padding(.bottom, AppLayout.composerBottom)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                // The thread fades under the composer.
                LinearGradient(colors: [Color.nw.bgWindow.opacity(0), Color.nw.bgWindow], startPoint: .top, endPoint: .bottom)
                    .frame(height: AppLayout.composerFade).offset(y: -AppLayout.composerFade).allowsHitTesting(false)
                // Over the fade, under the card and its menus.
                NWJumpToLatest(action: jumpToLatest)
                    .offset(y: -(NW.Height.controlM + NW.Space.m))
            }
        }
        .background(Color.nw.bgWindow)
        .onChange(of: query) { _, query in
            commandIndex = 0
            // One menu at a time: typing a command takes over from a chip's menu.
            if query != nil { menu = nil }
        }
        // The catalog decides whether the thinking chip applies; this Mac's is asked once per process.
        .task { if catalog?.isEmpty != false { await loadModels() } }
        .onChange(of: menuRequest) { _, request in
            switch request?.menu {
            case .models: openModels()
            case .thinking: toggleThinking()
            case nil: break
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            attachmentError = nil
            Task {
                let resolved = await AppImageDrop.resolve(urls.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() })
                attach(urls: resolved)
            }
        }
        .sheet(isPresented: $confirmingStopAll) {
            StopAllDialog(runningSubagents: store.subagents.count { !$0.isTerminal },
                          stopAgent: { confirmingStopAll = false; Task { await store.abort() } },
                          stopAll: { confirmingStopAll = false; Task { await store.abortAll() } },
                          cancel: { confirmingStopAll = false })
        }
    }

    private static func slashCommand(_ command: NativeCommand) -> NWSlashCommand {
        NWSlashCommand(name: command.name, description: command.description,
                       tag: command.source.flatMap { $0 == "extension" ? nil : $0 })
    }

    /// The levels pi offers the thread's model, with the board's notes.
    private var thinkingOptions: [NWThinkingOption] {
        store.thinkingLevels.map { NWThinkingOption(id: $0.id, title: $0.title, note: $0.note) }
    }

    // MARK: Menus

    /// The open menu, over the thread: its bottom-leading corner 8pt above the card's top-leading
    /// one, growing from there, and never taller than the room above the card (a long list
    /// scrolls inside). It is an overlay, so the card, the composer's height, and the thread's
    /// inset never change with it.
    private func menus(query: String?) -> some View {
        // Read only while a menu is open: the card moving as the draft grows re-renders nothing.
        let room = openMenu == .none ? nil : cardTop.map { max(0, $0 - AppLayout.menuGap - AppLayout.menuMargin) }
        return ZStack(alignment: .bottomLeading) {
            if let query {
                let matches = commandMatches
                NWSlashMenu(commands: matches.map(Self.slashCommand), total: commands.count, query: query,
                            selection: $commandIndex, maxHeight: room) { command in
                    if let match = matches.first(where: { $0.name == command.name }) { choose(match) }
                }
                .nwTransition(.overlay, anchor: .bottomLeading)
            }
            if menu == .models, let picker {
                ModelPicker(state: picker, maxHeight: room) { model in
                    menu = nil
                    composing = true
                    RecentModels.record(model, thread: agentName)
                    Task { await store.setModel(model) }
                } close: { menu = nil; composing = true }
                .nwTransition(.overlay, anchor: .bottomLeading)
            }
            if menu == .thinking, let thinking = store.thinking {
                NWThinkingMenu(options: thinkingOptions, current: thinking) { level in
                    menu = nil
                    composing = true
                    Task { await store.setThinking(level.id) }
                } onClose: { menu = nil; composing = true }
                .nwTransition(.overlay, anchor: .bottomLeading)
            }
        }
        // Its own height, not the card's, which the overlay proposes.
        .fixedSize(horizontal: false, vertical: true)
        .background { ComposerMenuRegion(dismissal: dismissal) }
        .alignmentGuide(.top) { $0[.bottom] + AppLayout.menuGap }
        .nwAnimation(.overlay, value: openMenu)
    }

    /// What a click outside the open menu and the card does: it closes the menu, as Esc does
    /// (without taking focus). It holds the menu's state, never the composer: the composer holds
    /// the watcher that keeps it.
    private func closeMenu(_ open: OpenMenu) -> () -> Void {
        let (menu, dismissedQuery, store) = ($menu, $dismissedQuery, store)
        return {
            if open == .slash { dismissedQuery.wrappedValue = store.draft } else { menu.wrappedValue = nil }
        }
    }

    // MARK: Card

    private var card: some View {
        let focused = composing || dropTargeted || menuOpen
        return NWComposer(isFocused: focused) {
            ForEach(attachments) { attachment in
                NWAttachmentChip(attachment.name, thumbnail: attachment.thumbnail) {
                    attachments.removeAll { $0.id == attachment.id }
                }
                .nwTransition(.list, edge: .leading)
            }
        } field: {
            // The card eases to the new height as a question takes the field's place (or gives
            // it back); what arrives fades in, and what leaves goes at once rather than
            // lingering over the controls.
            if let dialog = dialogs.first, let session = store.session, let questionKey {
                // The card swaps its field for the question so it can never scroll out of view.
                QuestionPanel(dialog: dialog, count: dialogs.count, enabled: active && store.supports("answer")) { answer in
                    Task {
                        await store.answer(dialogID: dialog.id, sessionID: session.piSessionID,
                                           generation: session.generation, answer: answer)
                    }
                }
                .id(questionKey)
                .nwEntrance(.content)
            } else {
                field.nwEntrance(.content)
            }
        } controls: {
            actionRow
        }
        .onDrop(of: [.image, .fileURL], isTargeted: canAttach ? $dropTargeted : nil) { providers in
            guard canAttach else { return false }
            attach(providers)
            return true
        }
    }

    private var placeholder: String {
        if !hasTurns { return "Describe the task, or / for commands…" }
        return commands.isEmpty ? "Follow up…" : "Follow up, or / for commands…"
    }

    private var field: some View {
        TextField(text: $store.draft, prompt: Text(placeholder).foregroundStyle(Color.nw.textTertiary), axis: .vertical) {
            Text("Message the agent")
        }
            .lineLimit(1...NWComposerMetrics.fieldMaxLines)
            .textFieldStyle(.plain)
            .font(Font.nw(.body))
            .lineSpacing(max(0, NWTextStyle.body.lineSpacing - 1))
            .foregroundStyle(Color.nw.textPrimary)
            .autocorrectionDisabled()
            .focused($composing)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) { store.draft += "\n"; return .handled }
                if commandQuery != nil {
                    let matches = commandMatches
                    if matches.indices.contains(commandIndex) { choose(matches[commandIndex]) }
                    return .handled
                }
                guard canSend, !store.busy else { return .handled }
                // ⌘↩ when a key press brings it here; the key monitor usually takes it first.
                let alternate = KeybindingsStore.shared.chord(for: .alternateSend).matches(press)
                sendDraft(alternate ? .alternate : .primary)
                return .handled
            }
            .onKeyPress(.tab) {
                let matches = commandMatches
                guard commandQuery != nil, matches.indices.contains(commandIndex) else { return .ignored }
                complete(matches[commandIndex])
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard commandQuery == nil else {
                    commandIndex = max(0, commandIndex - 1)
                    return .handled
                }
                // ↑ in an empty composer edits the last queued message.
                guard store.draft.isEmpty, menu == nil, queueStack.editLast(store: store) else { return .ignored }
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard commandQuery != nil else { return .ignored }
                commandIndex = min(max(0, commandMatches.count - 1), commandIndex + 1)
                return .handled
            }
            .onKeyPress(.escape) {
                switch ComposerEscape(menuOpen: menu != nil, commandsOpen: commandQuery != nil,
                                      canStop: running && dialogs.isEmpty && active && store.supports("abort")) {
                case .closeMenu: menu = nil
                case .dismissCommands: dismissedQuery = store.draft
                case .stop: stop()
                case .pass: return .ignored
                }
                return .handled
            }
            .onPasteCommand(of: [.image, .fileURL]) { providers in
                guard canAttach else { return }
                attach(providers)
            }
            .accessibilityLabel("Message the agent")
    }

    /// Full chip labels when they fit; in a narrow thread (a docked right pane) the chips drop
    /// their words ("/", the thinking level alone) instead of truncating mid-word.
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            actionChips(compact: false, startingLabel: true)
            // "Starting…" gives up its words before the chips do.
            actionChips(compact: false, startingLabel: false)
            actionChips(compact: true, startingLabel: false)
        }
        // A new model or level cross-fades. Only these: typing and width changes stay instant.
        .nwAnimation(.content, value: [store.model, store.thinking])
    }

    private func actionChips(compact: Bool, startingLabel: Bool) -> some View {
        let _ = NWRenderProbe.tick("composer.chips")
        return HStack(spacing: NW.Space.xxs) {
            if canAttach {
                Button { picking = true } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.nwIcon(size: NWComposerMetrics.chipHeight))
                    .disabled(attachments.count >= NativeImage.maxPerSend)
                    .help("Attach images (drop or paste also works), up to \(NativeImage.maxPerSend)")
                    .accessibilityLabel("Attach file")
            }
            if !commands.isEmpty {
                Button {
                    store.draft = "/"
                    dismissedQuery = nil
                    menu = nil
                    composing = true
                } label: {
                    HStack(spacing: NW.Space.s) {
                        Text("/").font(Font.nw(.code))
                        if !compact { Text("commands") }
                    }
                }
                .buttonStyle(.nwComposerChip(active: commandQuery != nil))
                .help("Commands")
                .accessibilityLabel("Commands")
            }
            modelChip
            thinkingChip(compact: compact)
            Spacer(minLength: NW.Space.m)
            if startingShown { startingIndicator(label: startingLabel).nwTransition(.content) }
            primary
        }
        .nwAnimation(.content, value: startingShown)
    }

    /// "Starting…" beside the action, quiet and in the row it never resizes. Its spinner
    /// gives way to Send's own while a message waits for the agent.
    private func startingIndicator(label: Bool) -> some View {
        HStack(spacing: AppLayout.startingSpacing) {
            if !store.busy {
                ProgressView().progressViewStyle(.nwSpinner(size: AppLayout.startingSpinner, color: Color.nw.textTertiary))
            }
            if label { Text("Starting…").font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary) }
        }
        .padding(.trailing, NW.Space.s)
        .help("The agent is starting. A message sent now goes once it is ready.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Starting the agent")
    }

    /// Send and Stop are one button that morphs; the spinner cross-fades over it while pi
    /// accepts a message. While pi works with a draft, Stop steps aside outlined and Send takes
    /// the corner; right-clicking or holding Send then opens the Send menu.
    private var primary: some View {
        let working = running && dialogs.isEmpty
        let stops = working && store.draft.isEmpty
        let beside = working && !store.draft.isEmpty && !store.busy
        return HStack(spacing: NW.Space.s) {
            if beside {
                NWComposerActionButton(.stop, outlined: true, enabled: active && store.supports("abort")) { stop() }
                    .help(stopHelp)
                    .nwTransition(.content)
            }
            ZStack {
                if store.busy {
                    ProgressView().progressViewStyle(.nwSpinner(color: Color.nw.textTertiary))
                        .frame(width: NWComposerMetrics.actionSize, height: NWComposerMetrics.actionSize)
                        .accessibilityLabel("Waiting for the agent")
                        .nwTransition(.content)
                } else {
                    NWComposerActionButton(stops ? .stop : .send, ringed: menu == .send,
                                           enabled: stops ? active && store.supports("abort") : canSend && dialogs.isEmpty) {
                        if stops { stop() } else if sendHeld { sendHeld = false } else { sendDraft(.primary) }
                    }
                    .help(stops ? stopHelp : !dialogs.isEmpty ? "Answer the question first" : sendHelp(working: working))
                    .overlay { if beside { SecondaryClick { openSendMenu() } } }
                    .simultaneousGesture(LongPressGesture(minimumDuration: AppLayout.sendHoldDelay / .seconds(1)).onEnded { _ in
                        guard beside else { return }
                        sendHeld = true
                        openSendMenu()
                    }, isEnabled: beside)
                    .nwTransition(.content)
                }
            }
        }
        .nwAnimation(.content, value: store.busy)
        .nwAnimation(.content, value: beside)
    }

    private var stopHelp: String {
        store.hasLiveSubagents ? "Stop the agent and its subagents" : "Stop the agent's turn"
    }

    /// "Send (↩)", or while pi works "Queue (↩) · Steer now (⌘↩)" in the order the Return
    /// setting gives them.
    private func sendHelp(working: Bool) -> String {
        let keys = KeybindingsStore.shared
        guard working else { return "Send (\(keys.sendDisplay))" }
        let (primary, alternate) = Self.sendTitles(AppSettings.shared.returnWhileWorking)
        return "\(primary) (\(keys.sendDisplay)) · \(alternate) (\(keys.display(.alternateSend)))"
    }

    /// The Return setting's way first.
    static func sendTitles(_ setting: ReturnWhileWorking) -> (primary: String, alternate: String) {
        setting == .steer ? ("Steer now", "Queue") : ("Queue", "Steer now")
    }

    private func stop() {
        if store.subagents.count(where: { !$0.isTerminal }) > 1 { confirmingStopAll = true }
        else { Task { await store.abortAll() } }
    }

    // MARK: Chips

    @ViewBuilder private var modelChip: some View {
        if let model = store.model {
            let settable = store.supportedActions.contains("setModel")
            Button { openModels() } label: {
                HStack(spacing: NW.Space.s) {
                    // A long id keeps both ends: the provider prefix and the model's tail.
                    Text(nativeModelShortName(model)).font(Font.nw(.code)).lineLimit(1).truncationMode(.middle)
                        .nwContentTransition(.crossFade)
                    if settable { NWChipChevron() }
                }
            }
            .buttonStyle(.nwComposerChip(active: menu == .models))
            .disabled(!settable || !store.supports("setModel"))
            .help("Model: \(model)")
            .accessibilityLabel("Model \(model)")
        }
    }

    /// The level pi runs at, opening the levels pi offers the model; hidden when the model takes
    /// no thinking level.
    @ViewBuilder private func thinkingChip(compact: Bool) -> some View {
        if thinkingAvailable, let thinking = store.thinking {
            Button {
                toggleThinking()
            } label: {
                HStack(spacing: NW.Space.s) {
                    Image(systemName: "lightbulb").font(.system(size: AppLayout.chipSymbol, weight: .medium)).foregroundStyle(Color.nw.textSecondary)
                    if !compact { Text("Thinking") }
                    Text(NativeThinkingLevel.title(thinking)).foregroundStyle(Color.nw.textPrimary).fontWeight(.medium)
                        .nwContentTransition(.crossFade)
                    NWChipChevron()
                }
            }
            .buttonStyle(.nwComposerChip(active: menu == .thinking))
            .disabled(!store.supports("setThinking"))
            .accessibilityLabel("Thinking level: \(NativeThinkingLevel.title(thinking))")
        }
    }

    private var thinkingAvailable: Bool {
        store.thinking != nil && store.supportedActions.contains("setThinking") && reasoningAvailable
            && NativeThinkingLevel.reasons(store.thinkingLevels)
    }

    /// Unknown models (a catalog that did not load) keep the chip.
    private var reasoningAvailable: Bool {
        guard let model = store.model, let entry = catalog?.model(model) else { return true }
        return entry.reasoning
    }

    // MARK: Actions

    /// The picker's list is made here, as it opens, so its first frame has everything.
    private func openModels() {
        guard store.supports("setModel") else { NSSound.beep(); return }
        guard menu != .models else { menu = nil; return }
        picker = ModelPickerState(catalog: catalog, recent: RecentModels.load(), current: store.model)
        dismissCommands()
        menu = .models
        if catalog?.isEmpty != false { Task { await loadModels() } }
    }

    private func toggleThinking() {
        guard thinkingAvailable, store.supports("setThinking") else { NSSound.beep(); return }
        guard menu != .thinking else { menu = nil; return }
        dismissCommands()
        menu = .thinking
    }

    /// A chip's menu takes over from the slash menu, which stays closed for the draft as typed
    /// (as Esc leaves it).
    private func dismissCommands() {
        if commandQuery != nil { dismissedQuery = store.draft }
    }

    private func loadModels() async {
        let loaded = if let listModels { await ModelCatalog.derive(listModels()) } else { await ModelCatalog.loadLocal() }
        catalog = loaded
        picker?.update(loaded)
    }

    private func choose(_ command: NativeCommand) {
        store.draft = "/\(command.name)"
        dismissedQuery = nil
        composing = true
        guard canSend else { return }
        sendDraft(.primary)
    }

    private func complete(_ command: NativeCommand) {
        store.draft = "/\(command.name) "
        dismissedQuery = nil
    }

    /// Sends the draft: ↩ (`primary`) the way Settings ▸ Agents says while pi works, ⌘↩
    /// (`alternate`) the other way. While pi is idle either one sends it now.
    private func sendDraft(_ key: ComposerSendKey) {
        sendDraft(delivery: key.delivery(AppSettings.shared.returnWhileWorking))
    }

    private func sendDraft(delivery: NativeThreadDelivery) {
        let images = attachments.map(\.image)
        Task {
            let before = store.sentCount
            await store.send(images: images, delivery: delivery)
            if store.sentCount > before { attachments.removeAll() }
        }
    }

    /// ⌘↩ (or the rebound chord): steers the focused queued message, or sends the draft the
    /// other way.
    private func sendTheOtherWay() {
        if let row = focusedRow {
            switch queueStack.handle(.steer, on: row, running: running, store: store) {
            case .row(let id): focusedRow = id
            case .composer:
                focusedRow = nil
                composing = true
            case .editor: focusedRow = nil
            }
            return
        }
        guard canSend, !store.busy, dialogs.isEmpty else { return }
        sendDraft(.alternate)
    }

    // MARK: Send menu

    private func openSendMenu() {
        guard running, dialogs.isEmpty, canSend, !store.busy else { return }
        dismissCommands()
        menu = .send
    }

    /// The Send menu stands beside the card, bottom-aligned, where the thread has room for it
    /// (Queue & steer boards), so it covers none of Up next; else above the card at its
    /// trailing corner.
    static func sendMenuBeside(room: CGFloat) -> Bool {
        room >= AppLayout.menuGap + NWQueueMetrics.sendMenuWidth + AppLayout.menuMargin
    }

    /// Queue and Steer now, beside the card or above it (`sendMenuBeside`), growing from the
    /// corner nearest Send; the Return setting's row leads the highlight and wears ↩.
    @ViewBuilder private func sendMenu(beside: Bool) -> some View {
        ZStack(alignment: beside ? .bottomLeading : .bottomTrailing) {
            if menu == .send {
                let setting = AppSettings.shared.returnWhileWorking
                let keys = KeybindingsStore.shared
                let options = Self.sendOptions(setting, send: keys.sendDisplay, alternate: keys.display(.alternateSend))
                NWSendMenu(options: options, highlighted: setting == .steer ? 1 : 0) { option in
                    menu = nil
                    composing = true
                    sendDraft(delivery: option.id == "steer" ? .steer : .followUp)
                } onClose: {
                    menu = nil
                    composing = true
                }
                .nwTransition(.overlay, anchor: beside ? .bottomLeading : .bottomTrailing)
            }
        }
        .fixedSize()
        .background { ComposerMenuRegion(dismissal: dismissal) }
        // Above: its bottom 8pt over the card's top. Beside: its leading edge 8pt after the
        // card's trailing one, bottoms aligned.
        .alignmentGuide(.top) { $0[.bottom] + AppLayout.menuGap }
        .alignmentGuide(.trailing) { beside ? $0[.leading] - AppLayout.menuGap : $0[.trailing] }
        .nwAnimation(.overlay, value: menu == .send)
    }

    /// Queue, then Steer now; ↩ on the Return setting's, the alternate chord on the other.
    static func sendOptions(_ setting: ReturnWhileWorking, send: String, alternate: String) -> [NWSendOption] {
        let steers = setting == .steer
        return [
            NWSendOption(id: "queue", title: "Queue", detail: "Goes when the agent finishes this turn.", glyph: .queue,
                         shortcut: steers ? alternate : send),
            NWSendOption(id: "steer", title: "Steer now", detail: "Lands once the agent’s current tool calls finish, before its next step.",
                         glyph: .symbol("arrow.turn.down.right"), shortcut: steers ? send : alternate),
        ]
    }

    /// Dropped or pasted images become attachments through the same resize rules as terminal
    /// drops (longest edge 2000px, JPEG stays JPEG, everything else PNG).
    private func attach(_ providers: [NSItemProvider]) {
        attachmentError = nil
        Task {
            let urls = await AppImageDrop.resolve(providers)
            attach(urls: urls)
        }
    }

    private func attach(urls: [URL]) {
        for url in urls {
            guard attachments.count < NativeImage.maxPerSend else {
                attachmentError = "At most \(NativeImage.maxPerSend) images per message."
                return
            }
            guard let attachment = ImageAttachment(url: url) else {
                attachmentError = "\(url.lastPathComponent) is not an image Shepherd can attach."
                continue
            }
            guard attachment.image.data.count <= NativeImage.maxBytes else {
                attachmentError = "\(url.lastPathComponent) is over \(NativeImage.maxBytes / 1024 / 1024) MiB after resizing."
                continue
            }
            attachments.append(attachment)
        }
    }
}

/// "provider/model" → "model".
func nativeModelShortName(_ model: String) -> String {
    guard let slash = model.firstIndex(of: "/") else { return model }
    return String(model[model.index(after: slash)...])
}

/// "42k" / "1.2M" for the header's context count.
func nativeTokenCount(_ tokens: Int) -> String {
    if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
    if tokens >= 1_000 { return "\(tokens / 1_000)k" }
    return "\(tokens)"
}

func nativeContextTooltip(_ stats: NativeThreadStats?) -> String {
    guard let stats else { return "" }
    var parts: [String] = []
    if let tokens = stats.contextTokens, tokens > 0 {
        var line = "\(tokens.formatted()) context tokens"
        if let window = stats.contextWindow { line += " of \(nativeTokenCount(window))" }
        if let percent = stats.contextPercent { line += " (\(Int(percent.rounded()))%)" }
        parts.append(line)
    }
    if let total = stats.totalTokens { parts.append("\(nativeTokenCount(total)) tokens this session") }
    if let cost = stats.cost { parts.append(cost.formatted(.currency(code: "USD"))) }
    return parts.joined(separator: " · ")
}

// MARK: Questions

/// A question from pi or an extension (select / confirm / input / editor), in place of the
/// field so it can never scroll away. Shepherd has no permission model: these are questions,
/// answered with the values the asker offered.
struct QuestionPanel: View {
    let dialog: NativeThreadDialog
    /// Pending questions in total; the panel shows the first as "1 / N".
    var count = 1
    let enabled: Bool
    let answer: (NativeDialogAnswer) -> Void
    @State private var text: String

    init(dialog: NativeThreadDialog, count: Int = 1, enabled: Bool, answer: @escaping (NativeDialogAnswer) -> Void) {
        self.dialog = dialog
        self.count = count
        self.enabled = enabled
        self.answer = answer
        _text = State(initialValue: dialog.prefill ?? "")
    }

    var body: some View {
        let blocked = !enabled || dialog.unavailable != nil
        VStack(alignment: .leading, spacing: AppLayout.questionSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                NWStateGlyph(.attention, size: AppLayout.questionGlyph)
                Text(dialog.title).font(Font.nw(.ui)).foregroundStyle(Color.nw.textPrimary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if count > 1 {
                    Text("1 / \(count)").font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary).monospacedDigit()
                        .nwContentTransition(.numeric())
                        .nwTransition(.content)
                }
            }
            // Another question queuing behind this one counts up.
            .nwAnimation(.content, value: count)
            if let message = dialog.message {
                ScrollView {
                    Text(message).font(Font.nw(.mono)).foregroundStyle(Color.nw.textPrimary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: AppLayout.questionMessageMaxHeight)
                .padding(.horizontal, NW.Space.l).padding(.vertical, NW.Space.m)
                .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
            }
            if let unavailable = dialog.unavailable {
                Text(unavailable == "external-editor" ? "An external editor is open · finish it before answering here" : "This question is too large to show here")
                    .font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                    .nwTransition(.content)
            }
            Group {
                switch dialog.kind {
                case .confirm:
                    HStack(spacing: NW.Space.m) {
                        Button("Yes") { answer(.confirm(value: true)) }.buttonStyle(NWButtonStyle(.primary, size: .m))
                        Button("No") { answer(.confirm(value: false)) }.buttonStyle(NWButtonStyle(.secondary))
                        Spacer(minLength: 0)
                        Button("Dismiss") { answer(.cancel) }.buttonStyle(NWButtonStyle(.ghost, size: .s))
                    }
                    // Y/N answer only while the panel itself has focus, so typing in the composer
                    // can never answer by accident.
                    .focusable()
                    .onKeyPress(characters: .init(charactersIn: "yYnN")) { press in
                        guard !blocked else { return .ignored }
                        answer(.confirm(value: press.characters.lowercased() == "y"))
                        return .handled
                    }
                case .select:
                    FlowLayout(spacing: NW.Space.s) {
                        ForEach(Array((dialog.options ?? []).enumerated()), id: \.offset) { index, option in
                            Button(option) { answer(.select(value: option)) }
                                .buttonStyle(NWButtonStyle(index == 0 ? .primary : .secondary))
                                .accessibilityLabel("Choose \(option)")
                        }
                        Button("Dismiss") { answer(.cancel) }.buttonStyle(NWButtonStyle(.ghost))
                    }
                case .input, .editor:
                    TextField(dialog.placeholder ?? "Answer", text: $text, axis: .vertical)
                        .lineLimit(dialog.kind == .editor ? 5...12 : 1...5)
                        .nwField(mono: dialog.kind == .editor)
                        .autocorrectionDisabled()
                        .accessibilityLabel(dialog.kind == .editor ? "Editor answer" : "Answer")
                    HStack(spacing: NW.Space.m) {
                        Button("Submit") { answer(dialog.kind == .editor ? .editor(value: text) : .input(value: text)) }
                            .buttonStyle(NWButtonStyle(.primary))
                        Button("Dismiss") { answer(.cancel) }.buttonStyle(NWButtonStyle(.ghost))
                    }
                }
            }
            .disabled(blocked)
            if dialog.timeout != nil {
                Text("The agent may stop waiting for this answer").font(Font.nw(.micro)).foregroundStyle(Color.nw.textTertiary)
            }
        }
        // An external editor opening or closing dims the answers and says why.
        .nwAnimation(.content, value: blocked)
        .padding(.top, NW.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question: \(dialog.title)")
    }
}

// MARK: Sending while pi works

/// What Esc does in the composer, the first that applies: close the open menu, close the
/// command list, then stop pi (as Stop does, asking first with live subagents).
enum ComposerEscape: Equatable {
    case closeMenu, dismissCommands, stop, pass

    init(menuOpen: Bool, commandsOpen: Bool, canStop: Bool) {
        self = menuOpen ? .closeMenu : commandsOpen ? .dismissCommands : canStop ? .stop : .pass
    }
}

/// Which key sent a draft: ↩ (`primary`) or ⌘↩, the rebindable `alternateSend`.
enum ComposerSendKey {
    case primary, alternate

    /// How the message goes while pi works: ↩ follows the Return setting, ⌘↩ does the other.
    /// (While pi is idle either one sends it now.)
    func delivery(_ setting: ReturnWhileWorking) -> NativeThreadDelivery {
        (self == .primary) == (setting == .steer) ? .steer : .followUp
    }
}

/// Takes the alternate send (⌘↩ unless rebound) for the composer while its field, or one of its
/// queued messages, has focus: ahead of any key equivalent in the window (the review pane's ⌘⏎),
/// and only in the composer's own window. The composer counts the presses it took.
@MainActor
@Observable
final class ComposerKeyMonitor {
    private(set) var presses = 0
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var chord: () -> KeyChord = { KeybindingsStore.shared.chord(for: .alternateSend) }
    /// Whether the composer can use a press now; one it cannot use goes on to the window.
    @ObservationIgnored var accepts: () -> Bool = { true }
    @ObservationIgnored private var monitor: Any?

    /// Watches the window's key presses while the composer has focus, and only then.
    func watch(_ focused: Bool) {
        if focused, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let taken = MainActor.assumeIsolated { self?.handle(event) == true }
                return taken ? nil : event
            }
        } else if !focused, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Takes `event` when it is the chord, in the composer's window.
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, chord().matches(event), accepts() else { return false }
        presses += 1
        return true
    }
}

/// Tells the key monitor which window the composer is in.
struct ComposerWindowReader: NSViewRepresentable {
    let monitor: ComposerKeyMonitor

    final class Reader: NSView {
        weak var monitor: ComposerKeyMonitor?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitor?.window = window
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Reader {
        let reader = Reader()
        reader.monitor = monitor
        return reader
    }

    func updateNSView(_ reader: Reader, context: Context) {
        reader.monitor = monitor
        if monitor.window !== reader.window { monitor.window = reader.window }
    }
}

/// A right-click (or ⌃-click) on the view it covers; every other click, and the pointer's
/// hover, pass through to the view beneath. Send's menu opens this way.
struct SecondaryClick: NSViewRepresentable {
    let action: () -> Void

    final class Catcher: NSView {
        var action: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, Self.isSecondary(event) else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) { action() }
        override func mouseDown(with event: NSEvent) { if Self.isSecondary(event) { action() } }

        static func isSecondary(_ event: NSEvent) -> Bool {
            event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        }
    }

    func makeNSView(context: Context) -> Catcher {
        let catcher = Catcher()
        catcher.action = action
        return catcher
    }

    func updateNSView(_ catcher: Catcher, context: Context) { catcher.action = action }
}

// MARK: Menu dismissal

/// Closes the composer's open menu on a click anywhere in its window outside the menu and the
/// card it grows from, the way a transient popover closes; the click still lands where it was
/// aimed. A click in the card is the card's own: a chip toggles its menu, and the field keeps
/// the slash menu its draft opened.
@MainActor
final class ComposerMenuDismissal {
    var dismiss: () -> Void = {}
    private let regions = NSHashTable<NSView>.weakObjects()
    private var monitor: Any?

    /// Watches the window's clicks while a menu is open, and only then.
    func watch(_ open: Bool) {
        if open, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        } else if !open, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Dismisses for a click in the regions' window that lands in none of them.
    func handle(_ event: NSEvent) {
        let regions = regions.allObjects.filter { $0.window != nil && $0.window === event.window }
        guard !regions.isEmpty, !regions.contains(where: { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) }) else { return }
        dismiss()
    }

    fileprivate func add(_ region: NSView) { regions.add(region) }
}

/// Marks the view it sits behind as part of the open menu for `ComposerMenuDismissal`. It is
/// never hit, so it takes no click from the view above it.
struct ComposerMenuRegion: NSViewRepresentable {
    let dismissal: ComposerMenuDismissal

    final class Region: NSView {
        weak var dismissal: ComposerMenuDismissal?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Region {
        let region = Region()
        updateNSView(region, context: context)
        return region
    }

    func updateNSView(_ region: Region, context: Context) {
        region.dismissal = dismissal
        dismissal.add(region)
    }
}

// MARK: Accessories

/// An extension's status or text widget, above the composer.
struct WidgetRow: View {
    let widget: NativeThreadWidget

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
            Text(widget.title ?? "\(widget.namespace) · \(widget.key)").nwSectionLabel()
            Text(widget.text).font(Font.nw(.micro)).foregroundStyle(Color.nw.textSecondary)
                .lineLimit(widget.kind == .status ? 1 : 4)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

/// A resized image waiting in the composer. `image.data` is the bytes pi will receive; the
/// thumbnail is decoded once, here.
struct ImageAttachment: Identifiable {
    let id = UUID()
    let name: String
    let image: NativeImage
    let thumbnail: Image?

    /// nil when the file is not a raster image.
    init?(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image),
              let data = try? Data(contentsOf: url), NSBitmapImageRep(data: data) != nil else { return nil }
        name = url.lastPathComponent
        image = NativeImage(mimeType: type == .jpeg ? "image/jpeg" : type == .gif ? "image/gif" : type == .webP ? "image/webp" : "image/png", data: data)
        thumbnail = NSImage(data: data).map { Image(nsImage: $0) }
    }
}

/// Left-to-right wrapping row (answer buttons, a result's file links). `lineSpacing` separates
/// wrapped rows (the item spacing unless given); items wider than the row are offered its width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = place(in: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let origin = placement.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          proposal: ProposedViewSize(placement.sizes[index]))
        }
    }

    private func place(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint], sizes: [CGSize]) {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width { x = 0; y += rowHeight + (lineSpacing ?? spacing); rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins, sizes)
    }
}
