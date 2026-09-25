import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The Changes pane's menus over its content (ChangesScope, ChangesBase, ChangesUnified): the
/// scope menu under the scope button with the Commits submenu beside it, the base picker under
/// the compare row's base, and Diff options under More. A click anywhere else or esc closes
/// them.
struct ChangesMenus: View {
    let model: ReviewPaneModel
    let session: ReviewSession
    let baseAnchor: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let menu = model.menu {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeMenu() }
                    .accessibilityHidden(true)
                switch menu {
                case .scope, .commits:
                    ChangesScopeMenu(model: model, session: session)
                        .offset(x: NW.Space.l, y: NWChangesMetrics.toolbarHeight - NW.Space.xs)
                        .nwTransition(.overlay, edge: .top)
                    if menu == .commits {
                        ChangesCommitsMenu(model: model, session: session)
                            .offset(x: NW.Space.l + NWChangesMenuMetrics.scopeWidth + NW.Space.xs,
                                    y: NWChangesMetrics.toolbarHeight + ChangesMenuLayout.commitsTop)
                            .nwTransition(.overlay, edge: .leading)
                    }
                case .base:
                    ChangesBasePicker(model: model, session: session)
                        .offset(x: max(NW.Space.s, baseAnchor - NW.Space.s),
                                y: NWChangesMetrics.toolbarHeight + NWChangesMetrics.compareHeight - NW.Space.xs)
                        .nwTransition(.overlay, edge: .top)
                case .options:
                    ChangesOptionsMenu(model: model, session: session)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 10)
                        .offset(y: NWChangesMetrics.toolbarHeight - NW.Space.xs)
                        .nwTransition(.overlay, edge: .top)
                }
            }
        }
        .nwAnimation(.overlay, value: model.menu)
    }
}

enum ChangesMenuLayout {
    /// Where the Commits submenu sits beside its row: the scope menu's rows above Commits.
    static let commitsTop: CGFloat = 127
}

/// What to compare (ScopeMenu): Last turn, the working tree's three, Commits, Branch and Pull
/// request, each with its diff stat; the current one checked. A legacy review offers only its
/// two sides.
private struct ChangesScopeMenu: View {
    let model: ReviewPaneModel
    let session: ReviewSession

    var body: some View {
        NWChangesMenu(width: NWChangesMenuMetrics.scopeWidth) {
            if session.engine == nil {
                NWChangesMenuRow("Uncommitted", subtitle: session.reference.map { "vs \($0)" }, systemImage: NWChangesScopeGlyph.uncommitted.systemImage,
                                 checked: !session.isPRMode) { choose { model.actions.setPullRequest(false) } }
                NWChangesMenuRow("Pull request", systemImage: NWChangesScopeGlyph.pullRequest.systemImage,
                                 checked: session.isPRMode) { choose { model.actions.setPullRequest(true) } }
            } else {
                let overview = session.overview
                row(.lastTurn, subtitle: "What the agent changed since your last message", glyph: .lastTurn)
                NWChangesMenuDivider()
                row(.uncommitted, glyph: .uncommitted)
                row(.unstaged, glyph: nil)
                row(.staged, glyph: nil)
                NWChangesMenuDivider()
                let commits = entry(.commits)
                NWChangesMenuRow("Commits", subtitle: commits?.unavailable, systemImage: NWChangesScopeGlyph.commits.systemImage,
                                 trailing: commits?.count.map { .text("\($0)") } ?? .none, checked: session.scope.kind == .commits,
                                 hasSubmenu: true, highlighted: model.menu == .commits, enabled: commits?.unavailable == nil && overview != nil) {
                    model.menu = model.menu == .commits ? .scope : .commits
                }
                let branch = entry(.branch)
                let branchLine = overview.flatMap { overview in
                    overview.defaultBase.map { "\(overview.branch ?? overview.head ?? "HEAD") vs \(currentBase ?? $0)" }
                }
                NWChangesMenuRow("Branch", subtitle: branch?.unavailable ?? branchLine, systemImage: NWChangesScopeGlyph.branch.systemImage,
                                 trailing: stat(branch), checked: session.scope.kind == .branch, enabled: branch?.unavailable == nil) {
                    choose { model.actions.setScope(.branch(base: currentBase)) }
                }
                let pull = entry(.pullRequest)
                NWChangesMenuRow("Pull request", subtitle: pull?.unavailable, systemImage: NWChangesScopeGlyph.pullRequest.systemImage,
                                 trailing: overview?.pullRequest.map { .text($0.label) } ?? .none, checked: session.scope.kind == .pullRequest,
                                 enabled: pull?.unavailable == nil) {
                    choose { model.actions.setScope(.pullRequest) }
                }
                if overview == nil {
                    HStack(spacing: NW.Space.m) {
                        ProgressView().progressViewStyle(.nwSpinner(size: 10))
                        Text("Counting each scope…").font(.nwSans(11)).foregroundStyle(Color.nw.textTertiary)
                    }
                    .padding(.horizontal, NW.Space.m)
                    .padding(.vertical, NW.Space.s)
                }
            }
        }
    }

    private var currentBase: String? {
        if case .branch(let base) = session.scope { return base }
        return nil
    }

    private func entry(_ kind: ChangesScope.Kind) -> ChangesOverview.Entry? {
        session.overview?.entries.first { $0.scope.kind == kind }
    }

    private func stat(_ entry: ChangesOverview.Entry?) -> NWChangesMenuTrailing {
        guard let entry, let added = entry.added, let removed = entry.removed else { return .none }
        return .stat(added: added, removed: removed)
    }

    @ViewBuilder
    private func row(_ scope: ChangesScope, subtitle: String? = nil, glyph: NWChangesScopeGlyph?) -> some View {
        let entry = entry(scope.kind)
        NWChangesMenuRow(scope.label, subtitle: entry?.unavailable ?? subtitle, systemImage: glyph?.systemImage, trailing: stat(entry),
                         checked: session.scope.kind == scope.kind, enabled: entry?.unavailable == nil) {
            choose { model.actions.setScope(scope) }
        }
    }

    private func choose(_ action: () -> Void) {
        model.closeMenu()
        action()
    }
}

/// One commit, or a range with ⇧ (CommitsMenu): the branch's commits newest first.
private struct ChangesCommitsMenu: View {
    let model: ReviewPaneModel
    let session: ReviewSession
    @State private var anchor: String?

    var body: some View {
        let overview = session.overview
        let commits = overview?.commits ?? []
        NWChangesMenu(width: NWChangesMenuMetrics.commitsWidth) {
            NWChangesMenuTitle("On \(overview?.branch ?? overview?.head ?? "HEAD")")
            if let oldest = commits.last, let newest = commits.first {
                NWChangesMenuRow(overview?.commitsBase == nil ? "Recent commits" : "All commits on the branch", systemImage: "square.on.square",
                                 checked: session.scope == .commits(first: oldest.id, last: newest.id) && commits.count > 1) {
                    choose(.commits(first: oldest.id, last: newest.id))
                }
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(commits) { commit in
                        NWChangesMenuRow(commit.subject, systemImage: NWChangesScopeGlyph.commits.systemImage,
                                         trailing: .text("\(commit.shortID) · \(changesAge(commit.date))"),
                                         checked: isChosen(commit), highlighted: anchor == commit.id) {
                            pick(commit, in: commits)
                        }
                    }
                }
            }
            .frame(maxHeight: ChangesMenuLayout.listMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            NWChangesMenuDivider()
            NWChangesMenuNote("Pick two with ⇧ to see the range between them.")
        }
    }

    private func isChosen(_ commit: ChangesCommit) -> Bool {
        if case .commits(let first, let last) = session.scope, first == last { return first == commit.id }
        return false
    }

    /// A click picks one commit; ⇧-click after it picks the range between the two.
    private func pick(_ commit: ChangesCommit, in commits: [ChangesCommit]) {
        if NSEvent.modifierFlags.contains(.shift), let anchor, anchor != commit.id,
           let a = commits.firstIndex(where: { $0.id == anchor }), let b = commits.firstIndex(where: { $0.id == commit.id }) {
            // Newest first: the older of the two starts the range.
            choose(.commits(first: commits[max(a, b)].id, last: commits[min(a, b)].id))
            return
        }
        if NSEvent.modifierFlags.contains(.shift) {
            anchor = commit.id
            return
        }
        choose(.commits(first: commit.id, last: commit.id))
    }

    private func choose(_ scope: ChangesScope) {
        model.closeMenu()
        model.actions.setScope(scope)
    }
}

extension ChangesMenuLayout {
    /// The commits and branches lists scroll past this.
    static let listMaxHeight: CGFloat = 300
}

/// Compare against another branch (BasePicker): search, recents first, every branch by its last
/// commit, worktrees tagged; then a commit, or the PR's base.
private struct ChangesBasePicker: View {
    let model: ReviewPaneModel
    let session: ReviewSession
    @State private var query = ""
    @State private var pickingCommit = false
    @FocusState private var searching: Bool

    var body: some View {
        NWChangesMenu(width: NWChangesMenuMetrics.baseWidth) {
            NWChangesMenuSearch(text: $query, prompt: pickingCommit ? "Search commits" : "Search branches", isFocused: $searching,
                                onSubmit: { if let first = names.first { choose(first) } }, onEscape: { model.closeMenu() })
            if pickingCommit {
                NWChangesMenuTitle("Compare against a commit")
                list {
                    ForEach(commits) { commit in
                        NWChangesMenuRow(commit.subject, systemImage: NWChangesScopeGlyph.commits.systemImage,
                                         trailing: .text(commit.shortID)) { choose(commit.id) }
                    }
                }
            } else {
                NWChangesMenuTitle("Compare against")
                if let branches = session.branches {
                    list {
                        ForEach(names, id: \.self) { name in
                            let branch = branches.branches.first { $0.name == name }
                            NWChangesMenuRow(name, systemImage: "arrow.triangle.branch", titleIsMono: true,
                                             trailing: tag(name, branch: branch, in: branches), checked: name == currentBase) { choose(name) }
                        }
                    }
                    NWChangesMenuDivider()
                    NWChangesMenuRow("A commit…", systemImage: NWChangesScopeGlyph.commits.systemImage,
                                     enabled: !(session.overview?.commits.isEmpty ?? true)) { pickingCommit = true }
                    if let pullBase = branches.pullRequestBase {
                        NWChangesMenuRow("The PR’s base", systemImage: NWChangesScopeGlyph.pullRequest.systemImage,
                                         trailing: .text(pullBase)) { choose(pullBase) }
                    }
                } else {
                    HStack(spacing: NW.Space.m) {
                        ProgressView().progressViewStyle(.nwSpinner(size: 10))
                        Text("Reading branches…").font(.nwSans(11)).foregroundStyle(Color.nw.textTertiary)
                    }
                    .padding(.horizontal, NW.Space.m)
                    .frame(height: NWChangesMenuMetrics.rowHeight)
                }
            }
        }
    }

    private func list<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView { VStack(spacing: 0) { content() } }
            .frame(maxHeight: ChangesMenuLayout.listMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var currentBase: String? {
        if case .branch(let base?) = session.scope { return base }
        return session.list?.comparison.base ?? session.branches?.defaultBase
    }

    /// Recents first, then every branch by its last commit, without the checked-out one, filtered.
    private var names: [String] {
        guard !pickingCommit, let branches = session.branches else { return [] }
        var seen = Set<String>()
        let current = Set(branches.branches.filter(\.isCurrent).map(\.name))
        let ordered = (branches.defaultBase.map { [$0] } ?? []) + branches.recents + branches.branches.map(\.name)
        return ordered.filter { !current.contains($0) && seen.insert($0).inserted }
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }

    private var commits: [ChangesCommit] {
        (session.overview?.commits ?? []).filter { query.isEmpty || $0.subject.localizedCaseInsensitiveContains(query) || $0.shortID.hasPrefix(query) }
    }

    private func tag(_ name: String, branch: ChangesBranch?, in branches: ChangesBranches) -> NWChangesMenuTrailing {
        if name == branches.defaultBase { return .text("default") }
        if branch?.worktree != nil { return .text("worktree") }
        return .none
    }

    private func choose(_ base: String) {
        model.closeMenu()
        model.actions.setScope(.branch(base: base))
    }
}

/// Diff options (DiffOptions, under More): toggles that stay open, then the patch and the editor.
private struct ChangesOptionsMenu: View {
    let model: ReviewPaneModel
    @Bindable var session: ReviewSession

    var body: some View {
        NWChangesMenu(width: NWChangesMenuMetrics.optionsWidth) {
            NWChangesMenuTitle("Diff")
            NWChangesMenuToggle("Word diffs", systemImage: "text.word.spacing", isOn: $session.wordDiffs)
            if session.engine != nil {
                NWChangesMenuToggle("Hide whitespace changes", systemImage: "space", isOn: option(\.ignoreWhitespace))
                NWChangesMenuToggle("Load full files", subtitle: "Expand past folds without a round trip", systemImage: "folder",
                                    isOn: option(\.fullFiles))
                NWChangesMenuDivider()
                NWChangesMenuRow("Copy git apply command", systemImage: "terminal", enabled: session.list != nil && !session.files.isEmpty) {
                    model.closeMenu()
                    model.actions.copyPatch(true)
                }
                NWChangesMenuRow("Copy as patch", systemImage: "doc.on.doc", enabled: session.list != nil && !session.files.isEmpty) {
                    model.closeMenu()
                    model.actions.copyPatch(false)
                }
            }
            if let open = model.actions.open {
                NWChangesMenuRow("Open in your editor", systemImage: "arrow.up.forward.square", trailing: .text("⇧⌘O"),
                                 enabled: !session.files.isEmpty) {
                    model.closeMenu()
                    if let file = session.files.first(where: { $0.id == model.currentFile }) ?? session.files.first { open(file) }
                }
            }
        }
    }

    /// An engine option: changing it loads the diff again.
    private func option(_ key: WritableKeyPath<ChangesOptions, Bool>) -> Binding<Bool> {
        Binding(get: { session.options[keyPath: key] }, set: { value in
            var options = session.options
            options[keyPath: key] = value
            model.actions.setOptions(options)
        })
    }
}

/// The Changes tab's items in the side pane's ⋯ menu: Maximize (ChangesWide), Expand and Collapse
/// All Files, Copy Review as Text. Without a `model` the items find the pane drawing the review
/// when chosen (`ReviewSession.paneModel`, unobserved): the strip draws before its pane appears.
struct ReviewOptionItems: View {
    let session: ReviewSession
    var model: ReviewPaneModel?
    var maximized = false
    var toggleMaximized: (() -> Void)? = nil

    var body: some View {
        if let toggleMaximized {
            Button(maximized ? "Restore the Thread" : "Maximize Pane", action: toggleMaximized)
            Divider()
        }
        Button("Expand All Files") { (model ?? session.paneModel)?.expandAllFiles() }
            .disabled(session.files.isEmpty)
        Button("Collapse All Files") { (model ?? session.paneModel)?.collapseAllFiles() }
            .disabled(session.files.isEmpty)
        Divider()
        Button("Copy Review as Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(formatChangesReview(fileIDs: session.files.map(\.id), comments: session.comments,
                                                               scopeTitle: session.scopeTitle), forType: .string)
        }
        .disabled(session.files.isEmpty)
    }
}
