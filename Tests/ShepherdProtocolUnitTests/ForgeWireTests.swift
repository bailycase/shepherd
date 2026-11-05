import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol

/// One of each forge request and result, as the wire carries them.
enum ForgeSamples {
    static let at = Date(timeIntervalSince1970: 1_700_000_000)
    static let pull = ForgeItemRef(kind: .pullRequest, repo: "acme/payments", number: 31)
    static let issue = ForgeItemRef(kind: .issue, repo: "acme/payments", number: 34)
    static let thread = ForgeThreadLink(agentID: AgentID(rawValue: "a"), title: "Add refund events", running: true,
                                        branch: "agent/refund-events", worktreePath: "/w/refund", automationName: "Triage")
    static let summary = PullRequestSummary(ref: pull, title: "Add \"refund\" events", author: "baily", updatedAt: at, state: .open,
                                            checks: .failing, reviewDecision: .changesRequested, headRef: "agent/refund-events",
                                            baseRef: "main", additions: 200, deletions: 8, team: "ledger", thread: thread)
    static let comment = ForgeLineComment(id: 5, author: "mara", path: "ledger/outbox.go", line: 103, diffHunk: "@@ -1 +1 @@\n+x",
                                          body: "Wrap it?", createdAt: at, inReplyTo: 4)
    static let detail = PullRequestDetail(
        summary: summary, createdAt: at, body: "## Summary\n`code`", changedFiles: 5,
        reviewers: [ForgeReviewer(login: "mara", state: .changesRequested), ForgeReviewer(login: "ledger", isTeam: true, state: .pending)],
        checks: [ForgeCheck(name: "test (arm64)", workflow: "CI", state: .failing, startedAt: at, completedAt: at.addingTimeInterval(178),
                            detailsURL: "https://github.com/acme/payments/actions/runs/9/job/4", runID: 9, jobID: 4)],
        events: [ForgeEvent(id: "opened", actor: "baily", at: at, kind: .opened),
                 ForgeEvent(id: "r", actor: "mara", at: at, kind: .reviewed(state: .changesRequested, body: "b", comments: [comment])),
                 ForgeEvent(id: "p", actor: "agent", at: at, kind: .pushed(commits: 2)),
                 ForgeEvent(id: "x", actor: "baily", at: at, kind: .referenced(number: 2, title: "t", isPullRequest: false))],
        mergeable: .conflicting, behindBase: true, mergeMethods: [.squash, .rebase], defaultMergeMethod: .squash, deletesBranchOnMerge: true,
        autoMerge: true, mergeCommit: "7d41c0a", headBranchDeleted: true, closesIssues: [28], viewer: "baily")
    static let issueSummary = IssueSummary(ref: issue, title: "Partial refunds", author: "mara", updatedAt: at, state: .open,
                                           labels: [ForgeLabel(name: "bug", color: "d73a4a")], assignees: ["baily"], assignedToViewer: true,
                                           linkedPullRequests: [31], thread: thread, automationName: "Triage")
    static let requests: [RemoteForgeRequest] = [
        .repos, .list(kind: .pullRequest, repo: "acme/payments", sections: nil), .list(kind: .issue, repo: "a/b", sections: [.closed]),
        .search(kind: .issue, repo: "a/b", query: "refund \"cent\""), .pullRequest(ref: pull), .pullRequestFiles(ref: pull), .issue(ref: issue),
        .checkLog(repo: "a/b", jobID: 4), .comment(ref: issue, body: "multi\nline"), .review(ref: pull, verdict: .requestChanges, body: "no"),
        .merge(ref: pull, method: .rebase, whenReady: false, deleteBranch: false), .deleteBranch(ref: pull), .setDraft(ref: pull, draft: true),
        .setOpen(ref: issue, open: false), .editTitle(ref: pull, title: "New"), .rerunFailed(repo: "a/b", runID: 9), .sidebar,
        .setPinned(ref: issue, title: "Partial refunds", pinned: true),
        .browse(kind: .pullRequest, repo: ForgeList.allRepos, filter: ForgeFilter(state: .merged, author: "mara", label: "bug fix", text: "x"),
                after: "Y3Vy"),
        .people(repo: "a/b"), .createIssue(repo: "a/b", title: "T", body: "b"),
        .edit(ref: pull, field: .reviewers, add: ["mara"], remove: []),
        .postReview(ref: pull, verdict: .comment, body: "", comments: [ForgeDraftComment(path: "x.go", line: 3, right: false, body: "why")]),
    ]
    static let results: [RemoteForgeResult] = [
        .ok, .repos([ForgeRepo(nameWithOwner: "acme/payments", path: "/r/payments")]),
        .list(ForgeList(kind: .pullRequest, repo: "acme/payments", viewer: "baily",
                        sections: [ForgeSection(id: .authored, pullRequests: [summary]), ForgeSection(id: .teamReview)])),
        .list(ForgeList(kind: .issue, repo: "acme/payments", sections: [ForgeSection(id: .assigned, issues: [issueSummary])])),
        .pullRequest(detail),
        .files(PullRequestFiles(ref: pull, files: [ChangesFileDiff(file: DiffFile.parse("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")[0])],
                                omitted: 2)),
        .issue(IssueDetail(summary: issueSummary, createdAt: at, body: "b",
                           events: [ForgeEvent(id: "a", actor: "mara", at: at, kind: .assigned(login: "baily"))],
                           linkedPullRequests: [.init(number: 31, title: nil, url: "u")], viewer: nil)),
        .checkLog("--- FAIL"),
        .people(ForgeRepoPeople(labels: [ForgeLabel(name: "bug", color: "d73a4a")], assignable: ["mara"])), .created(issue),
        .list(ForgeList(kind: .issue, repo: "", sections: [ForgeSection(id: .results)], next: "Y3Vy")),
        .sidebar(ForgeSidebar(pins: [ForgePinnedItem(pin: ForgePin(ref: pull, title: "t", pinnedAt: at), pullRequest: summary)], needsYou: 3)),
    ]
}

@Suite("Forge wire")
struct ForgeWireTests {
    @Test(arguments: ForgeSamples.requests)
    func everyRequestRoundTrips(_ request: RemoteForgeRequest) throws {
        let message = RemoteRequest.forge(id: 1, request: request)
        #expect(try Wire.roundTrip(message) == message)
    }

    @Test(arguments: ForgeSamples.results)
    func everyResultRoundTrips(_ result: RemoteForgeResult) throws {
        #expect(try Wire.roundTrip(RemoteReply.forgeResult(id: 1, result: result)) == .forgeResult(id: 1, result: result))
    }

    /// What each filter asks GitHub's search; across every repository it stays to what involves you
    /// unless a person is picked.
    @Test func aFilterReadsAsGitHubSearch() {
        #expect(ForgeFilter().query(kind: .pullRequest, repo: ForgeList.allRepos)
            == "is:pr is:open involves:@me archived:false sort:updated-desc")
        #expect(ForgeFilter(author: "mara").query(kind: .pullRequest, repo: ForgeList.allRepos)
            == "is:pr is:open author:mara archived:false sort:updated-desc")
        #expect(ForgeFilter(state: .closed, label: "good first issue", sort: .created).query(kind: .issue, repo: "acme/payments")
            == "is:issue is:closed repo:acme/payments label:\"good first issue\" archived:false sort:created-desc")
        #expect(ForgeFilter(state: .merged, mine: true, assignee: "@me", text: "refund").query(kind: .pullRequest, repo: "acme/payments")
            == "is:pr is:merged repo:acme/payments involves:@me assignee:@me archived:false sort:updated-desc refund")
        #expect(ForgeFilter(state: .all, label: "a\" b").query(kind: .issue, repo: "a/b") == "is:issue repo:a/b label:\"a b\" archived:false sort:updated-desc")
    }

    /// A list or pull request from a host before browsing decodes without its new fields.
    @Test func olderListsAndPagesStillDecode() throws {
        let list = try JSONDecoder().decode(ForgeList.self, from: Data(#"{"kind":"issue","repo":"a/b","sections":[]}"#.utf8))
        #expect(list.next == nil)
    }

    @Test func theHostOffersIssuesAndPRs() {
        #expect(RemoteProtocol.capabilities.contains(RemoteProtocol.forgeCapability) && RemoteProtocol.forgeCapability == "issuesAndPRs.v1")
    }

    /// A pin saved before a field existed still loads.
    @Test func anOlderPinDecodesWithDefaults() throws {
        let pin = try JSONDecoder().decode(ForgePin.self, from: Data(#"{"ref":{"kind":"issue","repo":"a/b","number":3}}"#.utf8))
        #expect(pin.title == "" && pin.pinnedAt == Date(timeIntervalSince1970: 0))
    }
}
