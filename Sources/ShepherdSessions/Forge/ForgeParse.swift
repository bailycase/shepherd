import Foundation
import ShepherdCore
import ShepherdProtocol

/// gh's JSON (`gh pr|issue list|view --json`, `gh api …/timeline`, `…/pulls/N/comments`) read into
/// the forge models. Pure: the service feeds it recorded or live output. Everything decoded is
/// untrusted text and stays data.
enum ForgeParse {
    /// The fields a row needs, asked of `gh pr list|view --json`.
    static let pullFields = "number,title,author,updatedAt,state,isDraft,headRefName,baseRefName,reviewDecision,statusCheckRollup,additions,deletions,reviewRequests"
    static let pullDetailFields = pullFields
        + ",createdAt,body,changedFiles,latestReviews,mergeable,mergeStateStatus,mergeCommit,closingIssuesReferences,autoMergeRequest"
    static let issueFields = "number,title,author,updatedAt,state,labels,assignees,closedByPullRequestsReferences"
    static let issueDetailFields = issueFields + ",createdAt,body,comments"
    static let repoFields = "squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed,viewerDefaultMergeMethod,deleteBranchOnMerge"

    struct ParseError: Error {}

    // MARK: gh shapes

    struct User: Decodable { var login: String? }
    struct Actor: Decodable { var login: String?; var name: String? }
    struct Check: Decodable {
        var __typename: String?
        var name: String?, context: String?
        var status: String?, conclusion: String?, state: String?
        var startedAt: String?, completedAt: String?
        var detailsUrl: String?, targetUrl: String?, workflowName: String?
    }
    struct Request: Decodable { var __typename: String?; var login: String?; var name: String?; var slug: String? }
    struct Review: Decodable { var author: User?; var state: String? }
    struct Numbered: Decodable { var number: Int; var url: String? }
    struct Pull: Decodable {
        var number: Int
        var title: String
        var author: User?
        var updatedAt: String?
        var createdAt: String?
        var state: String
        var isDraft: Bool?
        var headRefName: String?
        var baseRefName: String?
        var reviewDecision: String?
        var statusCheckRollup: [Check]?
        var additions: Int?
        var deletions: Int?
        var reviewRequests: [Request]?
        var body: String?
        var changedFiles: Int?
        var latestReviews: [Review]?
        var mergeable: String?
        var mergeStateStatus: String?
        struct Commit: Decodable { var oid: String? }
        var mergeCommit: Commit?
        var closingIssuesReferences: [Numbered]?
        struct AutoMerge: Decodable { var mergeMethod: String? }
        var autoMergeRequest: AutoMerge?
    }
    struct Label: Decodable { var name: String; var color: String? }
    struct Comment: Decodable { var author: User?; var body: String?; var createdAt: String?; var id: String? }
    struct Issue: Decodable {
        var number: Int
        var title: String
        var author: User?
        var updatedAt: String?
        var createdAt: String?
        var state: String
        var labels: [Label]?
        var assignees: [User]?
        var closedByPullRequestsReferences: [Numbered]?
        var body: String?
        var comments: [Comment]?
    }
    struct RepoSettings: Decodable {
        var squashMergeAllowed: Bool?, mergeCommitAllowed: Bool?, rebaseMergeAllowed: Bool?
        var viewerDefaultMergeMethod: String?, deleteBranchOnMerge: Bool?
    }
    struct TimelineItem: Decodable {
        var event: String?
        var id: Int?
        var sha: String?
        var actor: User?
        var user: User?
        var assignee: User?
        var created_at: String?
        var submitted_at: String?
        var body: String?
        var state: String?
        struct CommitAuthor: Decodable { var name: String?; var date: String? }
        var author: CommitAuthor?
        struct Source: Decodable {
            struct Item: Decodable {
                var number: Int?
                var title: String?
                struct Marker: Decodable {}
                var pull_request: Marker?
            }
            var issue: Item?
        }
        var source: Source?
    }
    struct LineComment: Decodable {
        var id: Int
        var user: User?
        var path: String?
        var line: Int?
        var original_line: Int?
        var diff_hunk: String?
        var body: String?
        var created_at: String?
        var in_reply_to_id: Int?
        var pull_request_review_id: Int?
    }
    struct SearchHit: Decodable {
        struct Repository: Decodable { var nameWithOwner: String? }
        var number: Int
        var repository: Repository?
    }

    // MARK: Helpers

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw ParseError() }
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    /// An ISO 8601 time; nil for none or GitHub's zero time ("0001-01-01T00:00:00Z").
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty, let date = iso.date(from: text) ?? isoFractional.date(from: text),
              date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    static func pullState(_ state: String, isDraft: Bool?) -> PullRequestState {
        switch state.uppercased() {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: isDraft == true ? .draft : .open
        }
    }

    static func reviewDecision(_ text: String?) -> ForgeReviewDecision? {
        switch text?.uppercased() {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .reviewRequired
        default: nil
        }
    }

    static func reviewState(_ text: String?) -> ForgeReviewState? {
        switch text?.uppercased() {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "COMMENTED": .commented
        case "DISMISSED": .dismissed
        case "PENDING": .pending
        default: nil
        }
    }

    // MARK: Checks

    /// `…/actions/runs/123/job/456` → (123, 456).
    static func actionsIDs(_ url: String?) -> (run: Int?, job: Int?) {
        guard let url else { return (nil, nil) }
        let parts = url.split(separator: "/").map(String.init)
        func after(_ word: String) -> Int? { parts.firstIndex(of: word).flatMap { $0 + 1 < parts.count ? Int(parts[$0 + 1]) : nil } }
        return (after("runs"), after("job"))
    }

    static func check(_ raw: Check) -> ForgeCheck? {
        let isStatus = raw.__typename == "StatusContext"
        guard let name = isStatus ? raw.context : raw.name, !name.isEmpty else { return nil }
        let state: ForgeCheckState
        if isStatus {
            switch raw.state?.uppercased() {
            case "SUCCESS": state = .passed
            case "FAILURE", "ERROR": state = .failing
            default: state = .running
            }
        } else if raw.status?.uppercased() == "COMPLETED" {
            switch raw.conclusion?.uppercased() {
            case "SUCCESS", "NEUTRAL": state = .passed
            case "SKIPPED", "STALE": state = .skipped
            default: state = .failing
            }
        } else {
            state = .running
        }
        let url = isStatus ? raw.targetUrl : raw.detailsUrl
        let ids = actionsIDs(url)
        return ForgeCheck(name: name, workflow: raw.workflowName.flatMap { $0.isEmpty ? nil : $0 }, state: state,
                          startedAt: date(raw.startedAt), completedAt: state == .running ? nil : date(raw.completedAt),
                          detailsURL: url, runID: ids.run, jobID: ids.job)
    }

    /// The rollup's checks, one per workflow and name (the latest run wins).
    static func checks(_ rollup: [Check]?) -> [ForgeCheck] {
        var order: [String] = []
        var latest: [String: ForgeCheck] = [:]
        for check in (rollup ?? []).compactMap(check) {
            let key = (check.workflow ?? "") + "\u{0}" + check.name
            if let kept = latest[key], (kept.startedAt ?? .distantPast) > (check.startedAt ?? .distantPast) { continue }
            if latest[key] == nil { order.append(key) }
            latest[key] = check
        }
        return order.compactMap { latest[$0] }
    }

    static func rollup(_ checks: [ForgeCheck]) -> ForgeChecksState {
        let counted = checks.filter { $0.state != .skipped }
        if counted.contains(where: { $0.state == .failing }) { return .failing }
        if counted.contains(where: { $0.state == .running }) { return .running }
        return counted.isEmpty ? (checks.isEmpty ? .none : .passed) : .passed
    }

    // MARK: Pull requests

    static func summary(_ pull: Pull, repo: String) -> PullRequestSummary {
        let team = pull.reviewRequests?.first { $0.__typename == "Team" }.flatMap { $0.slug ?? $0.name }
        return PullRequestSummary(
            ref: ForgeItemRef(kind: .pullRequest, repo: repo, number: pull.number), title: pull.title,
            author: pull.author?.login ?? "ghost", updatedAt: date(pull.updatedAt) ?? date(pull.createdAt) ?? Date(timeIntervalSince1970: 0),
            state: pullState(pull.state, isDraft: pull.isDraft), checks: rollup(checks(pull.statusCheckRollup)),
            reviewDecision: reviewDecision(pull.reviewDecision), headRef: pull.headRefName ?? "", baseRef: pull.baseRefName ?? "",
            additions: pull.additions ?? 0, deletions: pull.deletions ?? 0, team: team)
    }

    static func pullRequests(_ data: Data, repo: String) throws -> [PullRequestSummary] {
        try decode([Pull].self, data).map { summary($0, repo: repo) }
    }

    /// Reviewers who reviewed (their latest verdict), then those asked who haven't since.
    static func reviewers(_ pull: Pull) -> [ForgeReviewer] {
        var result: [ForgeReviewer] = []
        for review in pull.latestReviews ?? [] {
            guard let login = review.author?.login, let state = reviewState(review.state) else { continue }
            result.append(ForgeReviewer(login: login, state: state))
        }
        for request in pull.reviewRequests ?? [] {
            let isTeam = request.__typename == "Team"
            guard let login = isTeam ? (request.name ?? request.slug) : request.login else { continue }
            result.removeAll { $0.login == login && !isTeam }
            result.append(ForgeReviewer(login: login, isTeam: isTeam, state: .pending))
        }
        return result
    }

    static func mergeMethod(_ text: String?) -> ForgeMergeMethod? {
        switch text?.uppercased() {
        case "SQUASH": .squash
        case "MERGE": .merge
        case "REBASE": .rebase
        default: nil
        }
    }

    static func pullRequestDetail(view: Data, timeline: Data?, lineComments: Data?, repoSettings: Data?, repo: String,
                                  viewer: String?) throws -> PullRequestDetail {
        let pull = try decode(Pull.self, view)
        let summary = summary(pull, repo: repo)
        let settings = repoSettings.flatMap { try? decode(RepoSettings.self, $0) }
        var methods: [ForgeMergeMethod] = []
        if settings?.squashMergeAllowed ?? true { methods.append(.squash) }
        if settings?.mergeCommitAllowed ?? true { methods.append(.merge) }
        if settings?.rebaseMergeAllowed ?? true { methods.append(.rebase) }
        let comments = lineComments.flatMap { try? decode([LineComment].self, $0) } ?? []
        let created = date(pull.createdAt) ?? summary.updatedAt
        var events = [ForgeEvent(id: "opened", actor: summary.author, at: created, kind: .opened)]
        events += timeline.flatMap { try? self.events(timeline: $0, lineComments: comments) } ?? []
        let mergeable: ForgeMergeable = switch pull.mergeable?.uppercased() {
        case "MERGEABLE": .mergeable
        case "CONFLICTING": .conflicting
        default: .unknown
        }
        return PullRequestDetail(
            summary: summary, createdAt: created, body: pull.body ?? "", changedFiles: pull.changedFiles ?? 0,
            reviewers: reviewers(pull), checks: checks(pull.statusCheckRollup), events: events, mergeable: mergeable,
            behindBase: pull.mergeStateStatus?.uppercased() == "BEHIND", mergeMethods: methods,
            defaultMergeMethod: mergeMethod(settings?.viewerDefaultMergeMethod).flatMap { methods.contains($0) ? $0 : nil } ?? methods.first,
            deletesBranchOnMerge: settings?.deleteBranchOnMerge ?? false, autoMerge: pull.autoMergeRequest != nil,
            mergeCommit: pull.mergeCommit?.oid.flatMap { $0.isEmpty ? nil : $0 },
            headBranchDeleted: timeline.flatMap { try? decode([TimelineItem].self, $0) }?.contains { $0.event == "head_ref_deleted" } ?? false,
            closesIssues: (pull.closingIssuesReferences ?? []).map(\.number), viewer: viewer)
    }

    static func lineComment(_ raw: LineComment) -> ForgeLineComment {
        let hunk = (raw.diff_hunk ?? "").split(separator: "\n", omittingEmptySubsequences: false).suffix(ForgeLimits.hunkLines)
        return ForgeLineComment(id: raw.id, author: raw.user?.login ?? "ghost", path: raw.path ?? "", line: raw.line ?? raw.original_line,
                                diffHunk: hunk.joined(separator: "\n"), body: raw.body ?? "",
                                createdAt: date(raw.created_at) ?? Date(timeIntervalSince1970: 0), inReplyTo: raw.in_reply_to_id)
    }

    /// The timeline's events Activity shows, consecutive commits as one `pushed`. A review
    /// carries its line comments.
    static func events(timeline data: Data, lineComments: [LineComment] = []) throws -> [ForgeEvent] {
        let items = try decode([TimelineItem].self, data)
        var events: [ForgeEvent] = []
        for (index, item) in items.enumerated() {
            let id = "\(item.event ?? "event"):\(item.id.map(String.init) ?? item.sha ?? String(index))"
            let actor = item.user?.login ?? item.actor?.login ?? "ghost"
            let at = date(item.created_at) ?? date(item.submitted_at) ?? Date(timeIntervalSince1970: 0)
            let kind: ForgeEvent.Kind
            switch item.event {
            case "committed":
                let when = date(item.author?.date) ?? at
                if case .pushed(let commits)? = events.last?.kind {
                    events[events.count - 1].kind = .pushed(commits: commits + 1)
                    events[events.count - 1].at = when
                    continue
                }
                events.append(ForgeEvent(id: id, actor: item.author?.name ?? "someone", at: when, kind: .pushed(commits: 1)))
                continue
            case "commented": kind = .commented(body: item.body ?? "")
            case "reviewed":
                guard let state = reviewState(item.state) else { continue }
                let own = lineComments.filter { $0.pull_request_review_id == item.id && item.id != nil }.map(lineComment)
                // A bare reply to a comment thread is a review with no body: its comment is the event.
                if state == .commented, (item.body ?? "").isEmpty, own.isEmpty { continue }
                kind = .reviewed(state: state, body: item.body ?? "", comments: own)
            case "merged": kind = .merged
            case "closed": kind = .closed
            case "reopened": kind = .reopened
            case "convert_to_draft": kind = .convertedToDraft
            case "ready_for_review": kind = .readyForReview
            case "assigned":
                guard let login = item.assignee?.login else { continue }
                kind = .assigned(login: login)
            case "cross-referenced":
                guard let source = item.source?.issue, let number = source.number else { continue }
                kind = .referenced(number: number, title: source.title ?? "", isPullRequest: source.pull_request != nil)
            default: continue
            }
            events.append(ForgeEvent(id: id, actor: actor, at: at, kind: kind))
        }
        return events
    }

    // MARK: Issues

    static func summary(_ issue: Issue, repo: String, viewer: String?) -> IssueSummary {
        let assignees = (issue.assignees ?? []).compactMap(\.login)
        return IssueSummary(
            ref: ForgeItemRef(kind: .issue, repo: repo, number: issue.number), title: issue.title, author: issue.author?.login ?? "ghost",
            updatedAt: date(issue.updatedAt) ?? date(issue.createdAt) ?? Date(timeIntervalSince1970: 0),
            state: issue.state.uppercased() == "CLOSED" ? .closed : .open,
            labels: (issue.labels ?? []).map { ForgeLabel(name: $0.name, color: $0.color ?? "") }, assignees: assignees,
            assignedToViewer: viewer.map { viewer in assignees.contains { $0.caseInsensitiveCompare(viewer) == .orderedSame } } ?? false,
            linkedPullRequests: (issue.closedByPullRequestsReferences ?? []).map(\.number))
    }

    static func issues(_ data: Data, repo: String, viewer: String?) throws -> [IssueSummary] {
        try decode([Issue].self, data).map { summary($0, repo: repo, viewer: viewer) }
    }

    static func issueDetail(view: Data, timeline: Data?, repo: String, viewer: String?) throws -> IssueDetail {
        let issue = try decode(Issue.self, view)
        let summary = summary(issue, repo: repo, viewer: viewer)
        let created = date(issue.createdAt) ?? summary.updatedAt
        var events = [ForgeEvent(id: "opened", actor: summary.author, at: created, kind: .opened)]
        if let timeline, let read = try? self.events(timeline: timeline) {
            events += read
        } else {
            events += (issue.comments ?? []).enumerated().map { index, comment in
                ForgeEvent(id: "commented:\(comment.id ?? String(index))", actor: comment.author?.login ?? "ghost",
                           at: date(comment.createdAt) ?? created, kind: .commented(body: comment.body ?? ""))
            }
        }
        var linked = (issue.closedByPullRequestsReferences ?? []).map {
            IssueDetail.LinkedPullRequest(number: $0.number, url: $0.url ?? ForgeItemRef(kind: .pullRequest, repo: repo, number: $0.number).url)
        }
        for event in events {
            guard case .referenced(let number, let title, true) = event.kind else { continue }
            if let i = linked.firstIndex(where: { $0.number == number }) {
                linked[i].title = linked[i].title ?? title
            }
        }
        return IssueDetail(summary: summary, createdAt: created, body: issue.body ?? "", events: events, linkedPullRequests: linked,
                           viewer: viewer)
    }

    // MARK: Search, logs and diffs

    /// `gh search prs|issues --json number,repository` → "owner/name#12" keys.
    static func searchKeys(_ data: Data) throws -> Set<String> {
        Set(try decode([SearchHit].self, data).compactMap { hit in hit.repository?.nameWithOwner.map { "\($0)#\(hit.number)" } })
    }

    /// The last `ForgeLimits.logLines` lines of `gh run view --log-failed`, without the job and
    /// step columns, timestamps or terminal colors.
    static func logTail(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let columns = raw.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            var line = String(columns.count == 3 ? columns[2] : raw)
            line = line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            if let range = line.range(of: #"^\d{4}-\d\d-\d\dT[0-9:.]+Z ?"#, options: .regularExpression) { line.removeSubrange(range) }
            return line.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return String(lines.suffix(ForgeLimits.logLines).joined(separator: "\n").suffix(4096))
    }

    /// `gh pr diff` read with the Changes engine's parser: each file cut at
    /// `ChangesLimits.fileLines`, and all of them under `budget` bytes of JSON.
    static func files(_ diff: Data, ref: ForgeItemRef, budget: Int = ChangesLimits.remoteBytes) -> PullRequestFiles {
        let parsed = DiffFile.parse(String(decoding: diff, as: UTF8.self))
        var files: [ChangesFileDiff] = []
        var left = budget
        for (index, file) in parsed.enumerated() {
            let fitted = ChangesService.fitting(ChangesService.truncated(file, lines: ChangesLimits.fileLines), bytes: left)
            let size = (try? JSONEncoder().encode(fitted).count) ?? Int.max
            guard size <= left else { return PullRequestFiles(ref: ref, files: files, omitted: parsed.count - index) }
            left -= size
            files.append(fitted)
        }
        return PullRequestFiles(ref: ref, files: files)
    }
}
