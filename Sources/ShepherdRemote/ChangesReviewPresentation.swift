import Foundation
import ShepherdProtocol

// What the Changes pane's pickers and the "Edited N files" card show, derived once per change
// from what the host's engine answers (ChangesStates board: ScopeMenu, CommitsMenu, BasePicker,
// ChangesCard). Plain values, so the views compare rows and redraw only what changed.

// MARK: The card

/// The "Edited N files" card that ends a turn (ChangesStates › ChangesCard; MobileThread,
/// iPadReview): the title and stat, Undo or Redo, Review, the first three files with their
/// folder dimmed, then "N more". Built from the turn the host recorded, or, from a host that
/// records none, from the turn's own edit calls (no Undo then).
public struct NativeChangesCard: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String { path }
        public var path: String
        /// "ledger/" (empty at the root), dimmed, then the name.
        public var directory: String
        public var name: String
        /// Shown as "new" before the stat.
        public var isNew: Bool
        public var added: Int
        public var removed: Int
    }

    public enum State: Equatable, Sendable {
        /// Finished; Undo applies while `canUndo`.
        case ready
        /// Undone: the one dashed line with Redo.
        case undone
    }

    /// Files listed before "N more".
    public static let shownFiles = 3

    /// The host's record of the turn; nil for a card drawn from the turn's edit calls.
    public var turnID: UUID?
    public var title: String
    public var added: Int
    public var removed: Int
    public var rows: [Row]
    /// Files past `rows`.
    public var more: Int
    public var state: State
    public var canUndo: Bool
    public var canRedo: Bool

    /// The card for a recorded turn; nil for one that changed nothing, one still running, or
    /// one the host could not record (the card from its edit calls stands in).
    public init?(turn: ChangesTurn) {
        guard turn.fileCount > 0, turn.state == .ready || turn.state == .undone else { return nil }
        turnID = turn.id
        title = turn.title
        added = turn.added
        removed = turn.removed
        rows = turn.files.prefix(Self.shownFiles).map { file in
            let (directory, name) = reviewPathParts(file.path)
            return Row(path: file.path, directory: directory, name: name, isNew: file.status == .added, added: file.added, removed: file.removed)
        }
        more = max(0, turn.fileCount - rows.count)
        state = turn.state == .undone ? .undone : .ready
        canUndo = turn.canUndo
        canRedo = turn.canRedo
    }

    /// The card from a turn's edit calls, for a host that records no turns: no Undo.
    public init(changes: NativeTurnChanges) {
        turnID = nil
        title = "Edited " + nativeCount(changes.files.count, "file")
        added = changes.added
        removed = changes.removed
        rows = changes.files.prefix(Self.shownFiles).map {
            Row(path: $0.path, directory: $0.directory, name: $0.name, isNew: $0.status == .added, added: $0.added, removed: $0.removed)
        }
        more = max(0, changes.files.count - rows.count)
        state = .ready
        canUndo = false
        canRedo = false
    }

    /// "2 more", or nil when every file is listed.
    public var moreText: String? { more > 0 ? "\(more) more" : nil }
}

/// The card that ends a finished reply: the host's record of its turn when it has one, else the
/// turn's own edits.
public func nativeChangesCard(turn: ChangesTurn?, changes: NativeTurnChanges?) -> NativeChangesCard? {
    if let turn, let card = NativeChangesCard(turn: turn) { return card }
    return changes.map(NativeChangesCard.init(changes:))
}

// MARK: The scope menu

/// One entry of the scope menu (ChangesStates › ScopeMenu): what it compares, its diffstat, and
/// why it can't be picked.
public struct ChangesScopeOption: Identifiable, Equatable, Sendable {
    public var id: ChangesScope.Kind { kind }
    public var kind: ChangesScope.Kind
    /// What picking it shows (Commits: every commit on the branch).
    public var scope: ChangesScope
    /// "Last turn", "Branch".
    public var title: String
    /// "What the agent changed since your last message", "agent/refund-events vs origin/main".
    public var detail: String?
    public var added: Int?
    public var removed: Int?
    /// Commits: how many; Pull request: "#31 draft".
    public var trailing: String?
    public var unavailable: String?
    public var selected: Bool
    /// Starts a group: a divider goes above it (Uncommitted, Commits).
    public var startsGroup: Bool

    public var available: Bool { unavailable == nil }
}

/// The menu's entries in the board's order: Last turn, then the working tree (Uncommitted,
/// Unstaged, Staged), then history (Commits, Branch, Pull request). `selected` is the scope on
/// screen; `base` the base Branch compares against now.
public func changesScopeOptions(_ overview: ChangesOverview, selected: ChangesScope?, base: String?) -> [ChangesScopeOption] {
    let entries = Dictionary(overview.entries.map { ($0.scope.kind, $0) }, uniquingKeysWith: { first, _ in first })
    let head = overview.branch ?? overview.head ?? "HEAD"
    return ChangesScope.Kind.allCases.compactMap { kind in
        let entry = entries[kind]
        let scope: ChangesScope
        var detail: String?
        var trailing: String?
        switch kind {
        case .lastTurn:
            scope = .lastTurn
            detail = "What the agent changed since your last message"
        case .uncommitted: scope = .uncommitted
        case .unstaged: scope = .unstaged
        case .staged: scope = .staged
        case .commits:
            guard let newest = overview.commits.first, let oldest = overview.commits.last else {
                scope = .commits(first: "", last: "")
                trailing = nil
                break
            }
            scope = .commits(first: oldest.id, last: newest.id)
            trailing = "\(entry?.count ?? overview.commits.count)"
        case .branch:
            scope = .branch(base: base)
            if let base = base ?? overview.defaultBase { detail = "\(head) vs \(base)" }
        case .pullRequest:
            scope = .pullRequest
            trailing = overview.pullRequest?.label
        }
        let unavailable = entry?.unavailable ?? (kind == .commits && overview.commits.isEmpty ? "No commits" : nil)
        return ChangesScopeOption(kind: kind, scope: scope, title: kind.label, detail: detail,
                                  added: kind == .commits || kind == .pullRequest ? nil : entry?.added,
                                  removed: kind == .commits || kind == .pullRequest ? nil : entry?.removed,
                                  trailing: trailing, unavailable: unavailable, selected: selected?.kind == kind,
                                  startsGroup: kind == .uncommitted || kind == .commits)
    }
}

/// The commits submenu (ChangesStates › CommitsMenu): all of the branch's commits ("Recent
/// commits" when there is no base to count them from), then each one, newest first, with its
/// short id and age.
public struct ChangesCommitOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var scope: ChangesScope
    public var title: String
    /// "a1c9f2e · 12m".
    public var detail: String?
    public var selected: Bool
}

public func changesCommitOptions(_ overview: ChangesOverview, selected: ChangesScope?, now: Date = Date()) -> [ChangesCommitOption] {
    guard let newest = overview.commits.first, let oldest = overview.commits.last else { return [] }
    let all = ChangesScope.commits(first: oldest.id, last: newest.id)
    var options = [ChangesCommitOption(id: "all", scope: all, title: overview.commitsBase == nil ? "Recent commits" : "All commits on the branch", detail: nil,
                                       selected: overview.commits.count > 1 && selected == all)]
    for commit in overview.commits {
        let scope = ChangesScope.commits(first: commit.id, last: commit.id)
        let age = changesAgeText(Date(timeIntervalSince1970: commit.date), now: now)
        options.append(ChangesCommitOption(id: commit.id, scope: scope, title: commit.subject, detail: "\(commit.shortID) · \(age)",
                                           selected: selected == scope))
    }
    return options
}

/// "now", "12m", "3h", "4d": how long ago, as the commits menu says it.
public func changesAgeText(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
    return "\(Int(seconds / 86_400))d"
}

// MARK: The base picker

/// A branch in the base picker (ChangesStates › BasePicker).
public struct ChangesBaseOption: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    /// "default" for the default base, "worktree" for a branch checked out elsewhere.
    public var tag: String?
    public var selected: Bool
}

/// The picker's branches: the default base, then recents, then every other branch by last
/// commit; the checked-out branch is not a base. `query` filters by name, ignoring case.
public func changesBaseOptions(_ branches: ChangesBranches, selected: String?, query: String = "") -> [ChangesBaseOption] {
    let current = Set(branches.branches.filter(\.isCurrent).map(\.name))
    let worktrees = Set(branches.branches.filter { $0.worktree != nil }.map(\.name))
    let known = Set(branches.branches.map(\.name))
    var order: [String] = []
    var seen: Set<String> = []
    func add(_ name: String?) {
        guard let name, !name.isEmpty, !current.contains(name), seen.insert(name).inserted else { return }
        order.append(name)
    }
    add(branches.defaultBase)
    for recent in branches.recents where known.contains(recent) || recent == branches.defaultBase { add(recent) }
    for branch in branches.branches.sorted(by: { $0.committedAt > $1.committedAt }) { add(branch.name) }
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    let chosen = selected ?? branches.defaultBase
    return order.filter { needle.isEmpty || $0.lowercased().contains(needle) }.map { name in
        ChangesBaseOption(name: name, tag: name == branches.defaultBase ? "default" : worktrees.contains(name) ? "worktree" : nil,
                          selected: name == chosen)
    }
}

// MARK: The list

extension ReviewFileSummary {
    /// A listed file before its hunks arrive: the counts the host's list carries.
    public init(file: ChangesFile, comments: Int, viewed: Bool) {
        id = file.id
        path = file.path
        (directory, name) = reviewPathParts(file.path)
        status = ReviewFileStatus(file.status)
        added = file.added
        removed = file.removed
        hunks = 0
        isBinary = file.isBinary
        self.comments = comments
        self.viewed = viewed
    }
}

extension ReviewFileStatus {
    public init(_ status: ChangesFileStatus) {
        switch status {
        case .added: self = .added
        case .modified: self = .modified
        case .deleted: self = .deleted
        case .renamed: self = .renamed
        }
    }
}

/// `reviewSummaries` for a scope's list: its files in the host's order, with their counts.
public func reviewSummaries(listed: [ChangesFile], comments: [ReviewComment], viewed: Set<String>) -> (rows: [ReviewFileSummary], totals: ReviewTotals) {
    let counts = comments.reduce(into: [String: Int]()) { $0[$1.fileID, default: 0] += 1 }
    let rows = listed.map { ReviewFileSummary(file: $0, comments: counts[$0.id] ?? 0, viewed: viewed.contains($0.id)) }
    let totals = ReviewTotals(files: rows.count, added: rows.reduce(0) { $0 + $1.added }, removed: rows.reduce(0) { $0 + $1.removed },
                              viewed: rows.filter(\.viewed).count)
    return (rows, totals)
}

/// The unchanged lines before each hunk, by its row id in `reviewRows`: the lines between the
/// hunk and the one before it, or the file's start (iPadReview's "95 unmodified lines").
public func reviewHunkGaps(_ file: DiffFile) -> [String: Int] {
    var gaps: [String: Int] = [:]
    var previousEnd = 0
    for hunk in file.hunks {
        let first = hunk.lines.lazy.compactMap { $0.newLine ?? $0.oldLine }.first ?? previousEnd + 1
        gaps["\(file.id)\u{0}\(hunk.id)"] = max(0, first - previousEnd - 1)
        previousEnd = hunk.lines.lazy.compactMap(\.newLine).last ?? hunk.lines.lazy.compactMap(\.oldLine).last ?? previousEnd
    }
    return gaps
}

/// The compare row (ChangesStates › CompareRow): "agent/refund-events → origin/main", with the
/// merge base trailing; a turn says which message started it instead of a merge base.
public struct ChangesCompareText: Equatable, Sendable {
    public var head: String
    public var base: String
    /// "merge base 3f2a91c", "after “Wrap errors with context”", or nil.
    public var trailing: String?
    /// Only Branch's base is a picker.
    public var basePicks: Bool

    public init(head: String, base: String, trailing: String?, basePicks: Bool) {
        self.head = head
        self.base = base
        self.trailing = trailing
        self.basePicks = basePicks
    }
}

public func changesCompareText(_ list: ChangesList) -> ChangesCompareText {
    let comparison = list.comparison
    var trailing = comparison.mergeBase.map { "merge base \($0)" }
    if let prompt = comparison.turn?.prompt?.split(separator: "\n").first, !prompt.isEmpty {
        trailing = "after \u{201C}\(prompt)\u{201D}"
    }
    let picks: Bool = if case .branch = list.scope { true } else { false }
    return ChangesCompareText(head: comparison.head, base: comparison.base, trailing: trailing, basePicks: picks)
}
