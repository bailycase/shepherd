import Foundation
import ShepherdCore
import ShepherdProtocol

/// The status role an Issues & PRs dot, tag or word draws in. Every case but `merged` is the
/// ShepherdUI `AgentState` of the same name (`AgentState(rawValue: tone.rawValue)`); `merged` has
/// no agent state, so each UI picks its token for it.
public enum ForgeTone: String, Hashable, Sendable, CaseIterable {
    case running, attention, done, failed, idle, merged
}

/// A pull request row's dot and word: merged, closed and draft first, then the review, then the
/// checks.
public enum PullRequestRowState: String, Hashable, Sendable, CaseIterable {
    case merged, closed, draft, changesRequested, failing, running, passed, open

    public init(_ pull: PullRequestSummary) {
        switch pull.state {
        case .merged: self = .merged
        case .closed: self = .closed
        case .draft: self = .draft
        case .open:
            if pull.reviewDecision == .changesRequested { self = .changesRequested; return }
            switch pull.checks {
            case .failing: self = .failing
            case .running: self = .running
            case .passed: self = .passed
            case .none: self = .open
            }
        }
    }

    /// "Changes", "Failing", "Passed" (a mobile row's word).
    public var label: String {
        switch self {
        case .merged: "Merged"
        case .closed: "Closed"
        case .draft: "Draft"
        case .changesRequested: "Changes"
        case .failing: "Failing"
        case .running: "Running"
        case .passed: "Passed"
        case .open: "Open"
        }
    }

    public var tone: ForgeTone {
        switch self {
        case .merged: .merged
        case .closed, .changesRequested, .failing: .failed
        case .draft, .open: .idle
        case .running: .running
        case .passed: .done
        }
    }
}

/// The primary button of a pull request's page.
public enum ForgePrimaryAction: String, Hashable, Sendable {
    /// Opens the merge menu.
    case merge
    /// `setDraft(draft: false)`.
    case markReady
    /// Removes the worktree (the confirmed Delete Worktree path) and deletes the branch
    /// (`deleteBranch`) if GitHub still has it.
    case cleanUp
    /// `deleteBranch`: no worktree here, the branch is still on GitHub.
    case deleteBranch
    /// `setOpen(open: true)`.
    case reopen

    public var label: String {
        switch self {
        case .merge: "Merge…"
        case .markReady: "Ready for review"
        case .cleanUp: "Clean up"
        case .deleteBranch: "Delete branch"
        case .reopen: "Reopen"
        }
    }
}

/// Words, tones and lines both Issues & PRs UIs draw from the forge models.
public enum ForgePresentation {
    // MARK: States

    /// The page's state tag: "Open", "Draft", "Merged", "Closed".
    public static func badge(_ state: PullRequestState) -> (label: String, tone: ForgeTone) {
        switch state {
        case .open: ("Open", .done)
        case .draft: ("Draft", .idle)
        case .merged: ("Merged", .merged)
        case .closed: ("Closed", .failed)
        }
    }

    public static func badge(_ state: IssueState) -> (label: String, tone: ForgeTone) {
        state == .open ? ("Open", .done) : ("Closed", .merged)
    }

    /// An issue row's dot.
    public static func tone(_ progress: IssueProgress) -> ForgeTone {
        switch progress {
        case .new: .failed
        case .running: .running
        case .inPullRequest: .done
        case .open, .closed: .idle
        }
    }

    public static func label(_ progress: IssueProgress) -> String {
        switch progress {
        case .new: "New"
        case .open: "Open"
        case .running: "Running"
        case .inPullRequest: "In PR"
        case .closed: "Closed"
        }
    }

    public static func label(_ state: ForgeReviewState) -> String {
        switch state {
        case .approved: "approved"
        case .changesRequested: "changes requested"
        case .commented: "commented"
        case .pending: "pending"
        case .dismissed: "dismissed"
        }
    }

    public static func tone(_ state: ForgeReviewState) -> ForgeTone {
        switch state {
        case .approved: .done
        case .changesRequested: .failed
        case .commented, .pending, .dismissed: .idle
        }
    }

    public static func tone(_ state: ForgeCheckState) -> ForgeTone {
        switch state {
        case .passed: .done
        case .failing: .failed
        case .running: .running
        case .skipped: .idle
        }
    }

    /// The Checks tab's dot.
    public static func tone(_ checks: ForgeChecksState) -> ForgeTone? {
        switch checks {
        case .none: nil
        case .passed: .done
        case .failing: .failed
        case .running: .running
        }
    }

    // MARK: Sections

    public static func title(_ section: ForgeSectionID, kind: ForgeKind) -> String {
        switch section {
        case .authored: "Authored by me"
        case .reviewRequested: "Needs my review"
        case .teamReview: "Needs my team's review"
        case .openedByAgents: "Opened by agents"
        case .assigned: "Assigned to me"
        case .mentioned: "Mentioned"
        case .fromAutomations: "From automations"
        case .closed: kind == .pullRequest ? "Closed pull requests" : "Closed issues"
        case .results: "Results"
        }
    }

    /// "Needs my team's review · ledger" once its rows name the team.
    /// A browse's header: "Open pull requests", "Merged pull requests", "All issues".
    public static func browseTitle(_ state: ForgeFilter.State, kind: ForgeKind) -> String {
        let noun = kind == .pullRequest ? "pull requests" : "issues"
        return switch state {
        case .open: "Open \(noun)"
        case .closed: "Closed \(noun)"
        case .merged: "Merged \(noun)"
        case .all: "All \(noun)"
        }
    }

    public static func title(_ section: ForgeSection, kind: ForgeKind) -> String {
        let base = title(section.id, kind: kind)
        guard section.id == .teamReview, let team = section.pullRequests.lazy.compactMap(\.team).first else { return base }
        return "\(base) · \(team)"
    }

    /// An empty list's words ("Nothing waiting").
    public static func emptyTitle(_ kind: ForgeKind) -> String { "Nothing waiting" }

    public static func emptyDetail(_ kind: ForgeKind, repoName: String) -> String {
        kind == .pullRequest
            ? "No pull requests you wrote, need to review, or that an agent opened in \(repoName)."
            : "No issues assigned to you, mentioning you, or from automations in \(repoName)."
    }

    // MARK: Rows

    /// "baily · 2h"; "mara · Triage Sentry · 30m" for an automation's issue.
    public static func byline(author: String, updatedAt: Date, automation: String? = nil, now: Date = Date()) -> String {
        [author, automation, age(updatedAt, now: now)].compactMap { $0 }.joined(separator: " · ")
    }

    /// "#29 · devon · 5h" (a mobile row).
    public static func numberedByline(number: Int, author: String, updatedAt: Date, now: Date = Date()) -> String {
        "#\(number) · \(author) · \(age(updatedAt, now: now))"
    }

    /// A pinned row's trailing word: "changes", "failing", "review", "draft", "merged", else "#34".
    public static func pinnedTag(_ item: ForgePinnedItem, viewer: String?) -> (label: String, tone: ForgeTone?) {
        if let pull = item.pullRequest {
            switch PullRequestRowState(pull) {
            case .changesRequested: return ("changes", .failed)
            case .failing: return ("failing", .failed)
            case .merged: return ("merged", .merged)
            case .draft: return ("draft", .idle)
            default:
                if pull.reviewDecision == .reviewRequired, let viewer, pull.author.caseInsensitiveCompare(viewer) != .orderedSame {
                    return ("review", .attention)
                }
            }
        }
        return ("#\(item.pin.ref.number)", nil)
    }

    // MARK: Times

    /// "now", "5m", "2h", "3d", "Sep 12".
    public static func age(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if seconds < 30 * 86_400 { return "\(Int(seconds / 86_400))d" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return date.formatted(.verbatim("\(month: .abbreviated) \(day: .defaultDigits)", locale: Locale(identifier: "en_US_POSIX"),
                                        timeZone: timeZone, calendar: calendar))
    }

    /// "2h ago", "just now".
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let short = age(date, now: now)
        if short == "now" { return "just now" }
        return short.first?.isNumber == true ? "\(short) ago" : short
    }

    /// "38s", "1m 12s", "1h 4m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s" }
        return "\(total / 3_600)h \(total % 3_600 / 60)m"
    }

    // MARK: Details

    /// "Checks · 3 of 4 passed" (skipped checks don't count).
    public static func checksTitle(_ checks: [ForgeCheck]) -> String {
        let counted = checks.filter { $0.state != .skipped }
        guard !counted.isEmpty else { return "Checks" }
        return "Checks · \(counted.filter { $0.state == .passed }.count) of \(counted.count) passed"
    }

    /// The merge menu's warning, bold part first.
    public static let blockedTitle = "Merging is blocked."

    /// "mara requested changes and test · arm64 is failing." Nil when nothing blocks.
    public static func blockerSentence(_ blockers: [String]) -> String? {
        guard let last = blockers.last else { return nil }
        let joined = blockers.count == 1 ? last : blockers.dropLast().joined(separator: ", ") + " and " + last
        return joined + "."
    }

    public static func title(_ method: ForgeMergeMethod) -> String {
        switch method {
        case .squash: "Squash and merge"
        case .merge: "Create a merge commit"
        case .rebase: "Rebase and merge"
        }
    }

    public static func title(_ verdict: ForgeReviewVerdict) -> String {
        switch verdict {
        case .comment: "Comment"
        case .approve: "Approve"
        case .requestChanges: "Request changes"
        }
    }

    /// The page's primary button; nil when there's nothing left to do.
    public static func primaryAction(_ detail: PullRequestDetail) -> ForgePrimaryAction? {
        switch detail.state {
        case .open: .merge
        case .draft: .markReady
        case .closed: .reopen
        case .merged:
            if detail.summary.thread?.worktreePath != nil { .cleanUp }
            else if !detail.headBranchDeleted && !detail.deletesBranchOnMerge { .deleteBranch }
            else { nil }
        }
    }

    /// The card under a draft, merged or closed pull request's title.
    public static func stateNote(_ detail: PullRequestDetail) -> (title: String, body: String)? {
        switch detail.state {
        case .open: return nil
        case .draft: return ("Draft", "Reviewers aren't asked until you mark it ready. Checks still run.")
        case .merged:
            var body = detail.mergeCommit.map { "Merged as \($0.prefix(7))" } ?? "Merged"
            if !detail.closesIssues.isEmpty { body += " and closed " + detail.closesIssues.map { "#\($0)" }.joined(separator: ", ") }
            body += "."
            switch primaryAction(detail) {
            case .cleanUp?: body += " Clean up deletes the branch and removes the worktree."
            case .deleteBranch?: body += " Delete the branch once you're done with it."
            default: break
            }
            return ("Merged into \(detail.summary.baseRef)", body)
        case .closed:
            let here = detail.summary.thread?.worktreePath != nil ? "The branch and worktree are still here." : "The branch is still here."
            return ("Closed without merging", "\(here) Reopen to keep going.")
        }
    }

    /// One Activity line: who, and what they did ("requested changes · 2 comments on outbox.go").
    /// The viewer reads as "you" where the line names them as the object.
    public static func line(_ event: ForgeEvent, viewer: String? = nil) -> (actor: String, text: String) {
        func who(_ login: String) -> String {
            viewer.map { login.caseInsensitiveCompare($0) == .orderedSame } == true ? "you" : login
        }
        let text: String
        switch event.kind {
        case .opened: text = "opened this"
        case .commented: text = "commented"
        case .reviewed(let state, _, let comments):
            let verdict = switch state {
            case .approved: "approved"
            case .changesRequested: "requested changes"
            case .commented, .pending, .dismissed: "reviewed"
            }
            if comments.isEmpty { text = verdict; break }
            let files = Set(comments.map(\.path))
            let on = files.count == 1 ? " on \((files.first! as NSString).lastPathComponent)" : ""
            text = "\(verdict) · \(comments.count) comment\(comments.count == 1 ? "" : "s")\(on)"
        case .pushed(let commits): text = "pushed \(commits) commit\(commits == 1 ? "" : "s")"
        case .merged: text = "merged this"
        case .closed: text = "closed this"
        case .reopened: text = "reopened this"
        case .convertedToDraft: text = "converted this to a draft"
        case .readyForReview: text = "marked this ready for review"
        case .assigned(let login): text = login.caseInsensitiveCompare(event.actor) == .orderedSame ? "self-assigned this" : "assigned \(who(login))"
        case .referenced(let number, let title, let isPullRequest):
            text = "mentioned this in \(isPullRequest ? "pull request" : "issue") #\(number)\(title.isEmpty ? "" : " " + title)"
        }
        return (event.actor, text)
    }

    // MARK: The side pane's Pull request tab (PRPane, PRPaneMerged)

    /// The footer's line: what stands in the way of an open one ("Changes requested · 1 check
    /// failing"), where a merged one went and what it left here.
    public static func paneStatus(_ detail: PullRequestDetail) -> (text: String, tone: ForgeTone) {
        let base = detail.summary.baseRef
        switch detail.state {
        case .merged:
            guard detail.summary.thread?.worktreePath != nil else { return ("Merged into \(base)", .merged) }
            return ("Merged into \(base) · the worktree for \(detail.summary.headRef) is still on disk", .merged)
        case .closed: return ("Closed without merging", .failed)
        case .open, .draft:
            var parts: [String] = []
            if detail.state == .draft { parts.append("Draft") }
            if detail.reviewers.contains(where: { $0.state == .changesRequested }) { parts.append("Changes requested") }
            let failing = detail.checks.filter { $0.state == .failing }.count
            if failing > 0 { parts.append("\(failing) check\(failing == 1 ? "" : "s") failing") }
            if detail.mergeable == .conflicting { parts.append("Merge conflicts") }
            if detail.summary.reviewDecision == .reviewRequired, !detail.reviewers.contains(where: { $0.state == .changesRequested }) {
                parts.append("Needs an approving review")
            }
            if parts.isEmpty { return ("Ready to merge", .done) }
            return (parts.joined(separator: " · "), .failed)
        }
    }

    /// The rail's checks once all passed (PRPaneMerged): "All 4 passed" and the longest run.
    /// Nil while any is not passed: the rail lists them instead.
    public static func allPassed(_ checks: [ForgeCheck]) -> (text: String, duration: String?)? {
        let counted = checks.filter { $0.state != .skipped }
        guard !counted.isEmpty, counted.allSatisfy({ $0.state == .passed }) else { return nil }
        return ("All \(counted.count) passed", counted.compactMap(\.duration).max().map(duration))
    }

    /// Send feedback to agent: what reviews that requested changes or commented asked, each
    /// review's words as one comment on the pull request and its line comments as they are.
    public static func reviewFeedback(_ detail: PullRequestDetail) -> [ForgeLineComment] {
        detail.events.flatMap { event -> [ForgeLineComment] in
            guard case .reviewed(let state, let body, let comments) = event.kind,
                  state == .changesRequested || state == .commented else { return [] }
            let words = body.isEmpty ? [] : [ForgeLineComment(id: 0, author: event.actor, path: "the pull request", line: nil,
                                                               diffHunk: "", body: body, createdAt: event.at)]
            return words + comments
        }
    }

    /// "src/ledger/outbox.go · line 103".
    public static func location(_ comment: ForgeLineComment) -> String {
        comment.line.map { "\(comment.path) · line \($0)" } ?? comment.path
    }
}
