import SwiftUI
import AppKit
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// What the review pane can ask of its host (local agents and remote agents differ).
struct ReviewActions {
    var setPullRequest: (Bool) -> Void
    /// Send the overall and inline comments as the agent's next turn (queued if it is mid-turn).
    var requestChanges: () -> Void
    /// Ask the agent to commit what is under review.
    var commit: () -> Void
    var close: () -> Void
    /// Local reviews only: discard a file's changes (confirmed first), open it in an editor.
    var revert: ((DiffFile) -> Void)? = nil
    var open: ((DiffFile) -> Void)? = nil
    /// Return keyboard focus to the thread's composer (esc).
    var focusThread: () -> Void = {}
}

/// The review pane (Review board): a companion docked right of the thread. A header with the
/// scope and totals, the file strip, sticky file headers over a syntax-colored unified diff with
/// long runs folded, inline comments, and the review composer.
///
/// Equal when it shows the same session and touched files: the actions are rebuilt by every
/// parent render but always act on this session, so a thread streaming beside the pane never
/// re-renders it.
struct ReviewPane: View, Equatable {
    let session: ReviewSession
    let actions: ReviewActions
    /// Files the running agent is editing right now: their chips carry a running dot.
    var touchedPaths: Set<String> = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session === rhs.session && lhs.touchedPaths == rhs.touchedPaths
    }

    var body: some View {
        ReviewPaneContent(session: session, actions: actions, touchedPaths: touchedPaths)
            .id(session.id)
    }
}

/// The review pane beside a thread: observes the agent's thread for the files it is editing.
struct ReviewPaneHost: View {
    let session: ReviewSession
    let actions: ReviewActions
    var store: NativeThreadStore
    @State private var touched = ReviewTouchedPaths()

    var body: some View {
        ReviewPane(session: session, actions: actions,
                   touchedPaths: touched.paths(store.messages, running: store.snapshot?.running ?? false))
    }
}

/// The pane for one session; its state lives in `ReviewPaneModel`.
struct ReviewPaneContent: View {
    let session: ReviewSession
    let touchedPaths: Set<String>
    @State private var model: ReviewPaneModel
    @FocusState private var summaryFocused: Bool
    @FocusState private var commentFocused: Bool

    init(session: ReviewSession, actions: ReviewActions, touchedPaths: Set<String>) {
        self.init(model: ReviewPaneModel(session: session, actions: actions), touchedPaths: touchedPaths)
    }

    /// A pane over a model the caller holds (tests drive it as the pane's own controls do).
    init(model: ReviewPaneModel, touchedPaths: Set<String> = []) {
        session = model.session
        self.touchedPaths = touchedPaths
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeader(model: model, session: session)
            if !session.files.isEmpty {
                ReviewFileStrip(model: model, session: session, touchedPaths: touchedPaths)
                    .nwTransition(.content)
            }
            ReviewBody(model: model, session: session, commentFocused: $commentFocused)
            ReviewComposerBar(model: model, session: session, focused: $summaryFocused)
        }
        // Loading, the diff, "No changes", and an error cross-fade, as does one side's diff for
        // the other (Local | PR); a reload of the same side changes in place.
        .nwAnimation(.content, value: ReviewBody.Content(session))
        // Controls read focus from their nearest focusable ancestor: without this boundary the
        // focused pane would draw every button's focus ring.
        .focusable(false)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(characters: .init(charactersIn: "jknpvc")) { press in
            guard !commentFocused, !summaryFocused else { return .ignored }
            return model.handleKey(press.characters) ? .handled : .ignored
        }
        .onKeyPress(.escape) { model.actions.focusThread(); return .handled }
        .background(Color.nw.bgWindow)
        .modifier(RevertConfirmation(model: model))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review")
    }
}

/// Per-file Revert, confirmed first (local working-tree reviews only).
private struct RevertConfirmation: ViewModifier {
    @Bindable var model: ReviewPaneModel

    func body(content: Content) -> some View {
        content.sheet(item: $model.reverting) { file in
            RevertFileDialog(path: file.displayPath, isNew: file.isNew,
                             revert: { model.actions.revert?(file); model.reverting = nil },
                             cancel: { model.reverting = nil })
        }
    }
}

// MARK: Header

/// The pane header: "Review" over "4 files · +67 −58", the Local | PR control, the options
/// menu, and close.
private struct ReviewHeader: View, Equatable {
    @Bindable var model: ReviewPaneModel
    let session: ReviewSession

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.session === rhs.session }

    var body: some View {
        NWPaneHeader("Review", closeLabel: "Close review", close: model.actions.close) {
            // Cross-faded, not rolled: rolling digits through its colored runs leaves the old
            // count's ghost for most of a second.
            subtitle.truncationMode(.middle)
                .nwContentTransition(.crossFade)
                .nwAnimation(.content, value: [session.isLoading ? -1 : session.files.count, session.addedCount, session.removedCount])
        } controls: {
            NWSegmentedPicker("Diff", selection: $model.pullRequestMode, options: [(false, "Local"), (true, prLabel)], size: .s)
                .disabled(session.isLoading)
            NWOptionsMenu("Review options") {
                Button("Expand All Files") { model.expandAllFiles() }
                Button("Collapse All Files") { model.collapseAllFiles() }
                Divider()
                Button("Copy Review as Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(formatReview(files: session.files, comments: session.comments, summary: session.summary,
                                                                reference: session.reference), forType: .string)
                }
            }
            .nwHelp("Review options")
        }
    }

    private var prLabel: String {
        guard session.isPRMode, let reference = session.reference else { return "PR" }
        return "PR · \(reference)"
    }

    /// "4 files · +67 −58", led by a reference the agent asked for ("main..HEAD · …").
    private var subtitle: Text {
        let scope = !session.isPRMode ? session.reference.map { "\($0) · " } ?? "" : ""
        if session.isLoading { return Text("\(scope)loading…") }
        let count = session.files.count
        if count == 0 { return Text("\(scope)0 files") }
        let added = Text("+\(session.addedCount)").foregroundStyle(Color.nw.done)
        let removed = Text("\u{2212}\(session.removedCount)").foregroundStyle(Color.nw.failed)
        return Text("\(scope)\(count) file\(count == 1 ? "" : "s") · \(added) \(removed)")
    }
}

// MARK: File strip

private struct ReviewFileStrip: View {
    let model: ReviewPaneModel
    let session: ReviewSession
    let touchedPaths: Set<String>

    var body: some View {
        NWFileStrip(items, selection: model.currentFile, animatesSelection: !model.movedByKey) { model.select($0) }
            .overlay(alignment: .bottom) { NWHairline() }
    }

    private var items: [NWFileStrip.Item] {
        session.files.map { file in
            NWFileStrip.Item(id: file.id, path: file.displayPath, status: file.reviewStatus, added: file.addedCount, removed: file.removedCount,
                             isViewed: session.viewed.contains(file.id),
                             isTouched: touchedPaths.contains { reviewFile(matching: $0, in: [file]) != nil })
        }
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
        /// The diff of one side (`pr`: the PR's), so switching sides swaps the whole list.
        case diff(pr: Bool)

        @MainActor init(_ session: ReviewSession) {
            if session.loadError != nil { self = .error }
            else if session.isLoading && session.files.isEmpty { self = .loading }
            else if session.files.isEmpty { self = .empty }
            else { self = .diff(pr: session.filesArePR) }
        }
    }

    var body: some View {
        // Overlaid, so the state leaving and the one arriving cross-fade in the same place.
        ZStack {
            switch Content(session) {
            case .error:
                NWBanner(.failed, title: session.loadError ?? "")
                    .padding(NW.Space.l)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .nwTransition(.content)
            case .loading:
                HStack(spacing: NW.Space.m) {
                    ProgressView().progressViewStyle(.nwSpinner(size: AppLayout.reviewLoadingSpinner))
                    Text("Loading the diff…").font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .nwTransition(.content)
            case .empty:
                NWEmptyState(Text("No changes"), message: emptyMessage, showsMark: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .nwTransition(.content)
            case .diff(let pr):
                ReviewDiffList(model: model, session: session, commentFocused: commentFocused)
                    .id(pr)
                    .nwTransition(.content)
            }
        }
    }

    private var emptyMessage: String {
        if session.isPRMode { return "This branch matches its PR base." }
        return session.reference.map { "\($0) has no changes." } ?? "The working tree matches HEAD."
    }
}

private struct ReviewDiffList: View, Equatable {
    let model: ReviewPaneModel
    let session: ReviewSession
    var commentFocused: FocusState<Bool>.Binding

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.session === rhs.session }

    var body: some View {
        let canRevert = model.actions.revert != nil && !session.isPRMode
        let canOpen = model.actions.open != nil
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(session.files) { file in
                        let folded = model.isFolded(file.id)
                        DiffFileSection(
                            model: model, file: file, rows: folded ? [] : model.rows(for: file),
                            comments: session.commentsByFile[file.id] ?? [:],
                            editingLine: model.editing?.fileID == file.id ? model.editing?.lineID : nil,
                            isFolded: folded, isViewed: session.viewed.contains(file.id),
                            canRevert: canRevert, canOpen: canOpen, commentFocused: commentFocused
                        )
                    }
                }
                .nwAnimation(.disclosure, value: model.disclosures)
                // A file leaving (reverted) or arriving on a reload of the same side.
                .nwAnimation(.list, value: session.files.map(\.id))
            }
            .modifier(ReviewScrollFollower(model: model, session: session, proxy: proxy))
        }
        .task(id: session.files) { await model.highlightFiles(style: .theme) }
        .onAppear { if model.currentFile == nil { model.currentFile = session.files.first?.id } }
    }
}

/// Scrolls the diff to a requested file (the strip, n/p, a "review ›" link) or hunk (j/k). Its
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
            .onChange(of: model.currentHunk) { _, hunk in
                if let hunk { proxy.scrollTo(hunk, anchor: .top) }
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
    let rows: [NWDiffRow]
    let comments: [Int: ReviewComment]
    let editingLine: Int?
    let isFolded: Bool
    let isViewed: Bool
    let canRevert: Bool
    let canOpen: Bool
    var commentFocused: FocusState<Bool>.Binding

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.file == rhs.file && lhs.rows == rhs.rows && lhs.comments == rhs.comments
            && lhs.editingLine == rhs.editingLine && lhs.isFolded == rhs.isFolded && lhs.isViewed == rhs.isViewed
            && lhs.canRevert == rhs.canRevert && lhs.canOpen == rhs.canOpen
    }

    var body: some View {
        Section {
            if !isFolded {
                if file.isBinary {
                    Text("Binary file")
                        .font(.nw(.caption))
                        .foregroundStyle(Color.nw.textTertiary)
                        .padding(.vertical, NW.Space.m)
                        .padding(.leading, NWDiffMetrics.annotationLeading)
                } else {
                    NWDiffView(rows, onComment: { model.startComment(fileID: file.id, lineID: $0.key) },
                               onExpand: { model.expandFold($0, in: file.id) }, onExpandFile: { model.expandFile(file.id) }) { line in
                        annotation(line)
                    }
                }
            }
        } header: {
            NWFileHeader(path: file.displayPath, hunkCount: file.hunks.count, commentCount: comments.count,
                         isExpanded: !isFolded, isViewed: isViewed,
                         toggle: { model.toggleFolded(file.id) }, toggleViewed: { model.toggleViewed(file.id) },
                         revert: canRevert ? { model.reverting = file } : nil,
                         open: canOpen ? { model.actions.open?(file) } : nil)
                .contentShape(Rectangle())
                .onTapGesture { model.point(at: file.id) }
        }
    }

    @ViewBuilder private func annotation(_ line: NWDiffLineContent) -> some View {
        if editingLine == line.key {
            ReviewCommentEditor(initialText: comments[line.key]?.text ?? "", focused: commentFocused,
                                save: { model.saveComment($0, fileID: file.id, lineID: line.key) },
                                cancel: { model.cancelComment() })
                .nwTransition(.disclosure)
        } else if let comment = comments[line.key] {
            NWInlineComment(initial: ReviewAuthor.initial, author: "You",
                            meta: "line \(comment.lineNumber) · \(reviewCommentAge(comment.createdAt))", text: comment.text,
                            onEdit: { model.startComment(fileID: file.id, lineID: line.key) },
                            onDelete: { model.deleteComment(fileID: file.id, lineID: line.key) })
                .nwTransition(.disclosure)
        }
    }
}

/// The comment being written, with its own draft: typing re-renders only the editor.
private struct ReviewCommentEditor: View {
    @State private var draft: String
    var focused: FocusState<Bool>.Binding
    let save: (String) -> Void
    let cancel: () -> Void

    init(initialText: String, focused: FocusState<Bool>.Binding, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        _draft = State(initialValue: initialText)
        self.focused = focused
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        NWCommentEditor(text: $draft, isFocused: focused, onSave: { save(draft) }, onCancel: cancel)
    }
}

/// The reviewer as a comment author: "You", with the account name's initial on the avatar.
enum ReviewAuthor {
    static let initial: String = NSFullUserName().first.map { String($0).uppercased() } ?? "Y"
}

// MARK: Composer

/// The review composer at the foot of the pane. Reads the summary on its own, so typing never
/// re-renders the diff.
private struct ReviewComposerBar: View, Equatable {
    let model: ReviewPaneModel
    @Bindable var session: ReviewSession
    var focused: FocusState<Bool>.Binding

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.session === rhs.session }

    var body: some View {
        let hasReview = !session.comments.isEmpty || !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        NWReviewComposer(text: $session.summary, isFocused: focused, inlineCount: session.comments.count,
                         canCommit: !session.isSubmitting && !session.files.isEmpty && !session.isPRMode,
                         canRequestChanges: !session.isSubmitting && hasReview,
                         onCommit: { model.actions.commit() }, onRequestChanges: { model.actions.requestChanges() })
            .padding(NW.Space.l)
            .overlay(alignment: .top) { NWHairline() }
    }
}
