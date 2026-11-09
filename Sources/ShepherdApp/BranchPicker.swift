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
    /// The repository's main checkout, standardized: a branch checked out there reads "main checkout".
    var mainCheckout: String? = nil
    /// Why the thread can't move to another checkout now ("running"); nil when it can.
    var busy: String? = nil

    /// What choosing a row does.
    enum Pick: Equatable {
        /// `git switch` in this checkout.
        case checkout
        /// Re-point the thread at the checkout at this path, which already has the branch.
        case move(String)
        /// Nothing: listed, not chosen.
        case none
    }

    struct Row: Equatable, Identifiable {
        var name: String
        /// "1d", "in use · Add refund events · move here", "remote · 1d".
        var detail: String
        /// Checked out here.
        var current: Bool
        var pick: Pick
        /// Checked out in another worktree: git won't check it out twice.
        var inUse: Bool
        var id: String { name }
    }

    /// Local branches then remote ones, each newest first; a remote branch with a local copy and
    /// origin/HEAD are left out. `query` filters by substring. A branch another checkout has can't
    /// be checked out here; with `moves` (Switch branch) choosing it moves the thread there
    /// instead, unless the thread is `busy`.
    func rows(query: String = "", now: Date = Date(), moves: Bool = false) -> [Row] {
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
            guard !branch.isCurrent, let worktree = branch.worktree else {
                return Row(name: branch.name, detail: branch.isRemote ? "remote · \(age)" : age, current: branch.isCurrent,
                           pick: .checkout, inUse: false)
            }
            let path = ShepherdViewModel.standard(worktree)
            let holder = threads[path] ?? (path == mainCheckout ? "main checkout" : nil)
            let pick: Pick = moves && busy == nil ? .move(worktree) : .none
            let action = moves ? busy.map { "can’t move while \($0)" } ?? "move here" : nil
            return Row(name: branch.name, detail: ["in use", holder, action].compactMap { $0 }.joined(separator: " · "),
                       current: false, pick: pick, inUse: true)
        }
    }
}

/// The Branch picker (BranchPicker board): search, an optional first choice ("New branch from
/// main"), the branches, then "New branch…" and "Fetch from origin". A branch another worktree
/// has is listed but can't be chosen, except by Switch branch (`moves`), where choosing it moves
/// the thread to that worktree. Used by the branch card's Switch branch and Change base and by
/// the new thread's Branch and Base.
struct BranchPickerMenu: View {
    var title: String?
    /// A first row before the branches, checked when nothing else is chosen.
    var first: String?
    var selected: String?
    let load: () async throws -> BranchPickerList
    let choose: (String?) -> Void
    /// Switch branch: an in-use branch moves the thread to its checkout (`move`: branch, path).
    var move: ((String, String) -> Void)?
    var newBranch: (() -> Void)?
    var fetch: (() async throws -> Void)?
    let close: () -> Void
    @State private var list: BranchPickerList?
    @State private var failure: String?
    @State private var query = ""
    @State private var fetching = false
    @FocusState private var searching: Bool

    var body: some View {
        let rows = list?.rows(query: query, moves: move != nil) ?? []
        SHChangesMenu(width: SHChangesMenuMetrics.baseWidth) {
            SHChangesMenuSearch(text: $query, prompt: "Search branches", isFocused: $searching,
                                onSubmit: { if let row = rows.first(where: { $0.pick != .none }) { pick(row) } }, onEscape: close)
            if let title { SHChangesMenuTitle(title) }
            if let first, query.isEmpty {
                SHChangesMenuRow(first, systemImage: nil, titleIsMono: true, checked: selected == nil) { choose(nil) }
            }
            if list != nil {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            // A branch in use says where under its name, which stays whole.
                            SHChangesMenuRow(row.name, subtitle: row.inUse ? row.detail : nil, systemImage: nil, titleIsMono: true,
                                             trailing: row.inUse ? .none : .text(row.detail),
                                             checked: row.name == selected || (selected == nil && first == nil && row.current),
                                             enabled: row.pick != .none) { pick(row) }
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

    private func pick(_ row: BranchPickerList.Row) {
        if case .move(let path) = row.pick { move?(row.name, path) } else { choose(row.name) }
    }

    private func reload() async {
        do { list = try await load(); failure = nil }
        catch { failure = (error as? ChangesError)?.message ?? ActionError.describe(error) }
    }
}
