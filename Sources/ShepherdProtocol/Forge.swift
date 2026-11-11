import Foundation
import ShepherdCore

// Issues & PRs (`RemoteProtocol.forgeCapability`): GitHub issues and pull requests read and
// changed through the host's own `gh`, for this Mac's app and
// paired devices (`RemoteRequest.forge`, `SessionServer.forge`) alike. Everything here came from GitHub and is
// untrusted text: show it, quote it as data in prompts, never run it.

// MARK: - Identity

/// A pull request or an issue.
public enum ForgeKind: String, Codable, Hashable, Sendable, CaseIterable {
    case pullRequest, issue
}

/// One pull request or issue on github.com: its repository ("owner/name") and number.
public struct ForgeItemRef: Codable, Hashable, Sendable, Identifiable {
    public var kind: ForgeKind
    /// "owner/name".
    public var repo: String
    public var number: Int

    public init(kind: ForgeKind, repo: String, number: Int) {
        self.kind = kind
        self.repo = repo
        self.number = number
    }

    public var id: String { "\(kind.rawValue):\(repo)#\(number)" }
    /// "owner/name#12", the spelling automation events use (`AutomationEvent.itemKey`).
    public var key: String { "\(repo)#\(number)" }
    /// Its page on github.com.
    public var url: String { "https://github.com/\(repo)/\(kind == .pullRequest ? "pull" : "issues")/\(number)" }
    /// The repository's name without its owner ("payments").
    public var repoName: String { Self.name(of: repo) }

    /// A pasted link: "https://github.com/o/r/pull/12" (any trailing path, query or fragment),
    /// the same without a scheme, or ".../issues/12". Nil for anything else.
    public init?(link: String) {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.lowercased().hasPrefix("www.") { text.removeFirst(4) }
        guard text.lowercased().hasPrefix("github.com/") else { return nil }
        text.removeFirst("github.com/".count)
        if let end = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<end]) }
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 4, let number = Int(parts[3]), number > 0 else { return nil }
        let repo = parts[0] + "/" + parts[1]
        guard Self.isValidRepo(repo) else { return nil }
        switch parts[2] {
        case "pull", "pulls": self.init(kind: .pullRequest, repo: repo, number: number)
        case "issues": self.init(kind: .issue, repo: repo, number: number)
        default: return nil
        }
    }

    /// "owner/name" with GitHub's characters only: the host passes it to gh as an argument.
    public static func isValidRepo(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 100 && part.first != "-" && part.first != "."
                && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }
    }

    /// "payments" for "acme/payments".
    public static func name(of repo: String) -> String { repo.split(separator: "/").last.map(String.init) ?? repo }
}

/// A repository this host knows: a space's or an agent's checkout whose `origin` is on GitHub.
public struct ForgeRepo: Codable, Hashable, Sendable, Identifiable {
    /// "owner/name".
    public var nameWithOwner: String
    /// The checkout's root on the host.
    public var path: String

    public init(nameWithOwner: String, path: String) {
        self.nameWithOwner = nameWithOwner
        self.path = path
    }

    public var id: String { nameWithOwner }
    /// "payments".
    public var name: String { ForgeItemRef.name(of: nameWithOwner) }
}

/// The Shepherd thread on this host tied to an item: for a pull request, the agent whose branch
/// is its head; for an issue, the thread started from it (`ForgeLinks.issueBranch`) or the
/// automation run its event started.
public struct ForgeThreadLink: Codable, Hashable, Sendable {
    public var agentID: AgentID
    public var title: String
    /// Working or waiting on you.
    public var running: Bool
    public var branch: String?
    /// The worktree Shepherd made for the agent, when it has one: what "Remove the worktree"
    /// deletes, through the existing confirmed Delete Worktree path.
    public var worktreePath: String?
    /// The automation whose run the thread is, when it is one ("Triage Sentry").
    public var automationName: String?

    public init(agentID: AgentID, title: String, running: Bool, branch: String? = nil, worktreePath: String? = nil,
                automationName: String? = nil) {
        self.agentID = agentID
        self.title = title
        self.running = running
        self.branch = branch
        self.worktreePath = worktreePath
        self.automationName = automationName
    }
}

/// Branch names Shepherd gives threads it starts for an item, so the host can find them again.
public enum ForgeLinks {
    /// "agent/issue-34-partial-refunds-round-down": a thread started from issue 34.
    public static func issueBranch(number: Int, title: String) -> String {
        let slug = String(title.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            .split(separator: "-").prefix(6).joined(separator: "-")
        return slug.isEmpty ? "agent/issue-\(number)" : "agent/issue-\(number)-\(slug)"
    }

    /// The issue `issueBranch` named the branch for, if it is one.
    public static func issueNumber(ofBranch branch: String) -> Int? {
        guard branch.hasPrefix("agent/issue-") else { return nil }
        return Int(branch.dropFirst("agent/issue-".count).prefix { $0.isNumber })
    }
}

// MARK: - States

public enum PullRequestState: String, Codable, Hashable, Sendable, CaseIterable {
    case open, draft, merged, closed
}

public enum IssueState: String, Codable, Hashable, Sendable, CaseIterable {
    case open, closed
}

/// All of a pull request's checks rolled into one.
public enum ForgeChecksState: String, Codable, Hashable, Sendable, CaseIterable {
    /// It has none.
    case none
    case passed, failing, running
}

/// The review GitHub says a pull request has (its `reviewDecision`).
public enum ForgeReviewDecision: String, Codable, Hashable, Sendable, CaseIterable {
    case approved, changesRequested, reviewRequired
}

/// Where one reviewer stands.
public enum ForgeReviewState: String, Codable, Hashable, Sendable, CaseIterable {
    case approved, changesRequested, commented, pending, dismissed
}

/// What a submitted review says.
public enum ForgeReviewVerdict: String, Codable, Hashable, Sendable, CaseIterable {
    case comment, approve, requestChanges
}

/// What a browse lists (`RemoteForgeRequest.browse`): GitHub search qualifiers, each optional.
public struct ForgeFilter: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable, CaseIterable { case open, closed, merged, all }
    public enum Sort: String, Codable, Hashable, Sendable, CaseIterable { case updated, created, comments }

    public var state: State
    /// Only what involves the viewer. Across every repository it is implied unless a person is picked.
    public var mine: Bool
    /// Logins ("@me" for the viewer).
    public var author: String?
    public var assignee: String?
    public var label: String?
    public var sort: Sort
    /// Free words, GitHub search syntax.
    public var text: String

    public init(state: State = .open, mine: Bool = false, author: String? = nil, assignee: String? = nil, label: String? = nil,
                sort: Sort = .updated, text: String = "") {
        self.state = state
        self.mine = mine
        self.author = author
        self.assignee = assignee
        self.label = label
        self.sort = sort
        self.text = text
    }

    /// The search string for `kind` in `repo` (`ForgeList.allRepos`: everywhere). Logins and
    /// labels are quoted so a space or colon in them stays one value.
    public func query(kind: ForgeKind, repo: String) -> String {
        func quoted(_ value: String) -> String {
            let clean = value.replacingOccurrences(of: "\"", with: "")
            return clean.contains(where: { $0 == " " || $0 == ":" }) ? "\"\(clean)\"" : clean
        }
        var parts = [kind == .pullRequest ? "is:pr" : "is:issue"]
        switch state {
        case .open: parts.append("is:open")
        case .closed: parts.append(kind == .pullRequest ? "is:unmerged is:closed" : "is:closed")
        case .merged: parts.append(kind == .pullRequest ? "is:merged" : "is:closed")
        case .all: break
        }
        if repo != ForgeList.allRepos { parts.append("repo:\(repo)") }
        if mine || (repo == ForgeList.allRepos && author == nil && assignee == nil) { parts.append("involves:@me") }
        if let author { parts.append("author:\(quoted(author))") }
        if let assignee { parts.append("assignee:\(quoted(assignee))") }
        if let label { parts.append("label:\(quoted(label))") }
        parts.append("archived:false")
        parts.append("sort:\(sort.rawValue)-desc")
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { parts.append(words) }
        return parts.joined(separator: " ")
    }
}

/// A repository's labels and the people who can be assigned or asked to review.
public struct ForgeRepoPeople: Codable, Hashable, Sendable {
    public var labels: [ForgeLabel]
    public var assignable: [String]

    public init(labels: [ForgeLabel] = [], assignable: [String] = []) {
        self.labels = labels
        self.assignable = assignable
    }
}

/// A line comment on its way to GitHub with a review: `line` in the new file (`right`) or the
/// old one (a removed line).
public struct ForgeDraftComment: Codable, Hashable, Sendable {
    public var path: String
    public var line: Int
    public var right: Bool
    public var body: String

    public init(path: String, line: Int, right: Bool = true, body: String) {
        self.path = path
        self.line = line
        self.right = right
        self.body = body
    }
}

/// Which list a pull request's or issue's edit changes.
public enum ForgeEditField: String, Codable, Hashable, Sendable { case labels, assignees, reviewers }

public enum ForgeMergeMethod: String, Codable, Hashable, Sendable, CaseIterable {
    case squash, merge, rebase
}

public enum ForgeCheckState: String, Codable, Hashable, Sendable, CaseIterable {
    case passed, failing, running, skipped
}

/// An issue's place in its work, the dot its row draws.
public enum IssueProgress: String, Codable, Hashable, Sendable, CaseIterable {
    /// Open, assigned to you, nothing started.
    case new
    /// Open, nothing started.
    case open
    /// A thread on this host works on it.
    case running
    /// A pull request is linked to close it.
    case inPullRequest
    case closed
}

// MARK: - Rows

public struct ForgeLabel: Codable, Hashable, Sendable {
    public var name: String
    /// Hex without "#" ("d73a4a"), as GitHub gives it.
    public var color: String

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }
}

/// One pull request row.
public struct PullRequestSummary: Codable, Hashable, Sendable, Identifiable {
    public var ref: ForgeItemRef
    public var title: String
    /// The author's login.
    public var author: String
    public var updatedAt: Date
    public var state: PullRequestState
    public var checks: ForgeChecksState
    public var reviewDecision: ForgeReviewDecision?
    public var headRef: String
    public var baseRef: String
    public var additions: Int
    public var deletions: Int
    /// The team asked to review, for a row under Needs my team's review ("ledger").
    public var team: String?
    /// The thread on this host whose branch is the head.
    public var thread: ForgeThreadLink?

    public init(ref: ForgeItemRef, title: String, author: String, updatedAt: Date, state: PullRequestState,
                checks: ForgeChecksState = .none, reviewDecision: ForgeReviewDecision? = nil, headRef: String, baseRef: String,
                additions: Int = 0, deletions: Int = 0, team: String? = nil, thread: ForgeThreadLink? = nil) {
        self.ref = ref
        self.title = title
        self.author = author
        self.updatedAt = updatedAt
        self.state = state
        self.checks = checks
        self.reviewDecision = reviewDecision
        self.headRef = headRef
        self.baseRef = baseRef
        self.additions = additions
        self.deletions = deletions
        self.team = team
        self.thread = thread
    }

    public var id: String { ref.id }
}

/// One issue row.
public struct IssueSummary: Codable, Hashable, Sendable, Identifiable {
    public var ref: ForgeItemRef
    public var title: String
    public var author: String
    public var updatedAt: Date
    public var state: IssueState
    public var labels: [ForgeLabel]
    /// Assignees' logins.
    public var assignees: [String]
    /// It is assigned to the signed-in gh user.
    public var assignedToViewer: Bool
    /// Pull requests linked to close it (numbers in the same repository).
    public var linkedPullRequests: [Int]
    /// The thread on this host started from it.
    public var thread: ForgeThreadLink?
    /// The automation on this host that watches or acted on it ("Triage Sentry").
    public var automationName: String?

    public init(ref: ForgeItemRef, title: String, author: String, updatedAt: Date, state: IssueState, labels: [ForgeLabel] = [],
                assignees: [String] = [], assignedToViewer: Bool = false, linkedPullRequests: [Int] = [],
                thread: ForgeThreadLink? = nil, automationName: String? = nil) {
        self.ref = ref
        self.title = title
        self.author = author
        self.updatedAt = updatedAt
        self.state = state
        self.labels = labels
        self.assignees = assignees
        self.assignedToViewer = assignedToViewer
        self.linkedPullRequests = linkedPullRequests
        self.thread = thread
        self.automationName = automationName
    }

    public var id: String { ref.id }

    /// The row's dot.
    public var progress: IssueProgress {
        if state == .closed { return .closed }
        if thread?.running == true { return .running }
        if !linkedPullRequests.isEmpty { return .inPullRequest }
        return assignedToViewer && thread == nil ? .new : .open
    }
}

// MARK: - Lists

/// A list section. Each item shows in the first section of its list that holds it.
public enum ForgeSectionID: String, Codable, Hashable, Sendable, CaseIterable {
    // Pull requests
    case authored, reviewRequested, teamReview, openedByAgents
    // Issues
    case assigned, mentioned
    /// Open issues an automation on this host acted on (its run's event) or watches (a label its
    /// GitHub trigger on that repository waits for).
    case fromAutomations
    /// Both: closed (and merged) items that involve you, newest first.
    case closed
    /// A search's matches.
    case results

    /// The sections a list brings unless asked for others: those that do not load on demand.
    public static func defaults(for kind: ForgeKind) -> [ForgeSectionID] {
        all(for: kind).filter { !$0.loadsOnDemand }
    }

    /// Every section a list of `kind` can hold, in the order it shows them.
    public static func all(for kind: ForgeKind) -> [ForgeSectionID] {
        kind == .pullRequest ? [.authored, .reviewRequested, .openedByAgents, .teamReview, .closed]
            : [.assigned, .mentioned, .fromAutomations, .closed]
    }

    /// Collapsed until opened: Needs my team's review and Closed.
    public var loadsOnDemand: Bool { self == .teamReview || self == .closed }
}

public struct ForgeSection: Codable, Hashable, Sendable, Identifiable {
    public var id: ForgeSectionID
    /// Rows of a pull request list.
    public var pullRequests: [PullRequestSummary]
    /// Rows of an issue list.
    public var issues: [IssueSummary]

    public init(id: ForgeSectionID, pullRequests: [PullRequestSummary] = [], issues: [IssueSummary] = []) {
        self.id = id
        self.pullRequests = pullRequests
        self.issues = issues
    }

    public var count: Int { pullRequests.count + issues.count }
}

/// One repository's pull requests or issues, by section.
public struct ForgeList: Codable, Hashable, Sendable {
    /// The `repo` of a list across every repository: GitHub's search for what involves the viewer.
    public static let allRepos = ""

    public var kind: ForgeKind
    public var repo: String
    /// The signed-in gh user's login, when the host read it.
    public var viewer: String?
    /// In `ForgeSectionID.all(for:)` order; only the sections asked for.
    public var sections: [ForgeSection]
    /// A browse's next page (`RemoteForgeRequest.browse` `after`); nil at the end.
    public var next: String?

    public init(kind: ForgeKind, repo: String, viewer: String? = nil, sections: [ForgeSection], next: String? = nil) {
        self.kind = kind
        self.repo = repo
        self.viewer = viewer
        self.sections = sections
        self.next = next
    }

    public func section(_ id: ForgeSectionID) -> ForgeSection? { sections.first { $0.id == id } }
}

// MARK: - Details

public struct ForgeReviewer: Codable, Hashable, Sendable {
    /// A login, or a team's name.
    public var login: String
    public var isTeam: Bool
    public var state: ForgeReviewState

    public init(login: String, isTeam: Bool = false, state: ForgeReviewState) {
        self.login = login
        self.isTeam = isTeam
        self.state = state
    }
}

public struct ForgeCheck: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var workflow: String?
    public var state: ForgeCheckState
    public var startedAt: Date?
    public var completedAt: Date?
    public var detailsURL: String?
    /// The Actions run and job, read from `detailsURL`: what Re-run failed and the log tail need.
    public var runID: Int?
    public var jobID: Int?

    public init(name: String, workflow: String? = nil, state: ForgeCheckState, startedAt: Date? = nil, completedAt: Date? = nil,
                detailsURL: String? = nil, runID: Int? = nil, jobID: Int? = nil) {
        self.name = name
        self.workflow = workflow
        self.state = state
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.detailsURL = detailsURL
        self.runID = runID
        self.jobID = jobID
    }

    public var id: String { jobID.map { "\(name)#\($0)" } ?? name }
    /// How long it ran, once it finished.
    public var duration: TimeInterval? {
        guard let startedAt, let completedAt else { return nil }
        return max(0, completedAt.timeIntervalSince(startedAt))
    }
    /// "test · arm64" for a matrix job's "test (arm64)".
    public var displayName: String {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "("), open > name.startIndex else { return name }
        let base = name[..<open].trimmingCharacters(in: .whitespaces)
        let inner = name[name.index(after: open)..<name.index(before: name.endIndex)]
        return base.isEmpty || inner.isEmpty ? name : "\(base) · \(inner.replacingOccurrences(of: ", ", with: " · "))"
    }
}

/// A comment on one line of a pull request's diff.
public struct ForgeLineComment: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var author: String
    public var path: String
    public var line: Int?
    /// The last lines of the hunk it sits under (at most `ForgeLimits.hunkLines`).
    public var diffHunk: String
    public var body: String
    public var createdAt: Date
    /// The comment it answers, in a thread.
    public var inReplyTo: Int?

    public init(id: Int, author: String, path: String, line: Int?, diffHunk: String, body: String, createdAt: Date, inReplyTo: Int? = nil) {
        self.id = id
        self.author = author
        self.path = path
        self.line = line
        self.diffHunk = diffHunk
        self.body = body
        self.createdAt = createdAt
        self.inReplyTo = inReplyTo
    }
}

/// One line of an item's Activity.
public struct ForgeEvent: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: Codable, Hashable, Sendable {
        case opened
        case commented(body: String)
        /// A review and the line comments it left.
        case reviewed(state: ForgeReviewState, body: String, comments: [ForgeLineComment])
        /// Consecutive commits, as one line.
        case pushed(commits: Int)
        case merged
        case closed
        case reopened
        case convertedToDraft
        case readyForReview
        case assigned(login: String)
        /// Another issue or pull request mentioned this one.
        case referenced(number: Int, title: String, isPullRequest: Bool)
    }

    public var id: String
    /// A login; a commit's author name for `pushed`.
    public var actor: String
    public var at: Date
    public var kind: Kind

    public init(id: String, actor: String, at: Date, kind: Kind) {
        self.id = id
        self.actor = actor
        self.at = at
        self.kind = kind
    }
}

/// Whether GitHub can merge the head into the base.
public enum ForgeMergeable: String, Codable, Hashable, Sendable {
    case mergeable, conflicting, unknown
}

/// A pull request's page.
public struct PullRequestDetail: Codable, Hashable, Sendable {
    public var summary: PullRequestSummary
    public var createdAt: Date
    /// Markdown, untrusted.
    public var body: String
    public var changedFiles: Int
    public var reviewers: [ForgeReviewer]
    public var checks: [ForgeCheck]
    /// Oldest first, starting with `opened`.
    public var events: [ForgeEvent]
    public var mergeable: ForgeMergeable
    /// The base moved on since the head branched (GitHub's BEHIND).
    public var behindBase: Bool
    /// What the repository allows, and the method gh would use by default (the viewer's last).
    public var mergeMethods: [ForgeMergeMethod]
    public var defaultMergeMethod: ForgeMergeMethod?
    /// GitHub deletes the head branch after a merge here anyway.
    public var deletesBranchOnMerge: Bool
    /// Merge when ready (`gh pr merge --auto`) is on.
    public var autoMerge: Bool
    /// The merge's commit, once merged.
    public var mergeCommit: String?
    /// The head branch is gone from GitHub (deleted after the merge).
    public var headBranchDeleted: Bool
    /// Issues it closes when merged.
    public var closesIssues: [Int]
    /// The signed-in gh user's login, when the host read it.
    public var viewer: String?
    /// Its labels and assignees' logins; nil from a host that doesn't read them.
    public var labels: [ForgeLabel]?
    public var assignees: [String]?

    public init(summary: PullRequestSummary, createdAt: Date, body: String, changedFiles: Int = 0, reviewers: [ForgeReviewer] = [],
                checks: [ForgeCheck] = [], events: [ForgeEvent] = [], mergeable: ForgeMergeable = .unknown, behindBase: Bool = false,
                mergeMethods: [ForgeMergeMethod] = ForgeMergeMethod.allCases, defaultMergeMethod: ForgeMergeMethod? = nil,
                deletesBranchOnMerge: Bool = false, autoMerge: Bool = false, mergeCommit: String? = nil, headBranchDeleted: Bool = false, closesIssues: [Int] = [],
                viewer: String? = nil, labels: [ForgeLabel]? = nil, assignees: [String]? = nil) {
        self.labels = labels
        self.assignees = assignees
        self.summary = summary
        self.createdAt = createdAt
        self.body = body
        self.changedFiles = changedFiles
        self.reviewers = reviewers
        self.checks = checks
        self.events = events
        self.mergeable = mergeable
        self.behindBase = behindBase
        self.mergeMethods = mergeMethods
        self.defaultMergeMethod = defaultMergeMethod
        self.deletesBranchOnMerge = deletesBranchOnMerge
        self.autoMerge = autoMerge
        self.mergeCommit = mergeCommit
        self.headBranchDeleted = headBranchDeleted
        self.closesIssues = closesIssues
        self.viewer = viewer
    }

    public var ref: ForgeItemRef { summary.ref }
    public var state: PullRequestState { summary.state }

    /// Why it can't merge now, each a short line ("mara requested changes", "test · arm64 is
    /// failing"); empty when nothing stands in the way. Only for an open pull request.
    public var blockers: [String] {
        guard state == .open || state == .draft else { return [] }
        var lines: [String] = []
        if state == .draft { lines.append("It's a draft") }
        lines += reviewers.filter { $0.state == .changesRequested }.map { "\($0.login) requested changes" }
        lines += checks.filter { $0.state == .failing }.map { "\($0.displayName) is failing" }
        if mergeable == .conflicting { lines.append("It has merge conflicts") }
        if summary.reviewDecision == .reviewRequired, !reviewers.contains(where: { $0.state == .changesRequested }) {
            lines.append("It needs an approving review")
        }
        return lines
    }
}

/// A pull request's diff, from `gh pr diff`, each file cut at `ChangesLimits.fileLines` and all of
/// them kept under `ChangesLimits.remoteBytes`.
public struct PullRequestFiles: Codable, Hashable, Sendable {
    public var ref: ForgeItemRef
    public var files: [ChangesFileDiff]
    /// Files left out past the byte budget.
    public var omitted: Int

    public init(ref: ForgeItemRef, files: [ChangesFileDiff], omitted: Int = 0) {
        self.ref = ref
        self.files = files
        self.omitted = omitted
    }
}

/// An issue's page.
public struct IssueDetail: Codable, Hashable, Sendable {
    public struct LinkedPullRequest: Codable, Hashable, Sendable {
        public var number: Int
        public var title: String?
        public var url: String

        public init(number: Int, title: String? = nil, url: String) {
            self.number = number
            self.title = title
            self.url = url
        }
    }

    public var summary: IssueSummary
    public var createdAt: Date
    /// Markdown, untrusted.
    public var body: String
    /// Oldest first, starting with `opened`; comments are `commented` events.
    public var events: [ForgeEvent]
    public var linkedPullRequests: [LinkedPullRequest]
    public var viewer: String?

    public init(summary: IssueSummary, createdAt: Date, body: String, events: [ForgeEvent] = [],
                linkedPullRequests: [LinkedPullRequest] = [], viewer: String? = nil) {
        self.summary = summary
        self.createdAt = createdAt
        self.body = body
        self.events = events
        self.linkedPullRequests = linkedPullRequests
        self.viewer = viewer
    }

    public var ref: ForgeItemRef { summary.ref }
}

// MARK: - Sidebar

/// An item the user pinned to the sidebar. Persisted per host.
public struct ForgePin: Codable, Hashable, Sendable, Identifiable {
    public var ref: ForgeItemRef
    /// Its title when pinned: shown until the host reads it again.
    public var title: String
    public var pinnedAt: Date

    public init(ref: ForgeItemRef, title: String, pinnedAt: Date) {
        self.ref = ref
        self.title = title
        self.pinnedAt = pinnedAt
    }

    public var id: String { ref.id }

    private enum CodingKeys: String, CodingKey { case ref, title, pinnedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(ForgeItemRef.self, forKey: .ref)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt) ?? Date(timeIntervalSince1970: 0)
    }
}

/// A pin with what the host read of it now (nil when it couldn't).
public struct ForgePinnedItem: Codable, Hashable, Sendable, Identifiable {
    public var pin: ForgePin
    public var pullRequest: PullRequestSummary?
    public var issue: IssueSummary?

    public init(pin: ForgePin, pullRequest: PullRequestSummary? = nil, issue: IssueSummary? = nil) {
        self.pin = pin
        self.pullRequest = pullRequest
        self.issue = issue
    }

    public var id: String { pin.id }
    public var title: String { pullRequest?.title ?? issue?.title ?? pin.title }
}

/// What the sidebar's Issues & PRs row and its Pinned section show.
public struct ForgeSidebar: Codable, Hashable, Sendable {
    /// Newest pin first.
    public var pins: [ForgePinnedItem]
    /// Pull requests waiting on your review, yours with changes requested or failing checks,
    /// and new issues assigned to you, across the repositories this host knows.
    public var needsYou: Int

    public init(pins: [ForgePinnedItem], needsYou: Int) {
        self.pins = pins
        self.needsYou = needsYou
    }
}

public enum ForgeLimits {
    /// Pins a host keeps.
    public static let pins = 20
    /// Lines of a hunk a line comment carries.
    public static let hunkLines = 8
    /// Lines of a failing job's log `checkLog` returns.
    public static let logLines = 30
    /// The longest comment, review or title the host sends to GitHub (GitHub's own cap).
    public static let bodyCharacters = 65_536
}

// MARK: - Errors

/// Why a forge request failed, in words for the person (`message`).
public struct ForgeError: Error, Codable, Hashable, Sendable {
    public enum Code: String, Codable, Hashable, Sendable, CaseIterable {
        case ghMissing = "gh_missing"
        case signedOut = "gh_signed_out"
        case notFound = "not_found"
        case rateLimited = "rate_limited"
        case timedOut = "timed_out"
        case invalid
        case failed = "gh_failed"
        /// The host doesn't serve Issues & PRs (an older Shepherd).
        case unsupported
        /// The host couldn't be reached.
        case unreachable
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public static let ghMissing = ForgeError(.ghMissing, "gh isn't installed. Install the GitHub CLI, then run gh auth login.")
    public static let signedOut = ForgeError(.signedOut, "gh isn't signed in: run gh auth login.")
}

// MARK: - Requests

/// A forge request (`RemoteRequest.forge`, answered by `SessionServer.forge`). Repositories
/// are "owner/name". Changes go through gh at once; nothing polls.
public enum RemoteForgeRequest: Codable, Hashable, Sendable {
    /// The repositories this host knows (`ForgeRepo`): the picker. Answered `repos`.
    case repos
    /// A repository's sections (nil: `ForgeSectionID.defaults(for:)`), or with `ForgeList.allRepos`
    /// everything on GitHub that involves the viewer. Answered `list`.
    case list(kind: ForgeKind, repo: String, sections: [ForgeSectionID]?)
    /// Matches for a search in a repository (or `ForgeList.allRepos`), as one `results` section. Answered `list`.
    case search(kind: ForgeKind, repo: String, query: String)
    /// Answered `pullRequest`.
    case pullRequest(ref: ForgeItemRef)
    /// The diff. Answered `files`.
    case pullRequestFiles(ref: ForgeItemRef)
    /// Answered `issue`.
    case issue(ref: ForgeItemRef)
    /// The last lines of a failing job's log (`ForgeCheck.jobID`). Answered `checkLog`.
    case checkLog(repo: String, jobID: Int)
    /// Comment on a pull request or issue.
    case comment(ref: ForgeItemRef, body: String)
    case review(ref: ForgeItemRef, verdict: ForgeReviewVerdict, body: String)
    /// `whenReady`: merge once reviews and checks allow (`gh pr merge --auto`). `deleteBranch`
    /// deletes the head branch on GitHub; a worktree is removed separately (Delete Worktree).
    case merge(ref: ForgeItemRef, method: ForgeMergeMethod, whenReady: Bool, deleteBranch: Bool)
    /// Delete a merged pull request's head branch on GitHub (Clean up). The host reads the
    /// branch itself and refuses one that isn't merged or lives in a fork.
    case deleteBranch(ref: ForgeItemRef)
    /// Convert to draft (true) or mark ready for review (false).
    case setDraft(ref: ForgeItemRef, draft: Bool)
    /// Reopen (true) or close (false) a pull request or issue.
    case setOpen(ref: ForgeItemRef, open: Bool)
    case editTitle(ref: ForgeItemRef, title: String)
    /// Re-run a run's failed jobs (`ForgeCheck.runID`).
    case rerunFailed(repo: String, runID: Int)
    /// Every pull request or issue a filter matches, 30 at a time from `after` (`ForgeList.next`),
    /// as one `results` section. Answered `list`.
    case browse(kind: ForgeKind, repo: String, filter: ForgeFilter, after: String?)
    /// A repository's labels and assignable people. Answered `people`.
    case people(repo: String)
    /// Open an issue. Answered `created`.
    case createIssue(repo: String, title: String, body: String)
    /// Add and remove labels, assignees or (pull requests only) reviewers.
    case edit(ref: ForgeItemRef, field: ForgeEditField, add: [String], remove: [String])
    /// A review with line comments, posted on GitHub as the viewer.
    case postReview(ref: ForgeItemRef, verdict: ForgeReviewVerdict, body: String, comments: [ForgeDraftComment])
    /// Pins and the Needs you count. Answered `sidebar`.
    case sidebar
    /// Pin or unpin an item. Answered `sidebar` (pins as stored, without reading GitHub).
    case setPinned(ref: ForgeItemRef, title: String, pinned: Bool)

    /// It changes something on GitHub or the host.
    public var isChange: Bool {
        switch self {
        case .repos, .list, .search, .browse, .people, .pullRequest, .pullRequestFiles, .issue, .checkLog, .sidebar: false
        case .comment, .review, .merge, .deleteBranch, .setDraft, .setOpen, .editTitle, .rerunFailed, .setPinned, .createIssue, .edit,
             .postReview: true
        }
    }
}

/// A forge request's answer. A change answers `ok` (or `sidebar` for `setPinned`); read again
/// to see its effect.
public enum RemoteForgeResult: Codable, Hashable, Sendable {
    case ok
    case repos([ForgeRepo])
    case list(ForgeList)
    case pullRequest(PullRequestDetail)
    case files(PullRequestFiles)
    case issue(IssueDetail)
    case checkLog(String)
    case sidebar(ForgeSidebar)
    case people(ForgeRepoPeople)
    /// The item a change made (`createIssue`).
    case created(ForgeItemRef)
}
