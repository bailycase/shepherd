import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// A checkout's branches as the Branch picker lists them (BranchPicker board).
struct BranchPickerList: Equatable {
    var branches: ChangesBranches
    /// Each worktree's thread, by its standardized path.
    var threads: [String: String]

    struct Row: Equatable, Identifiable {
        var name: String
        /// "1d", "in use · Add refund events", "remote · 1d".
        var detail: String
        /// Checked out here.
        var current: Bool
        /// Checked out in another worktree: git won't check it out twice.
        var inUse: Bool
        var id: String { name }
    }

    /// Local branches then remote ones, each newest first; a remote branch with a local copy and
    /// origin/HEAD are left out. `query` filters by substring.
    func rows(query: String = "", now: Date = Date()) -> [Row] {
        let locals = Set(branches.branches.filter { !$0.isRemote }.map(\.name))
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let kept = branches.branches.filter { branch in
            guard q.isEmpty || branch.name.lowercased().contains(q) else { return false }
            guard branch.isRemote else { return true }
            guard let slash = branch.name.firstIndex(of: "/") else { return true }
            let local = String(branch.name[branch.name.index(after: slash)...])
            return local != "HEAD" && !locals.contains(local)
        }
        let ordered = kept.filter { !$0.isRemote }.sorted { $0.committedAt > $1.committedAt }
            + kept.filter(\.isRemote).sorted { $0.committedAt > $1.committedAt }
        return ordered.map { branch in
            let age = ForgePresentation.age(Date(timeIntervalSince1970: branch.committedAt), now: now)
            let inUse = !branch.isCurrent && branch.worktree != nil
            let detail = if inUse {
                ["in use", branch.worktree.flatMap { threads[ShepherdViewModel.standard($0)] }].compactMap { $0 }.joined(separator: " · ")
            } else if branch.isRemote { "remote · \(age)" } else { age }
            return Row(name: branch.name, detail: detail, current: branch.isCurrent, inUse: inUse)
        }
    }
}

/// The Branch picker (BranchPicker board): search, an optional first choice ("New branch from
/// main"), the branches, then "New branch…" and "Fetch from origin". A branch another worktree
/// has is listed but can't be chosen. Used by the branch card's Switch branch and Change base and
/// by the new thread's Branch and Base.
struct BranchPickerMenu: View {
    var title: String?
    /// A first row before the branches, checked when nothing else is chosen.
    var first: String?
    var selected: String?
    let load: () async throws -> BranchPickerList
    let choose: (String?) -> Void
    var newBranch: (() -> Void)?
    var fetch: (() async throws -> Void)?
    let close: () -> Void
    @State private var list: BranchPickerList?
    @State private var failure: String?
    @State private var query = ""
    @State private var fetching = false
    @FocusState private var searching: Bool

    var body: some View {
        let rows = list?.rows(query: query) ?? []
        SHChangesMenu(width: SHChangesMenuMetrics.baseWidth) {
            SHChangesMenuSearch(text: $query, prompt: "Search branches", isFocused: $searching,
                                onSubmit: { if let row = rows.first(where: { !$0.inUse }) { choose(row.name) } }, onEscape: close)
            if let title { SHChangesMenuTitle(title) }
            if let first, query.isEmpty {
                SHChangesMenuRow(first, systemImage: nil, titleIsMono: true, checked: selected == nil) { choose(nil) }
            }
            if list != nil {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            SHChangesMenuRow(row.name, systemImage: nil, titleIsMono: true, trailing: .text(row.detail),
                                             checked: row.name == selected || (selected == nil && first == nil && row.current),
                                             enabled: !row.inUse) { choose(row.name) }
                        }
                    }
                }
                .frame(maxHeight: ChangesMenuLayout.listMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                if rows.isEmpty, !query.isEmpty { SHChangesMenuNote("No branch matches “\(query)”.") }
            } else if let failure {
                SHChangesMenuNote(failure)
            } else {
                SHChangesMenuNote("Reading branches…")
            }
            if newBranch != nil || fetch != nil { SHChangesMenuDivider() }
            if let newBranch { SHChangesMenuRow("New branch…", systemImage: "plus", action: newBranch) }
            if let fetch {
                SHChangesMenuRow(fetching ? "Fetching…" : "Fetch from origin", systemImage: "arrow.down.to.line", enabled: !fetching) {
                    fetching = true
                    Task {
                        do { try await fetch(); await reload() } catch { failure = ActionError.describe(error) }
                        fetching = false
                    }
                }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        do { list = try await load(); failure = nil }
        catch { failure = (error as? ChangesError)?.message ?? ActionError.describe(error) }
    }
}

/// The new thread's ⚙ (BranchWhereItRuns board): where it runs. New worktree, and while it is on
/// the worktree's Branch and Base, each opening its picker; the host, shown and chosen elsewhere.
struct WhereItRunsMenu: View {
    let worktree: Bool
    /// "new from main", or the branch picked.
    let branch: String
    let base: String
    let host: String
    /// Branch and Base are this Mac's; a host resolves its own.
    let local: Bool
    let setWorktree: (Bool) -> Void
    let chooseBranch: () -> Void
    let chooseBase: () -> Void

    var body: some View {
        SHChangesMenu(width: AppLayout.whereItRunsWidth) {
            Text("Where this thread runs").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                .padding(.horizontal, SH.Space.m).padding(.top, SH.Space.xs).padding(.bottom, SH.Space.s)
            HStack {
                Text("New worktree")
                Spacer(minLength: SH.Space.m)
                Toggle("New worktree", isOn: Binding(get: { worktree }, set: setWorktree)).toggleStyle(.shSwitch).labelsHidden()
            }
            .font(.sh(.body)).foregroundStyle(Color.sh.textPrimary)
            .padding(.horizontal, SH.Space.m)
            .frame(minHeight: SHChangesMenuMetrics.rowHeight)
            if worktree && local {
                row("Branch", branch, action: chooseBranch)
                row("Base", base, action: chooseBase)
            }
            row("Host", host, action: nil)
        }
    }

    private func row(_ title: String, _ value: String, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            HStack(spacing: SH.Space.m) {
                Text(title).font(.sh(.body))
                Spacer(minLength: SH.Space.m)
                Text(value).font(.sh(.code)).foregroundStyle(Color.sh.textSecondary).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.right").font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
            }
            .foregroundStyle(action == nil ? Color.sh.textTertiary : Color.sh.textPrimary)
            .padding(.horizontal, SH.Space.m)
            .frame(maxWidth: .infinity, minHeight: SHChangesMenuMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.shRow())
        .disabled(action == nil)
        .accessibilityLabel("\(title), \(value)")
    }
}
