import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The side pane's Changes tab on iPad and iPhone Duo's inner display (DuoOpenSidePane, DuoBookSidePane): under the pane's tabs, the
/// compare row ("agent/widgets vs main ⌄ +137 −16 Commit…"), the file switcher ("‹ NeedsYouWidget.swift ⌄ 1 of 3 +84 −12 ›") in place
/// of a strip of chips and a head per file, then that file's diff, unified, its lines taking comments; comments not yet sent wait in the
/// send bar. The scope, the base and the diff options are in the pane's ⋯ (`SidePaneChangesOptions`). Full screen
/// (iPadReviewSplit, `PadChangesFull`) lists the files beside every file's diff.
struct SidePaneChanges: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @FocusState private var editorFocused: Bool

    var body: some View {
        let store = ReviewStores.shared.store(for: ref)
        VStack(spacing: 0) {
            PaneCompareRow(store: store)
            if !store.entries.isEmpty { PaneFileSwitcher(store: store) }
            ScrollView {
                if let fileID = store.currentFile, store.entry(fileID) != nil {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        PadFileRows(store: store, fileID: fileID, style: padDiffStyle(store, compact: true), editorFocused: $editorFocused)
                    }
                    .id(fileID)
                } else {
                    ReviewLoadState(store: store) { store.refresh() }.padding(MobileLayout.gutter)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxHeight: .infinity)
            PadSendBar(store: store, close: {})
        }
        .background(Color.sh.bgWindow)
        .task(id: hosts.host(ref.host)?.session) { await store.loadIfNeeded(hosts: hosts) }
        // The file's hunks come when it is shown, and the next file's meanwhile.
        .task(id: store.currentFile) {
            guard let id = store.currentFile else { return }
            store.ensure(id)
            if let next = store.entry(after: id) { store.ensure(next.id) }
        }
        .onChange(of: store.pullRequest) { _, _ in store.refresh() }
        // A pane opened at no file shows the first.
        .onChange(of: store.entries.first?.id, initial: true) { _, first in
            if store.entry(store.currentFile) == nil, let first { store.currentFile = first }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes")
    }
}

/// The Changes tab's ⋯ items: what to compare, the diff's options, the file on screen as viewed, and Full screen.
struct SidePaneChangesOptions: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let store = ReviewStores.shared.store(for: ref)
        ChangesScopeMenu(store: store, pickBase: { store.pickingBase = true }) {
            Label("Compare: \(store.scopeTitle)", systemImage: SHGlyph.gitBranch.symbolName)
        }
        if let id = store.currentFile {
            let viewed = store.viewed.contains(id)
            Button(viewed ? "Mark unviewed" : "Mark viewed", systemImage: viewed ? "checkmark.circle.fill" : SHGlyph.resolved.symbolName) {
                store.toggleViewed(id)
            }
        }
        Button("Full screen", systemImage: "arrow.up.left.and.arrow.down.right") {
            withSHAnimation(.disclosure) { store.padLayout = .full }
        }
        PadDiffOptionItems(store: store, compact: true, finalize: padFinalize(ref, hosts: hosts, navigator: navigator))
    }
}

/// Finalize for a worktree agent, presented over the review; nil where it isn't offered.
@MainActor func padFinalize(_ ref: AgentRef, hosts: MobileHosts, navigator: MobileNavigator) -> (() -> Void)? {
    let host = hosts.host(ref.host)
    guard ReviewFinalizeGate.available(host: host, agent: host?.agent(ref.agent)) else { return nil }
    return { navigator.present(.review(.finalize(ref))) }
}

/// The full-screen review (iPadReviewSplit), from the Changes tab's Full screen: it takes the thread's column until "‹ Thread".
struct PadChangesFull: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let store = ReviewStores.shared.store(for: ref)
        PadFullReview(store: store, finalize: padFinalize(ref, hosts: hosts, navigator: navigator)) {
            store.padLayout = .docked
            navigator.sidePane.isOpen = false
        }
        .task(id: hosts.host(ref.host)?.session) { await store.loadIfNeeded(hosts: hosts) }
        .onChange(of: store.pullRequest) { _, _ in store.refresh() }
    }
}

/// The compare row (DuoOpenSidePane): head vs base, the base opening the base picker where it can change, the scope's totals, and
/// Commit… trailing. A host without the Changes engine names its two sides instead.
private struct PaneCompareRow: View {
    let store: ReviewStore

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            if let compare = store.compare {
                HStack(spacing: SH.Space.s) {
                    Text(compare.head).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.middle)
                    Text("vs").foregroundStyle(sh.textTertiary).fixedSize()
                    if compare.basePicks {
                        Button { store.pickingBase = true } label: {
                            HStack(spacing: SH.Space.xs) {
                                Text(compare.base).lineLimit(1)
                                Image(systemName: "chevron.down").imageScale(.small)
                            }
                            .foregroundStyle(sh.textPrimary)
                            .shTouchTarget(height: SH.Height.touch)
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .accessibilityLabel("Base \(compare.base)")
                        .accessibilityHint("Compares against another branch")
                    } else {
                        Text(compare.base).foregroundStyle(sh.textPrimary).lineLimit(1).fixedSize()
                    }
                }
                .layoutPriority(-1)
            } else {
                Text(store.filesArePR ? "Pull request" : "Working tree").foregroundStyle(sh.textPrimary).lineLimit(1)
            }
            if store.loaded {
                SHDiffStat(added: store.totals.added, removed: store.totals.removed, font: .sh(.mono)).fixedSize()
            }
            Spacer(minLength: SH.Space.s)
            PadCommitButton(store: store)
        }
        .font(.sh(.mono))
        .padding(.horizontal, SH.Space.l)
        .frame(minHeight: MobileLayout.reviewToolbarHeight)
        .overlay(alignment: .bottom) { SHHairline() }
        // The base picker opens here, from the base and from the ⋯'s Compare against….
        .popover(isPresented: Binding(get: { store.pickingBase }, set: { store.pickingBase = $0 })) {
            ChangesBasePicker(store: store) { store.pickingBase = false }
                .frame(width: MobileLayout.reviewBasePickerSize.width, height: MobileLayout.reviewBasePickerSize.height)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The file switcher (DuoOpenSidePane): ‹ and › step through the files, the name opens a menu of them all, then where it sits ("1 of 3")
/// and its stat.
private struct PaneFileSwitcher: View {
    let store: ReviewStore

    var body: some View {
        let sh = Color.sh
        let current = store.currentFile.flatMap { id in store.summaries.first { $0.id == id } }
        let index = current.flatMap { store.index(of: $0.id) }
        let count = store.entries.count
        HStack(spacing: SH.Space.s) {
            Button { step(-1, from: index) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.shIcon(size: SH.Height.touch))
                .disabled((index ?? 0) == 0)
                .accessibilityLabel("Previous file")
            Menu {
                ForEach(store.summaries) { summary in
                    Button { show(summary.id) } label: {
                        Text(summary.name)
                        Text("+\(summary.added) \u{2212}\(summary.removed)\(summary.viewed ? " · viewed" : "")")
                        if summary.id == current?.id { Image(systemName: "checkmark") }
                    }
                }
            } label: {
                HStack(spacing: SH.Space.xs) {
                    Text(current?.name ?? "Files").foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(sh.textSecondary)
                }
                .shTouchTarget(height: SH.Height.touch)
            }
            .menuOrder(.fixed)
            .accessibilityLabel("File: \(current?.name ?? "none")")
            .accessibilityHint("Shows another changed file")
            .layoutPriority(-1)
            if let index {
                Text("\(index + 1) of \(count)").foregroundStyle(sh.textTertiary).lineLimit(1).fixedSize()
            }
            Spacer(minLength: SH.Space.s)
            if let current {
                SHDiffStat(added: current.added, removed: current.removed, font: .sh(.mono)).fixedSize()
            }
            Button { step(1, from: index) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.shIcon(size: SH.Height.touch))
                .disabled((index ?? count) >= count - 1)
                .accessibilityLabel("Next file")
        }
        .font(.sh(.mono))
        .padding(.horizontal, SH.Space.s)
        .frame(minHeight: SH.Height.touch)
        .overlay(alignment: .bottom) { SHHairline() }
        .accessibilityElement(children: .contain)
    }

    private func step(_ by: Int, from index: Int?) {
        let next = (index ?? 0) + by
        guard store.entries.indices.contains(next) else { return }
        show(store.entries[next].id)
    }

    private func show(_ id: String) {
        store.clearSelection()
        store.currentFile = id
    }
}

/// The toolbar (iPadReview, iPadReviewSplit): the scope pill, the whole scope's stat, then
/// Commit… and Diff options, which holds Refresh, Collapse all, the diff style and Finalize.
private struct PadChangesToolbar: View {
    let store: ReviewStore
    let compact: Bool
    let finalize: (() -> Void)?

    var body: some View {
        HStack(spacing: SH.Space.m) {
            PadScopePill(store: store)
            if store.loaded {
                SHDiffStat(added: store.totals.added, removed: store.totals.removed, font: .sh(.mono)).fixedSize()
            }
            Spacer(minLength: SH.Space.s)
            PadCommitButton(store: store)
            PadDiffOptions(store: store, compact: compact, finalize: finalize)
                .labelStyle(.iconOnly)
                .buttonStyle(.shIcon(size: SH.Height.touch))
        }
        .padding(.horizontal, SH.Space.l)
        .frame(height: MobileLayout.reviewToolbarHeight)
        .overlay(alignment: .bottom) { SHHairline() }
    }
}

/// "Branch ⌄": the scope, opening the scope menu.
private struct PadScopePill: View {
    let store: ReviewStore

    var body: some View {
        let sh = Color.sh
        ChangesScopeMenu(store: store, pickBase: { store.pickingBase = true }) {
            HStack(spacing: SH.Space.s) {
                Text(label).font(.sh(.ui)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(sh.textSecondary)
            }
            .padding(.horizontal, SH.Space.l)
            .frame(minHeight: SH.Height.touch)
            .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .shBorder(sh.lineStrong, radius: SH.Radius.s)
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
            .buttonStyle(.sh(.secondary, size: .l))
            .fixedSize()
            .disabled(!store.canCommit)
            .accessibilityHint("Choose the message and push options, then commit on the host")
            .commitPopover(ref: store.ref)
        } else {
            Button { Task { _ = await store.commit(hosts: hosts) } } label: {
                Text("Commit\u{2026}")
            }
            .buttonStyle(.sh(.secondary, size: .l))
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
        Menu {
            PadDiffOptionItems(store: store, compact: compact, finalize: finalize)
        } label: {
            Label("Diff options", systemImage: "ellipsis")
        }
    }
}

/// Diff options' items, in the full-screen review's ••• and the Changes tab's ⋯.
struct PadDiffOptionItems: View {
    let store: ReviewStore
    let compact: Bool
    let finalize: (() -> Void)?

    var body: some View {
        let split = padDiffStyle(store, compact: compact) == .split
        Section {
            Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }
                .disabled(store.loading)
            if !compact {
                Button(store.allCollapsed ? "Expand all files" : "Collapse all files",
                       systemImage: store.allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical") {
                    store.toggleCollapseAll()
                }
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
            .disabled(store.copyingPatch)
        }
        if let finalize {
            Button("Finalize worktree\u{2026}", systemImage: "checkmark.seal", action: finalize)
        }
    }

    private func copy(command: Bool) {
        Task { await store.copyPatch(command: command) }
    }
}

/// The compare row (iPadReview): head vs base (Branch's base opens the base picker), and how many
/// files are viewed trailing.
private struct PadCompareRow: View {
    let store: ReviewStore

    var body: some View {
        if let compare = store.compare {
            let sh = Color.sh
            HStack(spacing: SH.Space.m) {
                Text(compare.head).foregroundStyle(sh.textSecondary).lineLimit(1).truncationMode(.middle)
                Text("vs").foregroundStyle(sh.textTertiary)
                if compare.basePicks {
                    Button { store.pickingBase = true } label: {
                        HStack(spacing: SH.Space.xs) {
                            Text(compare.base).lineLimit(1)
                            Image(systemName: "chevron.down").imageScale(.small)
                        }
                        .foregroundStyle(sh.textPrimary)
                        .shTouchTarget(height: MobileLayout.reviewCompareHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Base \(compare.base)")
                    .accessibilityHint("Compares against another branch")
                } else {
                    Text(compare.base).foregroundStyle(sh.textPrimary).lineLimit(1)
                }
                Spacer(minLength: SH.Space.s)
                if store.loaded {
                    Text(store.totals.viewedText).foregroundStyle(sh.textSecondary).lineLimit(1).fixedSize()
                }
            }
            .font(.sh(.mono))
            .padding(.horizontal, SH.Space.l)
            .frame(height: MobileLayout.reviewCompareHeight)
            .overlay(alignment: .bottom) { SHHairline() }
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
                withSHAnimation(.disclosure) { proxy.scrollTo(id, anchor: .top) }
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
        let sh = Color.sh
        let collapsed = store.collapsed.contains(entry.id)
        let viewed = store.viewed.contains(entry.id)
        let (directory, name) = reviewPathParts(entry.path)
        let status = SHFileStatus(ReviewFileStatus(entry.status))
        HStack(spacing: SH.Space.m) {
            Button { withSHAnimation(.disclosure) { store.toggleCollapsed(entry.id) } } label: {
                Text("\(name) · +\(entry.added) \u{2212}\(entry.removed)")
                    .font(.sh(.mono))
                    .foregroundStyle(sh.textPrimary)
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
                .toggleStyle(.shCheckbox)
                .font(.sh(.caption))
                .foregroundStyle(sh.textSecondary)
                .fixedSize()
                .shTouchTarget(height: SH.Height.touch)
        }
        .padding(.horizontal, SH.Space.m + SH.Space.xxs)
        .frame(height: SH.Height.touch)
        .background(sh.bgRaised)
        .overlay(alignment: .bottom) { SHHairline() }
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
            if let notice = store.copyNotice {
                HStack(spacing: SH.Space.m) {
                    Text(notice).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                    if let command = store.failedCopyCommand {
                        Button("Retry") { Task { await store.copyPatch(command: command) } }
                            .buttonStyle(.sh(.secondary))
                    }
                    if !store.copyingPatch {
                        Button("Dismiss") { store.copyNotice = nil }.buttonStyle(.sh(.ghost))
                    }
                }
                .padding(SH.Space.l)
            }
            if let error = store.actionError {
                SHBanner(.failed, title: "Couldn't send the comments", message: error) {
                    Button("Dismiss") { store.actionError = nil }.buttonStyle(.sh(.ghost, size: .s))
                }
                .padding(SH.Space.l)
            }
            if !store.comments.isEmpty {
                let sh = Color.sh
                HStack(spacing: SH.Space.m) {
                    Text(padPendingText(store.comments))
                        .font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Discard") { store.discardComments() }
                        .buttonStyle(.sh(.ghost, size: .l))
                        .disabled(store.submitting)
                        .accessibilityHint("Deletes the comments you haven't sent")
                    Button {
                        Task { if await store.sendComments(hosts: hosts) { close() } }
                    } label: {
                        HStack(spacing: SH.Space.s) {
                            if store.submitting { ProgressView().progressViewStyle(SHSpinnerStyle()) }
                            Text(store.sendTitle)
                        }
                    }
                    .buttonStyle(.sh(.primary, size: .l))
                    .disabled(!store.canSend)
                    .accessibilityHint("Sends your comments as the agent's next message")
                }
                .padding(.horizontal, SH.Space.l)
                .padding(.vertical, SH.Space.m)
                .frame(minHeight: MobileLayout.reviewSendBarHeight)
                .background(sh.bgWindow)
                .overlay(alignment: .top) { SHHairline() }
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
            // Half open (iPhone Duo), the file list ends at the fold and the files start after it.
            GeometryReader { proxy in
                let fold = proxy.verticalFold
                HStack(spacing: 0) {
                    PadFileList(store: store) { id in
                        store.clearSelection()
                        store.currentFile = id
                        scrollTarget = id
                    }
                    .paneWidth(fold?.lowerBound ?? MobileLayout.reviewFileListWidth)
                    .padding(.trailing, fold.map { $0.upperBound - $0.lowerBound } ?? 0)
                    SHHairline(.vertical)
                    PadChangesStack(store: store, scrollTarget: $scrollTarget, compact: fold != nil)
                        .frame(maxWidth: .infinity)
                }
            }
            PadSendBar(store: store, close: close)
        }
        .background(Color.sh.bgWindow)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: SH.Space.m) {
                    Button { withSHAnimation(.disclosure) { store.padLayout = .docked } } label: {
                        HStack(spacing: SH.Space.xs) {
                            Image(systemName: "chevron.left").font(.sh(.ui, weight: .semibold))
                            Text("Thread")
                        }
                    }
                    .accessibilityLabel("Back to the thread")
                    Text("Review").font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
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
        let sh = Color.sh
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.summaries) { summary in
                    let selected = summary.id == store.currentFile
                    Button { select(summary.id) } label: {
                        VStack(alignment: .leading, spacing: SH.Space.xs) {
                            Text(summary.name).font(.sh(.code)).foregroundStyle(sh.textPrimary)
                                .lineLimit(1).truncationMode(.middle)
                            Text("+\(summary.added) \u{2212}\(summary.removed)").font(.sh(.micro, weight: .regular))
                                .foregroundStyle(sh.textTertiary)
                        }
                        .padding(SH.Space.l)
                        .frame(maxWidth: .infinity, minHeight: MobileLayout.reviewFileRowHeight, alignment: .leading)
                        .opacity(summary.viewed && !selected ? MobileLayout.reviewViewedOpacity : 1)
                        .background(selected ? sh.bgSelected : .clear)
                        .overlay(alignment: .bottom) { SHHairline() }
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
