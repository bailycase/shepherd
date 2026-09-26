import SwiftUI
import AppKit
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// What the Changes pane can ask of its host (local agents and remote agents differ).
struct ReviewActions {
    /// A legacy review's Local | PR (the scope menu's two entries there).
    var setPullRequest: (Bool) -> Void
    /// Send the comments as the agent's next turn (queued if it is mid-turn).
    var requestChanges: () -> Void
    /// Ask the agent to commit what is under review.
    var commit: () -> Void
    var close: () -> Void
    /// Local reviews only: discard a file's changes (confirmed first) in the directory its diff
    /// came from, open it in an editor.
    var revert: ((DiffFile, _ cwd: String) -> Void)? = nil
    var open: ((DiffFile) -> Void)? = nil
    /// Return keyboard focus to the thread's composer (esc).
    var focusThread: () -> Void = {}
    /// Whether the host commits from review (a local review, or a remote host that advertises it).
    var canCommitDirectly: () -> Bool = { false }
    /// The Commit… sheet's store, kept by the view model while its commit runs.
    var commitStore: () -> ReviewCommitStore? = { nil }
    /// The Commit… sheet closed: a finished commit reloads the review.
    var commitClosed: () -> Void = {}
    /// Changes reviews: pick a scope, a base, options; reload; fetch a file whole; the base
    /// picker's branches; copy the diff as a patch (or a `git apply` command).
    var setScope: (ChangesScope) -> Void = { _ in }
    var setOptions: (ChangesOptions) -> Void = { _ in }
    var refresh: () -> Void = {}
    var loadWholeFile: (String) -> Void = { _ in }
    var loadBranches: () -> Void = {}
    var copyPatch: (_ asCommand: Bool) -> Void = { _ in }
    /// Drop the unsent comments.
    var discard: () -> Void = {}
    /// The pane over the whole layout (ChangesWide), and back.
    var toggleMaximized: (() -> Void)? = nil
}

/// Where a review sits: the side pane's Changes tab, or a layout pane of its own (an older host's
/// review leaf), under a "Review" header with its close.
enum ReviewChrome {
    case tab, header
}

/// The Changes pane (ChangesSplit, ChangesScope, ChangesBase, ChangesUnified, ChangesLastTurn,
/// ChangesWide): the toolbar, the compare row, the file strip (or the file list when maximized),
/// sticky file headers over a syntax-colored diff, split or unified, with unchanged lines folded,
/// inline comments, and the send bar.
///
/// Equal when it shows the same session, touched files, turn and size: the actions are rebuilt
/// by every parent render but always act on this session, so a thread streaming beside the pane
/// never re-renders it.
struct ReviewPane: View, Equatable {
    let session: ReviewSession
    let actions: ReviewActions
    /// Files the running agent is editing right now: their chips carry a running dot.
    var touchedPaths: Set<String> = []
    var chrome: ReviewChrome = .tab
    /// The agent's latest recorded turn: a turn ending, an Undo or a Redo reloads the diff.
    var latestTurn: ChangesTurn? = nil
    var maximized = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session === rhs.session && lhs.touchedPaths == rhs.touchedPaths && lhs.chrome == rhs.chrome
            && lhs.latestTurn == rhs.latestTurn && lhs.maximized == rhs.maximized
    }

    var body: some View {
        // A review retargeted at another repository starts over: folds, the comment being
        // edited, the current file, and syntax colors all belonged to the old diff.
        ReviewPaneContent(session: session, actions: actions, touchedPaths: touchedPaths, chrome: chrome, maximized: maximized)
            .id(Identity(session: session.id, cwd: session.cwd))
            .onChange(of: latestTurn) { old, turn in
                guard let turn, old != turn, session.engine != nil else { return }
                ChangesFollow.turnChanged(session, old: old, turn: turn, actions: actions)
            }
    }

    private struct Identity: Hashable {
        let session: UUID
        let cwd: String
    }
}

/// How the pane follows the agent's turns: a turn that ends, is undone or redone reloads a scope
/// it can change; the agent's reply to a sent review turns the pane to Last turn.
@MainActor
enum ChangesFollow {
    static func turnChanged(_ session: ReviewSession, old: ChangesTurn?, turn: ChangesTurn, actions: ReviewActions) {
        let settled = turn.state != .running && (old?.id != turn.id || old?.state != turn.state)
        guard settled else { return }
        if let sentAt = session.sentAt, turn.startedAt >= sentAt, !session.scopeChosen {
            session.sentAt = nil
            actions.setScope(.lastTurn)
            return
        }
        if session.scope.comparesWorkingTree || session.scope.kind == .lastTurn { actions.refresh() }
    }
}

/// The pane beside a thread: observes the agent's thread for the files it is editing and its
/// latest recorded turn.
struct ReviewPaneHost: View {
    let session: ReviewSession
    let actions: ReviewActions
    var store: NativeThreadStore
    var maximized = false
    @State private var touched = ReviewTouchedPaths()

    var body: some View {
        ReviewPane(session: session, actions: actions,
                   touchedPaths: touched.paths(store.messages, running: store.hostRunning),
                   latestTurn: store.snapshot?.turnChanges?.last, maximized: maximized)
    }
}

/// The pane for one session; its state lives in `ReviewPaneModel`.
struct ReviewPaneContent: View {
    let session: ReviewSession
    let touchedPaths: Set<String>
    let chrome: ReviewChrome
    let maximized: Bool
    @State private var model: ReviewPaneModel
    @FocusState private var commentFocused: Bool
    /// Where the compare row's base button sits, for the base picker under it.
    @State private var baseAnchor: CGFloat = 0

    init(session: ReviewSession, actions: ReviewActions, touchedPaths: Set<String>, chrome: ReviewChrome = .tab, maximized: Bool = false) {
        self.init(model: ReviewPaneModel(session: session, actions: actions), touchedPaths: touchedPaths, chrome: chrome, maximized: maximized)
    }

    /// A pane over a model the caller holds (tests drive it as the pane's own controls do).
    init(model: ReviewPaneModel, touchedPaths: Set<String> = [], chrome: ReviewChrome = .tab, maximized: Bool = false) {
        session = model.session
        self.touchedPaths = touchedPaths
        self.chrome = chrome
        self.maximized = maximized
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            if chrome == .header {
                NWPaneHeader("Review", closeLabel: "Close review", close: model.actions.close) {
                    Text(session.scopeTitle).truncationMode(.middle)
                } controls: {
                    EmptyView()
                }
            }
            ChangesToolbar(model: model, session: session)
            ChangesCompare(model: model, session: session, baseAnchor: $baseAnchor)
            if !maximized, !session.files.isEmpty {
                ReviewFileStrip(model: model, session: session, touchedPaths: touchedPaths)
                    .nwTransition(.content)
            }
            HStack(spacing: 0) {
                if maximized, !session.files.isEmpty {
                    ChangesFileListColumn(model: model, session: session)
                }
                ReviewBody(model: model, session: session, commentFocused: $commentFocused)
            }
            ChangesSendBar(session: session, actions: model.actions)
        }
        .overlay(alignment: .topLeading) { ChangesMenus(model: model, session: session, baseAnchor: baseAnchor) }
        // Loading, the diff, "No changes", and an error cross-fade, as does one scope's diff for
        // another; a reload of the same scope changes in place.
        .nwAnimation(.content, value: ReviewBody.Content(session))
        .nwAnimation(.content, value: session.comments.isEmpty)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.noteWidth($0) }
        // Controls read focus from their nearest focusable ancestor: without this boundary the
        // focused pane would draw every button's focus ring.
        .focusable(false)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handle(press) }
        .background(Color.nw.bgWindow)
        .modifier(RevertConfirmation(model: model))
        .modifier(CommitSheetPresenter(model: model))
        // The side pane's ⋯ menu folds and unfolds this pane's files.
        .onAppear { session.paneModel = model }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chrome == .tab ? "Changes" : "Review")
    }

    /// The pane's keys (ChangesStates › Keys): j/k files, n/p changes, v viewed, c comment, ⌥U
    /// split or unified, ⌘E the scope menu, ⇧⌘O open in your editor, esc a menu or the thread.
    /// None while a comment is being written.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape {
            if model.menu != nil { model.closeMenu() } else { model.actions.focusThread() }
            return .handled
        }
        guard !commentFocused else { return .ignored }
        let key = press.key.character.lowercased()
        let modifiers = press.modifiers.intersection([.command, .shift, .option, .control])
        switch modifiers {
        case []:
            guard model.menu == nil else { return .ignored }
            return model.handleKey(key) ? .handled : .ignored
        case .option:
            return model.handleKey(key, option: true) || press.characters == "¨" && model.handleKey("u", option: true) ? .handled : .ignored
        case .command where key == "e":
            model.toggleMenu(.scope)
            return .handled
        case [.command, .shift] where key == "o":
            guard let open = model.actions.open, let file = session.files.first(where: { $0.id == model.currentFile }) ?? session.files.first
            else { return .ignored }
            open(file)
            return .handled
        default:
            return .ignored
        }
    }
}

/// Per-file Revert, confirmed first (local reviews of the working tree only).
private struct RevertConfirmation: ViewModifier {
    @Bindable var model: ReviewPaneModel

    func body(content: Content) -> some View {
        content.sheet(item: $model.reverting) { file in
            RevertFileDialog(path: file.displayPath, repository: (model.cwd as NSString).abbreviatingWithTildeInPath, isNew: file.isNew,
                             revert: { model.actions.revert?(file, model.cwd); model.reverting = nil },
                             cancel: { model.reverting = nil })
        }
    }
}

/// Commit…: the commit sheet over the pane, until it is closed.
private struct CommitSheetPresenter: ViewModifier {
    @Bindable var model: ReviewPaneModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { model.commitStore != nil }, set: { if !$0 { close() } })) {
            if let store = model.commitStore {
                ReviewCommitSheet(store: store, askAgent: model.actions.commit, close: close)
            }
        }
    }

    private func close() {
        guard model.commitStore != nil else { return }
        model.commitStore = nil
        model.actions.commitClosed()
    }
}

// MARK: Toolbar

/// The toolbar (ChangesToolbar): the scope button and the scope's diff stat; then "2/5 viewed",
/// Commit…, and Refresh, Collapse all, the split toggle and More as circles.
private struct ChangesToolbar: View, Equatable {
    @Bindable var model: ReviewPaneModel
    let session: ReviewSession

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.session === rhs.session }

    var body: some View {
        let _ = NWRenderProbe.tick("review.toolbar")
        let files = session.files.count
        HStack(spacing: 10) {
            NWScopeButton(title: ChangesText.scopeButton(session), glyph: session.engine == nil ? (session.isPRMode ? .pullRequest : .uncommitted) : session.scope.glyph,
                          isOpen: model.menu == .scope || model.menu == .commits) { model.toggleMenu(.scope) }
            if !(session.isLoading && session.files.isEmpty) {
                NWDiffStat(added: session.list?.added ?? session.addedCount, removed: session.list?.removed ?? session.removedCount, font: .nw(.code))
                    .nwContentTransition(.crossFade)
            }
            Spacer(minLength: NW.Space.m)
            // A narrow pane drops the viewed count, then Commit…'s label.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    if files > 0 { viewedPill(files) }
                    commitButton(label: true)
                }
                commitButton(label: true)
                commitButton(label: false)
            }
            HStack(spacing: NW.Space.xxs) {
                Button { model.actions.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.nwIcon(size: NWChangesMetrics.toolbarIcon))
                    .disabled(session.isLoading)
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
                Button { model.toggleAllFolded() } label: {
                    Image(systemName: model.allFolded ? "arrow.up.and.line.horizontal.and.arrow.down" : "arrow.down.and.line.horizontal.and.arrow.up")
                }
                .buttonStyle(.nwIcon(size: NWChangesMetrics.toolbarIcon))
                .disabled(files == 0)
                .help(model.allFolded ? "Expand all files" : "Collapse all files")
                .accessibilityLabel(model.allFolded ? "Expand all files" : "Collapse all files")
                // The toggle shows the layout it switches to.
                Button { model.toggleLayout() } label: {
                    Image(systemName: model.layout == .split ? "rectangle" : "rectangle.split.2x1")
                }
                .buttonStyle(.nwIcon(size: NWChangesMetrics.toolbarIcon))
                .help(model.layout == .split ? "Switch to unified diff (⌥U)" : "Switch to split diff (⌥U)")
                .accessibilityLabel(model.layout == .split ? "Switch to unified diff" : "Switch to split diff")
                Button { model.toggleMenu(.options) } label: { Image(systemName: "ellipsis") }
                    .buttonStyle(.nwIcon(isOn: model.menu == .options, size: NWChangesMetrics.toolbarIcon))
                    .help("Diff options")
                    .accessibilityLabel("Diff options")
            }
        }
        .padding(.leading, NW.Space.l)
        .padding(.trailing, 10)
        .frame(height: NWChangesMetrics.toolbarHeight)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
    }

    private func viewedPill(_ files: Int) -> some View {
        NWViewedPill(viewed: session.viewed.intersection(session.files.map(\.id)).count, total: files)
    }

    @ViewBuilder private func commitButton(label: Bool) -> some View {
        Button { commit() } label: {
            if label {
                Label("Commit…", systemImage: "smallcircle.filled.circle")
            } else {
                Image(systemName: "smallcircle.filled.circle")
            }
        }
        .buttonStyle(.nw(.secondary, size: .s))
        .fixedSize()
        .disabled(!canCommit)
        .help(canCommit ? "Commit these changes" : "Commit works on the working tree: pick Uncommitted or Branch")
        .accessibilityLabel("Commit…")
    }

    private var canCommit: Bool {
        guard !session.isSubmitting, !session.files.isEmpty else { return false }
        return session.engine == nil ? !session.isPRMode : session.scope.comparesWorkingTree
    }

    /// The sheet where the host commits from review; otherwise the agent is asked to.
    private func commit() {
        if model.actions.canCommitDirectly() { model.commitStore = model.actions.commitStore() } else { model.actions.commit() }
    }
}

/// The compare row under the toolbar (CompareRow): head → base, the base a picker on Branch; a
/// turn's times and prompt on Last turn.
private struct ChangesCompare: View {
    let model: ReviewPaneModel
    let session: ReviewSession
    @Binding var baseAnchor: CGFloat

    var body: some View {
        if let lead = ChangesText.compareLead(session) {
            let picks = session.engine != nil && session.scope.kind == .branch
            NWCompareRow(lead, note: session.list?.comparison.mergeBase.map { "merge base \($0)" }, pickerOpen: model.menu == .base,
                         pickBase: picks ? { toggleBase() } : nil)
                // The picker hangs from the base button, which follows the head's width.
                .background(alignment: .leading) { BaseAnchorReader(lead: lead, anchor: $baseAnchor) }
                .nwTransition(.content)
        }
    }

    private func toggleBase() {
        if model.menu != .base, session.branches == nil { model.actions.loadBranches() }
        model.toggleMenu(.base)
    }
}

/// Measures where the base button starts: the head's text, the arrow, and their gaps.
private struct BaseAnchorReader: View {
    let lead: NWCompareRow.Lead
    @Binding var anchor: CGFloat

    var body: some View {
        if case .compare(let head, _) = lead {
            HStack(spacing: NW.Space.m) {
                Text(head).font(.nw(.mono)).lineLimit(1)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium))
            }
            .padding(.leading, NW.Space.l)
            .fixedSize()
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width + NW.Space.m } action: { anchor = $0 }
        }
    }
}

/// The pane's copy that depends on the scope.
@MainActor
enum ChangesText {
    static func scopeButton(_ session: ReviewSession) -> String {
        guard session.engine != nil else { return session.isPRMode ? "Pull request" : session.reference ?? "Uncommitted" }
        if case .commits(let first, let last) = session.scope, first == last, !first.isEmpty { return "Commit" }
        return session.scope.label
    }

    static func compareLead(_ session: ReviewSession) -> NWCompareRow.Lead? {
        let directory = session.otherDirectoryName.map { "\($0) · " } ?? ""
        guard session.engine != nil else {
            if session.isPRMode { return .compare(head: directory + "HEAD", base: session.reference ?? "the PR's base") }
            return .compare(head: directory + "Working tree", base: session.reference ?? "HEAD")
        }
        guard let list = session.list else { return nil }
        let comparison = list.comparison
        if let turn = comparison.turn, list.scope.kind == .lastTurn {
            let title = list.scope == .lastTurn ? "The agent’s last turn" : "The agent’s turn"
            return .turn(title: title, detail: turnDetail(turn))
        }
        return .compare(head: directory + comparison.head, base: comparison.base)
    }

    /// "3:07–3:11 PM · after “Wrap errors with context”"; "since 3:07 PM" while it runs.
    static func turnDetail(_ turn: ChangesTurn) -> String {
        let times = turn.endedAt.map { changesTimeRange(start: turn.startedAt, end: $0) } ?? "since \(nativeClockText(turn.startedAt))"
        guard let prompt = turn.prompt?.split(separator: "\n").first.map(String.init), !prompt.isEmpty else { return times }
        return "\(times) · after “\(prompt)”"
    }

    /// What "No changes" says for the scope on screen.
    static func emptyMessage(_ session: ReviewSession) -> String {
        guard session.engine != nil else {
            if session.isPRMode { return "This branch matches its PR base." }
            return session.reference.map { "\($0) has no changes." } ?? "The working tree matches HEAD."
        }
        switch session.scope {
        case .lastTurn, .turn: return "The agent’s turn changed no files."
        case .uncommitted: return "The working tree matches HEAD."
        case .unstaged: return "Nothing is unstaged."
        case .staged: return "Nothing is staged."
        case .commits: return "These commits change no files."
        case .branch: return "This branch matches \(session.list?.comparison.baseName ?? "its base")."
        case .pullRequest: return "This branch matches its PR base."
        }
    }
}

/// "3:07–3:11 PM" when both times share a half of the day, else "11:58 AM–12:04 PM".
func changesTimeRange(start: Double, end: Double) -> String {
    let first = nativeClockText(start), last = nativeClockText(end)
    let suffixes = [" AM", " PM"]
    if let suffix = suffixes.first(where: { first.hasSuffix($0) && last.hasSuffix($0) }) {
        return "\(first.dropLast(suffix.count))–\(last)"
    }
    return "\(first)–\(last)"
}

// MARK: File strip and list

private struct ReviewFileStrip: View {
    let model: ReviewPaneModel
    let session: ReviewSession
    let touchedPaths: Set<String>

    var body: some View {
        NWFileStrip(items, selection: model.currentFile, animatesSelection: !model.movedByKey) { model.select($0) }
            .overlay(alignment: .bottom) { NWHairline() }
    }

    private var items: [NWFileStrip.Item] {
        let listed = Dictionary((session.list?.files ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return session.files.map { file in
            let entry = listed[file.id]
            return NWFileStrip.Item(id: file.id, path: file.displayPath, status: entry?.nwStatus ?? file.reviewStatus,
                                    added: entry?.added ?? file.addedCount, removed: entry?.removed ?? file.removedCount,
                                    isViewed: session.viewed.contains(file.id),
                                    isTouched: touchedPaths.contains { reviewFile(matching: $0, in: [file]) != nil })
        }
    }
}

/// The maximized pane's file list (ChangesWide).
private struct ChangesFileListColumn: View {
    let model: ReviewPaneModel
    let session: ReviewSession

    var body: some View {
        let listed = Dictionary((session.list?.files ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = session.files.map { file in
            let entry = listed[file.id]
            return NWChangesFileList.Item(id: file.id, path: file.displayPath, status: entry?.nwStatus ?? file.reviewStatus,
                                          added: entry?.added ?? file.addedCount, removed: entry?.removed ?? file.removedCount,
                                          comments: session.commentsByFile[file.id]?.count ?? 0, isViewed: session.viewed.contains(file.id))
        }
        NWChangesFileList(items, added: session.list?.added ?? session.addedCount, removed: session.list?.removed ?? session.removedCount,
                          selection: model.currentFile) { model.select($0) }
            .nwTransition(.content)
    }
}

// MARK: Diff

/// The diff, or its loading, empty, and error states.
private struct ReviewBody: View, Equatable {
    let model: ReviewPaneModel
    let session: ReviewSession
    var commentFocused: FocusState<Bool>.Binding

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.session === rhs.session }

    /// What the body shows.
    enum Content: Equatable {
        case error, loading, empty
        /// The diff of one scope, so switching scopes swaps the whole list.
        case diff(scope: String)

        @MainActor init(_ session: ReviewSession) {
            if session.loadError != nil { self = .error }
            else if session.isLoading && session.files.isEmpty { self = .loading }
            else if session.files.isEmpty { self = .empty }
            else { self = .diff(scope: session.engine == nil ? (session.filesArePR ? "pr" : "local") : session.list?.title ?? "") }
        }
    }

    var body: some View {
        // Overlaid, so the state leaving and the one arriving cross-fade in the same place.
        ZStack {
            switch Content(session) {
            case .error:
                ChangesErrorView(message: session.loadError ?? "", notice: session.loadErrorIsNotice ? ChangesText.scopeButton(session) : nil)
                    .nwTransition(.content)
            case .loading:
                HStack(spacing: NW.Space.m) {
                    ProgressView().progressViewStyle(.nwSpinner(size: AppLayout.reviewLoadingSpinner))
                    Text("Loading the diff…").font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .nwTransition(.content)
            case .empty:
                NWEmptyState(Text("No changes"), message: ChangesText.emptyMessage(session), showsMark: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .nwTransition(.content)
            case .diff(let scope):
                ReviewDiffList(model: model, session: session, commentFocused: commentFocused)
                    .id(scope)
                    .nwTransition(.content)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A load that failed: a scope that can't be compared here ("No turn yet.") reads as a quiet
/// note, anything else as a failed banner.
private struct ChangesErrorView: View {
    let message: String
    /// The scope's name when there is nothing to compare rather than a failure.
    let notice: String?

    var body: some View {
        if let notice {
            NWEmptyState(Text("Nothing to compare"), message: "\(notice): \(message)", showsMark: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NWBanner(.failed, title: message)
                .padding(NW.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct ReviewDiffList: View, Equatable {
    let model: ReviewPaneModel
    let session: ReviewSession
    var commentFocused: FocusState<Bool>.Binding

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.session === rhs.session }

    var body: some View {
        let _ = NWRenderProbe.tick("review.diffList")
        let canRevert = model.actions.revert != nil && (session.engine == nil ? !session.isPRMode : session.scope == .uncommitted)
        let canOpen = model.actions.open != nil
        let listed = Dictionary((session.list?.files ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(session.files) { file in
                        let folded = model.isFolded(file.id)
                        DiffFileSection(
                            model: model, file: file, status: listed[file.id]?.nwStatus ?? file.reviewStatus,
                            rows: folded ? [] : model.rows(for: file),
                            comments: session.commentsByFile[file.id] ?? [:],
                            editingLine: model.editing?.fileID == file.id ? model.editing?.lineID : nil,
                            isFolded: folded, isViewed: session.viewed.contains(file.id),
                            canRevert: canRevert, canOpen: canOpen, commentFocused: commentFocused
                        )
                    }
                }
                // A reload of the same scope (after a Revert, a refresh) lands at once: easing the
                // sections' offsets under pinned headers mid-scroll opens and closes blank gaps.
                .nwAnimation(.disclosure, value: model.disclosures)
            }
            .modifier(ReviewScrollFollower(model: model, session: session, proxy: proxy))
        }
        .task(id: session.files) { await model.highlightFiles(style: .theme) }
        .onAppear { if model.currentFile == nil { model.currentFile = session.files.first?.id } }
    }
}

/// A file header that knows when it sits at the top of the list, pinned over its file's rows
/// (the first one at rest, then whichever file scrolls under it): only then does it cast its
/// shadow. The check reruns the header only when the answer flips, never per scroll step.
private struct PinnedFileHeader<Header: View>: View {
    @ViewBuilder let header: (Bool) -> Header
    @State private var pinned = false

    var body: some View {
        header(pinned)
            .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).minY <= 0.5 } action: { pinned = $0 }
    }
}

/// Scrolls the diff to a requested file (the strip, j/k, a "review ›" link) or change (n/p). Its
/// own view, so the requests it watches never re-render the list. A click or a link scrolls
/// there; keyboard navigation lands at once.
private struct ReviewScrollFollower: ViewModifier {
    let model: ReviewPaneModel
    let session: ReviewSession
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        content
            .onChange(of: session.focusRequest) { _, _ in scrollToFocus(animated: true) }
            // A file asked for before the diff loaded: the diff opens there.
            .onChange(of: session.files) { _, _ in scrollToFocus(animated: false) }
            .onChange(of: model.currentChange) { _, change in
                if let change { proxy.scrollTo(change, anchor: .top) }
            }
            .onAppear { DispatchQueue.main.async { scrollToFocus(animated: false) } }
    }

    private func scrollToFocus(animated: Bool) {
        guard let id = model.takeFocusRequest() else { return }
        if animated, !model.movedByKey {
            withNWAnimation(.scroll) { proxy.scrollTo(id, anchor: .top) }
        } else {
            proxy.scrollTo(id, anchor: .top)
        }
    }
}

/// One file: its pinned header and rows. Equal when nothing it draws changed, so a comment or a
/// fold in one file never re-renders the others.
private struct DiffFileSection: View, Equatable {
    let model: ReviewPaneModel
    let file: DiffFile
    let status: NWFileStatus
    let rows: [NWChangesRow]
    let comments: [Int: ReviewComment]
    let editingLine: Int?
    let isFolded: Bool
    let isViewed: Bool
    let canRevert: Bool
    let canOpen: Bool
    var commentFocused: FocusState<Bool>.Binding

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.file == rhs.file && lhs.status == rhs.status && lhs.rows == rhs.rows && lhs.comments == rhs.comments
            && lhs.editingLine == rhs.editingLine && lhs.isFolded == rhs.isFolded && lhs.isViewed == rhs.isViewed
            && lhs.canRevert == rhs.canRevert && lhs.canOpen == rhs.canOpen
    }

    var body: some View {
        let _ = NWRenderProbe.tick("review.section")
        Section {
            // Where the file's rows start: a fold eases only while the file sits in its place.
            Color.clear.frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { model.noteRowsTop($0, of: file.id) }
            if !isFolded {
                // A comment on the whole file sits under its header.
                if let note = notes[ReviewSession.fileLineID] {
                    annotation(nil, note)
                        .padding(NWDiffMetrics.annotationInsets)
                        .overlay(alignment: .bottom) { NWHairline() }
                }
                NWDiffView(rows, notes: notes, onComment: file.isBinary ? nil : { model.startComment(fileID: file.id, lineID: $0.key) },
                           onReveal: { model.reveal($0, $1, in: file.id) }) { line, note in
                    annotation(line, note)
                }
            }
        } header: {
            PinnedFileHeader { pinned in
                NWFileHeader(path: file.displayPath, status: status, added: file.addedCount, removed: file.removedCount,
                             isExpanded: !isFolded, isViewed: isViewed,
                             toggle: { model.toggleFolded(file.id) }, toggleViewed: { model.toggleViewed(file.id) },
                             comment: { model.startFileComment(file.id) },
                             open: canOpen ? { model.actions.open?(file) } : nil, isPinned: pinned)
            }
                .contentShape(Rectangle())
                .onTapGesture { model.point(at: file.id) }
                .contextMenu {
                    Button("Show Whole File") { model.revealWholeFile(file.id) }
                        .disabled(file.isBinary)
                    if canRevert {
                        Button("Revert File…") { model.reverting = file }
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(file.displayPath, forType: .string)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.noteHeaderHeight($0) }
        }
    }

    /// What shows under each line: its comment, or the editor on the line being commented.
    private var notes: [Int: ReviewLineNote] {
        var notes = comments.mapValues(ReviewLineNote.comment)
        if let editingLine { notes[editingLine] = .editing(initialText: comments[editingLine]?.text ?? "") }
        return notes
    }

    @ViewBuilder private func annotation(_ line: NWDiffLineContent?, _ note: ReviewLineNote) -> some View {
        let lineID = line?.key ?? ReviewSession.fileLineID
        let place = line.flatMap(\.number).map { "line \($0)" } ?? "the file"
        switch note {
        case .editing(let initialText):
            ReviewCommentEditor(initialText: initialText, context: "on \(place)", focused: commentFocused,
                                save: { model.saveComment($0, fileID: file.id, lineID: lineID) },
                                cancel: { model.cancelComment() })
                .nwTransition(.disclosure)
        case .comment(let comment):
            NWInlineComment(initial: ReviewAuthor.initial, author: "You",
                            meta: "\(comment.lineID == ReviewSession.fileLineID ? "file" : "line \(comment.lineNumber)") · \(reviewCommentAge(comment.createdAt))",
                            text: comment.text,
                            onEdit: { model.startComment(fileID: file.id, lineID: lineID) },
                            onDelete: { model.deleteComment(fileID: file.id, lineID: lineID) })
                .nwTransition(.disclosure)
        }
    }
}

/// A line's annotation in the review: its comment, or the editor writing one. Rows compare it,
/// so a comment's change redraws only its line.
enum ReviewLineNote: Equatable {
    case comment(ReviewComment)
    case editing(initialText: String)
}

/// The comment being written, with its own draft: typing re-renders only the editor.
private struct ReviewCommentEditor: View {
    @State private var draft: String
    let context: String
    var focused: FocusState<Bool>.Binding
    let save: (String) -> Void
    let cancel: () -> Void

    init(initialText: String, context: String, focused: FocusState<Bool>.Binding, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        _draft = State(initialValue: initialText)
        self.context = context
        self.focused = focused
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        NWCommentEditor(text: $draft, isFocused: focused, context: context, onSave: { save(draft) }, onCancel: cancel)
    }
}

/// The reviewer as a comment author: "You", with the account name's initial on the avatar.
enum ReviewAuthor {
    static let initial: String = NSFullUserName().first.map { String($0).uppercased() } ?? "Y"
}

// MARK: Send bar

/// "1 comment on outbox.go, not sent yet" with Discard and Send to agent (ReviewSendBar), while
/// there are unsent comments. Reads the comments on its own, so a comment saved re-renders only
/// the bar and its line.
private struct ChangesSendBar: View {
    let session: ReviewSession
    let actions: ReviewActions

    var body: some View {
        if !session.comments.isEmpty {
            let pending = reviewPendingText(session.comments)
            NWReviewSendBar(count: pending.count, detail: pending.detail, sending: session.isSubmitting,
                            onDiscard: actions.discard, onSend: actions.requestChanges)
                .nwTransition(.list, edge: .bottom)
        }
    }
}
