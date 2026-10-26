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
                        .offset(x: SH.Space.l, y: SHChangesMetrics.toolbarHeight - SH.Space.xs)
                        .shTransition(.overlay, edge: .top)
                    if menu == .commits {
                        ChangesCommitsMenu(model: model, session: session)
                            .offset(x: SH.Space.l + SHChangesMenuMetrics.scopeWidth + SH.Space.xs,
                                    y: SHChangesMetrics.toolbarHeight + ChangesMenuLayout.commitsTop)
                            .shTransition(.overlay, edge: .leading)
                    }
                case .base:
                    ChangesBasePicker(model: model, session: session)
                        .offset(x: max(SH.Space.s, baseAnchor - SH.Space.s),
                                y: SHChangesMetrics.toolbarHeight + SHChangesMetrics.compareHeight - SH.Space.xs)
                        .shTransition(.overlay, edge: .top)
                case .options:
                    ChangesOptionsMenu(model: model, session: session)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 10)
                        .offset(y: SHChangesMetrics.toolbarHeight - SH.Space.xs)
                        .shTransition(.overlay, edge: .top)
                }
            }
        }
        .shAnimation(.overlay, value: model.menu)
    }
}

enum ChangesMenuLayout {
    /// Where the Commits submenu sits beside its row: the scope menu's rows above Commits.
    static let commitsTop: CGFloat = 127
}

/// What to compare (ScopeMenu): Last turn, the working tree's three, Commits, Branch and Pull
/// request, each with its diff stat; the current one checked (`changesScopeOptions`, shared with
/// iOS). A legacy review offers only its two sides.
private struct ChangesScopeMenu: View {
    let model: ReviewPaneModel
    let session: ReviewSession

    var body: some View {
        SHChangesMenu(width: SHChangesMenuMetrics.scopeWidth) {
            if session.engine == nil {
                SHChangesMenuRow("Uncommitted", subtitle: session.reference.map { "vs \($0)" }, systemImage: SHChangesScopeGlyph.uncommitted.systemImage,
                                 checked: !session.isPRMode) { choose { model.actions.setPullRequest(false) } }
                SHChangesMenuRow("Pull request", systemImage: SHChangesScopeGlyph.pullRequest.systemImage,
                                 checked: session.isPRMode) { choose { model.actions.setPullRequest(true) } }
            } else if let overview = session.overview {
                ForEach(changesScopeOptions(overview, selected: session.scope, base: currentBase)) { option in
                    VStack(spacing: 0) {
                        if option.startsGroup { SHChangesMenuDivider() }
                        row(option)
                    }
                }
            } else {
                HStack(spacing: SH.Space.m) {
                    ProgressView().progressViewStyle(.shSpinner(size: 10))
                    Text("Counting each scope…").font(.shSans(11)).foregroundStyle(Color.sh.textTertiary)
                }
                .padding(.horizontal, SH.Space.m)
                .padding(.vertical, SH.Space.s)
            }
        }
    }

    @ViewBuilder
    private func row(_ option: ChangesScopeOption) -> some View {
        let subtitle = option.unavailable ?? option.detail
        if option.kind == .commits {
            SHChangesMenuRow(option.title, subtitle: subtitle, systemImage: glyph(option.kind)?.systemImage,
                             trailing: option.trailing.map { .text($0) } ?? .none, checked: option.selected,
                             hasSubmenu: true, highlighted: model.menu == .commits, enabled: option.available) {
                model.menu = model.menu == .commits ? .scope : .commits
            }
        } else {
            SHChangesMenuRow(option.title, subtitle: subtitle, systemImage: glyph(option.kind)?.systemImage, trailing: trailing(option),
                             checked: option.selected, enabled: option.available) {
                choose { model.actions.setScope(option.scope) }
            }
        }
    }

    private var currentBase: String? {
        if case .branch(let base) = session.scope { return base }
        return nil
    }

    /// Unstaged and Staged sit under Uncommitted without a glyph of their own.
    private func glyph(_ kind: ChangesScope.Kind) -> SHChangesScopeGlyph? {
        switch kind {
        case .lastTurn: .lastTurn
        case .uncommitted: .uncommitted
        case .unstaged, .staged: nil
        case .commits: .commits
        case .branch: .branch
        case .pullRequest: .pullRequest
        }
    }

    private func trailing(_ option: ChangesScopeOption) -> SHChangesMenuTrailing {
        if let added = option.added, let removed = option.removed { return .stat(added: added, removed: removed) }
        return option.trailing.map { .text($0) } ?? .none
    }

    private func choose(_ action: () -> Void) {
        model.closeMenu()
        action()
    }
}

/// One commit, or a range with ⇧ (CommitsMenu): the branch's commits newest first
/// (`changesCommitOptions`, shared with iOS).
private struct ChangesCommitsMenu: View {
    let model: ReviewPaneModel
    let session: ReviewSession
    @State private var anchor: String?

    var body: some View {
        let overview = session.overview
        let options = overview.map { changesCommitOptions($0, selected: session.scope) } ?? []
        SHChangesMenu(width: SHChangesMenuMetrics.commitsWidth) {
            SHChangesMenuTitle("On \(overview?.branch ?? overview?.head ?? "HEAD")")
            if let all = options.first {
                SHChangesMenuRow(all.title, systemImage: "square.on.square", checked: all.selected) { choose(all.scope) }
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options.dropFirst()) { option in
                        SHChangesMenuRow(option.title, systemImage: SHChangesScopeGlyph.commits.systemImage,
                                         trailing: option.detail.map { .text($0) } ?? .none,
                                         checked: option.selected, highlighted: anchor == option.id) {
                            pick(option.id, in: overview?.commits ?? [])
                        }
                    }
                }
            }
            .frame(maxHeight: ChangesMenuLayout.listMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            SHChangesMenuDivider()
            SHChangesMenuNote("Pick two with ⇧ to see the range between them.")
        }
    }

    /// A click picks one commit; ⇧-click after it picks the range between the two.
    private func pick(_ id: String, in commits: [ChangesCommit]) {
        if NSEvent.modifierFlags.contains(.shift), let anchor, anchor != id,
           let a = commits.firstIndex(where: { $0.id == anchor }), let b = commits.firstIndex(where: { $0.id == id }) {
            // Newest first: the older of the two starts the range.
            choose(.commits(first: commits[max(a, b)].id, last: commits[min(a, b)].id))
            return
        }
        if NSEvent.modifierFlags.contains(.shift) {
            anchor = id
            return
        }
        choose(.commits(first: id, last: id))
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

/// Compare against another branch (BasePicker): search, then the default base, recents and every
/// branch by its last commit, worktrees tagged (`changesBaseOptions`, shared with iOS); then a
/// commit, or the PR's base.
private struct ChangesBasePicker: View {
    let model: ReviewPaneModel
    let session: ReviewSession
    @State private var query = ""
    @State private var pickingCommit = false
    @FocusState private var searching: Bool

    var body: some View {
        let options = pickingCommit ? [] : session.branches.map { changesBaseOptions($0, selected: currentBase, query: query) } ?? []
        SHChangesMenu(width: SHChangesMenuMetrics.baseWidth) {
            SHChangesMenuSearch(text: $query, prompt: pickingCommit ? "Search commits" : "Search branches", isFocused: $searching,
                                onSubmit: {
                                    if pickingCommit { if let first = commits.first { choose(first.id) } }
                                    else if let first = options.first { choose(first.name) }
                                }, onEscape: { model.closeMenu() })
            if pickingCommit {
                SHChangesMenuTitle("Compare against a commit")
                list {
                    ForEach(commits) { commit in
                        SHChangesMenuRow(commit.subject, systemImage: SHChangesScopeGlyph.commits.systemImage,
                                         trailing: .text(commit.shortID)) { choose(commit.id) }
                    }
                }
            } else {
                SHChangesMenuTitle("Compare against")
                if let branches = session.branches {
                    list {
                        ForEach(options) { option in
                            SHChangesMenuRow(option.name, systemImage: SHGlyph.gitBranch.symbolName, titleIsMono: true,
                                             trailing: option.tag.map { .text($0) } ?? .none, checked: option.selected) { choose(option.name) }
                        }
                    }
                    SHChangesMenuDivider()
                    SHChangesMenuRow("A commit…", systemImage: SHChangesScopeGlyph.commits.systemImage,
                                     enabled: !(session.overview?.commits.isEmpty ?? true)) { pickingCommit = true }
                    if let pullBase = branches.pullRequestBase {
                        SHChangesMenuRow("The PR’s base", systemImage: SHChangesScopeGlyph.pullRequest.systemImage,
                                         trailing: .text(pullBase)) { choose(pullBase) }
                    }
                } else {
                    HStack(spacing: SH.Space.m) {
                        ProgressView().progressViewStyle(.shSpinner(size: 10))
                        Text("Reading branches…").font(.shSans(11)).foregroundStyle(Color.sh.textTertiary)
                    }
                    .padding(.horizontal, SH.Space.m)
                    .frame(height: SHChangesMenuMetrics.rowHeight)
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

    private var commits: [ChangesCommit] {
        (session.overview?.commits ?? []).filter { query.isEmpty || $0.subject.localizedCaseInsensitiveContains(query) || $0.shortID.hasPrefix(query) }
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
        SHChangesMenu(width: SHChangesMenuMetrics.optionsWidth) {
            SHChangesMenuTitle("Diff")
            SHChangesMenuToggle("Word diffs", systemImage: "text.word.spacing", isOn: $session.wordDiffs)
            if session.engine != nil {
                SHChangesMenuToggle("Hide whitespace changes", systemImage: "space", isOn: option(\.ignoreWhitespace))
                SHChangesMenuToggle("Load full files", subtitle: "Expand past folds without a round trip", systemImage: "folder",
                                    isOn: option(\.fullFiles))
                SHChangesMenuDivider()
                SHChangesMenuRow("Copy git apply command", systemImage: "terminal", enabled: session.list != nil && !session.files.isEmpty) {
                    model.closeMenu()
                    model.actions.copyPatch(true)
                }
                SHChangesMenuRow("Copy as patch", systemImage: "doc.on.doc", enabled: session.list != nil && !session.files.isEmpty) {
                    model.closeMenu()
                    model.actions.copyPatch(false)
                }
            }
            if let open = model.actions.open {
                SHChangesMenuRow("Open in your editor", systemImage: "arrow.up.forward.square", trailing: .text("⇧⌘O"),
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
