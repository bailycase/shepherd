import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI

/// The branch card over a thread's top right (BranchCard board), shown while the thread works
/// in a git checkout. Where the transcript's column and the card both fit beside each other it is
/// the whole card; narrower (the side pane open, a small window), it folds to one row that opens
/// on hover or a click, so it never sits on the transcript's text. It reads only while its thread
/// is on screen, and never takes focus.
/// The thread with its branch card (BranchCard board): wide enough, the card takes a column at the
/// right and the transcript centers in the rest; narrower, the card folds to one row over the corner.
struct BranchCardDock: ViewModifier {
    let store: BranchCardStore?
    let branch: String?
    /// The checkout's changed-file count, for a layout whose model carries it (a remote page's):
    /// the card reads again when it moves. A local layout leaves it 0 and the view model asks
    /// the store instead, so the count is no input of the layout.
    var changedFiles = 0
    let active: Bool
    @State private var wide = true

    func body(content: Content) -> some View {
        let docked = wide && store?.card != nil
        content
            .padding(.trailing, docked ? AppLayout.branchCardColumn : 0)
            .overlay(alignment: .topTrailing) {
                if let store, let branch {
                    BranchCardOverlay(store: store, branch: branch, active: active, wide: wide)
                }
            }
            .onGeometryChange(for: Bool.self) { $0.size.width >= AppLayout.branchCardWideThread } action: { wide = $0 }
            // On the thread, not the card: the card draws nothing until its first read lands.
            .task(id: store.flatMap { store in
                branch.map { ReadKey(branch: $0, changedFiles: changedFiles, active: active, request: store.refreshRequest) }
            }) {
                guard let store, active else { return }
                while !Task.isCancelled {
                    await store.refresh()
                    try? await Task.sleep(for: BranchCardStore.interval)
                }
            }
    }

    /// Read again when the branch moves, a turn ends, the view model asks (its checkout's count
    /// moved while the thread was on screen), or the thread shows.
    private struct ReadKey: Equatable {
        let branch: String
        let changedFiles: Int
        let active: Bool
        let request: Int
    }
}

struct BranchCardOverlay: View {
    let store: BranchCardStore
    let branch: String
    let active: Bool
    /// The thread docks the whole card (`BranchCardDock`); else it folds to one row.
    let wide: Bool
    @State private var hovering = false
    @State private var pinnedOpen = false
    /// Switch branch and Change base show the Branch picker in the card's place.
    @State private var picking: Picking?

    enum Picking { case branch, base }

    var body: some View {
        Group {
            if let card = store.card {
                if let picking {
                    picker(picking, card: card)
                } else if wide || hovering || pinnedOpen {
                    BranchCardView(card: card, status: store.status) { action in
                        switch action {
                        case .pickBranch: picking = .branch
                        case .pickBase: picking = .base
                        default:
                            pinnedOpen = false
                            store.handle.perform(action)
                        }
                    }
                    .shCard(lift: true)
                } else {
                    Button { pinnedOpen = true } label: { BranchCardCompact(branch: card.branch, git: store.status?.git) }
                        .buttonStyle(.plain)
                        .help("\(card.branch): show the branch card")
                }
            }
        }
        .onHover { inside in
            hovering = inside && !wide
            if !inside { pinnedOpen = false }
        }
        .onExitCommand { picking = nil }
        .padding(.top, AppLayout.branchCardTop)
        .padding(.trailing, SH.Space.xl)
        .focusable(false)
        .shAnimation(.content, value: wide || hovering || pinnedOpen || picking != nil)
        // The pane's width decides the form; only crossing the line redraws it.
        .frame(maxWidth: .infinity, alignment: .topTrailing)
    }
}

extension BranchCardOverlay {
    @ViewBuilder fileprivate func picker(_ mode: Picking, card: BranchCardModel) -> some View {
        let handle = store.handle
        let directory = card.directory
        let fetch: () async throws -> Void = {
            guard let directory else { return }
            try await Task.detached { try BranchGit.fetchAll(cwd: directory) }.value
        }
        let finish: (BranchCardAction?) -> Void = { action in
            picking = nil
            pinnedOpen = false
            if let action { handle.perform(action) }
        }
        switch mode {
        case .branch:
            BranchPickerMenu(title: "Switch branch", selected: card.branch, load: handle.branches,
                             choose: { finish($0.map(BranchCardAction.switchBranch)) },
                             move: { finish(.moveToCheckout($0, $1)) },
                             newBranch: { finish(.newBranch) }, fetch: fetch, close: { picking = nil })
        case .base:
            BranchPickerMenu(title: "Change base", selected: store.status?.git.base.map { "origin/\($0)" }, load: handle.branches,
                             choose: { finish($0.map(BranchCardAction.changeBase)) }, fetch: fetch, close: { picking = nil })
        }
    }
}

/// The folded card: the branch, its +/- and how far behind, on one row.
struct BranchCardCompact: View {
    let branch: String
    let git: BranchCardGit?

    var body: some View {
        HStack(spacing: SH.Space.s) {
            Image(systemName: SHGlyph.gitBranch.symbolName).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
            Text(branch).font(.sh(.mono)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.middle)
            if let git {
                SHDiffStat(added: git.additions, removed: git.deletions, font: .sh(.mono))
                if git.behind > 0 {
                    Text("↓\(git.behind)").font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary)
                        .accessibilityLabel("\(git.behind) behind \(git.base ?? "base")")
                }
            }
        }
        .padding(.horizontal, SH.Space.m)
        .frame(height: SH.Height.controlS)
        .frame(maxWidth: AppLayout.branchCardCompactMaxWidth)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.s)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The card itself, from values (the boards' `.bk`): the branch with its switcher and +/−, then a row each for the pull
/// request and its checks, how far behind the base it is with Update, and the space's other branches, which open in place.
struct BranchCardView: View {
    let card: BranchCardModel
    let status: BranchCardStatus?
    let perform: (BranchCardAction) -> Void
    @State private var othersOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.m) {
                Button { perform(.pickBranch) } label: {
                    HStack(spacing: SH.Space.xs) {
                        Text(card.branch).font(.sh(.mono, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        SHChipChevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Switch branch")
                Spacer(minLength: SH.Space.m)
                if let git = status?.git {
                    Button { perform(.showChanges) } label: { SHDiffStat(added: git.additions, removed: git.deletions, font: .sh(.caption)) }
                        .buttonStyle(.plain)
                        .help("Show Changes")
                }
                SHOptionsMenu("Branch actions", size: SH.Height.controlS + 2) { menu }
            }
            .padding(EdgeInsets(top: SH.Space.m, leading: AppLayout.branchCardInset, bottom: SH.Space.xs, trailing: SH.Space.xs))
            if let pull = status?.pull {
                Button { perform(.openPull(pull.ref)) } label: {
                    row {
                        Text("Pull request #\(pull.ref.number)")
                    } value: {
                        let word = Self.pullWord(pull)
                        // Passing checks are the boards' green tick before quiet words; anything else says itself in its color.
                        let passed = pull.checks == .passed && pull.state != .merged && pull.state != .closed
                        if passed {
                            SHGlyph.resolved.image.foregroundStyle(Color.sh.done).accessibilityHidden(true)
                        }
                        Text(word.text).foregroundStyle(passed ? Color.sh.textSecondary : word.color)
                    }
                }
                .buttonStyle(.shRow(radius: 0))
            }
            if let git = status?.git, let base = git.base, git.behind > 0 {
                row {
                    Text(base).font(.sh(.mono))
                } value: {
                    Text("\(git.behind) new commit\(git.behind == 1 ? "" : "s")")
                    Button("Update") { perform(.update) }
                        .buttonStyle(.plain)
                        .font(.sh(.ui, weight: .medium))
                        .foregroundStyle(Color.sh.textPrimary)
                        .padding(.leading, SH.Space.s)
                        .help("Update from \(base)")
                }
            }
            if !card.others.isEmpty {
                Button { withSHAnimation(.disclosure) { othersOpen.toggle() } } label: {
                    row {
                        Text(card.others.count == 1 ? "1 other branch" : "\(card.others.count) other branches")
                    } value: {
                        SHTurningChevron(isOpen: othersOpen).foregroundStyle(Color.sh.textTertiary)
                    }
                }
                .buttonStyle(.shRow(radius: 0))
                .accessibilityValue(othersOpen ? "shown" : "hidden")
                if othersOpen {
                    ForEach(card.others) { other in
                        Button { perform(.select(other.id)) } label: {
                            row {
                                Text(other.branch).font(.sh(.mono)).lineLimit(1).truncationMode(.middle)
                            } value: {
                                Text(other.detail)
                            }
                        }
                        .buttonStyle(.shRow(radius: 0))
                        .accessibilityLabel("\(other.branch), \(other.detail)")
                    }
                }
            }
        }
        .padding(.bottom, SH.Space.s)
        .frame(width: AppLayout.branchCardWidth)
    }

    @ViewBuilder private var menu: some View {
        let git = status?.git
        Button("Commit…") { perform(.commit) }
        Button(Self.pushTitle(git?.ahead ?? 0)) { perform(.push) }.disabled(git == nil || git?.ahead == 0)
        Button("Update from \(git?.base ?? "Base")") { perform(.update) }.disabled(git?.base == nil)
        Divider()
        Button("Switch Branch…") { perform(.pickBranch) }
        Button("New Branch from Here…") { perform(.newBranch) }
        Button("Rename Branch…") { perform(.renameBranch) }
        if card.worktree { Button("Change Base…") { perform(.pickBase) } }
        Divider()
        Button("Copy Branch Name") { perform(.copyBranch) }
        if card.directory != nil { Button("Show in Finder") { perform(.showInFinder) } }
    }

    /// The boards' `.bkr`: a 28pt row, what it is in `ui` at its start and its value in `caption` `textSecondary` at its end.
    private func row<Key: View, Value: View>(@ViewBuilder _ key: () -> Key, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: SH.Space.l) {
            key().font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: SH.Space.xs + 1) { value() }
                .font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, AppLayout.branchCardInset)
        .frame(maxWidth: .infinity, minHeight: SH.Height.row, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// "Push 2 Commits", "Push 1 Commit", or "Push" with nothing to send.
    static func pushTitle(_ ahead: Int) -> String {
        ahead == 0 ? "Push" : "Push \(ahead) Commit\(ahead == 1 ? "" : "s")"
    }

    /// A finished pull request says how it ended; an open one, its checks.
    static func pullWord(_ pull: PullRequestSummary) -> (text: String, color: Color) {
        let (text, state): (String, AgentState) = switch (pull.state, pull.checks) {
        case (.merged, _): ("Merged", .done)
        case (.closed, _): ("Closed", .idle)
        case (_, .passed): ("Checks passed", .done)
        case (_, .failing): ("Checks failed", .failed)
        case (_, .running): ("Checks running", .running)
        case (.draft, .none): ("Draft", .idle)
        case (.open, .none): ("Open", .idle)
        }
        return (text, state.textColor)
    }
}
