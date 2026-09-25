import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The review on iPad. Docked (iPadReview board): the thread keeps the left and the review pane
/// takes the right, with its header, the file chips, the file's unified diff, and the review
/// composer. Full screen (iPadReviewSplit board): the file list with the overall comment on the
/// left and the file's diff, unified or side by side, on the right; Commit and Request changes
/// in the bar. Tapping a line opens a comment editor under it.
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
                            .frame(maxWidth: .infinity)
                        NWHairline(.vertical, color: Color.nw.lineStrong)
                        PadReviewPane(store: store, finalize: finalize, close: { dismiss() })
                            .frame(width: min(MobileLayout.reviewDockWidth, proxy.size.width * MobileLayout.reviewDockShare))
                    }
                }
            case .full:
                PadFullReview(store: store, finalize: finalize, close: { dismiss() })
            }
        }
        .onAppear { store.focus(file) }
        .task(id: hosts.host(ref.host)?.session) { await store.loadIfNeeded(hosts: hosts) }
        .onChange(of: store.pullRequest) { _, _ in Task { await store.load(hosts: hosts) } }
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

/// The docked pane (iPadReview board).
private struct PadReviewPane: View {
    let store: ReviewStore
    let finalize: (() -> Void)?
    let close: () -> Void
    @FocusState private var editorFocused: Bool
    @FocusState private var summaryFocused: Bool
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        VStack(spacing: 0) {
            PadReviewHeader(store: store, finalize: finalize, close: close)
            if !store.files.isEmpty {
                NWTouchFileStrip(store.chips, selection: store.currentFile) { id in
                    store.clearSelection()
                    store.currentFile = id
                }
            }
            if let file = store.file(store.currentFile) {
                PadFileHeader(store: store, file: file, showsStyle: false)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        PadDiffBody(store: store, file: file, style: .unified, editorFocused: $editorFocused)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .task(id: ReviewColorsKey(file: file.id, version: store.filesVersion)) { await store.highlight(file.id) }
            } else {
                ScrollView { ReviewLoadState(store: store) { Task { await store.load(hosts: hosts) } }.padding(MobileLayout.gutter) }
            }
            PadComposer(store: store, focused: $summaryFocused, close: close)
        }
        .background(Color.nw.bgWindow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review")
    }
}

/// "Review" over "4 files · +67 −58", Local | PR, full screen, and close.
private struct PadReviewHeader: View {
    @Bindable var store: ReviewStore
    let finalize: (() -> Void)?
    let close: () -> Void

    var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text("Review").font(.nw(.headline)).foregroundStyle(nw.textPrimary)
                HStack(spacing: NW.Space.s) {
                    Text("\(store.totals.filesText) ·")
                    NWDiffStat(added: store.totals.added, removed: store.totals.removed, font: .nw(.micro, weight: .regular))
                }
                .font(.nw(.micro, weight: .regular))
                .foregroundStyle(nw.textTertiary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: NW.Space.s)
            PadSourcePicker(store: store)
            if let finalize {
                Button("Finalize worktree", systemImage: "checkmark.seal", action: finalize)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.nwIcon())
            }
            Button("Full screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                withNWAnimation(.disclosure) { store.padLayout = .full }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.nwIcon())
            Button("Close review", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.nwIcon())
        }
        .padding(.leading, MobileLayout.gutter)
        .padding(.trailing, NW.Space.s)
        .padding(.vertical, NW.Space.xs)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

/// Local | PR: the working tree against HEAD, or the branch against its PR base.
private struct PadSourcePicker: View {
    @Bindable var store: ReviewStore

    var body: some View {
        Picker("Compare", selection: $store.pullRequest) {
            Text("Local").tag(false)
            Text("PR").tag(true)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(store.loading)
    }
}

/// The file's header: its path and hunks (or stat), Mark viewed, and in full screen the diff
/// style.
private struct PadFileHeader: View {
    @Bindable var store: ReviewStore
    let file: DiffFile
    let showsStyle: Bool

    var body: some View {
        let viewed = store.viewed.contains(file.id)
        NWTouchFileHeader(path: file.displayPath, detail: showsStyle ? nil : nativeCount(file.hunks.count, "hunk"),
                          added: showsStyle ? file.addedCount : nil, removed: showsStyle ? file.removedCount : nil) {
            if showsStyle {
                Toggle("Viewed", isOn: Binding(get: { viewed }, set: { _ in store.toggleViewed(file.id) }))
                    .toggleStyle(.button)
                    .font(.nw(.ui))
                    .tint(Color.nw.done)
                Picker("Diff style", selection: $store.diffStyle) {
                    Text("Unified").tag(ReviewStore.DiffStyle.unified)
                    Text("Split").tag(ReviewStore.DiffStyle.split)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            } else {
                Button(viewed ? "Mark unviewed" : "Mark viewed", systemImage: "checkmark") { store.toggleViewed(file.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.nwIcon(tint: viewed ? Color.nw.done : nil))
            }
        }
    }
}

/// One file's rows, unified or side by side, or why there are none.
private struct PadDiffBody: View {
    let store: ReviewStore
    let file: DiffFile
    let style: ReviewStore.DiffStyle
    var editorFocused: FocusState<Bool>.Binding

    var body: some View {
        if file.isBinary {
            NWEmptyState(Text("Binary file"), message: "Its changes can't be shown as lines.")
        } else if file.hunks.isEmpty {
            NWEmptyState(Text("No line changes"), message: "The file changed without changing its lines.")
        } else if style == .split {
            ReviewSplitRows(store: store, fileID: file.id, editorFocused: editorFocused)
        } else {
            ReviewDiffRows(store: store, fileID: file.id, gutters: 2, inlineEditor: true, tintedHunks: false, editorFocused: editorFocused)
        }
    }
}

/// The review composer at the pane's foot: the overall comment, the inline count, Commit and
/// Request changes.
private struct PadComposer: View {
    @Bindable var store: ReviewStore
    var focused: FocusState<Bool>.Binding
    let close: () -> Void
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        VStack(spacing: NW.Space.m) {
            if let error = store.actionError {
                NWBanner(.failed, title: "Couldn't send the review", message: error) {
                    Button("Dismiss") { store.actionError = nil }.buttonStyle(.nw(.ghost, size: .s))
                }
            }
            NWReviewComposer(text: $store.summary, isFocused: focused, inlineCount: store.comments.count,
                             canCommit: store.canCommit, canRequestChanges: store.canRequestChanges,
                             onCommit: { Task { if await store.commit(hosts: hosts) { close() } } },
                             onRequestChanges: { Task { if await store.requestChanges(hosts: hosts) { close() } } },
                             onCommitDirectly: CommitHooks.available(host: hosts.host(store.ref.host))
                                ? { CommitHooks.open(thread: store.ref, navigator: navigator, sizeClass: .regular) } : nil)
                .commitPopover(ref: store.ref, arrowEdge: .bottom)
        }
        .padding(NW.Space.l)
        .overlay(alignment: .top) { NWHairline() }
    }
}

/// The full-screen review (iPadReviewSplit board).
private struct PadFullReview: View {
    @Bindable var store: ReviewStore
    let finalize: (() -> Void)?
    let close: () -> Void
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @FocusState private var editorFocused: Bool
    @FocusState private var summaryFocused: Bool

    var body: some View {
        let host = hosts.host(store.ref.host)
        let agent = host?.agent(store.ref.agent)
        HStack(spacing: 0) {
            PadFileList(store: store, summaryFocused: $summaryFocused)
                .frame(width: MobileLayout.reviewFileListWidth)
            NWHairline(.vertical)
            VStack(spacing: 0) {
                if let error = store.actionError {
                    NWBanner(.failed, title: "Couldn't send the review", message: error) {
                        Button("Dismiss") { store.actionError = nil }.buttonStyle(.nw(.ghost, size: .s))
                    }
                    .padding(NW.Space.l)
                }
                if let file = store.file(store.currentFile) {
                    PadFileHeader(store: store, file: file, showsStyle: true)
                    if store.diffStyle == .split { PadSplitColumns(pullRequest: store.filesArePR) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            PadDiffBody(store: store, file: file, style: store.diffStyle, editorFocused: $editorFocused)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .task(id: ReviewColorsKey(file: file.id, version: store.filesVersion)) { await store.highlight(file.id) }
                } else {
                    ScrollView { ReviewLoadState(store: store) { Task { await store.load(hosts: hosts) } }.padding(MobileLayout.gutter) }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.nw.bgWindow)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: NW.Space.m) {
                    Text("Review").font(.nw(.headline)).foregroundStyle(Color.nw.textPrimary)
                    if let agent { NWStatusPill(AgentState(agent.status)) }
                    Text(reviewScopeText(pullRequest: store.filesArePR, reference: store.reference))
                        .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let finalize {
                    Button("Finalize worktree", systemImage: "checkmark.seal", action: finalize)
                }
                if CommitHooks.available(host: host) {
                    Button("Commit\u{2026}") { CommitHooks.open(thread: store.ref, navigator: navigator, sizeClass: .regular) }
                        .buttonStyle(.nw(.secondary, size: .l))
                        .fixedSize()
                        .disabled(!store.canCommit)
                        .accessibilityHint("Choose the files and message, then commit on the host")
                        .commitPopover(ref: store.ref)
                } else {
                    Button("Commit") { Task { if await store.commit(hosts: hosts) { close() } } }
                        .buttonStyle(.nw(.secondary, size: .l))
                        .fixedSize()
                        .disabled(!store.canCommit)
                        .accessibilityHint("Asks the agent to commit these changes")
                }
                Button("Request changes") { Task { if await store.requestChanges(hosts: hosts) { close() } } }
                    .buttonStyle(.nw(.primary, size: .l))
                    .fixedSize()
                    .disabled(!store.canRequestChanges)
                    .accessibilityHint("Sends your comments as the agent's next message")
                Button("Beside the thread", systemImage: "arrow.down.right.and.arrow.up.left") {
                    withNWAnimation(.disclosure) { store.padLayout = .docked }
                }
            }
        }
    }
}

/// The full-screen review's file list: "3 FILES +97 −48", a row per file, and the overall
/// comment at its foot.
private struct PadFileList: View {
    @Bindable var store: ReviewStore
    var summaryFocused: FocusState<Bool>.Binding

    var body: some View {
        let nw = Color.nw
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    PadSourcePicker(store: store)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, NW.Space.m)
                    HStack {
                        Text(store.totals.filesText).nwSectionLabel()
                        Spacer(minLength: NW.Space.s)
                        NWDiffStat(added: store.totals.added, removed: store.totals.removed, font: .nw(.micro, weight: .regular))
                    }
                    .padding(.horizontal, NW.Space.xs)
                    .padding(.bottom, NW.Space.s)
                    .accessibilityElement(children: .combine)
                    ForEach(store.summaries) { summary in
                        Button {
                            store.clearSelection()
                            store.currentFile = summary.id
                        } label: {
                            NWReviewFileRow(NWReviewFileRow.Item(summary), showsViewed: true, showsChevron: false,
                                            selected: summary.id == store.currentFile).equatable()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(NW.Space.m + NW.Space.xxs)
            }
            VStack(alignment: .leading, spacing: NW.Space.s) {
                Text("Overall").nwSectionLabel()
                TextField("Overall comment", text: $store.summary, prompt: Text("Add an overall comment…").foregroundStyle(nw.textTertiary),
                          axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.nw(.ui, weight: .regular))
                    .foregroundStyle(nw.textPrimary)
                    .tint(nw.lantern)
                    .focused(summaryFocused)
                    .frame(minHeight: NW.Height.touch, alignment: .topLeading)
                Text(nativeCount(store.comments.count, "inline comment")).font(.nw(.micro, weight: .regular)).foregroundStyle(nw.textTertiary)
            }
            .padding(MobileLayout.gutter)
            .overlay(alignment: .top) { NWHairline() }
        }
        .background(nw.bgWindow)
    }
}

/// "HEAD" over the left half and what it's compared with over the right.
private struct PadSplitColumns: View {
    let pullRequest: Bool

    var body: some View {
        let leading = NWTouchDiffMetrics.annotationLeading(gutters: 1)
        HStack(spacing: 0) {
            Text(pullRequest ? "BASE" : "HEAD")
                .padding(.leading, leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            NWHairline(.vertical)
            Text(pullRequest ? "BRANCH" : "WORKING TREE")
                .padding(.leading, leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.nw(.micro, weight: .regular))
        .foregroundStyle(Color.nw.textTertiary)
        .padding(.vertical, NW.Space.s)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottom) { NWHairline() }
        .accessibilityHidden(true)
    }
}
