import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
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
    let branch: AgentBranchLabel?
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
            .task(id: store.map { ReadKey(branch: branch, active: active, request: $0.refreshRequest) }) {
                guard let store, active else { return }
                while !Task.isCancelled {
                    await store.refresh()
                    try? await Task.sleep(for: BranchCardStore.interval)
                }
            }
    }

    /// Read again when the branch or its changed files move, a turn ends, or the thread shows.
    private struct ReadKey: Equatable {
        let branch: AgentBranchLabel?
        let active: Bool
        let request: Int
    }
}

struct BranchCardOverlay: View {
    let store: BranchCardStore
    let branch: AgentBranchLabel
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
                    .shPopover()
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
        .padding(.top, SH.Space.m)
        .padding(.trailing, SH.Space.l)
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

/// The card itself, from values: the space and its menu, the branch, Changes, how far behind the
/// base, the pull request and its checks, then the space's other branches.
struct BranchCardView: View {
    let card: BranchCardModel
    let status: BranchCardStatus?
    let perform: (BranchCardAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(card.space).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                Spacer(minLength: SH.Space.m)
                SHOptionsMenu("Branch actions", size: SH.Height.controlS) { menu }
            }
            .padding(.leading, AppLayout.branchCardInset).padding(.trailing, SH.Space.s)
            Button { perform(.pickBranch) } label: {
                row(SHGlyph.gitBranch.symbolName) {
                    Text(card.branch).font(.sh(.code)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: SH.Space.m)
                    Image(systemName: "chevron.right").font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                }
            }
            .buttonStyle(.shRow(radius: 0))
            .help("Switch branch")
            Button { perform(.showChanges) } label: {
                row("plus.forwardslash.minus") {
                    Text("Changes")
                    Spacer(minLength: SH.Space.m)
                    if let git = status?.git { SHDiffStat(added: git.additions, removed: git.deletions, font: .sh(.caption)) }
                }
            }
            .buttonStyle(.shRow(radius: 0))
            if let git = status?.git, let base = git.base, git.behind > 0 {
                row("arrow.down") {
                    Text("\(git.behind) behind \(base)")
                    Spacer(minLength: SH.Space.m)
                    Button("Update") { perform(.update) }
                        .buttonStyle(.shLink(font: .sh(.caption)))
                        .help("Update from \(base)")
                }
            }
            if let pull = status?.pull {
                Button { perform(.openPull(pull.ref)) } label: {
                    row(ForgeSymbol.pullRequest) {
                        Text("Pull request #\(pull.ref.number)")
                        Spacer(minLength: SH.Space.m)
                        let word = Self.pullWord(pull)
                        Text(word.text).font(.sh(.caption)).foregroundStyle(word.color)
                    }
                }
                .buttonStyle(.shRow(radius: 0))
            }
            if !card.others.isEmpty {
                SHHairline().padding(.top, SH.Space.s)
                Text("Other branches in \(card.space)").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    .padding(.horizontal, AppLayout.branchCardInset).padding(.top, SH.Space.l).padding(.bottom, SH.Space.xs)
                ForEach(card.others) { other in
                    Button { perform(.select(other.id)) } label: {
                        row(nil) {
                            SHStatusDot(other.state)
                                .frame(width: AppLayout.branchCardGlyph)
                            Text(other.branch).font(.sh(.code)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: SH.Space.m)
                            Text(other.detail).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                        }
                    }
                    .buttonStyle(.shRow(radius: 0))
                    .accessibilityLabel("\(other.branch), \(other.detail)")
                }
            }
        }
        .padding(.vertical, SH.Space.m)
        .frame(width: AppLayout.branchCardWidth)
        .background(Color.sh.bgRaised)
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

    /// A 28pt row in body type (the board's rows are regular weight): a glyph in its column (none for a dot row, which draws its own), then content.
    private func row<Content: View>(_ symbol: String?, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: SH.Space.m) {
            if let symbol {
                Image(systemName: symbol).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                    .frame(width: AppLayout.branchCardGlyph)
            }
            content()
        }
        .font(.sh(.body))
        .foregroundStyle(Color.sh.textPrimary)
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
