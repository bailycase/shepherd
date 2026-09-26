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
                        PadChangesPane(store: store, finalize: finalize, close: { dismiss() })
                            .frame(width: min(MobileLayout.reviewDockWidth, proxy.size.width * MobileLayout.reviewDockShare))
                    }
                }
            case .full:
                PadFullReview(store: store, finalize: finalize, close: { dismiss() })
            }
        }
        .onAppear { store.focus(file) }
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

/// The docked pane (iPadReview).
private struct PadChangesPane: View {
    let store: ReviewStore
    let finalize: (() -> Void)?
    let close: () -> Void
    @State private var scrollTarget: String?

    var body: some View {
        VStack(spacing: 0) {
            PadPaneHeader(store: store, finalize: finalize, close: close)
            PadChangesToolbar(store: store, compact: true)
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
        }
        .background(Color.nw.bgWindow)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes")
    }
}

/// The pane's head: the Changes tab with its file count, then pane options (Full screen,
/// Finalize worktree) and Close.
private struct PadPaneHeader: View {
    let store: ReviewStore
    let finalize: (() -> Void)?
    let close: () -> Void

    var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.xxs) {
            HStack(spacing: NW.Space.s) {
                Image(systemName: "plus.forwardslash.minus").imageScale(.small)
                Text("Changes").font(.nw(.ui, weight: .semibold))
                if store.loaded {
                    Text("\(store.entries.count)").font(.nw(.micro, weight: .regular)).foregroundStyle(nw.textTertiary)
                }
            }
            .foregroundStyle(nw.textPrimary)
            .padding(.horizontal, NW.Space.m + 1)
            .frame(minHeight: NW.Height.touch - NW.Space.m)
            .background(nw.bgSelected, in: RoundedRectangle(cornerRadius: NW.Radius.s))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits([.isHeader, .isSelected])
            Spacer(minLength: NW.Space.s)
            Menu {
                Button("Full screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    withNWAnimation(.disclosure) { store.padLayout = .full }
                }
                if let finalize {
                    Button("Finalize worktree…", systemImage: "checkmark.seal", action: finalize)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(.nwIcon(bordered: true))
            .nwTouchTarget(height: NW.Height.controlM, width: NW.Height.controlM)
            .accessibilityLabel("Pane options")
            Button("Close pane", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.nwIcon())
                .nwTouchTarget(height: NW.Height.controlM, width: NW.Height.controlM)
        }
        .padding(.horizontal, NW.Space.m + NW.Space.xxs)
        .frame(height: MobileLayout.reviewPaneHeaderHeight)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

/// The toolbar (ChangesStates › ChangesToolbar): the scope pill, the whole scope's stat, then
/// viewed, Commit…, Refresh, Collapse all, the split toggle (showing the mode it switches to) and
/// diff options. Full screen puts Refresh and Collapse all in diff options.
private struct PadChangesToolbar: View {
    let store: ReviewStore
    let compact: Bool
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        HStack(spacing: NW.Space.m + NW.Space.xxs) {
            PadScopePill(store: store)
            // A narrow pane drops the viewed count, then the stat, before anything clips.
            ViewThatFits(in: .horizontal) {
                middle(stat: true, viewed: true)
                middle(stat: true, viewed: false)
                middle(stat: false, viewed: false)
            }
            HStack(spacing: NW.Space.xxs) {
                if compact {
                    Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }
                        .disabled(store.loading)
                    Button(store.allCollapsed ? "Expand all files" : "Collapse all files",
                           systemImage: store.allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical") {
                        store.toggleCollapseAll()
                    }
                }
                PadStyleToggle(store: store, compact: compact)
                PadDiffOptions(store: store, compact: compact)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.nwIcon(size: NW.Height.touch - NW.Space.m))
        }
        .padding(.leading, NW.Space.l)
        .padding(.trailing, NW.Space.m + NW.Space.xxs)
        .frame(height: MobileLayout.reviewToolbarHeight)
        .overlay(alignment: .bottom) { NWHairline() }
    }

    private func middle(stat: Bool, viewed: Bool) -> some View {
        HStack(spacing: NW.Space.m + NW.Space.xxs) {
            if stat, store.loaded {
                NWDiffStat(added: store.totals.added, removed: store.totals.removed, font: .nw(.mono)).fixedSize()
            }
            Spacer(minLength: NW.Space.s)
            if viewed { PadViewedPill(totals: store.totals) }
            PadCommitButton(store: store)
        }
    }
}

/// "⑂ Branch ⌄": the scope, opening the scope menu.
private struct PadScopePill: View {
    let store: ReviewStore

    var body: some View {
        let nw = Color.nw
        ChangesScopeMenu(store: store, pickBase: { store.pickingBase = true }) {
            HStack(spacing: NW.Space.s) {
                Image(systemName: "arrow.triangle.branch").imageScale(.small).foregroundStyle(nw.textSecondary)
                Text(label).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary).lineLimit(1)
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(nw.textTertiary)
            }
            .padding(.horizontal, NW.Space.l)
            .frame(minHeight: NW.Height.touch - NW.Space.m)
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

/// "👁 2/5 viewed".
private struct PadViewedPill: View {
    let totals: ReviewTotals

    var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.s) {
            Image(systemName: "eye").imageScale(.small)
            Text("\(Text("\(totals.viewed)/\(totals.files)").font(.nw(.mono))) viewed")
        }
        .font(.nw(.caption))
        .foregroundStyle(nw.textSecondary)
        .padding(.horizontal, NW.Space.m)
        .frame(minHeight: NW.Height.controlS)
        .background(nw.bgSunken, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(totals.viewedText)
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
                Label("Commit\u{2026}", systemImage: "circle.and.line.horizontal")
            }
            .buttonStyle(.nw(.secondary, size: .m))
            .nwTouchTarget(height: NW.Height.controlM)
            .fixedSize()
            .disabled(!store.canCommit)
            .accessibilityHint("Choose the message and push options, then commit on the host")
            .commitPopover(ref: store.ref)
        } else {
            Button { Task { _ = await store.commit(hosts: hosts) } } label: {
                Label("Commit", systemImage: "circle.and.line.horizontal")
            }
            .buttonStyle(.nw(.secondary, size: .m))
            .nwTouchTarget(height: NW.Height.controlM)
            .fixedSize()
            .disabled(!store.canCommit)
            .accessibilityHint("Asks the agent to commit these changes")
        }
    }
}

/// Split ⇄ unified: its glyph is the mode it switches to.
private struct PadStyleToggle: View {
    let store: ReviewStore
    let compact: Bool

    var body: some View {
        let split = padDiffStyle(store, compact: compact) == .split
        Button(split ? "Switch to unified diff" : "Switch to split diff", systemImage: split ? "doc.plaintext" : "rectangle.split.2x1") {
            store.diffStyle = split ? .unified : .split
        }
    }
}

/// The style a pane draws: the reviewer's choice, else split when wide (full screen) and
/// unified beside the thread.
@MainActor func padDiffStyle(_ store: ReviewStore, compact: Bool) -> ReviewStore.DiffStyle {
    store.diffStyle ?? (compact ? .unified : .split)
}

/// Diff options (ChangesStates › DiffOptions): Word diffs, Hide whitespace changes, Load full
/// files, then Copy git apply command and Copy as patch. Full screen adds Refresh and Collapse all.
private struct PadDiffOptions: View {
    let store: ReviewStore
    let compact: Bool

    var body: some View {
        Menu {
            if !compact {
                Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }
                Button(store.allCollapsed ? "Expand all files" : "Collapse all files",
                       systemImage: store.allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical") {
                    store.toggleCollapseAll()
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

/// The compare row (ChangesStates › CompareRow): head → base (Branch's base opens the base
/// picker), and the merge base or the turn's prompt trailing.
private struct PadCompareRow: View {
    let store: ReviewStore

    var body: some View {
        if let compare = store.compare {
            let nw = Color.nw
            HStack(spacing: NW.Space.m) {
                Text(compare.head).font(.nw(.mono)).foregroundStyle(nw.textSecondary).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right").imageScale(.small).foregroundStyle(nw.textTertiary).accessibilityLabel("against")
                if compare.basePicks {
                    Button { store.pickingBase = true } label: {
                        HStack(spacing: NW.Space.xs) {
                            Text(compare.base).font(.nw(.mono)).foregroundStyle(nw.textPrimary).lineLimit(1)
                            Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(nw.textTertiary)
                        }
                        .nwTouchTarget(height: NW.Height.controlS)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Base \(compare.base)")
                    .accessibilityHint("Compares against another branch")
                } else {
                    Text(compare.base).font(.nw(.mono)).foregroundStyle(nw.textPrimary).lineLimit(1)
                }
                Spacer(minLength: NW.Space.s)
                if let trailing = compare.trailing {
                    Text(trailing).font(.nw(.micro, weight: .regular)).foregroundStyle(nw.textTertiary).lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, NW.Space.l)
            .frame(height: MobileLayout.reviewCompareHeight)
            .background(nw.bgBase)
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
                    ReviewUnifiedRowView(store: store, fileID: fileID, row: row, gutters: 2, inlineEditor: true, tintedHunks: false,
                                         changeBars: true, editorFocused: editorFocused)
                }
            }
            if store.truncated.contains(fileID) { ReviewTruncatedNote() }
        } else {
            ReviewFileNotice(state: state) { store.ensure(fileID) }
                .onAppear { store.ensure(fileID) }
        }
    }
}

/// A file's sticky head (ChangesStates › FileHeader): collapse, the status letter, the folder
/// dimmed and the name, its stat, and Viewed, which folds the file away.
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
                HStack(spacing: NW.Space.m) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.nw(.caption, weight: .semibold))
                        .foregroundStyle(nw.textTertiary)
                        .frame(width: NW.Space.l)
                    Text(status.letter).font(.nw(.mono, weight: .bold)).foregroundStyle(status.color)
                    Text("\(Text(directory).foregroundStyle(nw.textTertiary))\(Text(name).fontWeight(.semibold).foregroundStyle(nw.textPrimary))")
                        .font(.nw(.mono))
                        .lineLimit(1)
                        .truncationMode(.head)
                    NWDiffStat(added: entry.added, removed: entry.removed, font: .nw(.micro, weight: .regular))
                    Spacer(minLength: NW.Space.s)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(status.label), \(entry.added) added, \(entry.removed) removed")
            .accessibilityValue(collapsed ? "collapsed" : "expanded")
            .accessibilityHint(collapsed ? "Shows the file's changes" : "Hides the file's changes")
            Toggle("Viewed", isOn: Binding(get: { viewed }, set: { _ in store.toggleViewed(entry.id) }))
                .toggleStyle(.nwCheckbox)
                .font(.nw(.caption))
                .foregroundStyle(nw.textSecondary)
                .fixedSize()
                .nwTouchTarget(height: NW.Height.controlS)
        }
        .padding(.leading, NW.Space.m + NW.Space.xxs)
        .padding(.trailing, NW.Space.l)
        .frame(height: NW.Height.touch)
        .background(nw.bgRaised)
        .overlay(alignment: .top) { NWHairline() }
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

/// The send bar while comments wait (ChangesStates › ReviewSendBar), or why a send failed.
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
                let pending = reviewPendingText(store.comments)
                NWReviewSendBar(count: pending.count, detail: pending.detail, sending: store.submitting, size: .touch,
                                onDiscard: { store.discardComments() },
                                onSend: { Task { if await store.sendComments(hosts: hosts) { close() } } })
            }
        }
    }
}

// MARK: Full screen

/// The full-screen review (iPadReviewSplit): "‹ Thread" (back beside the thread), "Review", the
/// scope pill and stat; viewed, Commit…, the split toggle and diff options; the compare row;
/// then the file list beside the stacked files, and the send bar.
private struct PadFullReview: View {
    let store: ReviewStore
    let finalize: (() -> Void)?
    let close: () -> Void
    @State private var scrollTarget: String?

    var body: some View {
        VStack(spacing: 0) {
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { withNWAnimation(.disclosure) { store.padLayout = .docked } } label: {
                    HStack(spacing: NW.Space.xs) {
                        Image(systemName: "chevron.left").font(.nw(.ui, weight: .semibold))
                        Text("Thread")
                    }
                }
                .accessibilityLabel("Back to the thread")
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: NW.Space.l) {
                    Text("Review").font(.nw(.headline)).foregroundStyle(Color.nw.textPrimary)
                    PadScopePill(store: store)
                    if store.loaded {
                        NWDiffStat(added: store.totals.added, removed: store.totals.removed, font: .nw(.mono))
                    }
                }
                .fixedSize()
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                PadViewedPill(totals: store.totals)
                PadCommitButton(store: store)
                PadStyleToggle(store: store, compact: false)
                PadDiffOptions(store: store, compact: false)
                if let finalize {
                    Button("Finalize worktree", systemImage: "checkmark.seal", action: finalize)
                }
            }
        }
    }
}

/// The full-screen review's file list: "5 FILES +200 −8", then a row per file; the one shown
/// is filled, viewed files dim.
private struct PadFileList: View {
    let store: ReviewStore
    let select: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: NW.Space.xs) {
                HStack {
                    Text(store.totals.filesText).nwSectionLabel()
                    Spacer(minLength: NW.Space.s)
                    NWDiffStat(added: store.totals.added, removed: store.totals.removed, font: .nw(.micro, weight: .regular))
                }
                .padding(.horizontal, NW.Space.xs)
                .padding(.bottom, NW.Space.s)
                .accessibilityElement(children: .combine)
                ForEach(store.summaries) { summary in
                    Button { select(summary.id) } label: {
                        NWReviewFileRow(NWReviewFileRow.Item(summary), showsViewed: false, showsChevron: false,
                                        selected: summary.id == store.currentFile).equatable()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(NW.Space.m + NW.Space.xxs)
        }
        .background(Color.nw.bgBase)
    }
}
