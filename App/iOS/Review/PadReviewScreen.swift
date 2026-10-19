import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The Changes pane on iPad. Docked (iPadReview): the thread keeps the left and the pane takes
/// the right: its tab, the toolbar (scope, stat, viewed, Commit…, refresh, collapse all, split or
/// unified, diff options), the compare row, the file strip, then every file stacked with a
/// sticky head, unified while the pane is narrow. Full screen (iPadReviewSplit): the file list on
/// the left and the files side by side. Tapping a line opens a comment editor under it; comments
/// not yet sent wait in the send bar.
struct PadReviewScreen: View {
    let ref: AgentRef
    let file: String?
    /// An artifact to show on the Artifacts tab (a "Made an artifact" line opened on an iPad whose pane was not showing).
    var artifact: String? = nil
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let store = ReviewStores.shared.store(for: ref)
        Group {
            switch store.padLayout {
            case .docked:
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        ThreadScreen(ref: ref)
                            .environment(\.threadSidePaneOpen, true)
                            .frame(maxWidth: .infinity)
                        NWHairline(.vertical, color: Color.nw.lineStrong)
                        PadChangesPane(ref: ref, store: store, finalize: finalize, close: { dismiss() })
                            .frame(width: min(MobileLayout.reviewDockWidth, proxy.size.width * MobileLayout.reviewDockShare))
                    }
                }
            case .full:
                PadFullReview(store: store, finalize: finalize, close: { dismiss() })
            }
        }
        .onAppear {
            store.focus(file)
            if let artifact { store.padTab = .artifacts; store.artifact = artifact }
        }
        .task(id: hosts.host(ref.host)?.session) { await store.loadIfNeeded(hosts: hosts) }
        .onChange(of: store.pullRequest) { _, _ in store.refresh() }
    }

    /// Finalize for a worktree agent, presented over the review.
    private var finalize: (() -> Void)? {
        let host = hosts.host(ref.host)
        guard ReviewFinalizeGate.available(host: host, agent: host?.agent(ref.agent)) else { return nil }
        let ref = ref
        let navigator = navigator
        return { navigator.present(.review(.finalize(ref))) }
    }
}

// MARK: Docked

/// The docked pane (iPadReview, iPadPaneArtifacts): the head's tabs, then the open tab. Changes is the review; Artifacts is the files
/// the agent made in this thread, once it has made one.
private struct PadChangesPane: View {
    let ref: AgentRef
    let store: ReviewStore
    let finalize: (() -> Void)?
    let close: () -> Void
    @Environment(ThreadStores.self) private var threads
    @State private var scrollTarget: String?

    var body: some View {
        let artifacts = threads.store(for: ref).artifacts
        // A pane left on Artifacts over a thread that has none shows Changes.
        let tab: ReviewStore.PadTab = artifacts.isEmpty ? .changes : store.padTab
        VStack(spacing: 0) {
            PadPaneHeader(store: store, tab: tab, artifacts: artifacts.count, close: close)
            switch tab {
            case .changes:
                PadChangesToolbar(store: store, compact: true, finalize: finalize)
                PadCompareRow(store: store)
                if !store.entries.isEmpty {
                    NWTouchFileStrip(store.chips, selection: store.currentFile) { id in
                        store.clearSelection()
                        store.currentFile = id
                        scrollTarget = id
                    }
                }
                PadChangesStack(store: store, scrollTarget: $scrollTarget)
                PadSendBar(store: store, close: close)
            case .artifacts:
                PadArtifactsPane(ref: ref, store: store, artifacts: artifacts)
            }
        }
        .background(Color.nw.bgWindow)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab == .changes ? "Changes" : "Artifacts")
    }
}

/// The pane's head (iPadReview, iPadPaneArtifacts): the tabs Shepherd has as a segmented control, then the open tab's options
/// (Changes: Full screen) and Close pane. Finalize worktree is in the toolbar's Diff options. Browser and Files are not built, so
/// they have no tab.
private struct PadPaneHeader: View {
    let store: ReviewStore
    let tab: ReviewStore.PadTab
    let artifacts: Int
    let close: () -> Void

    var body: some View {
        var tabs = [NWPadPaneTab(id: "changes", title: "Changes", systemImage: "plus.forwardslash.minus", count: store.loaded ? store.entries.count : nil)]
        if artifacts > 0 { tabs.append(NWPadPaneTab(id: "artifacts", title: "Artifacts", systemImage: NWGlyph.artifact.symbolName, count: artifacts)) }
        return NWPadPaneHead(tabs, selection: tab == .changes ? "changes" : "artifacts",
                             select: { store.padTab = $0 == "artifacts" ? .artifacts : .changes }, close: close) {
            if tab == .changes {
                Button("Full screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    withNWAnimation(.disclosure) { store.padLayout = .full }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.nwIcon(size: NW.Height.touch - NW.Space.xs))
            }
        }
    }
}

/// The toolbar (iPadReview, iPadReviewSplit): the scope pill, the whole scope's stat, then
/// Commit… and Diff options, which holds Refresh, Collapse all, the diff style and Finalize.
private struct PadChangesToolbar: View {
    let store: ReviewStore
    let compact: Bool
    let finalize: (() -> Void)?

    var body: some View {
        HStack(spacing: NW.Space.m) {
            PadScopePill(store: store)
            if store.loaded {
                NWDiffStat(added: store.totals.added, removed: store.totals.removed, font: .nw(.mono)).fixedSize()
            }
            Spacer(minLength: NW.Space.s)
            PadCommitButton(store: store)
            PadDiffOptions(store: store, compact: compact, finalize: finalize)
                .labelStyle(.iconOnly)
                .buttonStyle(.nwIcon(size: NW.Height.touch))
        }
        .padding(.horizontal, NW.Space.l)
        .frame(height: MobileLayout.reviewToolbarHeight)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

/// "Branch ⌄": the scope, opening the scope menu.
private struct PadScopePill: View {
    let store: ReviewStore

    var body: some View {
        let nw = Color.nw
        ChangesScopeMenu(store: store, pickBase: { store.pickingBase = true }) {
            HStack(spacing: NW.Space.s) {
                Text(label).font(.nw(.ui)).foregroundStyle(nw.textPrimary).lineLimit(1)
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(nw.textSecondary)
            }
            .padding(.horizontal, NW.Space.l)
            .frame(minHeight: NW.Height.touch)
            .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.s))
            .nwBorder(nw.lineStrong, radius: NW.Radius.s)
            .fixedSize()
            .accessibilityLabel("Compare: \(store.scopeTitle)")
        }
        // The base picker opens here from the menu's Compare against… and the compare row's base.
        .popover(isPresented: Binding(get: { store.pickingBase }, set: { store.pickingBase = $0 })) {
            ChangesBasePicker(store: store) { store.pickingBase = false }
                .frame(width: MobileLayout.reviewBasePickerSize.width, height: MobileLayout.reviewBasePickerSize.height)
        }
    }

    private var label: String {
        if store.usesChanges { return store.scope?.label ?? "Changes" }
        return store.filesArePR ? "Pull request" : "Working tree"
    }
}

/// Commit…: the commit popover where the host commits from review, else a turn asking the
/// agent to commit.
private struct PadCommitButton: View {
    let store: ReviewStore
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if CommitHooks.available(host: hosts.host(store.ref.host)) {
            Button { CommitHooks.open(thread: store.ref, navigator: navigator, sizeClass: .regular) } label: {
                Text("Commit\u{2026}")
            }
            .buttonStyle(.nw(.secondary, size: .l))
            .fixedSize()
            .disabled(!store.canCommit)
            .accessibilityHint("Choose the message and push options, then commit on the host")
            .commitPopover(ref: store.ref)
        } else {
            Button { Task { _ = await store.commit(hosts: hosts) } } label: {
                Text("Commit\u{2026}")
            }
            .buttonStyle(.nw(.secondary, size: .l))
            .fixedSize()
            .disabled(!store.canCommit)
            .accessibilityHint("Asks the agent to commit these changes")
        }
    }
}

/// The style a pane draws: the reviewer's choice, else split when wide (full screen) and
/// unified beside the thread.
@MainActor func padDiffStyle(_ store: ReviewStore, compact: Bool) -> ReviewStore.DiffStyle {
    store.diffStyle ?? (compact ? .unified : .split)
}

/// Diff options (iPadReview's •••): Refresh, Collapse all, split or unified (its glyph is the
/// mode it switches to), then Word diffs, Hide whitespace changes, Load full files, Copy git apply
/// command and Copy as patch, and Finalize worktree for a worktree agent.
private struct PadDiffOptions: View {
    let store: ReviewStore
    let compact: Bool
    let finalize: (() -> Void)?

    var body: some View {
        let split = padDiffStyle(store, compact: compact) == .split
        Menu {
            Section {
                Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }
                    .disabled(store.loading)
                Button(store.allCollapsed ? "Expand all files" : "Collapse all files",
                       systemImage: store.allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical") {
                    store.toggleCollapseAll()
                }
                Button(split ? "Unified diff" : "Split diff", systemImage: split ? "doc.plaintext" : "rectangle.split.2x1") {
                    store.diffStyle = split ? .unified : .split
                }
            }
            Section("Diff") {
                Toggle(isOn: Binding(get: { store.wordDiffs }, set: { store.setWordDiffs($0) })) {
                    Label("Word diffs", systemImage: "text.word.spacing")
                }
                if store.usesChanges {
                    Toggle(isOn: Binding(get: { store.options.ignoreWhitespace }, set: { store.setIgnoreWhitespace($0) })) {
                        Label("Hide whitespace changes", systemImage: "space")
                    }
                    Toggle(isOn: Binding(get: { store.options.fullFiles }, set: { store.setFullFiles($0) })) {
                        Label("Load full files", systemImage: "folder")
                        Text("Expand past folds without a round trip")
                    }
                }
            }
            if store.usesChanges {
                Section {
                    Button("Copy git apply command", systemImage: "doc.on.clipboard") { copy(command: true) }
                    Button("Copy as patch", systemImage: "doc.on.doc") { copy(command: false) }
                }
            }
            if let finalize {
                Button("Finalize worktree\u{2026}", systemImage: "checkmark.seal", action: finalize)
            }
        } label: {
            Label("Diff options", systemImage: "ellipsis")
        }
    }

    private func copy(command: Bool) {
        Task {
            guard let patch = try? await store.patch() else { return }
            UIPasteboard.general.string = command ? "git apply <<'PATCH'\n\(patch)\(patch.hasSuffix("\n") ? "" : "\n")PATCH\n" : patch
        }
    }
}

/// The compare row (iPadReview): head vs base (Branch's base opens the base picker), and how many
/// files are viewed trailing.
private struct PadCompareRow: View {
    let store: ReviewStore

    var body: some View {
        if let compare = store.compare {
            let nw = Color.nw
            HStack(spacing: NW.Space.m) {
                Text(compare.head).foregroundStyle(nw.textSecondary).lineLimit(1).truncationMode(.middle)
                Text("vs").foregroundStyle(nw.textTertiary)
                if compare.basePicks {
                    Button { store.pickingBase = true } label: {
                        HStack(spacing: NW.Space.xs) {
                            Text(compare.base).lineLimit(1)
                            Image(systemName: "chevron.down").imageScale(.small)
                        }
                        .foregroundStyle(nw.textPrimary)
                        .nwTouchTarget(height: MobileLayout.reviewCompareHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Base \(compare.base)")
                    .accessibilityHint("Compares against another branch")
                } else {
                    Text(compare.base).foregroundStyle(nw.textPrimary).lineLimit(1)
                }
                Spacer(minLength: NW.Space.s)
                if store.loaded {
                    Text(store.totals.viewedText).foregroundStyle(nw.textSecondary).lineLimit(1).fixedSize()
                }
            }
            .font(.nw(.mono))
            .padding(.horizontal, NW.Space.l)
            .frame(height: MobileLayout.reviewCompareHeight)
            .overlay(alignment: .bottom) { NWHairline() }
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: The stacked files

/// Every file, stacked: a sticky head per file, then its rows, fetched as it nears the screen.
/// `scrollTarget` scrolls a file's head to the top (the strip, the file list).
private struct PadChangesStack: View {
    let store: ReviewStore
    @Binding var scrollTarget: String?
    var compact = true
    @FocusState private var editorFocused: Bool

    var body: some View {
        let style = padDiffStyle(store, compact: compact)
        ScrollViewReader { proxy in
            ScrollView {
                if store.entries.isEmpty {
                    ReviewLoadState(store: store) { store.refresh() }.padding(MobileLayout.gutter)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(store.entries) { entry in
                            Section {
                                if !store.collapsed.contains(entry.id) {
                                    PadFileRows(store: store, fileID: entry.id, style: style, editorFocused: $editorFocused)
                                }
                            } header: {
                                PadFileHead(store: store, entry: entry)
                                    .id(entry.id)
                                    .onAppear { store.ensure(entry.id) }
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                withNWAnimation(.disclosure) { proxy.scrollTo(id, anchor: .top) }
                scrollTarget = nil
            }
        }
    }
}

/// A file's rows in the stack, or what it shows instead.
private struct PadFileRows: View {
    let store: ReviewStore
    let fileID: String
    let style: ReviewStore.DiffStyle
    var editorFocused: FocusState<Bool>.Binding

    var body: some View {
        let state = store.state(of: fileID)
        if state == .lines {
            if style == .split {
                ForEach(store.splitRows(fileID)) { row in
                    ReviewSplitRowView(store: store, fileID: fileID, row: row, editorFocused: editorFocused)
                }
            } else {
                ForEach(store.unifiedRows(fileID, gaps: true)) { row in
                    ReviewUnifiedRowView(store: store, fileID: fileID, row: row, gutters: 1, inlineEditor: true, tintedHunks: true,
                                         changeBars: false, editorFocused: editorFocused)
                }
            }
            if store.truncated.contains(fileID) { ReviewTruncatedNote() }
        } else {
            ReviewFileNotice(state: state) { store.ensure(fileID) }
                .onAppear { store.ensure(fileID) }
        }
    }
}

/// A file's sticky head (iPadReview): "FleetView.swift · +9 −7", a tap folds or opens it, and
/// Viewed, which folds the file away.
private struct PadFileHead: View {
    let store: ReviewStore
    let entry: ChangesFile

    var body: some View {
        let nw = Color.nw
        let collapsed = store.collapsed.contains(entry.id)
        let viewed = store.viewed.contains(entry.id)
        let (directory, name) = reviewPathParts(entry.path)
        let status = NWFileStatus(ReviewFileStatus(entry.status))
        HStack(spacing: NW.Space.m) {
            Button { withNWAnimation(.disclosure) { store.toggleCollapsed(entry.id) } } label: {
                Text("\(name) · +\(entry.added) \u{2212}\(entry.removed)")
                    .font(.nw(.mono))
                    .foregroundStyle(nw.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(directory.isEmpty ? "" : "in \(directory), ")\(status.label), \(entry.added) added, \(entry.removed) removed")
            .accessibilityValue(collapsed ? "collapsed" : "expanded")
            .accessibilityHint(collapsed ? "Shows the file's changes" : "Hides the file's changes")
            Toggle("Viewed", isOn: Binding(get: { viewed }, set: { _ in store.toggleViewed(entry.id) }))
                .toggleStyle(.nwCheckbox)
                .font(.nw(.caption))
                .foregroundStyle(nw.textSecondary)
                .fixedSize()
                .nwTouchTarget(height: NW.Height.touch)
        }
        .padding(.horizontal, NW.Space.m + NW.Space.xxs)
        .frame(height: NW.Height.touch)
        .background(nw.bgRaised)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

/// The send bar while comments wait (iPadReview): "1 pending · FleetView.swift", Discard and
/// Send 1 comment; or why a send failed.
private struct PadSendBar: View {
    let store: ReviewStore
    let close: () -> Void
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.actionError {
                NWBanner(.failed, title: "Couldn't send the comments", message: error) {
                    Button("Dismiss") { store.actionError = nil }.buttonStyle(.nw(.ghost, size: .s))
                }
                .padding(NW.Space.l)
            }
            if !store.comments.isEmpty {
                let nw = Color.nw
                HStack(spacing: NW.Space.m) {
                    Text(padPendingText(store.comments))
                        .font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Discard") { store.discardComments() }
                        .buttonStyle(.nw(.ghost, size: .l))
                        .disabled(store.submitting)
                        .accessibilityHint("Deletes the comments you haven't sent")
                    Button {
                        Task { if await store.sendComments(hosts: hosts) { close() } }
                    } label: {
                        HStack(spacing: NW.Space.s) {
                            if store.submitting { ProgressView().progressViewStyle(NWSpinnerStyle()) }
                            Text(store.sendTitle)
                        }
                    }
                    .buttonStyle(.nw(.primary, size: .l))
                    .disabled(!store.canSend)
                    .accessibilityHint("Sends your comments as the agent's next message")
                }
                .padding(.horizontal, NW.Space.l)
                .padding(.vertical, NW.Space.m)
                .frame(minHeight: MobileLayout.reviewSendBarHeight)
                .background(nw.bgWindow)
                .overlay(alignment: .top) { NWHairline() }
            }
        }
    }
}

/// "1 pending · FleetView.swift", or "3 pending · 2 files".
func padPendingText(_ comments: [ReviewComment]) -> String {
    let files = Set(comments.map(\.fileID))
    let place = files.count == 1 ? comments.first.map { reviewPathParts($0.filePath).name } ?? "" : "\(files.count) files"
    return "\(comments.count) pending · \(place)"
}

// MARK: Full screen

/// The full-screen review (iPadReviewSplit): "‹ Thread" and "Review" in the bar with Close; the
/// toolbar and compare row as docked; then the file list beside the stacked files, and the send bar.
private struct PadFullReview: View {
    let store: ReviewStore
    let finalize: (() -> Void)?
    let close: () -> Void
    @State private var scrollTarget: String?

    var body: some View {
        VStack(spacing: 0) {
            PadChangesToolbar(store: store, compact: false, finalize: finalize)
            PadCompareRow(store: store)
            HStack(spacing: 0) {
                PadFileList(store: store) { id in
                    store.clearSelection()
                    store.currentFile = id
                    scrollTarget = id
                }
                .frame(width: MobileLayout.reviewFileListWidth)
                NWHairline(.vertical)
                PadChangesStack(store: store, scrollTarget: $scrollTarget, compact: false)
                    .frame(maxWidth: .infinity)
            }
            PadSendBar(store: store, close: close)
        }
        .background(Color.nw.bgWindow)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: NW.Space.m) {
                    Button { withNWAnimation(.disclosure) { store.padLayout = .docked } } label: {
                        HStack(spacing: NW.Space.xs) {
                            Image(systemName: "chevron.left").font(.nw(.ui, weight: .semibold))
                            Text("Thread")
                        }
                    }
                    .accessibilityLabel("Back to the thread")
                    Text("Review").font(.nw(.ui, weight: .semibold)).foregroundStyle(Color.nw.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                .fixedSize()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close review", systemImage: "xmark", action: close)
            }
        }
    }
}

/// The full-screen review's file list (iPadReviewSplit): a row per file, its name over its stat;
/// the one shown is filled, viewed files dim.
private struct PadFileList: View {
    let store: ReviewStore
    let select: (String) -> Void

    var body: some View {
        let nw = Color.nw
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.summaries) { summary in
                    let selected = summary.id == store.currentFile
                    Button { select(summary.id) } label: {
                        VStack(alignment: .leading, spacing: NW.Space.xs) {
                            Text(summary.name).font(.nw(.code)).foregroundStyle(nw.textPrimary)
                                .lineLimit(1).truncationMode(.middle)
                            Text("+\(summary.added) \u{2212}\(summary.removed)").font(.nw(.micro, weight: .regular))
                                .foregroundStyle(nw.textTertiary)
                        }
                        .padding(NW.Space.l)
                        .frame(maxWidth: .infinity, minHeight: MobileLayout.reviewFileRowHeight, alignment: .leading)
                        .opacity(summary.viewed && !selected ? MobileLayout.reviewViewedOpacity : 1)
                        .background(selected ? nw.bgSelected : .clear)
                        .overlay(alignment: .bottom) { NWHairline() }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(summary.name), \(summary.added) added, \(summary.removed) removed\(summary.viewed ? ", viewed" : "")")
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }
}
