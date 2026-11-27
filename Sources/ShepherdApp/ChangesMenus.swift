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
    /// The side pane's Changes tab has no toolbar to hang the menus from: they open at its top right, from the pane's ⋯ menu.
    var compact = false

    var body: some View {
        if compact { compactBody } else { toolbarBody }
    }

    private var compactBody: some View {
        ZStack(alignment: .topTrailing) {
            if let menu = model.menu {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeMenu() }
                    .accessibilityHidden(true)
                switch menu {
                case .scope, .commits:
                    ChangesScopeMenu(model: model, session: session)
                        .padding(.trailing, SH.Space.m)
                        .shTransition(.overlay, edge: .top)
                    if menu == .commits {
                        ChangesCommitsMenu(model: model, session: session)
                            .padding(.trailing, SH.Space.m + SHChangesMenuMetrics.scopeWidth + SH.Space.xs)
                            .offset(y: ChangesMenuLayout.commitsTop)
                            .shTransition(.overlay, edge: .leading)
                    }
                case .base:
                    ChangesBasePicker(model: model, session: session)
                        .padding(.trailing, SH.Space.m)
                        .shTransition(.overlay, edge: .top)
                case .options:
                    ChangesOptionsMenu(model: model, session: session)
                        .padding(.trailing, SH.Space.m)
                        .shTransition(.overlay, edge: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .shAnimation(.overlay, value: model.menu)
    }

    private var toolbarBody: some View {
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
                if !session.pullRequestOnly {
                    SHChangesMenuRow("Uncommitted", subtitle: session.reference.map { "vs \($0)" }, systemImage: SHChangesScopeGlyph.uncommitted.systemImage,
                                     checked: !session.isPRMode) { choose { model.actions.setPullRequest(false) } }
                }
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
                Text("Counting each scope…").font(.shSans(11)).shShimmer(active: true)
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
                    if let problem = branches.recentsProblem {
                        SHBanner(.failed, title: "Recent bases", message: problem)
                            .padding(.horizontal, SH.Space.m)
                    }
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
                } else if let failure = session.branchesError {
                    SHChangesMenuNote(failure)
                } else {
                    Text("Reading branches…").font(.shSans(11)).shShimmer(active: true)
                    .padding(.horizontal, SH.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            SHChangesMenuToggle("Wrap lines", systemImage: "arrow.turn.down.left", isOn: $session.wrapLines)
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

/// The Changes tab's items in the side pane's ⋯ menu: Maximize (ChangesWide), and in the tab itself (`compact`, which draws only the
/// branch card, the files and one diff) everything the toolbar and the file header carry: the file's Viewed mark, comment, editor,
/// whole file, revert and path; Compare (the scope menu), Base, Commit…, Refresh, the diff's layout and options. Expand and
/// Collapse All Files, Copy Review as Text. Without a `model` the items find the pane drawing the review when chosen
/// (`ReviewSession.paneModel`, unobserved): the strip draws before its pane appears.
struct ReviewOptionItems: View {
    let session: ReviewSession
    var model: ReviewPaneModel?
    var maximized = false
    var compact = false
    var toggleMaximized: (() -> Void)? = nil

    var body: some View {
        let pane = model ?? session.paneModel
        if let toggleMaximized {
            Button(maximized ? "Restore the Thread" : "Maximize Pane", action: toggleMaximized)
            Divider()
        }
        if compact, let pane {
            ReviewCompactItems(model: pane, session: session)
            Divider()
        }
        if !compact {
            Button("Expand All Files") { pane?.expandAllFiles() }
                .disabled(session.files.isEmpty)
            Button("Collapse All Files") { pane?.collapseAllFiles() }
                .disabled(session.files.isEmpty)
            Divider()
        }
        Button("Copy Review as Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(formatChangesReview(fileIDs: session.files.map(\.id), comments: session.comments,
                                                               scopeTitle: session.scopeTitle), forType: .string)
        }
        .disabled(session.files.isEmpty)
    }
}

/// What the toolbar, the compare row and the file header hold, as menu items (the side pane's Changes tab draws none of them).
private struct ReviewCompactItems: View {
    let model: ReviewPaneModel
    let session: ReviewSession

    var body: some View {
        let file = session.files.first { $0.id == model.currentFile } ?? session.files.first
        if let file {
            let viewed = session.viewed.contains(file.id)
            Button(viewed ? "Mark \(SHFileHeader.split(file.displayPath).name) Not Viewed" : "Mark \(SHFileHeader.split(file.displayPath).name) Viewed") {
                model.toggleViewed(file.id)
            }
            Button("Comment on \(SHFileHeader.split(file.displayPath).name)…") { model.startFileComment(file.id) }
                .disabled(file.isBinary)
            if let open = model.actions.open { Button("Open in Your Editor") { open(file) } }
            Button("Show Whole File") { model.revealWholeFile(file.id) }
                .disabled(file.isBinary)
            if canRevert, let revert = model.actions.revert {
                Button("Revert File…") {
                    if AppSettings.shared.skipped(.revertFile) != nil { revert(file, model.cwd) } else { model.reverting = file }
                }
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.displayPath, forType: .string)
            }
            Divider()
        }
        let files = session.files.count
        if files > 0 {
            Text("\(session.viewed.intersection(session.files.map(\.id)).count) of \(files) viewed")
        }
        Button("Compare: \(ChangesText.scopeButton(session))…") { model.toggleMenu(.scope) }
        if session.engine != nil, session.scope.kind == .branch {
            Button("Base: \(session.list?.comparison.base ?? "choose")…") {
                if session.branches == nil { model.actions.loadBranches() }
                model.toggleMenu(.base)
            }
        }
        Button("Commit…") { model.commit() }
            .disabled(!model.canCommit)
        Button("Refresh") { model.actions.refresh() }
            .disabled(session.isLoading)
        Divider()
        Button(model.layout == .split ? "Show Unified Diff" : "Show Split Diff") { model.toggleLayout() }
        Button("Diff Options…") { model.toggleMenu(.options) }
    }

    private var canRevert: Bool {
        session.engine == nil ? !session.isPRMode : session.scope == .uncommitted
    }
}

extension ReviewPaneModel {
    /// Commit… works on the working tree, with changes to commit.
    var canCommit: Bool {
        guard !session.isSubmitting, !session.files.isEmpty else { return false }
        return session.engine == nil ? !session.isPRMode : session.scope.comparesWorkingTree
    }

    /// The sheet where the host commits from review; otherwise the agent is asked to.
    func commit() {
        if actions.canCommitDirectly() { commitStore = actions.commitStore() } else { actions.commit() }
    }
}
