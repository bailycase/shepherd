import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShepherdCore
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// The composer (NWComposer board): pinned under the thread in the same 820pt column, a fade
/// above it, the `NWComposer` card with the field (or a pending question) and one row of
/// controls: attach · / commands · model · thinking · Send or Stop. Menus float over the thread
/// above the card, so opening one never moves the thread or changes the composer's height.
/// Messages sent while pi works wait in "Up next" above the card (`QueueStackView`) or steer in at
/// pi's next step: ↩ does what Settings says, ⌘↩ always steers now (stops pi and sends), and the
/// Send menu offers all three (`NativeSendChoice`). Running subagents
/// share that card, above Up next (`ComposerDock`), and a subagent's question answered from its
/// row takes the composer's place until it is answered or hidden.
struct Composer: View {
    /// The thread's coordinate space: the menus measure the room above the card in it.
    static let threadSpace = "composer.thread"
    /// The card's own: the context details line up with the ring in it.
    static let cardSpace = "composer.card"

    @Bindable var store: NativeThreadStore
    var input: ThreadInput
    var allowsLocalFiles = false
    let active: Bool
    /// The thread is the focused pane: the field takes the keyboard while it is on screen.
    let isFocused: Bool
    let agentName: String?
    let hasTurns: Bool
    let gutter: CGFloat
    /// Another host's catalog; nil for this Mac's (`ModelCatalog.loadLocal`).
    var listModels: (() async -> ModelCatalog)?
    /// This thread's key in the command center: ⇧⌘M's model picker and the thinking menu come
    /// to the composer by it, and open with one redraw of the composer alone.
    var commandKey: String? = nil
    /// Set while the thread is detached from its tail: what "Jump to latest" does.
    var jumpToLatest: (() -> Void)? = nil
    /// Brings an entry into view (the context details' Largest and Show summary).
    var finder: ThreadFinder? = nil
    /// The "Up next" stack's state, from a test or preview that drives it; else the composer's own.
    var queueState: QueueStackState? = nil
    /// Previews: open with the context ring's details showing.
    var contextDetailsOpen = false
    /// Opens a subagent in the inspector; nil hides the tray (a thread with no inspector). The
    /// composer takes the thread's own closures, never ones built per render, so a revision the
    /// thread adopts leaves the composer alone.
    var inspectSubagent: ((ChildRun) -> Void)? = nil
    /// Opens a subagent with its Steer field focused (the tray's Steer).
    var steerSubagent: ((ChildRun) -> Void)? = nil
    /// The run open in the inspector: its tray row wears the selection.
    var inspectedRunID: String? = nil
    /// A design's chat (DZCanvas): the standard composer with the design's placeholder. Its pane
    /// draws it compact (`nwComposerSize(.compact)`).
    var designChat = false
    /// Retry in the Can't start banner (true: start a new conversation); nil for a remote agent,
    /// whose banner says to retry on its host.
    var restartPi: ((Bool) -> Void)? = nil
    /// The thread's Not signed in card says it instead of the Can't start banner (a local agent).
    var hidesNotSignedIn = false
    /// `/login` and `/logout`: Shepherd's own commands, for this Mac's agents (nil elsewhere).
    var slashLogin: SlashLoginActions? = nil
    /// The thread's design references (the @ picker, a pasted reference, the chips); nil where
    /// none reach: a design's chat, another host's thread, the Design tool off.
    @Environment(\.designReferences) private var references
    /// The @ picker: where it is and what it lists, derived once per change of the draft.
    @State private var mentions = MentionPickerState()
    /// Where the field's caret is, for ⌫ at the start of the words (not observed: the caret
    /// moving redraws nothing).
    @State private var caret = ComposerCaret()
    /// Why the last design reference couldn't join the message.
    @State private var referenceError: String?
    @State private var commandIndex = 0
    /// Esc closes the slash menu for the draft as typed; typing more reopens it.
    @State private var dismissedQuery: String?
    /// The slash menu's matches for the draft, derived once per change (never while drawing).
    @State private var slash = SlashMatchCache()
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
    /// How far the context ring's trailing edge sits in from the card's: its details open above
    /// it, trailing edges aligned.
    @State private var meterInset: CGFloat = 0
    @State private var dismissal = ComposerMenuDismissal()
    /// Owned here, not by the thread: claiming the keyboard redraws the composer alone.
    @FocusState private var composing: Bool
    /// "Up next": what the stack shows of the store's queue, and its own view state.
    @State private var ownQueueStack = QueueStackState()
    private var queueStack: QueueStackState { queueState ?? ownQueueStack }
    /// The subagent tray's collapse and "Show N more".
    @State private var trayState = SubagentTrayState()
    /// The run whose question is open in the composer's place (from its row's Answer).
    @State private var answering: String?
    /// pi's question the user shrank to its hidden line.
    @State private var questionHiding = NativeQuestionHiding()
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

    /// When the field claims the keyboard: the thread taking it, or a question giving the card
    /// back.
    private struct FieldClaim: Equatable {
        var focused: Bool
        var question: Bool
    }

    /// How long pi may keep the thread waiting before the composer says it is starting: `delay`
    /// over a thread that draws something, no more than `AppLayout.blankStartingIndicatorDelay`
    /// over one that is still blank.
    static func startingDelay(blank: Bool, delay: Duration) -> Duration {
        blank ? min(delay, AppLayout.blankStartingIndicatorDelay) : delay
    }

    private enum Menu: Equatable { case models, thinking, speed, send, context }

    /// The menu over the card, whichever path opened it (typing "/", a chip, ⇧⌘M, Esc, holding
    /// Send).
    private enum OpenMenu: Equatable { case none, slash, mention, models, thinking, speed, send, context }

    // One effective state: a lost connection wins over a cached running snapshot (error maps
    // to Send + an inline error, never Stop).
    // Each reads the store's own property for it, never the snapshot, so a streamed chunk
    // leaves the composer alone.
    private var errored: Bool { store.loadError != nil }
    private var running: Bool { store.running }
    private var dialogs: [NativeThreadDialog] { errored ? [] : store.dialogs }
    /// While pi starts, a send waits for it behind the spinner.
    private var canSend: Bool {
        active && store.acceptsSend && (store.hasDraft || !input.attachments.isEmpty)
    }
    private var canAttach: Bool { store.supportedActions.contains("sendImages") }
    /// pi answers `/name` prompts itself; the list comes from its command registry. Its skills'
    /// commands stay out unless Settings ▸ Skills lists them.
    private var commands: [NativeCommand] {
        let pi = AppSettings.shared.skillsInSlashMenu ? store.commands : store.commands.filter { $0.source != "skill" }
        return slashLogin == nil ? pi : pi + SlashLogin.commands
    }
    /// "/login " (or "/logout ") being typed: its verb and argument so far, for the provider list.
    private var loginQuery: (verb: SlashLogin.Verb, partial: String)? {
        guard slashLogin != nil, store.draft != dismissedQuery else { return nil }
        return SlashLogin.argumentQuery(store.draft)
    }
    /// The provider rows for `loginQuery`, as the menu last drew them.
    private var loginMatches: [SlashLogin.Choice] {
        guard let loginQuery, let slashLogin else { return [] }
        return SlashLogin.matches(loginQuery.partial, in: slashLogin.choices())
    }
    private var commandQuery: String? {
        guard !commands.isEmpty, store.draft.hasPrefix("/"), !store.draft.contains(where: \.isWhitespace),
              store.draft != dismissedQuery else { return nil }
        return String(store.draft.dropFirst()).lowercased()
    }
    /// The commands the slash menu lists for the draft, as `body` last derived them: every key
    /// press comes after the render that saw the draft change.
    private var commandMatches: [NativeCommand] { commandQuery == nil ? [] : slash.matches }
    private var menuOpen: Bool { commandQuery != nil || loginQuery != nil || mentionShown || menu != nil }

    /// @ picks design pieces here: a local thread (not a design's chat) whose host takes references.
    private var mentionsAvailable: Bool { references != nil && !designChat && store.supportedActions.contains("designReferences") }

    /// The @ picker is up: a mention is being typed and the catalog is read.
    private var mentionShown: Bool {
        mentions.isOpen && commandQuery == nil && loginQuery == nil && references?.catalog != nil
    }

    private var openMenu: OpenMenu {
        if commandQuery != nil || loginQuery != nil { return .slash }
        if mentionShown { return .mention }
        return switch menu {
        case .models: .models
        case .thinking: .thinking
        case .speed: .speed
        case .send: .send
        case .context: .context
        case nil: .none
        }
    }

    /// What sits above the card: a banner, the notice, extension widgets, the queue.
    private var accessories: [String] {
        let banner = store.startProblem.map { !(hidesNotSignedIn && $0.kind == .notSignedIn) } == true ? "cannotStart" : store.loadError != nil ? "lost" : input.attachments.error != nil ? "attachment" : referenceError != nil ? "reference" : store.notice != nil ? "notice" : nil
        return [banner].compactMap { $0 } + store.widgets.map(\.id) + (queueStack.isVisible ? ["queue"] : [])
            + (showsTray ? ["tray"] : []) + (answeringRun != nil ? ["answering"] : [])
    }

    private var showsTray: Bool { subagents != nil && store.tray != nil }

    /// What the tray's rows do.
    private var subagents: SubagentActions? {
        guard let inspectSubagent else { return nil }
        return SubagentActions(
            inspect: inspectSubagent,
            command: { [store] run, action, text, mode in
                Task { await store.subagentCommand(runID: run.runID, action: action, text: text, mode: mode) }
            },
            steer: steerSubagent,
            inspectedRunID: inspectedRunID)
    }

    /// The run whose question is open, while it still asks.
    private var answeringRun: ChildRun? {
        guard let answering, subagents != nil else { return nil }
        return store.subagents.first { $0.runID == answering && nativeRunPhase($0) == .needsYou }
    }

    /// pi's question in the composer's place, by the identity its dock takes.
    private var questionKey: String? {
        guard let dialog = dialogs.first, let session = store.session else { return nil }
        return session.key + ":" + dialog.id
    }

    /// Everything here is anchored to the bottom of the thread: what opens above the card grows
    /// up from it while the card stays put. Menus float over the thread from the card's corner
    /// and take no room in the composer; a question takes the whole card's place (the question
    /// dock); banners, widgets, and attachments nudge in. Each is keyed on its own state, so
    /// typing and filtering stay instant.
    var body: some View {
        let _ = NWRenderProbe.tick("composer.body")
        let catchingUp = catchUp.catchingUp(caughtUpAt: store.catchUp?.chrome, version: store.chromeVersion)
        let widgets = store.widgets
        let query = commandQuery
        let _ = slash.update(query: query, commands: commands)
        VStack(alignment: .leading, spacing: AppLayout.menuGap) {
            if !widgets.isEmpty {
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    ForEach(widgets) { WidgetRow(widget: $0).nwTransition(.list, edge: .bottom) }
                }
                .padding(.horizontal, NW.Space.xs)
                .nwTransition(.list, edge: .bottom)
            }
            if let problem = store.startProblem, !(hidesNotSignedIn && problem.kind == .notSignedIn) {
                NWBanner(.failed, title: problem.title, message: problem.message(host: restartPi == nil ? store.hostName ?? "the host" : nil)) {
                    if let restartPi {
                        if problem.kind == .resumedAsNew {
                            Button("Start new conversation") {
                                store.restarting()
                                restartPi(true)
                            }
                            .buttonStyle(.nw(.ghost, size: .s))
                        }
                        Button("Retry") {
                            store.restarting()
                            restartPi(false)
                        }
                        .buttonStyle(.nw(.secondary, size: .s))
                    }
                }
                .nwTransition(.list, edge: .bottom)
            } else if let error = store.loadError {
                NWBanner(.failed, title: "Lost connection to the agent process.", message: error) {
                    Button("Reconnect") { Task { await store.refresh(fresh: true) } }
                        .buttonStyle(.nw(.secondary, size: .s))
                }
                .nwTransition(.list, edge: .bottom)
            } else if let attachmentError = input.attachments.error {
                NWBanner(.failed, title: attachmentError)
                    .nwTransition(.list, edge: .bottom)
            } else if let referenceError {
                NWBanner(.failed, title: referenceError) {
                    Button("Dismiss") { self.referenceError = nil }.buttonStyle(.nw(.ghost, size: .s))
                }
                .nwTransition(.list, edge: .bottom)
            } else if let notice = store.notice {
                Text(notice).font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary).textSelection(.enabled)
                    .padding(.horizontal, NW.Space.xs)
                    .nwTransition(.list, edge: .bottom)
            }
            // The subagents and "Up next" grow upward from the card, which never moves.
            if answeringRun == nil, showsTray || queueStack.isVisible {
                ComposerDock(tray: store.tray, trayState: trayState, runs: store.subagents, actions: subagents,
                             answer: { answering = $0.runID }, showsQueue: queueStack.isVisible) {
                    if queueStack.isVisible {
                        QueueStackView(state: queueStack, store: store, running: running, animated: !catchingUp, framed: !showsTray,
                                       focusedRow: $focusedRow, focusComposer: { composing = true })
                    }
                }
                // A lifted row floats over the card too.
                .zIndex(queueStack.dragging == nil ? 0 : 1)
                .nwTransition(.list, edge: .bottom)
            }
            // A question takes the card's place (the question dock): a subagent's answered from
            // its row until it is answered or hidden, else pi's own while pi waits on it.
            Group {
                if let run = answeringRun, let subagents {
                    SubagentQuestion(run: run, enabled: active && store.supports("subagents"), focused: active && isFocused,
                                     actions: subagents) {
                        answering = nil
                        composing = true
                    }
                    .id(run.runID)
                    .nwTransition(.content)
                } else if let dialog = dialogs.first, let session = store.session, let questionKey {
                    QuestionDock(prompt: NativeQuestionPrompt(dialog: dialog), count: dialogs.count,
                                 enabled: active && store.supports("answer"), hidden: questionHiding.isHidden(questionKey),
                                 focused: active && isFocused) { answer in
                        guard let reply = NativeQuestionPrompt(dialog: dialog).dialogAnswer(answer) else { return }
                        Task {
                            await store.answer(dialogID: dialog.id, sessionID: session.piSessionID,
                                               generation: session.generation, answer: reply)
                        }
                    } setHidden: { hidden in
                        if hidden { questionHiding.hide(questionKey) } else { questionHiding.show() }
                    }
                    .id(questionKey)
                    .nwTransition(.content)
                } else {
                    card
                }
            }
                .background { ComposerMenuRegion(dismissal: dismissal) }
                .background { ComposerWindowReader(monitor: keyMonitor) }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.threadSpace)).minY } action: { cardTop = $0 }
                .onGeometryChange(for: Bool.self) { proxy in
                    Self.sendMenuBeside(room: (proxy.bounds(of: .named(Self.threadSpace))?.maxX ?? proxy.size.width) - proxy.size.width)
                } action: { sendMenuFitsBeside = $0 }
                .overlay(alignment: .topLeading) { menus(query: query) }
                .overlay(alignment: .topTrailing) { contextDetails }
                .overlay(alignment: sendMenuFitsBeside ? .bottomTrailing : .topTrailing) {
                    sendMenu(beside: sendMenuFitsBeside)
                }
        }
        .nwAnimation(.list, value: accessories)
        .nwAnimation(.list, value: input.attachments.ids)
        .nwAnimation(.list, value: store.attachedFiles.map(\.id))
        .nwAnimation(.list, value: store.attachedReferences.map(\.id))
        .nwAnimation(.disclosure, value: questionKey)
        .nwAnimation(.disclosure, value: questionHiding)
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
            keyMonitor.accepts = { [store, input, focusedRow = $focusedRow] in
                focusedRow.wrappedValue != nil
                    || ((store.hasDraft || !input.attachments.isEmpty) && store.acceptsSend && !store.busy
                        && store.dialogs.isEmpty)
            }
            keyMonitor.watch(focused)
        }
        .onChange(of: keyMonitor.presses) { _, _ in sendTheOtherWay() }
        // A hold that opened the Send menu and let go elsewhere leaves the next click a send.
        .onChange(of: menu) { _, menu in if menu != .send { sendHeld = false } }
        .onChange(of: active && questionKey == nil && answeringRun == nil, initial: true) { _, available in
            input.available = available
        }
        .onChange(of: input.focusRequest) { _, _ in
            guard active, questionKey == nil, answeringRun == nil else { return }
            composing = true
        }
        .onDisappear {
            input.available = false
            dismissal.watch(false)
            keyMonitor.watch(false)
        }
        // Let any deferred AppKit focus release finish before claiming the field (again once a
        // question gives the card back).
        .task(id: FieldClaim(focused: active && isFocused, question: questionKey != nil || answeringRun != nil)) {
            composing = false
            guard active && isFocused, questionKey == nil, answeringRun == nil else { return }
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
        // A pasted reference becomes a chip; a mention opens the @ picker.
        .onChange(of: store.draft, initial: true) { old, new in draftChanged(from: old, to: new) }
        .onChange(of: references?.catalog) { _, _ in updateMentions() }
        .onChange(of: mentionsAvailable) { _, _ in updateMentions() }
        .onChange(of: references?.picturesVersion) { _, _ in if mentions.isOpen { updateMentions() } }
        .onChange(of: mentionShown) { _, shown in if shown { menu = nil } }
        .onChange(of: loginQuery?.partial) { _, partial in
            commandIndex = 0
            if partial != nil { menu = nil }
        }
        .task { if contextDetailsOpen { menu = .context } }
        // The catalog decides whether the thinking chip applies; this Mac's is asked once per process.
        .task { if catalog?.isEmpty != false { await loadModels() } }
        // ⇧⌘M and the thinking menu's command, watched apart from the thread and the composer.
        .modifier(ThreadCommandHandler(key: commandKey, active: active, handle: handleCommand))
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            attach(urls.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() })
        }
        .sheet(isPresented: $confirmingStopAll) {
            StopAllDialog(runningSubagents: store.subagents.count { !$0.isTerminal },
                          stopAgent: { confirmingStopAll = false; Task { await store.abort() } },
                          stopAll: { confirmingStopAll = false; Task { await store.abortAll() } },
                          cancel: { confirmingStopAll = false })
        }
    }

    /// The command center's menu commands; the thread handles the rest.
    private func handleCommand(_ command: ThreadCommandCenter.Command) {
        switch command {
        case .modelPicker: openModels()
        case .thinkingMenu: toggleThinking()
        case .speedMenu: toggleSpeed()
        case .previousTurn, .nextTurn, .inspectSubagent: break
        }
    }

    /// The levels pi offers the thread's model, with the board's notes.
    private var thinkingOptions: [NWThinkingOption] {
        store.thinkingLevels.map { NWThinkingOption(id: $0.id, title: $0.title, note: $0.note) }
    }

    /// The tiers the model offers, with the board's words.
    private var speedOptions: [NWSpeedOption] {
        store.serviceTiers.map { NWSpeedOption(id: $0.rawValue, title: $0.title, detail: $0.summary, boosted: $0 != .standard) }
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
                let slash = slash
                NWSlashMenu(commands: slash.rows, total: commands.count, query: query, selection: $commandIndex, maxHeight: room) { command in
                    if let match = slash.matches.first(where: { $0.name == command.name }) { choose(match) }
                }
                .nwTransition(.overlay, anchor: .bottomLeading)
            } else if let login = loginQuery, let slashLogin {
                // SlashLoginArgs: the providers, with their states, before anything reaches pi.
                let all = slashLogin.choices()
                let rows = SlashLogin.matches(login.partial, in: all)
                NWSlashMenu(commands: rows.map { SlashLogin.row($0, verb: login.verb) }, total: all.count, query: login.partial,
                            title: SlashLogin.title(login.verb), selection: $commandIndex, maxHeight: room) { row in
                    openLogin(SlashLogin.Command(verb: login.verb, provider: row.name))
                }
                .nwTransition(.overlay, anchor: .bottomLeading)
            } else if mentionShown {
                // MentionPicker: designs, then a design's boards and a board's elements.
                let content = mentions.content
                NWMentionPicker(sections: content.sections, crumbs: content.crumbs, empty: content.empty, highlighted: mentions.highlighted,
                                maxHeight: room, choose: { chooseMention($0) }, drill: { chooseMention($0) },
                                back: { mentionBack() }, hover: { mentions.highlighted = $0 }, startDesign: references?.io.startDesign,
                                appear: { id in
                                    // An element's row on screen: its picture is cut now, not before.
                                    if let item = mentions.content.items[id] { references?.rowAppeared(item) }
                                })
                    .nwTransition(.overlay, anchor: .bottomLeading)
            }
            // The picker and the thinking menu compare what they draw, so a composer redraw for
            // something else (the field losing focus to them, a keystroke) leaves their rows alone.
            if menu == .models, let picker {
                ModelPicker(state: picker, maxHeight: room) { model in
                    menu = nil
                    composing = true
                    RecentModels.record(model, thread: agentName)
                    Task { await store.setModel(model) }
                } close: { menu = nil; composing = true }
                .equatable()
                .nwTransition(.overlay, anchor: .bottomLeading)
            }
            if menu == .thinking, let thinking = store.thinking {
                ThinkingMenu(options: thinkingOptions, current: thinking) { level in
                    menu = nil
                    composing = true
                    Task { await store.setThinking(level.id) }
                } close: { menu = nil; composing = true }
                .equatable()
                .nwTransition(.overlay, anchor: .bottomLeading)
            }
            if menu == .speed, store.offersServiceTier {
                SpeedMenu(options: speedOptions, current: store.serviceTier.rawValue) { option in
                    menu = nil
                    composing = true
                    if let tier = ServiceTier(rawValue: option.id) { Task { await store.setServiceTier(tier) } }
                } close: { menu = nil; composing = true }
                .equatable()
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
        let (menu, dismissedQuery, store, mentions) = ($menu, $dismissedQuery, store, $mentions)
        return {
            switch open {
            case .slash: dismissedQuery.wrappedValue = store.draft
            case .mention:
                mentions.wrappedValue.dismissed = store.draft
                mentions.wrappedValue.close()
            default: menu.wrappedValue = nil
            }
        }
    }

    // MARK: Card

    /// The context ring's details, above the ring, trailing edges aligned (ContextDetails).
    private var contextDetails: some View {
        ZStack(alignment: .bottomTrailing) {
            if menu == .context {
                ContextDetailsPopover(store: store, active: active, find: { id in
                    menu = nil
                    finder?.find(id)
                }, close: { menu = nil; composing = true })
                .background { ComposerMenuRegion(dismissal: dismissal) }
                .nwTransition(.overlay, anchor: .bottomTrailing)
            }
        }
        .fixedSize()
        .padding(.trailing, meterInset)
        .alignmentGuide(.top) { $0[.bottom] + AppLayout.menuGap }
        .nwAnimation(.overlay, value: menu == .context)
    }

    private var card: some View {
        // The context details float over the thread without the card taking focus's look.
        let focused = composing || (active && input.dropTargeted) || (menuOpen && menu != .context)
        return NWComposer(isFocused: focused) {
            // Design references sit first, above the words (DesignReferenceChip(ref)).
            ForEach(store.attachedReferences) { attached in
                ComposerReferenceChip(attached: attached, references: references) { store.detachReference(attached.id) }
                    .nwTransition(.list, edge: .leading)
            }
            // Elements picked in the Browser (PaneBrowser's composer).
            ForEach(store.attachedElements) { attached in
                NWElementChip(attached.element.label, source: attached.element.sourceShort) { store.detachElement(attached.id) }
                    .help(attached.element.selector)
                    .nwTransition(.list, edge: .leading)
            }
            ForEach(store.attachedFiles) { file in
                NWAttachmentChip(file.name, thumbnail: nil) { store.detachFile(file.id) }
                    .help(file.path)
                    .nwTransition(.list, edge: .leading)
            }
            ForEach(input.attachments.items) { attachment in
                NWAttachmentChip(attachment.name, thumbnail: attachment.thumbnail) {
                    input.attachments.remove(attachment.id)
                }
                .nwTransition(.list, edge: .leading)
            }
        } field: {
            field.nwEntrance(.content)
        } controls: {
            ComposerControls(model: controlsModel, actions: controlsActions, store: store).equatable()
        }
        .coordinateSpace(.named(Self.cardSpace))
    }

    private var placeholder: String {
        if designChat { return "Describe a change, or click something on the canvas to comment…" }
        if !hasTurns { return "Describe the task, or / for commands…" }
        return commands.isEmpty ? "Follow up…" : "Follow up, or / for commands…"
    }

    /// The field's selection, kept in `caret` without redrawing the composer. A selection the
    /// draft has outgrown (the draft replaced from outside the field) reads as none.
    private var caretBinding: Binding<TextSelection?> {
        Binding(get: { [caret, store] in caret.selection(in: store.draft) }, set: { [caret] in caret.selection = $0 })
    }

    private var field: some View {
        TextField(text: $store.draft, selection: caretBinding, prompt: Text(placeholder).foregroundStyle(Color.nw.textTertiary),
                  axis: .vertical) {
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
                if press.modifiers.contains(.shift) { return .ignored }
                if let login = loginQuery {
                    let matches = loginMatches
                    openLogin(SlashLogin.Command(verb: login.verb,
                                                 provider: matches.indices.contains(commandIndex) ? matches[commandIndex].id : nil))
                    return .handled
                }
                if commandQuery != nil {
                    let matches = commandMatches
                    if matches.indices.contains(commandIndex) { choose(matches[commandIndex]) }
                    return .handled
                }
                if mentionShown {
                    if let row = mentions.highlightedRow { chooseMention(row) }
                    return .handled
                }
                guard canSend, !store.busy else { return .handled }
                // ⌘↩ when a key press brings it here; the key monitor usually takes it first.
                let alternate = KeybindingsStore.shared.chord(for: .alternateSend).matches(press)
                sendDraft(alternate ? .alternate : .primary)
                return .handled
            }
            .onKeyPress(.tab) {
                if let login = loginQuery {
                    let matches = loginMatches
                    guard matches.indices.contains(commandIndex) else { return .handled }
                    store.draft = "/\(login.verb.rawValue) \(matches[commandIndex].id)"
                    return .handled
                }
                if mentionShown, commandQuery == nil {
                    if let row = mentions.highlightedRow { chooseMention(row) }
                    return .handled
                }
                let matches = commandMatches
                guard commandQuery != nil, matches.indices.contains(commandIndex) else { return .ignored }
                complete(matches[commandIndex])
                return .handled
            }
            .onKeyPress(.upArrow) {
                if mentionShown {
                    mentions.move(-1)
                    return .handled
                }
                guard commandQuery == nil, loginQuery == nil else {
                    commandIndex = max(0, commandIndex - 1)
                    return .handled
                }
                // ↑ in an empty composer edits the last queued message.
                guard store.draft.isEmpty, menu == nil, queueStack.editLast(store: store) else { return .ignored }
                return .handled
            }
            .onKeyPress(.downArrow) {
                if mentionShown {
                    mentions.move(1)
                    return .handled
                }
                if loginQuery != nil {
                    commandIndex = min(max(0, loginMatches.count - 1), commandIndex + 1)
                    return .handled
                }
                guard commandQuery != nil else { return .ignored }
                commandIndex = min(max(0, commandMatches.count - 1), commandIndex + 1)
                return .handled
            }
            // → drills into a design or a board; ← and ⌫ with nothing typed after the breadcrumb go
            // back a level (MentionPicker · inside a board).
            .onKeyPress(.rightArrow) {
                guard mentionShown, let row = mentions.highlightedRow, row.trailing == .drill else { return .ignored }
                chooseMention(row)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard mentionShown, mentions.filterIsEmpty, mentions.scope != .designs else { return .ignored }
                mentionBack()
                return .handled
            }
            .onKeyPress(.delete) {
                if mentionShown, mentions.filterIsEmpty, mentions.scope != .designs {
                    mentionBack()
                    return .handled
                }
                // ⌫ with the caret at the start of the words takes the last chip back (RefPasted).
                guard let last = store.attachedReferences.last,
                      ComposerCaret.takesBackChip(draft: store.draft, selection: caret.selection(in: store.draft)) else { return .ignored }
                store.detachReference(last.id)
                return .handled
            }
            .onKeyPress(.escape) {
                switch ComposerEscape(menuOpen: menu != nil, commandsOpen: commandQuery != nil || loginQuery != nil || mentionShown,
                                      canStop: running && dialogs.isEmpty && active && store.supports("abort")) {
                case .closeMenu: menu = nil
                case .dismissCommands where mentionShown && commandQuery == nil && loginQuery == nil:
                    mentions.dismissed = store.draft
                    mentions.close()
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

    // MARK: Controls

    /// What the control row draws, gathered once per composer render so the row can compare it
    /// before redrawing (`ComposerControls`): past the first character, typing changes none of
    /// it, and neither does the field losing focus to a menu.
    /// The card shows only while no question waits (the question dock takes its place).
    private var controlsModel: ComposerControlsModel {
        let working = running
        let draftEmpty = !store.hasDraft && input.attachments.isEmpty
        let stops = working && draftEmpty
        return ComposerControlsModel(
            active: active, canAttach: canAttach, attachFull: input.attachments.isFull,
            hasCommands: !commands.isEmpty, commandsActive: commandQuery != nil,
            model: store.model, modelChangeable: store.supportedActions.contains("setModel"),
            modelEnabled: store.supports("setModel"), modelsOpen: menu == .models,
            thinking: store.thinking, thinkingShown: thinkingAvailable, thinkingEnabled: store.supports("setThinking"),
            thinkingOpen: menu == .thinking,
            speed: store.serviceTier, speedShown: store.offersServiceTier, speedEnabled: store.supports("setServiceTier"),
            speedOpen: menu == .speed,
            startingShown: startingShown, busy: store.busy, stops: stops, beside: working && !draftEmpty && !store.busy,
            sendRinged: menu == .send, contextOpen: menu == .context,
            stopEnabled: active && store.supports("abort"),
            actionEnabled: stops ? active && store.supports("abort") : canSend,
            stopHelp: stopHelp, actionHelp: stops ? stopHelp : sendHelp(working: working))
    }

    /// What the row's controls do. Each reads the store and the composer's own state as it runs,
    /// never a value of the render that made it, so the row keeps them while its model holds.
    private var controlsActions: ComposerControlsActions {
        ComposerControlsActions(
            attach: { picking = true },
            commands: {
                store.draft = "/"
                dismissedQuery = nil
                menu = nil
                composing = true
            },
            models: { openModels() },
            thinking: { toggleThinking() },
            speed: { toggleSpeed() },
            stop: { stop() },
            send: { if sendHeld { sendHeld = false } else { sendDraft(.primary) } },
            sendMenu: { openSendMenu() },
            holdSend: {
                sendHeld = true
                openSendMenu()
            },
            context: { menu = menu == .context ? nil : .context },
            meterInset: { meterInset = max(0, $0) })
    }

    private var stopHelp: String {
        store.hasLiveSubagents ? "Stop the agent and its subagents" : "Stop the agent's turn"
    }

    /// "Send (↩)", or while pi works "Steer at the next step (↩) · Steer now (⌘↩)": the Return
    /// setting's way, then the alternate's.
    private func sendHelp(working: Bool) -> String {
        let keys = KeybindingsStore.shared
        guard working else { return "Send (\(keys.sendDisplay))" }
        let (primary, alternate) = Self.sendTitles(AppSettings.shared.returnWhileWorking)
        return "\(primary) (\(keys.sendDisplay)) · \(alternate) (\(keys.display(.alternateSend)))"
    }

    /// The Return setting's way first, then what the alternate send always does.
    static func sendTitles(_ setting: ReturnWhileWorking) -> (primary: String, alternate: String) {
        (setting.title, NativeSendChoice.now.title)
    }

    private func stop() {
        if store.subagents.count(where: { !$0.isTerminal }) > 1 { confirmingStopAll = true }
        else { Task { await store.abortAll() } }
    }

    /// The thinking chip shows while pi reports a level it can set and the model takes one.
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
        picker = ModelPickerState(catalog: catalog, recent: RecentModels.load().map(\.id), current: store.model,
                                  currentLevels: store.snapshot?.thinkingLevels)
        dismissCommands()
        menu = .models
        // The shared catalog caches unchanged files. Re-read on opening so connections added
        // in Settings appear in an already-mounted thread, and disabled ones disappear.
        Task { await loadModels() }
    }

    private func toggleThinking() {
        guard thinkingAvailable, store.supports("setThinking") else { NSSound.beep(); return }
        guard menu != .thinking else { menu = nil; return }
        dismissCommands()
        menu = .thinking
    }

    private func toggleSpeed() {
        guard store.offersServiceTier, store.supports("setServiceTier") else { NSSound.beep(); return }
        guard menu != .speed else { menu = nil; return }
        dismissCommands()
        menu = .speed
    }

    /// A chip's menu takes over from the slash menu, which stays closed for the draft as typed
    /// (as Esc leaves it).
    private func dismissCommands() {
        if commandQuery != nil || loginQuery != nil { dismissedQuery = store.draft }
    }

    private func loadModels() async {
        // Without a host's listing, this Mac's: the app's pi (the composition root's setup).
        let loaded = if let listModels { await listModels() } else { await ModelCatalog.loadLocal(from: PiSetup.app.catalog) }
        guard catalog?.models != loaded.models else { return }
        catalog = loaded
        picker?.update(loaded)
    }

    private func choose(_ command: NativeCommand) {
        if command.source == SlashLogin.source, let verb = SlashLogin.Verb(rawValue: command.name) {
            openLogin(SlashLogin.Command(verb: verb, provider: nil))
            return
        }
        store.draft = "/\(command.name)"
        dismissedQuery = nil
        composing = true
        guard canSend else { return }
        sendDraft(.primary)
    }

    /// `/login` or `/logout`: never sent. The composer clears, and Sign-in opens.
    private func openLogin(_ command: SlashLogin.Command) {
        store.draft = ""
        dismissedQuery = nil
        slashLogin?.open(command)
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
        // `/login …` typed out and sent: Sign-in opens; nothing reaches pi.
        if slashLogin != nil, let command = SlashLogin.parse(store.draft) {
            openLogin(command)
            return
        }
        let images = input.attachments.images
        let submitted = input.attachments.ids
        Task {
            if await store.send(images: images, delivery: delivery) {
                for id in submitted { input.attachments.remove(id) }
            }
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

    // MARK: Design references

    /// The draft changed: a reference it gained by a paste becomes a chip (the text around it
    /// stays), and the @ picker follows the mention it ends in.
    private func draftChanged(from old: String, to new: String) {
        guard mentionsAvailable else {
            if mentions.isOpen { mentions.close() }
            return
        }
        if let pasted = ComposerReferencePaste.extract(new, previous: old) {
            store.draft = pasted.draft
            for reference in pasted.references { attachReference(reference) }
            return
        }
        updateMentions()
    }

    /// Derives what the @ picker lists for the draft as it is; opening it reads this Mac's designs.
    private func updateMentions() {
        guard mentionsAvailable, let references else { return }
        let wasOpen = mentions.isOpen, scope = mentions.scope
        mentions.update(draft: store.draft, catalog: references.catalog) { references.rowPicture($0) }
        if mentions.isOpen, !wasOpen {
            referenceError = nil
            Task { await references.loadCatalog() }
            references.io.wantPictures(mentions.scope)
        } else if mentions.isOpen, mentions.scope != scope {
            references.io.wantPictures(mentions.scope)
        }
    }

    /// A row chosen: a design or board drills in; anything else joins the message as a chip, its
    /// mention taken out of the words.
    private func chooseMention(_ row: NWMentionRow) {
        switch mentions.choose(row) {
        case .drill(let draft):
            store.draft = draft
        case .pick(let reference, let draft):
            store.draft = draft
            attachReference(reference)
        case nil:
            break
        }
        composing = true
    }

    private func mentionBack() {
        if let draft = mentions.back() { store.draft = draft }
        composing = true
    }

    /// Pins `reference` and puts its chip in the composer; why it can't, in the banner.
    private func attachReference(_ reference: DesignReference) {
        guard let references else { return }
        Task {
            do {
                try await references.io.attach(reference)
                referenceError = nil
            } catch {
                referenceError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
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

    /// The three ways to send, beside the card or above it (`sendMenuBeside`), growing from the
    /// corner nearest Send; the Return setting's row leads the highlight and wears ↩.
    @ViewBuilder private func sendMenu(beside: Bool) -> some View {
        ZStack(alignment: beside ? .bottomLeading : .bottomTrailing) {
            if menu == .send {
                let setting = AppSettings.shared.returnWhileWorking
                let keys = KeybindingsStore.shared
                let options = Self.sendOptions(setting, send: keys.sendDisplay, alternate: keys.display(.alternateSend))
                NWSendMenu(options: options, highlighted: options.firstIndex { $0.id == setting.choice.id } ?? 0) { option in
                    menu = nil
                    composing = true
                    sendDraft(delivery: (NativeSendChoice(rawValue: option.id) ?? .wait).delivery)
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

    /// Wait for the turn to end, Steer at the next step, then Steer now: ↩ on the Return
    /// setting's row, the alternate chord on Steer now, and no keys on the remaining one.
    static func sendOptions(_ setting: ReturnWhileWorking, send: String, alternate: String) -> [NWSendOption] {
        NativeSendChoice.allCases.map { choice in
            NWSendOption(id: choice.id, title: choice.title, detail: choice.detail, glyph: glyph(choice),
                         shortcut: choice == .now ? alternate : choice == setting.choice ? send : nil)
        }
    }

    private static func glyph(_ choice: NativeSendChoice) -> NWSendOption.Glyph {
        switch choice {
        case .wait: .queue
        case .nextStep: .symbol("arrow.right.to.line")
        case .now: .symbol("arrow.turn.down.right")
        }
    }

    /// Dropped or pasted images become attachments through the same resize rules as terminal
    /// drops (longest edge 2000px, JPEG stays JPEG, everything else PNG).
    private func attach(_ providers: [NSItemProvider]) {
        input.attach(providers, store: store, localFiles: allowsLocalFiles)
    }
}

// MARK: The control row

/// What the composer's control row draws (`ComposerControls`), compared before the row redraws.
struct ComposerControlsModel: Equatable {
    var active: Bool
    var canAttach: Bool
    var attachFull: Bool
    var hasCommands: Bool
    var commandsActive: Bool
    var model: String?
    /// The host lets the model change (the chevron); `modelEnabled` is whether it can right now.
    var modelChangeable: Bool
    var modelEnabled: Bool
    var modelsOpen: Bool
    var thinking: String?
    var thinkingShown: Bool
    var thinkingEnabled: Bool
    var thinkingOpen: Bool
    /// The Speed chip: the agent's tier, shown while the model offers one besides Standard.
    var speed: ServiceTier
    var speedShown: Bool
    var speedEnabled: Bool
    var speedOpen: Bool
    var startingShown: Bool
    var busy: Bool
    /// Stop takes the corner: pi works and the field is empty.
    var stops: Bool
    /// Stop stands aside outlined: pi works, with a draft to send.
    var beside: Bool
    var sendRinged: Bool
    /// The context ring's details are open.
    var contextOpen: Bool
    var stopEnabled: Bool
    var actionEnabled: Bool
    var stopHelp: String
    var actionHelp: String
}

/// What the control row's controls do, kept apart from the model so they never count as a change.
struct ComposerControlsActions {
    var attach: () -> Void
    var commands: () -> Void
    var models: () -> Void
    var thinking: () -> Void
    var speed: () -> Void
    var stop: () -> Void
    var send: () -> Void
    var sendMenu: () -> Void
    var holdSend: () -> Void
    var context: () -> Void
    /// How far the ring's trailing edge sits in from the card's.
    var meterInset: (CGFloat) -> Void
}

/// The composer's control row: attach · / commands · model · thinking, then the context ring and
/// Send or Stop, with full chip labels when they fit; in a narrow thread (a docked right pane) the chips drop their words
/// ("/", the thinking level alone) instead of truncating mid-word, after "Starting…" drops
/// its own. At the compact size (`NWComposerSize`: a design's chat) they never show their words. `ViewThatFits` builds and measures every alternative, each with its tooltips and
/// accessibility, whenever the row is rebuilt, so the row compares what it draws first: a
/// keystroke past the first character and the field losing focus to a menu rebuild the field,
/// never the chips.
struct ComposerControls: View, Equatable {
    let model: ComposerControlsModel
    let actions: ComposerControlsActions
    /// Handed to the ring, which reads its meter; the row itself reads nothing from it.
    let store: NativeThreadStore

    @Environment(\.nwComposerSize) private var size

    static func == (a: Self, b: Self) -> Bool { a.model == b.model && a.store === b.store }

    var body: some View {
        ComposerControlsMinimum {
            HStack(spacing: NW.Space.xxs) {
                ViewThatFits(in: .horizontal) {
                    // At the compact size the chips never show their words: only "Starting…" can drop its own.
                    chips(compact: size == .compact, startingLabel: true)
                    // "Starting…" gives up its words before the chips do.
                    chips(compact: size == .compact, startingLabel: false)
                    if size == .regular { chips(compact: true, startingLabel: false) }
                }
                // A new model or level cross-fades. Only these: typing and width changes stay instant.
                .nwAnimation(.content, value: [model.model, model.thinking, model.speedShown ? model.speed.rawValue : nil])
                // The ring and the action, 6pt apart, keep their place whatever the chips drop; out
                // of the fitting candidates, each is built once (a streamed chunk redraws neither).
                HStack(spacing: NW.Space.s) {
                    ContextMeterButton(store: store, expanded: model.contextOpen, toggle: actions.context)
                        .equatable()
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            (proxy.bounds(of: .named(Composer.cardSpace))?.width ?? 0)
                                - proxy.frame(in: .named(Composer.cardSpace)).maxX
                        } action: { actions.meterInset($0) }
                    primary
                }
            }
        }
    }

    private func chips(compact: Bool, startingLabel: Bool) -> some View {
        let _ = NWRenderProbe.tick("composer.chips")
        return HStack(spacing: NW.Space.xxs) {
            if model.canAttach {
                Button(action: actions.attach) { Image(systemName: "paperclip") }
                    .buttonStyle(.nwIcon(size: NWComposerMetrics.chipHeight))
                    .disabled(model.attachFull)
                    .help("Attach images (drop or paste also works), up to \(NativeImage.maxPerSend)")
                    .accessibilityLabel("Attach file")
            }
            if model.hasCommands {
                Button(action: actions.commands) { NWComposerCommandsLabel(short: compact) }
                .buttonStyle(.nwComposerChip(active: model.commandsActive))
                .help("Commands")
                .accessibilityLabel("Commands")
            }
            modelChip(compact: compact)
            thinkingChip(compact: compact)
            speedChip(compact: compact)
            Spacer(minLength: NW.Space.m)
            if model.startingShown { startingIndicator(label: startingLabel).nwTransition(.content) }
        }
        .nwAnimation(.content, value: model.startingShown)
    }

    @ViewBuilder private func modelChip(compact: Bool) -> some View {
        if let name = model.model {
            ComposerModelChip(model: name, short: compact, changeable: model.modelChangeable,
                              enabled: model.modelEnabled, active: model.modelsOpen, action: actions.models)
        }
    }

    /// The level pi runs at, opening the levels pi offers the model; hidden when the model takes
    /// no thinking level.
    @ViewBuilder private func thinkingChip(compact: Bool) -> some View {
        if model.thinkingShown, let thinking = model.thinking {
            ComposerThinkingChip(level: thinking, short: compact, enabled: model.thinkingEnabled,
                                 active: model.thinkingOpen, action: actions.thinking)
        }
    }

    /// How fast the agent asks its provider to answer, opening the tiers its model offers; hidden
    /// when the model offers none (an Anthropic or Gemini model, an older host).
    @ViewBuilder private func speedChip(compact: Bool) -> some View {
        if model.speedShown {
            ComposerSpeedChip(tier: model.speed, short: compact, enabled: model.speedEnabled,
                              active: model.speedOpen, action: actions.speed)
        }
    }

    /// "Starting…" beside the action, quiet and in the row it never resizes. Its spinner
    /// gives way to Send's own while a message waits for the agent.
    private func startingIndicator(label: Bool) -> some View {
        HStack(spacing: AppLayout.startingSpacing) {
            if !model.busy {
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
        let beside = model.beside
        return HStack(spacing: NW.Space.s) {
            if beside {
                NWComposerActionButton(.stop, outlined: true, enabled: model.stopEnabled, action: actions.stop)
                    .help(model.stopHelp)
                    .nwTransition(.content)
            }
            ZStack {
                if model.busy {
                    ProgressView().progressViewStyle(.nwSpinner(color: Color.nw.textTertiary))
                        .frame(width: NWComposerMetrics.actionSize, height: NWComposerMetrics.actionSize)
                        .accessibilityLabel("Waiting for the agent")
                        .nwTransition(.content)
                } else {
                    NWComposerActionButton(model.stops ? .stop : .send, ringed: model.sendRinged, enabled: model.actionEnabled,
                                           action: model.stops ? actions.stop : actions.send)
                    .help(model.actionHelp)
                    .overlay { if beside { SecondaryClick(action: actions.sendMenu) } }
                    .simultaneousGesture(LongPressGesture(minimumDuration: AppLayout.sendHoldDelay / .seconds(1)).onEnded { _ in
                        guard beside else { return }
                        actions.holdSend()
                    }, isEnabled: beside)
                    .nwTransition(.content)
                }
            }
        }
        .nwAnimation(.content, value: model.busy)
        .nwAnimation(.content, value: beside)
    }
}

/// Answers the window's minimum-size pass for the control row without measuring it. The window
/// sizes to its content's minimum (`windowResizability(.contentMinSize)`), so after every change
/// that could move it (each keystroke in the field, whose text field reports a new intrinsic
/// size) the scene's hosting view measures the whole view tree from a zero-width proposal: the
/// row is asked at no width, at the width of its paddings, and again at its own minimum as the
/// pass places it. At each of those `ViewThatFits` measures every alternative, building the two
/// it does not show, with their tooltips and accessibility: half of a keystroke's main-thread
/// time. A real layout never proposes the row less than `AppLayout.composerControlsNarrowest`,
/// and the row's minimum is never the window's (`AppLayout.windowMinWidth` on the root and the
/// thread column's `threadMinWidth` are both wider than the compact row), so a narrower proposal
/// is answered with the width offered (the row's spacer takes all of any width it fits in) and
/// the row's height, and every other proposal reaches the row as it is. Placed, the row gets the
/// width it answered, as a stack would have proposed it.
struct ComposerControlsMinimum: Layout {
    // Its probes count layout passes, not bodies, so they stay out of "composer." (which the
    // redraw budgets read as the composer drawing).
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let row = subviews.first else { return .zero }
        if let width = proposal.width, width < AppLayout.composerControlsNarrowest {
            MainActor.assumeIsolated { NWRenderProbe.tick("layout.composerControlsMinimum") }
            return CGSize(width: max(0, width), height: NWComposerMetrics.actionSize)
        }
        MainActor.assumeIsolated { NWRenderProbe.tick("layout.composerControlsMeasured") }
        return row.sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }

    // The pass asks for the row's alignment guides too, and `Layout`'s own answer places the
    // subviews to find them, which at those widths measures every alternative after all. The
    // row sets no explicit guide (its chips use none, and nothing above it aligns to a
    // baseline), so it aligns by its frame, as the stack it wraps did.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) -> CGFloat? { nil }
}

/// The slash menu's rows for the draft, derived once per draft and command list (a keystroke,
/// pi's registry changing), never while drawing or on a key press. A reference read in `body`,
/// so keeping it current re-renders nothing. `NWRenderProbe` counts each derivation
/// ("composer.slashMatches").
@MainActor
final class SlashMatchCache {
    private var query: String?
    private var commands: [NativeCommand] = []
    /// The commands matching the query, in the menu's order.
    private(set) var matches: [NativeCommand] = []
    /// The same as the menu draws them.
    private(set) var rows: [NWSlashCommand] = []

    /// `query` is the draft after "/" (nil while the menu is closed).
    func update(query: String?, commands: [NativeCommand]) {
        guard query != self.query || commands != self.commands else { return }
        self.query = query
        self.commands = commands
        matches = Self.matches(query: query, in: commands)
        rows = matches.map(Self.row)
        NWRenderProbe.tick("composer.slashMatches")
    }

    /// Commands whose name starts with `query` first, then those whose name or description
    /// contains it, each in pi's order; all of them for an empty query.
    static func matches(query: String?, in commands: [NativeCommand]) -> [NativeCommand] {
        guard let query else { return [] }
        guard !query.isEmpty else { return commands }
        var prefixed: [NativeCommand] = []
        var containing: [NativeCommand] = []
        for command in commands {
            let name = command.name.lowercased()
            if name.hasPrefix(query) {
                prefixed.append(command)
            } else if name.contains(query) || (command.description ?? "").lowercased().contains(query) {
                containing.append(command)
            }
        }
        return prefixed + containing
    }

    static func row(_ command: NativeCommand) -> NWSlashCommand {
        NWSlashCommand(name: command.name, description: command.description, arguments: command.arguments,
                       tag: command.source.flatMap { $0 == "extension" ? nil : $0 == SlashLogin.source ? SlashLogin.tag : $0 })
    }
}

/// The thinking menu over `NWThinkingMenu`, compared on the levels it offers and the current
/// one, so a composer redraw for something else leaves its rows alone.
struct ThinkingMenu: View, Equatable {
    let options: [NWThinkingOption]
    let current: String
    let choose: (NWThinkingOption) -> Void
    let close: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.options == b.options && a.current == b.current }

    var body: some View {
        NWThinkingMenu(options: options, current: current, onChoose: choose, onClose: close)
    }
}

/// The speed menu over `NWSpeedMenu`, compared on the tiers it offers and the current one, so a
/// composer redraw for something else leaves its rows alone.
struct SpeedMenu: View, Equatable {
    let options: [NWSpeedOption]
    let current: String
    let choose: (NWSpeedOption) -> Void
    let close: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.options == b.options && a.current == b.current }

    var body: some View {
        NWSpeedMenu(options: options, current: current, onChoose: choose, onClose: close)
    }
}

/// "provider/model" → "model".
func nativeModelShortName(_ model: String) -> String {
    guard let slash = model.firstIndex(of: "/") else { return model }
    return String(model[model.index(after: slash)...])
}

/// The narrow composer's model name: the short name without a trailing release date, so a
/// long id keeps the model ("claude-sonnet-4") rather than its date.
func nativeModelCompactName(_ model: String) -> String {
    var name = nativeModelShortName(model)
    if let dash = name.lastIndex(of: "-"), name.distance(from: dash, to: name.endIndex) == 9,
       name[name.index(after: dash)...].allSatisfy({ $0.isASCII && $0.isNumber }) {
        name = String(name[..<dash])
    }
    return name.isEmpty ? model : name
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
        if let percent = stats.contextPercent { line += " (\(nativeContextPercentText(percent)))" }
        parts.append(line)
    }
    if let total = stats.totalTokens { parts.append("\(nativeTokenCount(total)) tokens this session") }
    if let cost = stats.cost { parts.append(cost.formatted(.currency(code: "USD"))) }
    return parts.joined(separator: " · ")
}

// MARK: Sending while pi works

/// Where the composer field's caret is. Written by the field as the caret moves, read only when
/// ⌫ is pressed, so nothing observes it.
final class ComposerCaret {
    var selection: TextSelection?

    /// The selection, while it still lies inside `draft`.
    func selection(in draft: String) -> TextSelection? {
        guard let selection else { return nil }
        switch selection.indices {
        case .selection(let range): return range.upperBound <= draft.endIndex ? selection : nil
        case .multiSelection(let ranges): return ranges.ranges.allSatisfy { $0.upperBound <= draft.endIndex } ? selection : nil
        @unknown default: return nil
        }
    }

    /// Whether ⌫ takes the last chip back rather than deleting a character: in an empty field, or
    /// with the caret (no selection) before the first character.
    static func takesBackChip(draft: String, selection: TextSelection?) -> Bool {
        if draft.isEmpty { return true }
        guard let selection, case .selection(let range) = selection.indices else { return false }
        return range.isEmpty && range.lowerBound == draft.startIndex
    }
}

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

    /// How the message goes while pi works: ↩ follows the Return setting, ⌘↩ always steers now.
    /// (While pi is idle either one sends it now.)
    func delivery(_ setting: ReturnWhileWorking) -> NativeThreadDelivery {
        self == .primary ? setting.choice.delivery : NativeSendChoice.now.delivery
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
