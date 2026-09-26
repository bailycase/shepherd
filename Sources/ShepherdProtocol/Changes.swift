import Foundation

// The Changes pane's engine on the wire (ChangesScope, ChangesBase, ChangesLastTurn boards): what
// a review compares, the files and counts each comparison yields, the base picker's branches,
// and the turns the host recorded for the "Edited N files" card. The host computes all of it
// (`ChangesService` in ShepherdSessions); the Mac calls it directly and remote clients reach it
// through `RemoteAgentQuery.changes*` (`RemoteProtocol.changesCapability`). A file's hunks are
// the `DiffFile` every review already draws; its word diffs are `DiffWords`, computed by
// whoever draws it.

/// What to compare.
public enum ChangesScope: Codable, Hashable, Sendable {
    /// What the agent changed in its last turn: the working tree when the turn started against
    /// the working tree when it ended (or now, while it runs).
    case lastTurn
    /// One recorded turn (`ChangesTurn.id`): a changes card's Review.
    case turn(id: UUID)
    /// The working tree, untracked files included, against HEAD.
    case uncommitted
    /// The working tree, untracked files included, against the index.
    case unstaged
    /// The index against HEAD.
    case staged
    /// One commit (`first == last`) or an inclusive range: `first`'s parent against `last`.
    case commits(first: String, last: String)
    /// The working tree against its merge base with `base` (nil: the default base).
    case branch(base: String?)
    /// The checkout's pull request: its head against the merge base with its base branch.
    case pullRequest

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case lastTurn, uncommitted, unstaged, staged, commits, branch, pullRequest
    }

    public var kind: Kind {
        switch self {
        case .lastTurn, .turn: .lastTurn
        case .uncommitted: .uncommitted
        case .unstaged: .unstaged
        case .staged: .staged
        case .commits: .commits
        case .branch: .branch
        case .pullRequest: .pullRequest
        }
    }

    /// The scope menu's name and the toolbar's pill: "Last turn", "Branch".
    public var label: String { kind.label }
}

extension ChangesScope.Kind {
    public var label: String {
        switch self {
        case .lastTurn: "Last turn"
        case .uncommitted: "Uncommitted"
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        case .commits: "Commits"
        case .branch: "Branch"
        case .pullRequest: "Pull request"
        }
    }
}

/// Diff options the engine applies (ChangesUnified's More menu). Word diffs are drawn from the
/// hunks (`DiffWords`) and need no option here.
public struct ChangesOptions: Codable, Hashable, Sendable {
    /// Hide whitespace changes (`git diff -w`).
    public var ignoreWhitespace: Bool
    /// Load full files: every unchanged line comes with the hunks, so folds open without another
    /// request.
    public var fullFiles: Bool

    public init(ignoreWhitespace: Bool = false, fullFiles: Bool = false) {
        self.ignoreWhitespace = ignoreWhitespace
        self.fullFiles = fullFiles
    }

    private enum CodingKeys: String, CodingKey { case ignoreWhitespace, fullFiles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ignoreWhitespace = try c.decodeIfPresent(Bool.self, forKey: .ignoreWhitespace) ?? false
        fullFiles = try c.decodeIfPresent(Bool.self, forKey: .fullFiles) ?? false
    }
}

/// The two objects a list was computed between (trees or commits; the working tree is a tree
/// the host wrote for it). A file's hunks are asked for by revision, so they always belong to
/// the list on screen, whatever changed since.
public struct ChangesRevision: Codable, Hashable, Sendable {
    public var old: String
    public var new: String

    public init(old: String, new: String) {
        self.old = old
        self.new = new
    }

    /// Both are object ids (hex), never options or revision expressions.
    public var isWellFormed: Bool {
        [old, new].allSatisfy { id in (4...64).contains(id.utf8.count) && id.utf8.allSatisfy { isHexDigit($0) } }
    }
}

private func isHexDigit(_ c: UInt8) -> Bool {
    (c >= 48 && c <= 57) || (c >= 97 && c <= 102)
}

/// A changed file's status letter.
public enum ChangesFileStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case added = "A", modified = "M", deleted = "D", renamed = "R"
}

/// One changed file in a list: path, status, and line counts.
public struct ChangesFile: Codable, Hashable, Sendable, Identifiable {
    /// The new path (the old one for a deleted file), from the repository's root.
    public var path: String
    /// Renames: where it came from.
    public var oldPath: String?
    public var status: ChangesFileStatus
    public var added: Int
    public var removed: Int
    public var isBinary: Bool

    public var id: String { path }

    public init(path: String, oldPath: String? = nil, status: ChangesFileStatus, added: Int, removed: Int, isBinary: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.added = added
        self.removed = removed
        self.isBinary = isBinary
    }
}

/// The compare row: head → base, and the merge base shown for trust.
public struct ChangesComparison: Codable, Hashable, Sendable {
    /// "agent/refund-events", "Working tree", "Index", "a1c9f2e".
    public var head: String
    /// "origin/main", "HEAD", "Index", "a1c9f2e^".
    public var base: String
    /// The base as a title says it: "main" for "origin/main".
    public var baseName: String
    /// Short id of the merge base (branch and pull request scopes).
    public var mergeBase: String?
    /// A turn's times and the message that started it (turn scopes).
    public var turn: ChangesTurn?

    public init(head: String, base: String, baseName: String? = nil, mergeBase: String? = nil, turn: ChangesTurn? = nil) {
        self.head = head
        self.base = base
        self.baseName = baseName ?? base
        self.mergeBase = mergeBase
        self.turn = turn
    }
}

/// What a scope yields: its files with counts, the revision to fetch hunks from, and the
/// compare row.
public struct ChangesList: Codable, Hashable, Sendable {
    public var scope: ChangesScope
    public var revision: ChangesRevision
    public var comparison: ChangesComparison
    public var files: [ChangesFile]
    public var added: Int
    public var removed: Int
    /// Untracked files the working tree snapshot left out, too big to hash (`ChangesLimits`).
    public var skipped: [String]

    public init(scope: ChangesScope, revision: ChangesRevision, comparison: ChangesComparison, files: [ChangesFile], skipped: [String] = []) {
        self.scope = scope
        self.revision = revision
        self.comparison = comparison
        self.files = files
        self.added = files.reduce(0) { $0 + $1.added }
        self.removed = files.reduce(0) { $0 + $1.removed }
        self.skipped = skipped
    }

    /// "Branch · vs main", "Last turn", "Pull request · vs main", "Commit · a1c9f2e".
    public var title: String { changesTitle(scope: scope, comparison: comparison) }
}

/// A scope's title as the pane and the phone's Changes screen show it.
public func changesTitle(scope: ChangesScope, comparison: ChangesComparison?) -> String {
    switch scope {
    case .lastTurn, .turn, .uncommitted, .unstaged, .staged: return scope.label
    case .branch: return comparison.map { "Branch · vs \($0.baseName)" } ?? "Branch"
    case .pullRequest: return comparison.map { "Pull request · vs \($0.baseName)" } ?? "Pull request"
    case .commits(let first, let last):
        let a = String(first.prefix(7)), b = String(last.prefix(7))
        return first == last ? "Commit · \(a)" : "Commits · \(a)–\(b)"
    }
}

/// A file's hunks, from `ChangesList.revision`.
public struct ChangesFileDiff: Codable, Hashable, Sendable {
    public var file: DiffFile
    /// The file was cut short at `ChangesLimits.fileLines` lines (a generated or minified file).
    public var truncated: Bool

    public init(file: DiffFile, truncated: Bool = false) {
        self.file = file
        self.truncated = truncated
    }
}

public enum ChangesLimits {
    /// The most diff lines one file brings; past it the file is truncated.
    public static let fileLines = 20_000
    /// The most bytes a file's hunks or a patch bring over the remote protocol (the frame cap is
    /// 1 MiB).
    public static let remoteBytes = 900 * 1024
    /// Untracked files bigger than this stay out of working-tree snapshots (never hashed into
    /// the repository's objects).
    public static let untrackedFileBytes = 16 * 1024 * 1024
    /// Files a turn carries in a thread snapshot; the rest are counted.
    public static let turnFiles = 20
    /// Turns kept per agent.
    public static let turns = 10
}

// MARK: Turns

/// A turn the host recorded: the working tree when it started and when it ended, the files it
/// changed (the "Edited N files" card), and whether Undo or Redo applies.
public struct ChangesTurn: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Hashable, Sendable {
        /// The turn runs: its changes are the working tree now against the baseline.
        case running
        /// Ended; Undo puts its edits back (while it is the last turn).
        case ready
        /// Undone; Redo reapplies its edits until the next turn starts.
        case undone
        /// No baseline (the capture failed, or its objects are gone): `reason` says why.
        case unavailable
    }

    public var id: UUID
    /// pi's timestamp (ms) of the user message that started the turn: the card's turn.
    public var messageTimestamp: Double?
    /// That message's first line, for "after “Wrap errors with context”".
    public var prompt: String?
    /// Milliseconds since the epoch.
    public var startedAt: Double
    public var endedAt: Double?
    public var state: State
    public var reason: String?
    /// The first `ChangesLimits.turnFiles` files the turn changed; `fileCount` counts them all.
    public var files: [ChangesFile]
    public var fileCount: Int
    public var added: Int
    public var removed: Int
    public var canUndo: Bool
    public var canRedo: Bool

    public init(id: UUID = UUID(), messageTimestamp: Double? = nil, prompt: String? = nil, startedAt: Double, endedAt: Double? = nil,
                state: State, reason: String? = nil, files: [ChangesFile] = [], fileCount: Int? = nil, added: Int = 0, removed: Int = 0,
                canUndo: Bool = false, canRedo: Bool = false) {
        self.id = id
        self.messageTimestamp = messageTimestamp
        self.prompt = prompt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
        self.reason = reason
        self.files = files
        self.fileCount = fileCount ?? files.count
        self.added = added
        self.removed = removed
        self.canUndo = canUndo
        self.canRedo = canRedo
    }

    /// "Edited 5 files"; "Undid the agent’s edits to 5 files" once undone.
    public var title: String {
        let files = "\(fileCount) file\(fileCount == 1 ? "" : "s")"
        return state == .undone ? "Undid the agent’s edits to \(files)" : "Edited \(files)"
    }
}

// MARK: Overview

/// The scope menu (ChangesScope board): each scope with its diffstat, the branch's commits, the
/// pull request, and the scope the pane opens on.
public struct ChangesOverview: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var scope: ChangesScope
        /// nil while unavailable.
        public var files: Int?
        public var added: Int?
        public var removed: Int?
        /// Commits: how many.
        public var count: Int?
        /// Why the scope can't be compared ("No turn yet", "No pull request").
        public var unavailable: String?

        public init(scope: ChangesScope, files: Int? = nil, added: Int? = nil, removed: Int? = nil, count: Int? = nil, unavailable: String? = nil) {
            self.scope = scope
            self.files = files
            self.added = added
            self.removed = removed
            self.count = count
            self.unavailable = unavailable
        }
    }

    /// The repository's root, or nil when the directory is no repository (`reason`).
    public var repository: String?
    public var reason: String?
    /// The checked-out branch, nil when detached.
    public var branch: String?
    /// HEAD's short id, nil before the first commit.
    public var head: String?
    /// Branch for a worktree agent, else Uncommitted.
    public var defaultScope: ChangesScope
    /// What Branch compares against unless another base is picked ("origin/main").
    public var defaultBase: String?
    /// Last turn, Uncommitted, Unstaged, Staged, Commits, Branch, Pull request, in menu order.
    public var entries: [ChangesOverview.Entry]
    /// The branch's commits against `defaultBase`, newest first (or HEAD's recent history
    /// without a base).
    public var commits: [ChangesCommit]
    /// What `commits` are counted against: nil when they are HEAD's recent history (the branch
    /// has none of its own).
    public var commitsBase: String?
    public var pullRequest: ChangesPullRequest?
    public var lastTurn: ChangesTurn?

    public init(repository: String?, reason: String? = nil, branch: String? = nil, head: String? = nil, defaultScope: ChangesScope,
                defaultBase: String? = nil, entries: [ChangesOverview.Entry] = [], commits: [ChangesCommit] = [],
                commitsBase: String? = nil, pullRequest: ChangesPullRequest? = nil, lastTurn: ChangesTurn? = nil) {
        self.repository = repository
        self.reason = reason
        self.branch = branch
        self.head = head
        self.defaultScope = defaultScope
        self.defaultBase = defaultBase
        self.entries = entries
        self.commits = commits
        self.commitsBase = commitsBase
        self.pullRequest = pullRequest
        self.lastTurn = lastTurn
    }
}

public struct ChangesCommit: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var shortID: String
    public var subject: String
    /// Committer date, seconds since the epoch.
    public var date: Double

    public init(id: String, shortID: String, subject: String, date: Double) {
        self.id = id
        self.shortID = shortID
        self.subject = subject
        self.date = date
    }
}

public struct ChangesPullRequest: Codable, Hashable, Sendable {
    public var number: Int
    public var title: String
    public var isDraft: Bool
    /// "OPEN", "MERGED", "CLOSED".
    public var state: String
    /// The base branch as GitHub names it ("main").
    public var base: String
    public var head: String
    public var url: String

    public init(number: Int, title: String, isDraft: Bool, state: String, base: String, head: String, url: String) {
        self.number = number
        self.title = title
        self.isDraft = isDraft
        self.state = state
        self.base = base
        self.head = head
        self.url = url
    }

    /// "#31 draft", "#31".
    public var label: String { "#\(number)" + (isDraft ? " draft" : "") }
}

// MARK: Base picker

/// The base picker (ChangesBase): recents first, then every branch by last commit.
public struct ChangesBranches: Codable, Hashable, Sendable {
    public var defaultBase: String?
    /// The pull request's base as a ref here ("origin/main"), when the checkout has one.
    public var pullRequestBase: String?
    /// Bases picked before in this repository, most recent first.
    public var recents: [String]
    public var branches: [ChangesBranch]

    public init(defaultBase: String?, pullRequestBase: String? = nil, recents: [String] = [], branches: [ChangesBranch]) {
        self.defaultBase = defaultBase
        self.pullRequestBase = pullRequestBase
        self.recents = recents
        self.branches = branches
    }
}

public struct ChangesBranch: Codable, Hashable, Sendable, Identifiable {
    /// "feat/ledger-v2", "origin/release/2.4".
    public var name: String
    public var isRemote: Bool
    /// Checked out in another worktree: its path (the picker's "worktree" tag).
    public var worktree: String?
    public var isCurrent: Bool
    /// Last commit, seconds since the epoch.
    public var committedAt: Double

    public var id: String { name }

    public init(name: String, isRemote: Bool, worktree: String? = nil, isCurrent: Bool = false, committedAt: Double) {
        self.name = name
        self.isRemote = isRemote
        self.worktree = worktree
        self.isCurrent = isCurrent
        self.committedAt = committedAt
    }
}

/// A failed changes request: the code a remote reply carries, and a sentence for the user.
public struct ChangesError: Error, Codable, Hashable, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String
    /// `changedSince`: the files that changed after the turn (Undo) or after the Undo (Redo).
    public var files: [String]

    public init(_ code: String, _ message: String, files: [String] = []) {
        self.code = code
        self.message = message
        self.files = files
    }

    public var description: String { message }

    public static let notARepository = "not_a_repository"
    public static let unavailable = "unavailable"
    public static let invalid = "invalid"
    public static let changedSince = "changed_since"
    public static let gitFailed = "git_failed"
}
