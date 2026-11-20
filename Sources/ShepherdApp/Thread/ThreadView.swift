import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
#if DEBUG
import Synchronization
#endif

extension EnvironmentValues {
    /// Keyboard commands for the thread on screen, when the app provides them.
    @Entry var threadCommands: ThreadCommandCenter? = nil
    /// How long a thread that draws something waits for pi before its composer says pi is
    /// starting; a blank one waits no longer than `AppLayout.blankStartingIndicatorDelay`
    /// (previews show it at once).
    @Entry var threadStartingDelay: Duration = AppLayout.startingIndicatorDelay
    /// How long the window must stay unseen before the thread on screen rests (`ThreadRest`); previews and tests set none.
    @Entry var threadRestDelay: Duration = AppLayout.threadRestDelay
    /// A design's chat: its comments' cards, which messages carrying a comment draw.
    @Entry var designCommentCards: DesignCommentCards? = nil
    @Entry var threadReaderPins: ThreadReaderPins? = nil
    /// Whether the person is typing or scrolling, which a restore of a thread's rows waits out (`ThreadRestore`).
    @Entry var userActivity: UserActivity? = nil
    /// The window is mid live resize: the thread lays out only the rows that cover it, and
    /// takes its whole eager tail back when the drag ends (`eagerCount`).
    @Entry var liveResizing: Bool = false
}

/// An agent's thread (SHThread board): an 820pt column of turns in a scroll view that follows
/// the tail, with the composer floating over its bottom edge. The store derives every row once
/// per change; this view only lays them out.
struct ThreadView: View {
    let store: NativeThreadStore
    let active: Bool
    let isFocused: Bool
    let request: NativeThreadStore.Request
    /// The thread as pi's session file holds it, shown while pi starts (local agents).
    var preview: NativeThreadStore.Preview? = nil
    /// This thread's key in the command center (see `ThreadCommandCenter`).
    var commandKey: String? = nil
    /// The empty thread's title and the composer placeholder name the agent and its folder.
    var agentName: String? = nil
    var workingDirectory: String? = nil
    /// Opens a subagent in the inspector.
    var inspectSubagent: ((ChildRun) -> Void)? = nil
    /// Opens a subagent in the inspector with its Steer field focused (the tray's Steer).
    var steerSubagent: ((ChildRun) -> Void)? = nil
    /// The run open in the inspector; its tray row wears the selection.
    var inspectedRunID: String? = nil
    /// Opens the review pane at a file (a changed file, the changes card, an edit call).
    var review: ((String) -> Void)? = nil
    /// The changes cards' Review, Undo and Redo, where the host records turns.
    var turnActions: TurnChangesActions? = nil
    /// The models the host offers, for the composer's model picker.
    var listModels: (() async -> ModelCatalog)? = nil
    /// Retry in the composer's Can't start banner (true: start a new conversation); nil for a
    /// remote agent, whose pi only its host starts.
    var restartPi: ((Bool) -> Void)? = nil
    /// Waiting for the first launch's copy, or not signed in (local agents): the line or card at
    /// the thread's end, and what its buttons do.
    var authNotice: ThreadAuthNotice? = nil
    var authActions: ThreadAuthActions? = nil
    /// `/login` and `/logout` in the composer (this Mac's agents).
    var slashLogin: SlashLoginActions? = nil
    /// The composer's "Up next" state, when a test or preview drives it.
    var queueState: QueueStackState? = nil
    /// Previews: the composer opens with the context ring's details showing.
    var contextDetailsOpen = false
    var modelSettingsOpen = false
    /// A design's chat: its composer says the design's placeholder.
    var designChat = false
    /// A Project's conversation sets this around the thread (an environment value, so this long initializer is unchanged).
    @Environment(\.projectComposerSend) private var projectSend
    @Environment(\.projectActionCards) private var projectActionCards
    @Environment(\.projectWorkerThread) private var workerStyle
    /// A design's Git merge, in its chat (GitDesignMerge): the card after the last turn, and the
    /// intro in an empty chat of a design opened from Git.
    @Environment(\.designGitChat) private var designGitChat
    /// A Project conversation or one of its worker threads: the boards space the column at 16pt, not an ordinary thread's 28 and 14.
    private var leadColumn: Bool { projectSend != nil || workerStyle != nil }
    /// No composer at all, not a disabled one: a resolved Project thread, or a held-off thread
    /// (offline and offering no send).
    private var composerHidden: Bool {
        workerStyle?.composerHidden == true || (projectSend == nil && store.offline && !store.supports("send"))
    }
    private var userOrigins: ProjectUserOrigins {
        ProjectUserOrigins(assignment: workerStyle?.assignmentOperations ?? [], runtime: projectSend?.runtimeOperations ?? [])
    }
    /// Only this Mac's agents may receive paths from this Mac.
    var allowsLocalFiles = false
    /// A remote thread's folder on its host, for the composer's hook glyph only.
    var hookDirectory: String? = nil
    var retainedInput: ThreadInput? = nil
    /// What watches the thread for a stranded scroll position; a test holds its own to read.
    var retainedTailGuard: ThreadTailGuard? = nil
    /// Whether the scroll view keeps the tail itself (`ThreadTailAnchor.isNative`); a test drives either.
    var nativeTail = ThreadTailAnchor.isNative
    @Environment(\.presentImages) private var presentImages
    @Environment(\.threadReaderPins) private var readerPins
    @Environment(\.userActivity) private var userActivity
    /// This view's claim on the store's poll loop: one agent's store can be shown by two views at once.
    @State private var storeOwner = UUID()
    @State private var fallbackInput = ThreadInput()
    private var input: ThreadInput { retainedInput ?? fallbackInput }
    @State private var fallbackTailGuard = ThreadTailGuard()
    @State private var transcriptRevision = 0
    private var tailGuard: ThreadTailGuard { retainedTailGuard ?? fallbackTailGuard }
    @State private var follower = NativeScrollFollower()
    @State private var historyPaging = NativeHistoryPaging()
    @State private var historyAnchor = ThreadHistoryAnchor()
    /// What the context details ask the thread to find (Largest, Show summary). A stable object,
    /// not a closure, so the composer is not redrawn with every render of the thread.
    @State private var finder = ThreadFinder()
    @State private var hovering = false
    @State private var wheelMonitor: Any?
    /// Composer height and responsive gutters are observed by their consumers, not the
    /// transcript builder. Resizing or a growing composer must not rebuild every row.
    @State private var composerInset = ComposerInset()
    /// Points of estimated row height the eager tail covers (`AppLayout.eagerCoverHeight`):
    /// bucketed, so a height drag rebuilds the transcript a few times, not at every point.
    @State private var eagerCover = AppLayout.eagerCoverHeight(forViewport: AppLayout.windowDefaultHeight)
    /// The eager tail's size while it grows back after a live resize (`returnEagerTail`):
    /// rebuilding a heavy thread's rows in one update would stall the release of the drag.
    @State private var eagerReturning: Int?
    /// Whether the last pass drew with a live resize running, kept across renders in a
    /// reference: the first pass after a drag must keep the small tail, before `onChange`
    /// has had its say and `eagerReturning` is set.
    @State private var liveResizeGate = LiveResizeGate()
    /// The user turn the last ⌥⌘↑/↓ landed on.
    @State private var jumpedTurn: String?
    @State private var arrivals = ThreadArrivals()
    @State private var rowIndex = ThreadRowIndex()
    @State private var restore = ThreadRestore()
    @State private var eagerTail = ThreadEagerTail()
    @State private var historyBuilt = ThreadHistoryBuilt()
    @State private var shownSignpost = ThreadShownSignpost()
    /// Bumped when another view showing this thread hands the store's loop back to this one (`ThreadReaderPins`).
    @State private var loopRun = 0
    @Environment(\.liveResizing) private var liveResizing
    @Environment(\.designCommentCards) private var commentCards
    @Environment(\.shUserBubbleMetrics) private var bubbleMetrics
    /// Dispatches: what this thread sent and where it came from (FleetDispatch, FleetRemote).
    @Environment(\.fleetThread) private var fleetThread

    var body: some View {
        let _ = SHRenderProbe.tick("thread.view")
        // A turn made only of the owner's wake-ups has no row. A mixed turn keeps its row (and identity); `turn` draws it per message.
        let origins = userOrigins
        // The list, not `rows`: the streaming reply is a shell here, and its content (`liveRow`) is
        // read by its own row view, so a streamed chunk redraws that row and not this body.
        let rows = listedRows(origins)
        // A hidden thread whose rows were let go to keep what the hidden views hold within a budget (`NativeThreadStores`) draws
        // only the last ones it still has, in steps down to its last screen; only the two lists of rows below read this. The thread
        // on screen never reads it, so it is never redrawn by it.
        let kept = active ? nil : store.transcriptDrawn
        let dormant = kept != nil
        // Shown again, such a thread draws the rows it kept at once (they never went), and the rest after that frame, a step at a time
        // from the newest (`ThreadRestore`): the eager tail grows over the lazy stack's rows, which the second frame brings back.
        let eagerCount = eagerCount(origins, rows: rows)
        let restored = restore.plan(active: active, hiddenKept: kept, rows: rows, eagerRows: eagerCount, following: follower.sticky,
                                    tailParsed: !store.tailAwaitsParse(lastRows: eagerCount), keepsOnlyTail: store.keepsOnlyTail) { [store] drawn in
            store.restoreCost(drawn: drawn, upTo: eagerCount)
        }
        let restoreStepping = restore.restoring
        let drawn = rows.suffix(kept ?? restored.map { $0.history ? rows.count : $0.eager } ?? rows.count)
        let eager = drawn.suffix(restored?.eager ?? eagerCount)
        let history = drawn.prefix(drawn.count - eager.count)
        // A Project's accepted messages the transcript has not taken in: waiting ones go to the composer's Up next, outcomes stay here.
        let held = projectSend?.held() ?? []
        // A row's background needs only the boundary ID, not a captured copy of the transcript.
        let historyRowID = historyAnchor.rowID ?? rows.first?.id
        let running = store.running
        // The IDs, rebuilt only when the store's row structure changes, never per streamed chunk.
        let _ = rowIndex.update(rows, revision: store.rowStructureRevision, filter: origins.runtime)
        // Set with the rows: a turn that finishes with unchanged IDs ends its waiting line.
        let liveRowID = store.liveRowID
        // Until the thread has caught up since it came on screen (opening it, or the first pull
        // after switching back to the agent), whatever changes lands at once.
        let catchingUp = arrivals.catchUp.catchingUp(caughtUpAt: store.catchUp?.thread, version: store.threadVersion)
        // The history's stack of built rows starts again once the thread has added enough of them behind a reader at the tail,
        // at rest, in the update that adds the next. Rows the tail gives to it while a live resize shrinks it, or the rule does, are not
        // the thread's. `restoreStepping` is true from the first frame of a thread whose tail is bound by cost until its first stack is
        // back (the wait for the replies to draw their blocks too), so none starts while that stack comes.
        let atRest = follower.sticky && !follower.userScrolling && !input.decelerating
        let historyStack = historyBuilt.stack(history: history, onScreen: active, mayLetGo: atRest && !restoreStepping && !catchingUp,
                                              tailMoves: !tailAtRest, tail: eager.count)
        let _ = historyBuilt.note(in: store)
        // Until it has caught up, the live reply's state is read here too: the pull that catches a thread up on
        // a tool boundary changes nothing else, and it must redraw this view so its gate draws that catch-up.
        // After it, the live row and the wait line read them and tool boundaries stay out of this body.
        let _ = store.catchUp == nil ? [store.liveRow != nil, store.showsThinking, store.liveWait == NativeLiveWait()] : []
        let drawnVersion = store.threadVersion
        let settled = active && !catchingUp
        let _ = shownSignpost.render(active: active, settled: settled)
        let arrived = arrivals.update(rowIndex.ids, session: store.sessionKey, active: active, catchingUp: catchingUp)
        ScrollViewReader { proxy in
            let _ = keepTail(proxy)
            ZStack(alignment: .bottom) {
                let spacing = leadColumn ? SHLeadMetrics.turnGap : AppLayout.turnSpacing
                ScrollView {
                    // Never animated as a whole (rows, their text, and the tail anchor change on
                    // every streamed chunk): turns that arrive make their own entrance.
                    // The tail is laid out for real (`eagerCount`); only the history above it is
                    // lazy, so no row at the end of the thread is a guess the scroll view can be
                    // left past (the blank thread). A giant reply (`NativeProse.isGiant`) keeps its
                    // tail real and the chunks before it lazy (`SHProseChunks`); any other is real.
                    VStack(alignment: .leading, spacing: spacing) {
                        // Counts the column's content (the rows' wrappers and its environment) being built again.
                        let _ = SHRenderProbe.tick("thread.column")
                        notices
                        if rows.isEmpty {
                            if let project = projectSend?.emptyState { project() }
                            else if designGitChat?.opened == true { SHGitDesignIntro() }
                            else { emptyState }
                        }
                        if let day = leadDayTitle(rows) { SHLeadDaySeparator(word: day) }
                        historyColumn(history, tail: eager, spacing: spacing, dormant: dormant,
                                      releasing: !active && (rows.isEmpty || restoreStepping), stack: historyStack, running: running,
                                      catchingUp: catchingUp, arrived: arrived, settled: settled, historyRowID: historyRowID,
                                      parked: parksHistory)
                        ForEach(eager) { row in
                            rowView(row, running: running, catchingUp: catchingUp, arrived: arrived, settled: settled, historyRowID: historyRowID)
                        }
                        // A Project's accepted messages the transcript has not taken in: held, in flight, or not delivered.
                        // Not delivered (unknown, failed): the person's words with what became of them. Never retried for them.
                        // Its note always shows, so it takes its own room below the bubble: an overlaid caption that wraps (a refusal's
                        // reason, a larger text size) would grow up into the words.
                        ForEach(held.filter { !$0.waiting }) { message in
                            UserTurn(bubbles: [.init(text: message.text, images: message.images.count, caption: nil, pending: true)], note: message.note)
                                .equatable()
                                .environment(\.shUserBubbleMetrics, { var metrics = bubbleMetrics; metrics.overlaysCaption = false; return metrics }())
                        }
                        // Sends captured but not yet accepted: sending, refused (restore or discard) or of unknown outcome.
                        if projectSend == nil { ThreadSubmissions(store: store, input: input) }
                        ThreadWaitLine(store: store, hasLiveRow: liveRowID != nil, active: active, parentCatchingUp: catchingUp, drawn: drawnVersion,
                                       project: projectActionCards != nil || workerStyle != nil)
                        // Where its last message goes, while the dispatch that started this thread is going (FleetRemote).
                        if let line = fleetThread?.sentBy?.goesBackLine, fleetThread?.goesBack == true {
                            FleetGoesBackBanner(line: line).equatable()
                        }
                        if let authNotice {
                            ThreadAuthNoticeView(notice: authNotice, actions: authActions)
                                .id(ThreadAuthNotice.rowID)
                        }
                        if let git = designGitChat, let phase = git.phase {
                            SHGitMergeCard(phase: phase, review: git.review, retry: git.retry)
                                .equatable()
                                .id(DesignGitChat.rowID)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .scrollTargetLayout()
                    .overlay(alignment: .top) {
                        // With no history the lazy stack is empty and still takes the column's spacing: the first row starts that far below the
                        // column's top, and the sentinel reaches it, or turning to that row leaves it above the scroll view's margin.
                        Color.clear.frame(height: AppLayout.turnSpacing + (history.isEmpty ? spacing : 0))
                            .onScrollVisibilityChange { visible in
                                historyPaging.visible = visible
                                loadVisibleHistory()
                            }
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: projectSend?.columnWidth ?? AppLayout.threadMaxWidth)
                    .modifier(ThreadGutterPadding(inset: composerInset, fixedGutter: workerStyle?.gutter))
                    .frame(maxWidth: .infinity)
                    .background { ThreadInputBackground(input: input) }
                    .background { ThreadScrollViewFinder(guardian: tailGuard) }
                    .environment(\.compactionExpansion, store.compactions)
                    .environment(\.turnErrorExpansion, store.errors)
                    // A local agent's images and file links resolve in its folder; a remote agent's files are not here.
                    .environment(\.shProseFileRoot, workingDirectory.map {
                        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
                    })
                    .environment(\.shProseFileLinks, .app)
                    .environment(\.shOpenIn, .app)
                }
                .id(transcriptRevision)
                // A dispatched thread whose Mac stopped answering: its words fade under the banner, the composer and header don't (FleetRemote).
                .opacity(fleetThread?.offline == true || fleetThread?.move?.phase == .moving ? AppLayout.fleetOfflineOpacity : 1)
                // A move of this thread, going or waiting or failed, sits above the conversation (FleetMove).
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let move = fleetThread?.move, let actions = fleetThread?.actions {
                        FleetMoveCardView(card: move, cancel: { actions.cancelMove($0) }, dismiss: { actions.dismissMove($0) }).equatable()
                    }
                }
                .scrollPosition($historyAnchor.position)
                // The composer floats over the scroll view; inset by its real height so "the
                // bottom" is the last turn, not the space under the card.
                .modifier(ComposerInsetPadding(inset: composerInset, gap: leadColumn ? 0 : AppLayout.composerTranscriptGap,
                                               present: !composerHidden))
                // A margin rather than padding so scrollTo(.top) keeps the 28pt above a turn.
                .contentMargins(.top, workerStyle != nil ? SHLeadMetrics.paneThreadTop : leadColumn ? SHLeadMetrics.columnTopPadding : AppLayout.threadTop, for: .scrollContent)
                // Target IDs are only candidates: `ThreadTailGuard` also checks native row placement
                // before accepting cached visibility as proof that the transcript contains content.
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0) { tailGuard.targets($0) }
                .onChange(of: rows.first?.id) { _, first in
                    historyAnchor.prepended(firstID: first, session: store.sessionKey, active: active) { [weak historyAnchor] id in
                        historyAnchor?.position.scrollTo(id: id, anchor: .top)
                    }
                }
                .onChange(of: dormant) { _, dormant in
                    // Its rows gone, a reader left scrolled up would come back at the top of a shrunken scroll view, with nothing
                    // to anchor it to the bottom: it comes back at its tail, and no longer keeps its history pinned.
                    guard dormant, !follower.sticky else { return }
                    historyAnchor.cancel()
                    follower.jumpToLatest()
                    readerPins?.unpin(store, owner: storeOwner)
                }
                .onChange(of: historyEnabled) { _, _ in loadVisibleHistory() }
                .onChange(of: running) { _, running in
                    if !running { tailGuard.turnFinished() }
                }
                .onChange(of: store.sessionKey) { _, _ in
                    historyAnchor.cancel()
                    loadVisibleHistory()
                }
                .modifier(ThreadTailAnchor(sticky: follower.sticky, native: nativeTail, restoring: restored != nil))
                .onScrollGeometryChange(for: NativeScrollProbe.self, of: Self.probe) { old, new in
                    // Intent is a wheel tick (350 ms window) or a live drag phase.
                    let gesture = input.hasWheelIntent(movingUp: new.distance > old.distance) || follower.userScrolling
                    // Where nothing anchors the scroll view, every reading is the layout's own:
                    // growth, a shrinking history, the composer resizing and a send's collapsing
                    // tray all land back on the tail as they arrive.
                    // The guard walks the scroll view itself while it repairs one, and is not fought.
                    if follower.observe(from: old, to: new, gesture: gesture, nativeAnchor: nativeTail), !tailGuard.repairing {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                    tailGuard.distance = new.distance
                    tailGuard.suspect()
                    // Every reading that can move the boundary row lands here, so the row itself is not measured per frame.
                    if historyAnchor.isEngaged { historyAnchor.moved() }
                }
                .onScrollPhaseChange { old, phase, context in
                    // Only a live finger/wheel counts. Momentum and programmatic phases are not
                    // intent; a gesture that ends near the bottom re-sticks from where it lands.
                    historyAnchor.animating = phase == .animating
                    follower.userScrolling = phase == .interacting
                    input.decelerating = phase == .decelerating
                    if phase == .interacting {
                        historyAnchor.cancel()
                        historyPaging.beginScroll()
                        tailGuard.readerMoved()
                    }
                    if phase == .idle, old == .interacting || old == .decelerating {
                        follower.observe(distanceFromBottom: Self.distanceFromBottom(context.geometry), userIntent: true)
                    }
                    if phase == .idle { loadVisibleHistory() }
                }
                .onChange(of: store.sentCount) { _, _ in
                    // A send that goes in now re-attaches to the tail: the echoed turn is the last
                    // thing in the thread, and the reply streams in under it. A follow-up that
                    // waits in Up next leaves the reader where they are, now and when it goes.
                    let queued = store.lastSendQueued
                    let wasFollowing = follower.sticky
                    follower.sent(queued: queued)
                    if !queued {
                        historyAnchor.cancel()
                        jumpedTurn = nil
                        // Already following, the thread's anchoring (`ThreadTailAnchor`) or the
                        // follower lands the echo and the collapsing tray together as their layout
                        // arrives, instead of two competing jumps.
                        if !wasFollowing {
                            proxy.scrollTo(Self.bottomID, anchor: .bottom)
                        }
                        tailGuard.asked()
                    }
                }
                // New output at the tail is what "unseen" means, never the content height.
                // The version, not the last row's value: comparing a live turn's messages per chunk is a deep string compare.
                .onChange(of: store.threadVersion) { _, _ in
                    follower.contentArrived()
                    tailGuard.suspect()
                }
                .modifier(ThreadCommandHandler(key: commandKey, active: active) { command in
                    handle(command, proxy: proxy)
                })
                .onChange(of: finder.request) { _, request in
                    guard let request else { return }
                    Task { await find(request.entryID, proxy: proxy) }
                }
                // The composer draws "Jump to latest" over the fade it lays on the thread and under
                // its card and menus, so the pill reads clearly and never covers an open menu.
                // A resolved Project thread takes no message: no composer at all, not a disabled one.
                if !composerHidden {
                    Composer(store: store, input: input, allowsLocalFiles: allowsLocalFiles, active: active, isFocused: isFocused, agentName: agentName, hasTurns: !rows.isEmpty,
                             gutter: AppLayout.gutter, measuredInset: composerInset, listModels: listModels,
                             hookDirectory: allowsLocalFiles ? workingDirectory : hookDirectory,
                             modelSettingsOpen: modelSettingsOpen, commandKey: commandKey,
                             jumpToLatest: follower.showsJump(running: running) ? {
                                 historyAnchor.cancel()
                                 follower.jumpToLatest()
                                 proxy.scrollTo(Self.bottomID, anchor: .bottom)
                                 tailGuard.asked()
                             } : nil, finder: finder, queueState: queueState, contextDetailsOpen: contextDetailsOpen,
                             inspectSubagent: inspectSubagent, steerSubagent: steerSubagent, inspectedRunID: inspectedRunID,
                             designChat: designChat, restartPi: restartPi,
                             hidesNotSignedIn: { if case .notSignedIn? = authNotice { true } else { false } }(),
                             slashLogin: slashLogin, projectUpNext: projectSend.map { _ in ProjectHeldMessages.upNext(held) })
                        .equatable()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [composerInset] in
                            if composerInset.height != $0 { composerInset.height = $0 }
                        }
                }
            }
        }
        // The composer's menus float over the thread and fit the room above the card in it.
        .coordinateSpace(.named(Composer.threadSpace))
        .modifier(ThreadInputDrop(input: input, store: store, localFiles: allowsLocalFiles, imagesSupported: projectSend?.carriesImages))
        // Switching back to an agent is a visibility flip: the pull that catches its thread up
        // runs none of the thread's view-attached motion (the composer gates its own).
        // Keyed on what the render drew, so only the update carrying it is touched: a hover or a
        // disclosure inside the thread later still moves.
        .transaction(value: CatchUpGate.Key(version: store.threadVersion, active: active)) {
            if catchingUp { $0.disablesAnimations = true }
        }
        // The tray's controls: it changes only when the thread is switched to or away from (and
        // when the host's support does), and redraws the tray's rows.
        .environment(\.threadActionsEnabled, active && store.supports("subagents"))
        // The images the host names, fetched on demand; pressing one opens the viewer (set once per window).
        .environment(\.threadImages, store.supportedActions.contains("images") ? store.images : nil)
        .transformEnvironment(\.viewImages) { opener in
            let present = presentImages
            let images = store.supportedActions.contains("images") ? store.images : nil
            let add: ((ViewerImage) -> Void)? = { [input] image in
                input.add(images: [image], store: store)
            }
            opener = ThreadImageOpener(store: store, hasImages: images != nil) { set, index in
                present(ImageViewerState(set: set, index: index, images: images, addToMessage: add))
            }
        }
        .foregroundStyle(Color.sh.textPrimary)
        .tint(Color.sh.running)
        .background { ThreadInputBackground(input: input) }
        .background(Color.sh.bgWindow)
        .onGeometryChange(for: CGFloat.self) { AppLayout.threadGutter(width: $0.size.width) } action: { [composerInset] in composerInset.gutter = $0 }
        .onGeometryChange(for: Int.self) { AppLayout.eagerCoverHeight(forViewport: $0.size.height) } action: { [gate = liveResizeGate] cover in
            gate.cover = cover
            // A drag only widens what the tail covers: a window that shrinks and grows back over the same ground builds no row on the way.
            eagerCover = gate.wasLive ? max(eagerCover, cover) : cover
        }
        .onHover { hovering = $0 }
        .onDisappear {
            historyAnchor.cancel()
            tailGuard.stop()
            store.stop(owner: storeOwner)
            // Another view still showing the thread runs it again if this one's loop was running.
            readerPins?.stopped(store, owner: storeOwner)
            readerPins?.unpin(store, owner: storeOwner)
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
        }
        // Hidden, the thread stops polling and keeps what it shows; shown again, it polls from
        // there (`NativeThreadStore.suspend`). In a window nobody can see it keeps its loop and pulls
        // nothing (`ThreadRest`).
        .modifier(ThreadRest(store: store, owner: storeOwner, active: active, run: loopRun))
        // The row steps wait for the reader to be at the tail: the rows that join the eager tail change height above them, which only a
        // view held to the tail takes without moving. They start again when the reader returns (the key reads `sticky` only while a
        // restore is under way). The lazy stack does not wait for that: until it is back they cannot reach the older rows.
        .task(id: restoreStepping && active && (follower.sticky || restore.awaitsHistory)) {
            if restoreStepping && active && (follower.sticky || restore.awaitsHistory) { await restoreRows() }
        }
        // The drag over, the eager tail grows back a step at a time (`returnEagerTail`).
        .onChange(of: liveResizing) { _, resizing in
            guard !resizing else { return }
            liveResizeGate.wasLive = false
            // The window's own height again, whatever the drag widened it to.
            if eagerCover != liveResizeGate.cover, liveResizeGate.cover > 0 { eagerCover = liveResizeGate.cover }
            guard active else { return }
            let live = liveEagerCount(userOrigins)
            if live < restingCount(userOrigins, rows: listedRows(userOrigins)) { eagerReturning = live }
        }
        .task(id: eagerReturning != nil) {
            if eagerReturning != nil { await returnEagerTail() }
        }
        .task(id: LoopKey(active: active, run: loopRun)) {
            guard !Task.isCancelled else { return }
            guard active else {
                if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
                wheelMonitor = nil
                hovering = false
                historyAnchor.cancel()
                historyAnchor.animating = false
                // A flick's momentum ends with no word once the view is hidden: the next showing's restore does not wait for it.
                input.decelerating = false
                tailGuard.stop()
                store.suspend(owner: storeOwner)
                readerPins?.stopped(store, owner: storeOwner)
                // Hidden: left scrolled up into the history, it stays loaded while this view keeps the place;
                // following the tail, it lets it go (it reloads to the tail when shown).
                if follower.sticky { readerPins?.unpin(store, owner: storeOwner) } else { readerPins?.pin(store, owner: storeOwner) }
                // A little after the switch, never while a key is being pressed and not while it is one of the threads left last (the ones
                // a person goes back to, whose stack comes back with a flip), so that taking its stack down is not a turn of the one that
                // shows another thread (`ThreadRestore.plan`).
                try? await Task.sleep(for: AppLayout.hiddenStackDelay)
                while !Task.isCancelled {
                    if userActivity?.inputRecent == true {
                        try? await Task.sleep(for: AppLayout.restoreRetry)
                    } else if readerPins?.leftRecently(store, within: AppLayout.keptStacks) == true {
                        try? await Task.sleep(for: AppLayout.hiddenStackRecheck)
                    } else {
                        break
                    }
                }
                // Only a thread with a stack beyond a tail bounded by cost has one to let go; the others draw nothing again.
                if !Task.isCancelled, let tail = store.drawnEagerRows, tail < Self.eagerRows, listedRows(userOrigins).count > tail { restore.withdrawStack() }
                return
            }
            // On screen: this view needs the history whichever view's loop polls the store.
            readerPins?.pin(store, owner: storeOwner)
            installWheelMonitor()
            readerPins?.started(store, owner: storeOwner) { [$loopRun] in $loopRun.wrappedValue &+= 1 }
            await store.run(request: request, preview: preview, owner: storeOwner)
            // Returned while this view still shows the thread: stopped, detached or taken over, never handed back.
            if !Task.isCancelled { readerPins?.loopEnded(store, owner: storeOwner) }
        }
    }

    /// The rows the thread draws: its list, less a Project's user turns made only of the runtime's wake-ups.
    private func listedRows(_ origins: ProjectUserOrigins) -> [NativeThreadRow] {
        origins.runtime.isEmpty ? store.listRows : store.listRows.filter { !($0.isUser && origins.hides($0.turn)) }
    }

    /// How many rows at the end of the thread are laid out for real. At rest, the last rows its cost allows (`restingCount`). While the
    /// window is being live-resized, only enough of them, by the store's low height estimate, to cover
    /// the window (`eagerCover`): every other row stays in the lazy stack, out of each resize
    /// step's layout pass, and the full tail is laid out again when the drag ends. The tail at rest
    /// is what keeps the scroll view's bottom anchor honest when rows land, so a thread
    /// at rest always has it.
    private func eagerCount(_ origins: ProjectUserOrigins, rows: [NativeThreadRow]) -> Int {
        // A hidden thread's frame is frozen through the drag, so its tail ignores the window; its rows still move it (`ThreadEagerTail.held`).
        guard active else { liveResizeGate.wasLive = liveResizing; return restingCount(origins, rows: rows, hidden: true) }
        if liveResizing { liveResizeGate.wasLive = true; return liveEagerCount(origins) }
        if liveResizeGate.wasLive, eagerReturning == nil { return liveEagerCount(origins) }
        return eagerReturning ?? restingCount(origins, rows: rows)
    }

    /// The tail a thread at rest lays out: where it starts moves toward the rule (`ruleCount`) by a few rows each time the thread's
    /// rows change (`ThreadEagerTail`), on screen or not (the rows of a hidden thread change too), and the store is told what was
    /// drawn, which the budget counts (`NativeThreadStore.drawnEagerRows`). Written from `body`, as `ThreadRowIndex` is read there: the
    /// store does not observe it and the same count is written once, so it redraws nothing.
    private func restingCount(_ origins: ProjectUserOrigins, rows: [NativeThreadRow], hidden: Bool = false) -> Int {
        let settling = store.tailAwaitsParse(lastRows: Self.eagerRows)
        let count = hidden
            ? eagerTail.held(rows: rows, revision: store.rowStructureRevision, costs: store.rowCostRevision, cover: eagerCover, maxRows: Self.eagerRows,
                             crossing: AppLayout.eagerTailCrossing, detached: !follower.sticky, settling: settling) { ruleCount(origins) }
            : eagerTail.update(rows: rows, revision: store.rowStructureRevision, costs: store.rowCostRevision, cover: eagerCover, maxRows: Self.eagerRows,
                               crossing: AppLayout.eagerTailCrossing, detached: !follower.sticky, settling: settling) { ruleCount(origins) }
        let drawn = count > 0 ? count : nil
        if store.drawnEagerRows != drawn { store.drawnEagerRows = drawn }
        return count
    }

    /// How many rows the thread's cost allows at its end (`NativeThreadStore.eagerTailRows`), whatever it drew so far.
    private func ruleCount(_ origins: ProjectUserOrigins) -> Int {
        store.eagerTailRows(maxRows: Self.eagerRows, costCap: NativeMountedCost.eagerTailCap,
                            coveringHeight: AppLayout.eagerTailHeight(cover: eagerCover)) { $0.isUser && origins.hides($0.turn) }
    }

    /// Whether the tail drawn is the one a thread at rest has (`restingCount`), and not the one that covers the window while it is
    /// live-resized or the one growing back after it (`eagerCount`, which keeps the gate it reads).
    private var tailAtRest: Bool { !liveResizing && !liveResizeGate.wasLive && eagerReturning == nil }

    /// Whether the history above the tail stands down while the window is dragged, and while the tail grows back after it: the reader at
    /// the tail sees none of it (the tail covers the window, `eagerCount`), a lazy stack is measured again at every width a drag passes
    /// through, and now and then it lays out the whole history from its top, tens of milliseconds a time. There is no stack for it, and the
    /// scroll view keeps the tail (`ThreadTailAnchor`) as its content gets shorter and taller above it. A stack that comes back with the
    /// tail full-sized builds nothing, for the tail is out of its reach; one that came back under the small tail built a screen of rows.
    /// A reader who has scrolled up reads the history, so for them it stays.
    private var parksHistory: Bool { active && follower.sticky && (liveResizing || !tailAtRest) }

    /// The tail that covers the window while it is being live-resized (`eagerCount`).
    private func liveEagerCount(_ origins: ProjectUserOrigins) -> Int {
        store.eagerRowCount(coveringHeight: eagerCover, maxRows: Self.eagerRows) { $0.isUser && origins.hides($0.turn) }
    }

    /// Grows the eager tail back to full size after a live resize, a restore-sized step of
    /// rows at a time (`NativeThreadStore.restoreStep`), so no one update rebuilds them all.
    private func returnEagerTail() async {
        while let current = eagerReturning, !Task.isCancelled {
            guard active, !liveResizing else { eagerReturning = nil; return }
            let more = store.restoreStep(drawn: current, bytes: AppLayout.restoreStepBytes)
            if more == 0 || current + more >= restingCount(userOrigins, rows: listedRows(userOrigins)) { eagerReturning = nil; return }
            eagerReturning = current + more
            try? await Task.sleep(for: AppLayout.restorePause)
        }
    }

    /// The lazy stack of the rows older than the eager tail, drawn again only when what its rows are built from changes
    /// (`ThreadHistoryCache`).
    @ViewBuilder
    private func historyColumn(_ history: ArraySlice<NativeThreadRow>, tail: ArraySlice<NativeThreadRow>, spacing: CGFloat, dormant: Bool,
                               releasing: Bool, stack: Int, running: Bool, catchingUp: Bool, arrived: Set<String>, settled: Bool,
                               historyRowID: String?, parked: Bool) -> some View {
        // Parked, there is no stack at all (`parksHistory`): its rows go with it, and come back with it.
        if !parked {
            let key = historyKey(history, tail: tail, arrived: arrived, dormant: dormant, stack: stack, boundary: historyRowID, running: running,
                                 detached: !follower.sticky)
            ThreadHistoryColumn(key: key) {
                AnyView(LazyVStack(alignment: .leading, spacing: spacing) {
                    ForEach(history) { row in
                        rowView(row, running: running, catchingUp: catchingUp, arrived: arrived, settled: settled, historyRowID: historyRowID)
                    }
                }
                .scrollTargetLayout()
                // The stack of a hidden host keeps the rows it has realized when its list empties (it drops them in a layout
                // that host does not run). Its identity changes whenever the rows are let go (a pass, a released history, a hidden
                // thread that draws its tail alone: `releasing`), and takes them with it. A thread with no history to let go (one of a few
                // rows) and the one on screen keep their own. It changes too when the thread on screen has added enough rows for the stack
                // to have built more than a reader at the tail has any use for (`ThreadHistoryBuilt`), which it does only on screen and once
                // its restore is done: the two never change it in the same update.
                .id(StackID(dormant: dormant || (releasing && history.isEmpty), built: stack)))
            }
        }
    }

    /// What the history's rows are built from. None while there is no history, and for a thread whose rows also read what cannot be
    /// compared (a Project's references, a design's comments): the stack is drawn every time.
    private func historyKey(_ history: ArraySlice<NativeThreadRow>, tail: ArraySlice<NativeThreadRow>, arrived: Set<String>, dormant: Bool,
                            stack: Int, boundary: String?, running: Bool, detached: Bool) -> ThreadHistoryCache.Key? {
        guard !history.isEmpty, !leadColumn, projectActionCards == nil, commentCards == nil else { return nil }
        // The key leaves out what only the live reply reads, which is always among the tail's rows (`ThreadHistoryCache`).
        assert(Self.eagerRows >= 1)
        return ThreadHistoryCache.Key(rows: history, dormant: dormant, stack: stack, boundary: boundary, running: running, detached: detached,
                                      arrived: ThreadHistoryCache.Key.arrivals(in: history, tail: tail, among: arrived),
                                      inspected: inspectedRunID, fleet: fleetThread,
                                      actions: [review != nil, turnActions != nil, inspectSubagent != nil, steerSubagent != nil],
                                      store: ObjectIdentifier(store), tailGuard: ObjectIdentifier(tailGuard))
    }

    /// Brings back what a restore still owes (`ThreadRestore`), a step at a time, each after the frame of the one before it. The lazy
    /// stack comes first, as soon as the frame that drew the last screen is out and the scroll view is at rest (no hand on it, no flick's
    /// momentum), whatever the person types and wherever the reader is: it builds nothing at the tail, and until it is back the thread
    /// seems to end where its last screen does. The rows then wait while the scroll view is not at rest, and for keystrokes: a step takes
    /// tens of milliseconds, which a key pressed in it feels. It looks again every `restoreRetry` while either lasts, and a key or a scroll
    /// lasts `AppLayout.inputRecentWindow` past its event. They run only while the reader is at the tail (the task's key): the rows that join
    /// the eager tail change height above them, which only a view held to the tail (`ThreadTailAnchor`) takes without moving.
    private func restoreRows() async {
        func scrolling() -> Bool { follower.userScrolling || input.decelerating }
        func waiting() -> Bool { scrolling() || !follower.sticky || userActivity?.inputRecent == true }
        if restore.awaitsHistory {
            try? await Task.sleep(for: AppLayout.restorePause)
            // Replies still to be parsed (a large one is parsed off the main thread) draw as nothing, and a tail a few points tall leaves the
            // stack in the window, where it builds rows that grow to their full size out of view and out of the budget. The update that
            // brings their blocks builds them, and the stack comes in the one after it. A parse that does not land holds it back only so long.
            // So does the pull that catches the thread up, for a thread whose first frame came before it because it kept only its tail
            // (`ThreadRestore.awaitsPull`): what it brings changes the tail and adds rows above it, and a stack built before it is built
            // against a tail that is still to move. And the scroll view of such a thread, until it has stopped reporting and rests on its
            // end (`ThreadTailGuard.rests`): the pull may land with the tail's rows still being measured, and a stack that joins in the
            // middle of that is laid out where the viewport was, and builds the heavy rows it finds there. Each waits no longer than the
            // replies do.
            var parseRetries = 0, pullRetries = 0, restRetries = 0
            func pullPending() -> Bool { restore.awaitsPull && store.catchUp == nil && pullRetries < AppLayout.restoreParseRetries }
            func tailMoving() -> Bool {
                restore.awaitsPull && restRetries < AppLayout.restoreParseRetries && !tailGuard.rests(quietFor: AppLayout.restoreQuiet)
            }
            while scrolling() || restore.waitsForParse(retries: parseRetries) || pullPending() || tailMoving(), !Task.isCancelled {
                if !restore.tailDrawnParsed { parseRetries += 1 }
                if pullPending() { pullRetries += 1 }
                if tailMoving() { restRetries += 1 }
                try? await Task.sleep(for: AppLayout.restoreRetry)
            }
            guard !Task.isCancelled else { return }
            // The stack's height comes in above whatever the reader is looking at, and a scroll view held to nothing keeps its offset
            // from the top: a reader who scrolled away in the moments before it comes goes back to the tail, held there as it grows.
            if !follower.sticky {
                follower.jumpToLatest()
                tailGuard.land()
            }
            let rows = listedRows(userOrigins)
            _ = restore.advance(rows: rows, eagerRows: eagerCount(userOrigins, rows: rows)) { _ in 0 }
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: waiting() ? AppLayout.restoreRetry : AppLayout.restorePause)
            guard !Task.isCancelled else { return }
            if waiting() { continue }
            let rows = listedRows(userOrigins)
            let more = restore.advance(rows: rows, eagerRows: eagerCount(userOrigins, rows: rows)) { [store] drawn in
                store.restoreStep(drawn: drawn, bytes: AppLayout.restoreStepBytes)
            }
            if !more { return }
        }
    }

    /// A sent message rises into the thread; a reply's parts make their own entrances.
    /// A design comment's message draws its card, and the reply to it sits inside the card
    /// (DZCanvas); a comment whose card isn't known draws as the viewer's words.
    @ViewBuilder private func turn(_ row: NativeThreadRow, running: Bool, thinking: Bool, wait: NativeLiveWait, arriving: Bool,
                                   settled: Bool) -> some View {
        let card = row.designComment.flatMap { commentCards?.cards[$0] }
        if row.isUser {
            let segments = userOrigins.segments(row.turn)
            if let card {
                SHCommentCard(number: card.number, target: card.target, meta: card.meta, text: card.text,
                              continues: row.commentAnswered)
                    .equatable()
                    .shArrival(arriving, .list, edge: .bottom)
            } else if let fleet = fleetThread, let message = fleetMessage(row, fleet) {
                message
                    .shArrival(arriving, .list, edge: .bottom)
            } else if segments.count == 1, case .person(let person) = segments[0] {
                UserTurn(turn: person)
                    .equatable()
                    .shArrival(arriving, .list, edge: .bottom)
            } else {
                ProjectUserSegments(segments: segments)
                    .equatable()
                    .shArrival(arriving, .list, edge: .bottom)
            }
        } else if let presentation = row.presentation {
            AgentTurn(presentation: presentation, live: row.live, subagents: TurnSubagents(store.placements[row.id]),
                      subagentActions: subagentActions, startedAt: row.startedAt,
                      retry: retryAction(row, running: running), review: review, recordedTurn: row.recordedTurn,
                      turnActions: turnActions, thinking: thinking, wait: wait, arriving: arriving,
                      settled: settled, footer: card == nil, cards: projectCardState(row))
                .equatable()
                .modifier(CommentAnswer(inCard: card != nil))
        }
    }

    /// A user turn a dispatch wrote: the result a dispatched thread sent back, or the task a dispatched thread started with. Nil for any other.
    private func fleetMessage(_ row: NativeThreadRow, _ fleet: FleetThreadSurface) -> FleetMessageRow? {
        let bubbles = row.turn.bubbles
        guard bubbles.count == 1, let bubble = bubbles.first else { return nil }
        let time = bubble.sentAt.map { nativeClockText($0, meridiem: false) }
        if let result = FleetResultMessage.parse(bubble.text) {
            return FleetMessageRow(kind: .result(result, fleet.card(for: result)), time: time, actions: fleet.actions)
        }
        // The first message of a thread another thread sent: the From box, over the words that were sent.
        if let sentBy = fleet.sentBy, FleetSentBy.isDispatchMessage(bubble.text) {
            return FleetMessageRow(kind: .from(sentBy, FleetSentBy.task(in: bubble.text)),
                                   time: sentBy.at > 0 ? nativeClockText(sentBy.at, meridiem: false) : time, actions: fleet.actions)
        }
        return nil
    }

    /// What this turn's typed Project references resolve to now (empty in an ordinary thread), so its card redraws when they change.
    private func projectCardState(_ row: NativeThreadRow) -> [ProjectActionResolver.Card?] {
        guard let cards = projectActionCards else { return [] }
        return row.turn.messages.compactMap(\.projectAction).map(cards.resolved)
    }

    /// A Project thread opens under the day of its first message.
    private func leadDayTitle(_ rows: [NativeThreadRow]) -> String? {
        guard projectSend != nil || workerStyle != nil, let at = rows.first?.turn.messages.first?.timestamp ?? rows.first?.startedAt else { return nil }
        return FleetFinishedDay.dayTitle(Date(timeIntervalSince1970: at / 1000), now: Date())
    }

    /// How many rows at the end of the thread are laid out for real rather than lazily at
    /// rest, at most: more than any window shows, few enough that a streamed chunk's relayout stays
    /// cheap. A thread of heavy rows lays out fewer (`NativeThreadStore.eagerTailRows`: the last rows
    /// within `NativeMountedCost.eagerTailCap`, and never fewer than two viewports). While the window live-resizes the tail is only
    /// as many as cover it (`eagerCount`).
    static let eagerRows = 30

    /// One view per row whatever it holds, so the lazy stack builds only the rows on screen: a
    /// row that could be nothing would make it evaluate every row of a long thread on each
    /// streamed chunk.
    @ViewBuilder private func rowView(_ row: NativeThreadRow, running: Bool, catchingUp: Bool, arrived: Set<String>, settled: Bool,
                                      historyRowID: String?) -> some View {
        let _ = SHRenderProbe.tick("thread.rowBuilder")
        ThreadRowLayer {
            // One view serves the streaming shell and the reply it becomes, so the turn's end updates its turn in place.
            ThreadRowContent(store: store, row: row, active: active, parentCatchingUp: catchingUp, settled: settled,
                             arriving: arrived.contains(row.id)) { shown, inputs in
                turn(shown, running: running, thinking: inputs.thinking, wait: inputs.wait, arriving: arrived.contains(shown.id), settled: inputs.settled)
            }
        }
        .id(row.id)
        .background {
            ThreadTailGuard.RowProbe(guardian: tailGuard, rowID: row.id)
                .accessibilityHidden(true)
        }
        .background {
            if row.id == historyRowID {
                ThreadHistoryAnchor.Probe(anchor: historyAnchor, rowID: row.id)
            }
        }
    }

    /// What the streaming reply draws besides its content.
    private struct LiveTurnInputs: Equatable {
        var thinking: Bool
        var wait: NativeLiveWait
        var settled: Bool
    }

    /// A transcript row's content. A finished row draws what the list holds, and reads none of the streaming state
    /// (`liveRow`, `showsThinking`, `liveWait`, the thread's version), so a chunk never reaches it.
    /// The streaming reply is held in the list as a shell (`NativeThreadStore.listRows`), and its row reads the
    /// store's `liveRow` and `showsThinking` itself, so each streamed chunk and each tool boundary invalidates this
    /// one view and not the transcript that holds its shell.
    ///
    /// The same view draws the shell and the reply it becomes, with no branch between them: when the turn ends its
    /// turn is updated where it stands, and keeps its code views, its disclosures and the entrances it has played,
    /// where a branch flipping under the row's id would build every part again. The render in which it flips still
    /// moves as the swap did: what that render brings (the footer, the changes card, a new part) enters only for a
    /// reply that arrived on screen (`arriving`).
    ///
    /// Only one thing moves (LiveText): a running call's own line, thinking, or the reply as it
    /// is written. Between tools the turn ends in "Thinking…". A question waits in the composer
    /// instead, and a pi that is starting says so there too, never here (`NativeThreadStore.showsThinking`).
    private struct ThreadRowContent<Content: View>: View {
        let store: NativeThreadStore
        let row: NativeThreadRow
        let active: Bool
        /// The transcript's verdict, for the shell's first render: a new reply's row is made while the thread is on screen.
        let parentCatchingUp: Bool
        /// The transcript's verdict on whether its motion is on, for a row that is not the shell.
        let settled: Bool
        /// The row arrived with the thread's latest change (`ThreadArrivals`).
        let arriving: Bool
        @ViewBuilder let content: (NativeThreadRow, LiveTurnInputs) -> Content
        @State private var memory = ThreadRowMemory()

        /// What one render draws, and what its catch-up gate decided.
        private struct Drawn {
            var row: NativeThreadRow
            var inputs: LiveTurnInputs
            var catchingUp = false
            /// The thread's version the shell drew; 0 for a row that reads none, so a chunk never reaches it.
            var version = 0
        }

        private func resolve() -> Drawn {
            memory.count(in: store)
            let shell = row.live && row.presentation == nil
            // The turn is kept across the flip, so its first render after it has already appeared. Without this, what
            // that render brings would enter for every reply and not only for one that arrived on screen.
            let flipped = memory.shell.map { $0 != shell } ?? false
            memory.shell = shell
            let moves = arriving || !flipped
            guard shell else {
                memory.catchUp = nil
                return Drawn(row: row, inputs: LiveTurnInputs(thinking: false, wait: NativeLiveWait(), settled: settled && moves))
            }
            SHRenderProbe.tick("thread.liveRow")
            let version = store.threadVersion
            let gate = memory.catchUp ?? CatchUpGate()
            memory.catchUp = gate
            let catchingUp = gate.catchingUp(caughtUpAt: store.catchUp?.thread, version: version, parent: parentCatchingUp)
            let thinking = store.showsThinking
            let inputs = LiveTurnInputs(thinking: thinking, wait: thinking ? store.liveWait : NativeLiveWait(),
                                        settled: active && !catchingUp && moves)
            // No live row draws nothing: the shell holds no content.
            return Drawn(row: store.liveRow ?? row, inputs: inputs, catchingUp: catchingUp, version: version)
        }

        var body: some View {
            let drawn = resolve()
            content(drawn.row, drawn.inputs)
                // As the thread's own (see `body`).
                .transaction(value: CatchUpGate.Key(version: drawn.version, active: active)) {
                    if drawn.catchingUp { $0.disablesAnimations = true }
                }
        }
    }

    /// The wait line, "Thinking…" before the reply has a row. It reads `showsThinking` and `liveWait`
    /// itself, so a change redraws this view and not the transcript. Empty, it takes no room in the column.
    private struct ThreadWaitLine: View {
        let store: NativeThreadStore
        let hasLiveRow: Bool
        let active: Bool
        let parentCatchingUp: Bool
        /// The thread's version when it last drew: the line redraws, and its gate records, whenever the thread does.
        let drawn: Int
        let project: Bool
        @State private var catchUp = CatchUpGate()

        var body: some View {
            let _ = SHRenderProbe.tick("thread.waitLine")
            let catchingUp = catchUp.catchingUp(caughtUpAt: store.catchUp?.thread, version: store.threadVersion, parent: parentCatchingUp)
            if !hasLiveRow, store.showsThinking {
                Group {
                    if project { ProjectLiveLine(startedAt: nil) } else { LiveWaitLine(wait: store.liveWait) }
                }
                .shArrival(active && !catchingUp)
                .transaction(value: CatchUpGate.Key(version: store.threadVersion, active: active)) {
                    if catchingUp { $0.disablesAnimations = true }
                }
            }
        }
    }

    /// The scroll target at the end of the thread: scrolled to when following, and in view
    /// whenever the tail is (`ThreadTailGuard`).
    static let bottomID = "thread-bottom"

    /// What the tail guard reads when a check comes due, refreshed by every render and never
    /// observed.
    private func keepTail(_ proxy: ScrollViewProxy) {
        tailGuard.requiresNativeRows = true
        tailGuard.bottomID = Self.bottomID
        tailGuard.active = active
        tailGuard.following = follower.sticky
        tailGuard.userScrolling = follower.userScrolling
        tailGuard.land = { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        tailGuard.rebuild = { [historyAnchor, weak guardian = tailGuard, revision = $transcriptRevision] in
            historyAnchor.cancel()
            guardian?.targets([])
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { revision.wrappedValue &+= 1 }
        }
        if tailGuard.rowIDsStamp != rowIndex.stamp {
            tailGuard.rowIDsStamp = rowIndex.stamp
            tailGuard.rowIDs = rowIndex.set
        }
    }

    // Starting history during an animated jump can discard its restoration scroll request.
    // The rows of a thread still to bring its lazy stack back (`ThreadRestore`) are in memory, drawn or not: nothing to load for them.
    private var historyEnabled: Bool { active && store.ready && !store.loadingOlder && !follower.sticky && !historyAnchor.animating && !restore.awaitsHistory }

    private func loadVisibleHistory() {
        guard historyPaging.takeRequest(session: store.sessionKey, cursor: store.olderCursor, enabled: historyEnabled) else { return }
        let token = historyAnchor.begin(store.rows.first?.id, session: store.sessionKey)
        Task {
            await store.loadOlder()
            historyAnchor.finished(token, firstID: store.rows.first?.id)
        }
    }

    private var subagentActions: SubagentActions {
        SubagentActions(
            inspect: { run in inspectSubagent?(run) },
            command: { run, action, text, mode in Task { await store.subagentCommand(runID: run.runID, action: action, text: text, mode: mode) } },
            steer: steerSubagent,
            inspectedRunID: inspectedRunID)
    }

    /// Request checkpoint recovery from the latest settled turn. Never resend its user input.
    private func retryAction(_ row: NativeThreadRow, running: Bool) -> (() -> Void)? {
        guard store.canRetry(row, running: running) else { return nil }
        return { [store] in Task { await store.retry(row) } }
    }

    private func handle(_ command: ThreadCommandCenter.Command, proxy: ScrollViewProxy) {
        switch command {
        case .modelPicker, .thinkingMenu, .speedMenu:
            // The composer's own: it watches the command center itself, so the menu opens with
            // one redraw of the composer and none of the thread.
            break
        case .inspectSubagent:
            if let run = store.subagents.first(where: { !$0.isTerminal }) ?? store.subagents.last { inspectSubagent?(run) }
            else { NSSound.beep() }
        case .previousTurn, .nextTurn:
            historyAnchor.cancel()
            historyPaging.beginScroll()
            let userTurns = store.rows.filter(\.isUser).map(\.id)
            guard !userTurns.isEmpty else { NSSound.beep(); return }
            let current = jumpedTurn.flatMap(userTurns.firstIndex(of:)) ?? userTurns.count
            let target = command == .previousTurn ? max(0, current - 1) : current + 1
            guard userTurns.indices.contains(target) else {
                jumpedTurn = nil
                follower.jumpToLatest()
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
                tailGuard.asked()
                return
            }
            jumpedTurn = userTurns[target]
            follower.beginJump()
            withSHAnimation(.scroll) { proxy.scrollTo(userTurns[target], anchor: .top) }
        }
    }

    /// Brings the turn holding `entryID` (a tool result, a compaction) to the top of the
    /// thread, loading older pages until it is there (the context meter's Largest and Show
    /// summary).
    private func find(_ entryID: String, proxy: ScrollViewProxy) async {
        historyAnchor.cancel()
        var pages = 0
        while store.rows.first(where: { $0.turn.messages.contains { $0.entryID == entryID } }) == nil,
              store.olderCursor != nil, pages < AppLayout.findPageLimit {
            await store.loadOlder()
            pages += 1
        }
        guard let row = store.rows.first(where: { $0.turn.messages.contains { $0.entryID == entryID } }) else { NSSound.beep(); return }
        jumpedTurn = nil
        follower.beginJump()
        withSHAnimation(.scroll) { proxy.scrollTo(row.id, anchor: .top) }
    }

    /// How far the visible bottom sits above the end of the content (`NativeScrollProbe`): 0 at
    /// the tail, negative for content that fits the viewport.
    static func distanceFromBottom(_ geometry: ScrollGeometry) -> CGFloat {
        CGFloat(probe(geometry).distance)
    }

    static func probe(_ geometry: ScrollGeometry) -> NativeScrollProbe {
        NativeScrollProbe(content: geometry.contentSize.height, offset: geometry.contentOffset.y,
                          container: geometry.containerSize.height, insetTop: geometry.contentInsets.top,
                          insetBottom: geometry.contentInsets.bottom)
    }

    /// Wheel/trackpad events are the one user scroll intent SwiftUI does not phase for us.
    private func installWheelMonitor() {
        guard wheelMonitor == nil else { return }
        // The view's state holds the monitor, so a handler that held the view would hold it in return, and a teardown that cannot write
        // `wheelMonitor` back to nil (a window released with the thread in it) would leave the pair and the store alive for good. The
        // handler holds only what it moves.
        let hovering = $hovering
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak input = input, weak anchor = historyAnchor, weak paging = historyPaging, weak guardian = tailGuard] event in
            if hovering.wrappedValue {
                anchor?.cancel()
                if event.scrollingDeltaY != 0 { input?.readerScrolled(upward: event.scrollingDeltaY > 0) }
                paging?.beginScroll()
                guardian?.readerMoved()
            }
            return event
        }
    }

    @ViewBuilder private var notices: some View {
        if store.session != nil {
            if !store.ready, store.loadError == nil, store.startProblem == nil, !store.starting, !store.previewing {
                quiet("Last known thread · refreshing before enabling actions")
            }
            if !store.dialogsSupported { quiet("This host's agent cannot answer questions here · update Shepherd on the host") }
            if let notice = store.clipNotice { ForEach(notice.lines, id: \.self) { quiet($0) } }
        }
    }

    /// An agent with nothing said yet. A new one is known to be empty from the start, so its
    /// framed state shows while pi boots. While the history is not known yet (connecting, or pi
    /// still starting with no session file to read) the thread stays blank and the composer says
    /// pi is starting; an error keeps the last transcript and shows its banner there instead.
    @ViewBuilder private var emptyState: some View {
        if store.session != nil {
            SHEmptyState(
                Text("New agent in \(Text(abbreviatedPath).font(Font.shMono(AppLayout.emptyThreadPathSize, .medium)))"),
                message: "Describe the task. Drop or paste images to attach them, or type / for commands.",
                showsMark: false, framed: true
            )
            .padding(.top, AppLayout.emptyThreadTop)
            // Fades in when pi's history arrives empty; a thread known to be empty just shows it.
            .shArrival(arrivals.startedLoading)
        }
    }

    private var abbreviatedPath: String {
        guard let workingDirectory else { return agentName ?? "this folder" }
        return (workingDirectory as NSString).abbreviatingWithTildeInPath
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(Font.sh(.caption)).foregroundStyle(Color.sh.textTertiary).textSelection(.enabled)
    }
}

/// Tells a view whether the render it is in draws a catch-up: what a thread brought back from
/// while it was away (or loading), which lands without motion. The store marks where it caught
/// up (`NativeThreadStore.catchUp`, with its content version then) in the same update as the
/// pull, so catching up takes no pass of its own; this remembers the version the view last
/// drew, so the render showing those changes, and only it, counts as the catch-up. A thread
/// that came back unchanged is caught up at once. Read in `body`, and a reference, so keeping
/// it current never re-renders the view.
@MainActor
final class CatchUpGate {
    /// The version this view last drew; nil until its first render.
    private var drawn: Int?

    /// What a view keys its `transaction(value:)` on, so that only the update in which it drew
    /// a catch-up (or flipped on screen) is touched, never its subviews' later updates.
    struct Key: Equatable {
        let version: Int
        let active: Bool
    }

    /// `caughtUpAt` is the version the store had when it caught up (nil until then), and
    /// `version` its version now. A view made in the middle of a session (each new reply's live
    /// row) passes its parent's verdict: its first render is not the thread's catch-up, so it
    /// moves as its parent does. Without a parent, a gate that has not drawn is catching up.
    func catchingUp(caughtUpAt: Int?, version: Int, parent: Bool? = nil) -> Bool {
        defer { drawn = version }
        guard let drawn else { return parent ?? true }
        guard let caughtUpAt else { return true }
        return caughtUpAt > drawn
    }
}

/// What a transcript row keeps between its renders (`ThreadRowContent`). A reference, so keeping it current never redraws the row.
@MainActor
final class ThreadRowMemory {
    #if DEBUG
    /// How many rows have view state alive, by the store they are drawn with: the rows a thread keeps built, which the tests pin
    /// (`ThreadHistoryRetentionTests`). Per store, so other threads drawn in the same process do not move it.
    private nonisolated static let counts = Mutex<[ObjectIdentifier: Int]>([:])
    private var counted: ObjectIdentifier?

    static func built(in store: NativeThreadStore) -> Int {
        counts.withLock { $0[ObjectIdentifier(store)] ?? 0 }
    }

    deinit {
        guard let counted else { return }
        Self.counts.withLock { counts in
            let left = (counts[counted] ?? 1) - 1
            counts[counted] = left > 0 ? left : nil
        }
    }
    #endif

    /// Counts this row's view state under `store` (`built(in:)`); nothing in a release build.
    func count(in store: NativeThreadStore) {
        #if DEBUG
        let id = ObjectIdentifier(store)
        guard counted != id else { return }
        Self.counts.withLock { counts in
            if let counted {
                let left = (counts[counted] ?? 1) - 1
                counts[counted] = left > 0 ? left : nil
            }
            counts[id, default: 0] += 1
        }
        counted = id
        #endif
    }

    /// The catch-up gate of the shell: made when the row draws the shell and dropped when it draws a finished reply, so a reply
    /// that goes live again starts from the transcript's verdict, as a row made then would.
    var catchUp: CatchUpGate?
    /// Whether the last render drew the shell; nil until the first.
    var shell: Bool?
}

/// The identity the history's lazy stack is drawn with: it changes while the thread is let go (`dormant`, or the rows being let go,
/// `ThreadView.historyColumn`) and each time the stack starts again (`ThreadHistoryBuilt`).
private struct StackID: Hashable {
    let dormant: Bool
    let built: Int
}

/// What the history's lazy stack has built, and when it starts again. A lazy stack builds the last row it is handed, off screen as it
/// is, and keeps it built for good; the rows that leave the eager tail join the history at its end, so each turn's reply stays built
/// behind the tail (about 0.6 MB for one line) for as long as the thread is on screen. A reader at the tail has no use for them, so
/// once the thread has added `ThreadHistoryBuilt.rows` of them since the stack began, it begins again, with the rows it builds first, as
/// it does when the thread opens. That happens in the update that adds rows, the frame a turn lands in, and only while the reader is at
/// the tail, at rest, and the thread is not coming back: a reader in the history keeps the rows they are reading, and one that
/// scrolled up through it keeps what they passed, until the first turn that lands once they are back.
///
/// The state of the history's rows goes with the stack: a disclosure opened in one (a tool's lines, a thinking block, a diagram) closes,
/// as it does when the row leaves the eager tail or the thread is let go.
///
/// A reference, so keeping it never draws the thread; `stack` is read in the thread's body, and is the identity the stack is drawn with.
@MainActor
final class ThreadHistoryBuilt {
    /// Rows added at the history's end that the stack may have built.
    static let rows = 16
    private(set) var stack = 0
    private var last: String?
    private var lastTail: Int?
    private var added = 0

    #if DEBUG
    /// The stack each thread's history was last drawn in, by store, which the tests pin (`ThreadHistoryRetentionTests`). Per store, so
    /// other threads drawn in the same process do not move it.
    private nonisolated static let drawn = Mutex<[ObjectIdentifier: Int]>([:])
    private var noted: ObjectIdentifier?

    static func drawn(in store: NativeThreadStore) -> Int {
        drawn.withLock { $0[ObjectIdentifier(store)] ?? 0 }
    }

    deinit {
        guard let noted else { return }
        Self.drawn.withLock { $0[noted] = nil }
    }
    #endif

    /// Notes the stack drawn under `store` (`drawn(in:)`); nothing in a release build.
    func note(in store: NativeThreadStore) {
        #if DEBUG
        let id = ObjectIdentifier(store)
        noted = id
        Self.drawn.withLock { $0[id] = stack }
        #endif
    }

    /// The stack to draw `history` in. Only rows added while the thread is `onScreen` count (a hidden host does not lay out, so builds
    /// none), and the stack starts again only in an update that adds rows, when `mayLetGo`: the reader is at the tail and at rest, and
    /// the thread is not coming back.
    ///
    /// Rows count when the row that was last is still in the history, followed by new ones: paging in at the top leaves the last row as
    /// it was, and a thread coming back has no rows to compare with, so neither counts. Nor do rows while the tail is not at its resting
    /// size (`tailMoves`: a live resize, and the tail growing back after it): the rows that move into the history then are no turn's, and
    /// the stack builds none of them but the last.
    ///
    /// The rows a thread adds land in the eager tail, which holds `tail` of them, and cross into the history as it moves on. At rest the
    /// tail is a count the rule sets (`NativeThreadStore.eagerTailRows`), fewer than the eager rows for a thread of heavy rows, and it
    /// differs from one update to the next. So an update counts the rows that joined the history's end together with the tail's change:
    /// a tail that shrank gave the history rows no turn added (a thread that turned heavy), and one that grew kept a turn's rows that the
    /// history has yet to take (a reply still being parsed keeps them in the tail until it is).
    func stack(history: ArraySlice<NativeThreadRow>, onScreen: Bool, mayLetGo: Bool, tailMoves: Bool = false, tail: Int? = nil) -> Int {
        defer {
            last = history.last?.id
            lastTail = tail
        }
        let counts = onScreen && !tailMoves
        var grew = false
        if let old = last, let at = history.lastIndex(where: { $0.id == old }) {
            let joined = history.endIndex - 1 - at
            grew = joined > 0
            if counts { added += max(0, joined + (tail.flatMap { now in lastTail.map { now - $0 } } ?? 0)) }
        } else if history.isEmpty {
            added = 0
        }
        if grew, counts, mayLetGo, added >= Self.rows {
            stack += 1
            added = 0
        }
        return stack
    }
}

/// The lazy stack of the rows older than the eager tail, kept as the view it was while what its rows are built from has not changed (`Key`:
/// the rows, the boundary row's probe, whether a turn runs and whether the reader has left the tail, the arrivals among the rows, the run open
/// in the inspector, the dispatches, which actions the thread was given, and the store and the tail guard its rows are drawn with). The
/// thread's body runs for much else (it is shown or hidden, it catches up), which nothing in the stack reads; handed the same rows in a new
/// closure, the stack builds them again and moves its estimate of the rows it has not measured, and a reader in the eager tail below it has
/// nothing to hold their rows where they were. A turn ending is not ignored: the stack's estimates are replaced as it does, and a reply
/// landing at the tail was blank for a frame without it. A reference, so keeping it never draws the thread.
///
/// Two things are relied on. Handing SwiftUI the very `AnyView` it drew last lets it leave the stack alone, which a new one built from the
/// same rows does not; `switchingAwayAndBackKeepsLoadedHistoryAndScrollPosition` is the guard for that and fails if it stops holding. And
/// the key leaves out whether the thread is on screen, is catching up and has settled (`active`, `catchingUp`, `settled`): only the
/// streaming reply and a row that arrives read them to play their motion, and the reply is the last row, which `ThreadView.eagerRows >= 1`
/// (and a restore's plan, which draws at least one) keeps in the eager tail, while an arrival among the history's rows is in the key.
///
/// The kept view holds the thread view that drew it, so the cache must not be held by that thread view (`ThreadHistoryColumn`).
@MainActor
final class ThreadHistoryCache {
    struct Key: Equatable {
        let rows: ArraySlice<NativeThreadRow>
        let dormant: Bool
        /// Which stack of `ThreadHistoryBuilt` the rows are drawn in.
        var stack = 0
        let boundary: String?
        let running: Bool
        let detached: Bool
        let arrived: Set<String>
        let inspected: String?
        let fleet: FleetThreadSurface?
        let actions: [Bool]
        let store: ObjectIdentifier
        let tailGuard: ObjectIdentifier

        /// The rows of `arrived` that are among the `history`'s. Rows arrive at the thread's tail, so unless a batch larger than the
        /// tail arrived at once, every one is in `tail` and only it is looked at; the history is walked only for such a batch.
        static func arrivals(in history: ArraySlice<NativeThreadRow>, tail: ArraySlice<NativeThreadRow>, among arrived: Set<String>) -> Set<String> {
            guard !arrived.isEmpty else { return [] }
            var inTail = 0
            for row in tail where arrived.contains(row.id) { inTail += 1 }
            guard inTail < arrived.count else { return [] }
            return Set(history.lazy.map(\.id).filter(arrived.contains))
        }
    }

    private var key: Key?
    private var kept: AnyView?

    /// `make` draws the stack: every time with no `key`, and otherwise when the key is not the last one's.
    func view(for key: Key?, make: () -> AnyView) -> AnyView {
        guard let key else {
            self.key = nil
            kept = nil
            return make()
        }
        if let kept, self.key == key { return kept }
        let view = make()
        self.key = key
        kept = view
        return view
    }
}

/// Shows the history stack through `ThreadHistoryCache`, which it holds in its own state. The stack's rows are built by the thread view's
/// methods, so the view the cache keeps holds a copy of the thread view; had the thread view held the cache, the two would hold each other,
/// and with them the thread's store and tail guard and every row of its history, until something broke the loop (`onDisappear` once
/// did), and a teardown that never got there left them for good. Here the cache is the column's, and goes with it
/// (`ThreadHistoryRetentionTests`).
private struct ThreadHistoryColumn: View {
    let key: ThreadHistoryCache.Key?
    let make: () -> AnyView
    @State private var cache = ThreadHistoryCache()

    init(key: ThreadHistoryCache.Key?, make: @escaping () -> AnyView) {
        self.key = key
        self.make = make
    }

    var body: some View { cache.view(for: key, make: make) }
}

/// What a thread view's loop task restarts for: showing or hiding, and a loop handed back to it.
private struct LoopKey: Equatable {
    let active: Bool
    let run: Int
}

/// Rests the thread's store (`NativeThreadStore.rest`) while the main window can't be seen, and wakes it at once when it
/// can. It reads the window's presence itself, so a window showing or hiding reruns this modifier and no `ThreadView` body.
private struct ThreadRest: ViewModifier {
    let store: NativeThreadStore
    let owner: UUID
    let active: Bool
    /// A loop handed back to this view (`ThreadReaderPins`) asks again.
    let run: Int
    @Environment(\.mainWindowVisible) private var visible
    @Environment(\.threadRestDelay) private var delay

    private struct Key: Equatable {
        let resting: Bool
        let run: Int
    }

    func body(content: Content) -> some View {
        let resting = active && !visible
        content.task(id: Key(resting: resting, run: run)) {
            guard resting else {
                store.rest(false, owner: owner)
                return
            }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            store.rest(true, owner: owner)
        }
    }
}

/// A thread's row IDs, structural: rebuilt only when the store's row structure revision
/// (`NativeThreadStore.rowStructureRevision`) moves or the view's filter (a Project's runtime
/// operations, which hide wake-up turns) changes, never when only a row's text or live state
/// does (every streamed chunk). Content-only updates compare the key (the filter's operations,
/// not the rows), no walk over the rows.
@MainActor
final class ThreadRowIndex {
    private(set) var ids: [String] = []
    private(set) var set: Set<String> = []
    /// Bumped when the IDs were rebuilt, so a reader can skip an equal set.
    private(set) var stamp = 0
    private var key: Key?

    private struct Key: Equatable {
        let revision: Int
        let count: Int
        let first: String?
        let last: String?
        let filter: Set<UUID>
    }

    /// `filter` is what decides which of the store's rows `rows` keeps: a new one can swap interior rows at one revision.
    func update(_ rows: [NativeThreadRow], revision: Int, filter: Set<UUID> = []) {
        let key = Key(revision: revision, count: rows.count, first: rows.first?.id, last: rows.last?.id, filter: filter)
        guard key != self.key else { return }
        self.key = key
        let ids = rows.map(\.id)
        guard ids != self.ids else { return }
        self.ids = ids
        set = Set(ids)
        stamp &+= 1
    }
}

/// How a thread that let its rows go (`NativeThreadStores`) brings them back when it is shown again, bottom first. The rows it kept
/// (`NativeThreadStore.keptRows`) are all it draws in its first frame, and are not built again: a lazy stack drawn in that frame
/// would be shown its estimates, before the scroll view has been held to the tail, and would build them. The next frame brings the lazy
/// stack back with the rows older than the eager tail, whatever the person types (it builds nothing at the tail, and without it the
/// thread seems to end where its last screen does), and the rows between join the eager tail a step at a time, newest first, each
/// leaving the lazy stack for the eager stack once, when no key or scroll is recent. The end of the thread, where the reader is, never
/// moves: the scroll view keeps it while the content above it grows, at the bottom of the window even where the rows drawn so far do
/// not fill it (`ThreadTailAnchor`).
/// No update builds more than a step of rows, except the first frame of a thread whose rest costs no more than a step (a dozen rows of
/// one line cost nothing), which draws all of it: up to the eager rows, and the lazy stack's first screen.
///
/// Read in `body`, which it changes only through `steps`: the rest is a reference's, so keeping it current never draws the view.
@MainActor
@Observable
final class ThreadRestore {
    /// What a restore draws in one update.
    struct Plan: Equatable {
        /// How many rows at the end of the thread the eager stack holds.
        let eager: Int
        /// The lazy stack draws the rows before them; before it, they are not drawn at all.
        let history: Bool
    }

    /// Raised by each step, which is what draws the next one.
    private(set) var steps = 0
    /// Rows are still to come back, one step at a time.
    @ObservationIgnored private(set) var restoring = false
    /// The oldest row of the eager stack while restoring.
    @ObservationIgnored private var first: String?
    /// The lazy stack is back.
    @ObservationIgnored private var history = false
    /// The rows the thread's hidden view drew, as the last hidden update saw them (nil: all of them).
    @ObservationIgnored private var hiddenKept: Int?
    /// This showing has begun (or needed no restore).
    @ObservationIgnored private var begun = false
    /// The thread has had rows since it last had none, and `plan` has seen them, hidden or shown (`noteArrival`).
    @ObservationIgnored private var arrived = false

    /// The last update drew the replies at the end of the eager tail with their blocks (`NativeThreadStore.tailAwaitsParse` was false):
    /// a large reply is parsed off the main thread and draws as nothing until then, and the update that brings its content builds it,
    /// which the lazy stack above must not share (it would be laid out against a tail still growing, and build rows).
    @ObservationIgnored private(set) var tailDrawnParsed = true

    /// The thread has been hidden long enough that a tail bounded by cost is all it draws (`plan`). Cleared when it is shown.
    @ObservationIgnored private var withdrawsStack = false

    /// This restore began with the thread holding only its tail (`NativeThreadStore.keepsOnlyTail`): its first frame came before the pull
    /// that catches it up, and the lazy stack waits for that pull (`ThreadView.restoreRows`). Not for a restore of rows that were let go
    /// from a thread that holds its history, whose pull brings no rows above the tail.
    @ObservationIgnored private(set) var awaitsPull = false

    /// Has the hidden thread draw only its tail from now on: raises `steps`, which draws the next update. A thread whose tail is not
    /// bounded by cost, or whose reader is in its history, draws what it did.
    func withdrawStack() {
        guard !withdrawsStack else { return }
        withdrawsStack = true
        steps &+= 1
    }

    /// The first lazy stack still waits for the replies at the end of the tail to draw their blocks, having waited `retries` times
    /// (`AppLayout.restoreRetry` each): not for ever, so that a parse that does not land cannot keep the older rows from coming back.
    func waitsForParse(retries: Int) -> Bool { !tailDrawnParsed && retries < AppLayout.restoreParseRetries }

    /// The lazy stack is still to come back (the next step brings it): the thread draws only the rows the eager stack holds, so a
    /// reader cannot scroll to older ones.
    var awaitsHistory: Bool { restoring && !history }

    /// What the thread draws in this update; nil for all of it. `hiddenKept` is what the hidden view draws
    /// (`NativeThreadStore.transcriptDrawn`, read only while hidden, so that the thread on screen is not drawn again by the store
    /// clearing it), and `rows` all the rows once the thread is shown. `owed` is what building the rows between the last `hiddenKept`
    /// and the eager tail costs, beyond their chrome (`NativeThreadStore.restoreCost`), read once as it comes back: a thread that owes
    /// no more than a step (`AppLayout.restoreStepBytes`) draws them all in its first frame, as it would after any release, because
    /// there is nothing to spread (a dozen rows of one line owe nothing), and a last screen that is all it drew might not fill its
    /// window (`ThreadTailAnchor`). `keepsOnlyTail` is whether the thread holds only the end of its history, as it is shown
    /// (`NativeThreadStore.keepsOnlyTail`): its restore waits for the pull that catches it up (`awaitsPull`).
    func plan<Rows: BidirectionalCollection>(active: Bool, hiddenKept: Int?, rows: Rows, eagerRows: Int, following: Bool = true,
                                             tailParsed: Bool = true, keepsOnlyTail: Bool = false, owed: (Int) -> Int) -> Plan?
    where Rows.Element == NativeThreadRow, Rows.Index == Int {
        _ = steps
        tailDrawnParsed = tailParsed
        guard active else {
            self.hiddenKept = hiddenKept
            noteArrival(rows: rows, eagerRows: eagerRows)
            // A hidden thread that follows its tail and whose tail is bounded by cost draws that tail alone, once it has been hidden a
            // while (`withdrawStack`): its lazy stack is laid out from the top of a thread no one scrolls, builds the oldest rows there, and
            // keeps them, hundreds of megabytes nothing counts. The stack comes after the first frame it is shown, as for any first show.
            // A reader left in the history keeps the stack that holds their place.
            if following, withdrawsStack, rows.count > eagerRows, eagerRows < ThreadView.eagerRows, !restoring || history {
                if !restoring { first = rows[rows.endIndex - eagerRows].id }
                restoring = true
                history = false
            }
            // Hidden halfway through, it keeps the rows it has and waits for the next showing: the rest is not built for no one.
            // Unless a pass has let those go again (`hiddenKept` below what the restore had): the next showing starts again from
            // the rows kept, as after any release, and does not build the difference in its first frame.
            if let plan = underway(rows: rows, eagerRows: eagerRows), self.hiddenKept.map({ $0 >= plan.eager }) ?? true { return plan }
            begun = false
            finish()
            return nil
        }
        withdrawsStack = false
        if !begun {
            begun = true
            // At least one row, so that the first frame is not blank.
            if let kept = self.hiddenKept.map({ max(1, $0) }), kept < min(rows.count, eagerRows), owed(kept) > AppLayout.restoreStepBytes {
                first = rows[rows.endIndex - kept].id
                restoring = true
                history = false
            } else if keepsOnlyTail, self.hiddenKept != nil, rows.count > eagerRows, eagerRows < ThreadView.eagerRows {
                // What it owes costs no more than a step, but a tail bounded by cost sits above a lazy stack of rows that cost as much or
                // more: a thread that let go of its older history and kept its end (`NativeThreadStore.releaseToTail`) comes back as rows
                // that arrive do (`noteArrival`), its eager tail in the first frame and the stack after it, not the stack's first screen
                // with it. A thread that holds its history and let its rows go draws what it owes in the first frame, as it always did.
                first = rows[rows.endIndex - eagerRows].id
                restoring = true
                history = false
            }
            awaitsPull = keepsOnlyTail && restoring
            self.hiddenKept = nil
        }
        noteArrival(rows: rows, eagerRows: eagerRows)
        guard restoring else { return nil }
        // The tail alone is a whole eager tail, one that waits for its lazy stack.
        guard let plan = underway(rows: rows, eagerRows: eagerRows), plan.eager < eagerRows || !plan.history else {
            finish()
            return nil
        }
        return plan
    }

    /// What a restore under way draws: the eager stack from the row it has reached. A tail that waits for its lazy stack is the rule's at
    /// most, whatever rows arrive meanwhile (a hidden thread waits as long as it stays hidden), the row it starts from moving with them.
    private func underway<Rows: BidirectionalCollection>(rows: Rows, eagerRows: Int) -> Plan? where Rows.Element == NativeThreadRow, Rows.Index == Int {
        guard restoring, let first, let index = rows.lastIndex(where: { $0.id == first }) else { return nil }
        var eager = rows.endIndex - index
        if !history, eager > eagerRows {
            eager = eagerRows
            self.first = rows[rows.endIndex - eager].id
        }
        return Plan(eager: eager, history: history)
    }

    /// The first rows of a thread whose tail is bounded by cost (it opened, or its history came back), hidden or shown, draw their eager
    /// tail alone, and the lazy stack after the frame that shows it (`advance`): a stack drawn with them is shown its estimates before the
    /// scroll view has been held to the tail, and builds rows at the top of the thread that are nowhere near its reader, which for rows
    /// that cost that much is hundreds of megabytes nothing counts. A thread of cheap rows (the most of them are the tail) draws as it
    /// always did.
    private func noteArrival<Rows: BidirectionalCollection>(rows: Rows, eagerRows: Int) where Rows.Element == NativeThreadRow, Rows.Index == Int {
        if rows.isEmpty {
            arrived = false
            return
        }
        guard !arrived else { return }
        arrived = true
        if !restoring, rows.count > eagerRows, eagerRows < ThreadView.eagerRows {
            first = rows[rows.endIndex - eagerRows].id
            restoring = true
            history = false
        }
    }

    /// Draws the next step: the lazy stack first, then rows. `step` is how many more rows to take, given how many the eager stack
    /// holds. False when the eager tail is whole.
    func advance<Rows: BidirectionalCollection>(rows: Rows, eagerRows: Int, step: (Int) -> Int) -> Bool
    where Rows.Element == NativeThreadRow, Rows.Index == Int {
        guard restoring, let first, let index = rows.lastIndex(where: { $0.id == first }) else {
            finish()
            return false
        }
        if !history {
            history = true
            steps &+= 1
            return true
        }
        let more = step(rows.endIndex - index)
        let next = max(rows.startIndex, index - more)
        if more == 0 || rows.endIndex - next >= eagerRows {
            finish()
        } else {
            self.first = rows[next].id
        }
        steps &+= 1
        return restoring
    }

    private func finish() {
        restoring = false
        awaitsPull = false
        first = nil
        history = false
    }
}

/// Which turns arrived at a thread's tail with its latest change, so they (and only they) make
/// an entrance. Loading is instant: opening the thread, the first pull after it comes back on
/// screen (an agent switched back to catches up at once), a page of older history, and a
/// window or session swapped out from under the view. Read in `body`, and a reference, so
/// keeping it current never re-renders the thread; the same rows always answer the same set.
@MainActor
final class ThreadArrivals {
    /// Whether the thread's latest render showed a catch-up (see `CatchUpGate`).
    let catchUp = CatchUpGate()
    /// The thread is on screen and caught up: turns appended at its tail arrive.
    private(set) var armed = false
    /// The first rows this saw were still loading (pi's history not known yet).
    private(set) var startedLoading = false
    private var seen = false
    private var signature: Signature?
    private var arrived: Set<String> = []

    private struct Signature: Equatable {
        var session: String?
        var count: Int
        var first: String?
        var last: String?
    }

    /// The rows in `ids` that arrived with this change. `session` names the snapshot's pi
    /// session (nil before the first one), `active` is whether the thread is on screen (a hidden
    /// thread stops polling), and `catchingUp` whether this render shows a catch-up.
    func update(_ ids: [String], session: String?, active: Bool, catchingUp: Bool) -> Set<String> {
        if !seen {
            seen = true
            startedLoading = session == nil
        }
        armed = active && !catchingUp && session != nil
        let next = Signature(session: session, count: ids.count, first: ids.first, last: ids.last)
        let previous = signature
        guard armed, let previous else {
            signature = next
            arrived = []
            return arrived
        }
        guard next != previous else { return arrived }
        signature = next
        if previous.session != session {
            arrived = []
        } else if let last = previous.last, let index = ids.lastIndex(of: last) {
            arrived = Set(ids[(index + 1)...])
        } else {
            // An empty thread's first turns arrive; a different window does not.
            arrived = previous.last == nil ? Set(ids) : []
        }
        return arrived
    }
}

/// Watches the command center in its own view, so a command sent to another thread never
/// re-evaluates this thread's body (nor the composer's, which watches it for its menus).
struct ThreadCommandHandler: ViewModifier {
    let key: String?
    let active: Bool
    let handle: (ThreadCommandCenter.Command) -> Void
    @Environment(\.threadCommands) private var commands

    func body(content: Content) -> some View {
        content.onChange(of: commands?.request) { _, request in
            guard let request, request.thread == key, active else { return }
            handle(request.command)
        }
    }
}

/// A request to bring an entry into view, from the composer's context details.
@MainActor
@Observable
final class ThreadFinder {
    struct Request: Equatable {
        let entryID: String
        let id = UUID()
    }

    private(set) var request: Request?

    func find(_ entryID: String) { request = Request(entryID: entryID) }
}

/// What keeps a following thread on its tail besides the follower's own scrolling.
///
/// The scroll view itself: a bottom `defaultScrollAnchor` for the initial offset and for size
/// changes while following, so streamed text and a settling turn move the view with no `scrollTo`
/// (which builds every row of a long thread). That anchor over a lazy stack of estimated row
/// heights once left the scroll view with a content size that disagreed with where the rows were
/// placed, and the viewport drew nothing (the blank thread after a send or a finished turn;
/// `ThreadBlankScreenTests`): the thread's tail is therefore laid out eagerly
/// (`ThreadView.eagerRows`), and only the history above it is lazy; a giant reply's chunks are
/// lazy except its tail (`NativeProse.eagerTail`), and `ThreadBlankScreenTests` checks the blank
/// band inside them. `ThreadTailGuard` stays as the net under it (`ThreadTailFlowTests` runs the
/// thread with and without the anchor).
struct ThreadTailAnchor: ViewModifier {
    let sticky: Bool
    let native: Bool
    /// A released thread's rows are coming back (`ThreadRestore`): the first frame draws only its last screen, which may be shorter
    /// than the window, and the rows above it join over the frames after.
    var restoring = false

    /// The scroll view keeps the tail itself, as the follower's `nativeAnchor` says.
    static let isNative = true

    @ViewBuilder func body(content: Content) -> some View {
        if native {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                // While stuck, growth keeps the tail pinned without any scrollTo; detaching only
                // ever happens on user scroll intent.
                .defaultScrollAnchor(sticky ? .bottom : nil, for: .sizeChanges)
                // Content shorter than the window rests at the bottom of it while the rows above come back, not at the top with
                // a blank band under it that the rest then pushes the end of the thread out of. A thread whose rows are all
                // drawn rests where it always did.
                .defaultScrollAnchor(restoring ? .bottom : nil, for: .alignment)
        } else {
            content
                // Detached, a shrinking live reply must not move the reader beyond its rows.
                // While following, leave size anchoring to the existing follower and guard.
                .defaultScrollAnchor(sticky ? nil : .top, for: .sizeChanges)
        }
    }
}

/// Whether the thread's last pass drew with a live resize running (`ThreadView.eagerCount`).
/// A reference, so keeping it current in a render redraws nothing.
@MainActor
final class LiveResizeGate {
    var wasLive = false
    /// What the window's height asks the tail to cover as last measured (`ThreadView.eagerCover` follows it, but for a drag's widening).
    var cover = 0
}

/// Measured insets, read by the composer and padding rather than the transcript builder.
@MainActor
@Observable
final class ComposerInset {
    var height: CGFloat = 120
    var gutter = AppLayout.gutter
}

private struct ThreadGutterPadding: ViewModifier {
    let inset: ComposerInset
    let fixedGutter: CGFloat?

    func body(content: Content) -> some View {
        content.padding(.horizontal, fixedGutter ?? inset.gutter)
    }
}

/// Reserves the floating composer and the transcript's breathing room above it.
struct ComposerInsetPadding: ViewModifier {
    let inset: ComposerInset
    /// The space between the last turn and the composer's card: 24pt. A Project's threads add none: the column's own 16pt spacing already
    /// separates the last turn from the 1pt anchor row after it, which is the board's 16pt gap to the card.
    var gap = AppLayout.composerTranscriptGap
    /// False while the thread draws no composer: nothing floats over the transcript, so nothing is reserved for it.
    var present = true

    func body(content: Content) -> some View {
        content.safeAreaPadding(.bottom, present ? inset.height + gap : 0)
    }
}

/// A reply to a design comment, inside the comment's card above it.
private struct CommentAnswer: ViewModifier {
    let inCard: Bool

    func body(content: Content) -> some View {
        if inCard {
            content.shCommentAnswer(bridge: AppLayout.turnSpacing)
        } else {
            content
        }
    }
}

/// One thread row, drawn over the rows after it while a design reference's preview in it is open
/// (`ReferencePreviewOpenKey`), so a preview that opens below its chip stays on top.
private struct ThreadRowLayer<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var raised = false

    var body: some View {
        VStack(spacing: 0) { content }
            .onPreferenceChange(ReferencePreviewOpenKey.self) { open in
                MainActor.assumeIsolated { if raised != open { raised = open } }
            }
            .zIndex(raised ? 1 : 0)
    }
}
