import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdUI

/// The toolbar's branch button and its card (BranchCard board): pressed while the card is open.
struct BranchCardButton: View {
    let handle: BranchCardHandle
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: SHGlyph.gitBranch.symbolName) }
            .buttonStyle(.shIcon(isOn: open))
            .help("Branch")
            .accessibilityLabel("Branch")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                BranchCardPopover(handle: handle) { open = false }
            }
    }
}

/// The card as it opens: what the workspace knows at once, then git's and GitHub's reads.
private struct BranchCardPopover: View {
    let handle: BranchCardHandle
    let close: () -> Void
    @State private var card: BranchCardModel?
    @State private var status: BranchCardStatus?

    init(handle: BranchCardHandle, close: @escaping () -> Void) {
        self.handle = handle
        self.close = close
        _card = State(initialValue: handle.card())
    }

    var body: some View {
        if let card {
            BranchCardView(card: card, status: status) { action in
                close()
                handle.perform(action)
            }
            .task { status = await handle.load(card) }
        }
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
            row(SHGlyph.gitBranch.symbolName) { Text(card.branch).font(.sh(.code)).lineLimit(1).truncationMode(.middle) }
            Button { perform(.showChanges) } label: {
                row("plus.forwardslash.minus") {
                    Text("Changes")
                    Spacer(minLength: SH.Space.m)
                    if let git = status?.git { SHDiffStat(added: git.additions, removed: git.deletions, font: .sh(.caption)) }
                }
            }
            .buttonStyle(.shRow(radius: 0))
            if let git = status?.git, let base = git.base, git.behind > 0 {
                row("arrow.down") { Text("\(git.behind) behind \(base)") }
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
        Button("Commit…") { perform(.commit) }
        Divider()
        if card.worktree { Button("Finalize…") { perform(.finalize) } }
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
