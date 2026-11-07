import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestKit
@testable import ShepherdSessions

/// Issues & PRs on recorded gh JSON (`ForgeFixtures`): what the parser reads, how lists fall into
/// sections and link to threads, how gh's failures read, and that untrusted text only ever
/// reaches gh as an argument value or stdin. No process runs.
@Suite("Forge service")
struct ForgeServiceTests {
    static let repo = ForgeFixtures.repo
    static let pr31 = ForgeItemRef(kind: .pullRequest, repo: repo, number: 31)
    static let agent = AgentID(rawValue: "refund")

    /// A service on the fake gh, recording every command it ran.
    static func service(_ seen: Locked<[ForgeCommand]> = Locked([]), now: @escaping @Sendable () -> Date = { Date() },
                        answer: @escaping @Sendable ([String]) -> (output: String, status: Int32, errors: String) = ForgeFixtures.answer)
        throws -> ForgeService {
        let pins = try makeScratchDirectory("forge").appendingPathComponent("forge-pins.json")
        return ForgeService(pinsURL: pins, runner: { command in
            seen.withValue { $0.append(command) }
            let (output, status, errors) = answer(command.arguments)
            return ForgeOutput(output: Data(output.utf8), errors: errors, status: status)
        }, now: now)
    }

    static let context = ForgeContext(
        agents: [
            .init(id: agent, title: "Add refund events", running: true, branch: "agent/refund-events",
                  worktreePath: ForgeFixtures.root + "-refund", directory: ForgeFixtures.root + "-refund"),
            .init(id: AgentID(rawValue: "pay"), title: "Fix pay button", running: false, branch: "agent/pay-button", worktreePath: nil,
                  directory: ForgeFixtures.root),
            .init(id: AgentID(rawValue: "issue"), title: "Fix partial refund rounding", running: true,
                  branch: ForgeLinks.issueBranch(number: 34, title: "Partial refunds round down by a cent"), worktreePath: nil,
                  directory: ForgeFixtures.root),
            .init(id: AgentID(rawValue: "triage"), title: "Triage", running: false, branch: nil, worktreePath: nil, directory: "/tmp",
                  automationName: "Triage Sentry", automationItem: "acme/payments#41"),
        ],
        directories: [ForgeFixtures.root, ForgeFixtures.root + "/sub"],
        watches: [.init(automationName: "Sentry labels", directory: "/tmp", repo: "acme/payments", labels: ["Sentry"])])

    static func value(_ result: Result<RemoteForgeResult, ForgeError>) throws -> RemoteForgeResult {
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    // MARK: Parsing

    @Test func aPullRequestsDetailReadsEveryField() throws {
        let detail = try ForgeParse.pullRequestDetail(
            view: Data(ForgeFixtures.pullView31.utf8), timeline: Data(ForgeFixtures.timeline31.utf8),
            lineComments: Data(ForgeFixtures.comments31.utf8), repoSettings: Data(ForgeFixtures.repoSettings.utf8),
            repo: Self.repo, viewer: "baily")
        #expect(detail.state == .open && detail.summary.title == "Add refund events to the ledger outbox")
        #expect(detail.summary.headRef == "agent/refund-events" && detail.summary.baseRef == "main")
        #expect(detail.summary.checks == .failing && detail.summary.reviewDecision == .changesRequested)
        #expect(detail.changedFiles == 5 && detail.summary.additions == 200 && detail.closesIssues == [28])
        #expect(detail.reviewers == [ForgeReviewer(login: "mara", state: .changesRequested), ForgeReviewer(login: "devon", state: .pending)])
        #expect(detail.checks.map(\.displayName) == ["build", "lint", "test · amd64", "test · arm64"])
        let arm = try #require(detail.checks.last)
        #expect(arm.state == .failing && arm.runID == 900 && arm.jobID == 4 && arm.duration == 178)
        #expect(detail.mergeMethods == [.squash, .merge] && detail.defaultMergeMethod == .squash && !detail.autoMerge)
        #expect(detail.blockers == ["mara requested changes", "test · arm64 is failing"])

        let kinds = detail.events.map(\.kind)
        #expect(kinds.count == 7)
        #expect(kinds[0] == .opened && kinds[1] == .pushed(commits: 2) && kinds[6] == .pushed(commits: 1))
        #expect(kinds[3] == .commented(body: "Looks close.") && kinds[4] == .convertedToDraft && kinds[5] == .readyForReview)
        guard case .reviewed(.changesRequested, "Wrap the errors.", let comments) = kinds[2] else { Issue.record("no review"); return }
        #expect(comments.map(\.line) == [103, 120] && comments[0].path == "ledger/outbox.go")
        #expect(comments[0].diffHunk.split(separator: "\n").count == ForgeLimits.hunkLines)
    }

    /// The branch card asks for the newest pull request from its branch, in any state.
    @Test func aBranchsPullRequestIsTheNewestWithThatHead() async throws {
        let seen = Locked<[ForgeCommand]>([])
        let service = try Self.service(seen, answer: { arguments in
            let line = arguments.joined(separator: " ")
            if line.hasPrefix("gh pr list") {
                guard line.contains("--head=agent/refund-events --state=all --limit=1") else { return ("[]", 0, "") }
                return (ForgeFixtures.open, 0, "")
            }
            return ForgeFixtures.answer(arguments)
        })
        let pull = try #require(await service.pullRequest(directory: ForgeFixtures.root, branch: "agent/refund-events"))
        #expect(pull.ref == Self.pr31 && pull.state == PullRequestState.open && pull.headRef == "agent/refund-events")
        #expect(await service.pullRequest(directory: ForgeFixtures.root, branch: "agent/none") == nil)
        #expect(seen.withValue { $0 }.contains { $0.arguments.contains("--repo=acme/payments") })
    }

    @Test func aDraftConflictedPullRequestSaysSo() throws {
        var detail = try ForgeParse.pullRequestDetail(view: Data(ForgeFixtures.pullView31.utf8), timeline: nil, lineComments: nil,
                                                      repoSettings: nil, repo: Self.repo, viewer: nil)
        detail.summary.state = .draft
        detail.mergeable = .conflicting
        detail.reviewers = []
        detail.summary.reviewDecision = .reviewRequired
        #expect(detail.blockers == ["It's a draft", "test · arm64 is failing", "It has merge conflicts", "It needs an approving review"])
        detail.summary.state = .merged
        #expect(detail.blockers.isEmpty)
    }

    @Test func anIssuesDetailReadsItsTimelineAndLinks() throws {
        let detail = try ForgeParse.issueDetail(view: Data(ForgeFixtures.issueView34.utf8), timeline: Data(ForgeFixtures.timeline34.utf8),
                                                repo: Self.repo, viewer: "baily")
        #expect(detail.summary.labels == [ForgeLabel(name: "bug", color: "d73a4a")] && detail.summary.assignedToViewer)
        #expect(detail.events.map(\.kind) == [.opened, .assigned(login: "baily"), .commented(body: "Payouts have the same split."),
                                             .referenced(number: 31, title: "Add refund events to the ledger outbox", isPullRequest: true)])
        #expect(detail.linkedPullRequests == [.init(number: 31, title: "Add refund events to the ledger outbox", url: "https://github.com/acme/payments/pull/31")])
        // Without a timeline the comments still show.
        let bare = try ForgeParse.issueDetail(view: Data(ForgeFixtures.issueView34.utf8), timeline: nil, repo: Self.repo, viewer: nil)
        #expect(bare.events.map(\.kind) == [.opened, .commented(body: "Payouts have the same split.")])
    }

    @Test func aFailedLogLosesColumnsTimestampsAndColors() {
        #expect(ForgeParse.logTail(Data(ForgeFixtures.logFailed.utf8))
            == "--- FAIL: TestRefundSettled/partial\nrefund_test.go:58: amount = 4999, want 5000")
    }

    @Test func aDiffFitsItsBudget() throws {
        let ref = Self.pr31
        let files = ForgeParse.files(Data(ForgeFixtures.diff.utf8), ref: ref)
        #expect(files.files.map(\.file.displayPath) == ["ledger/outbox.go", "ledger/refund.go"] && files.omitted == 0)
        let first = try JSONEncoder().encode(files.files[0]).count
        let cut = ForgeParse.files(Data(ForgeFixtures.diff.utf8), ref: ref, budget: first + 10)
        #expect(cut.files.count == 1 && cut.omitted == 1)
    }

    @Test(arguments: [
        ("https://github.com/acme/payments/pull/31/files?w=1", ForgeItemRef(kind: .pullRequest, repo: "acme/payments", number: 31)),
        ("github.com/acme/payments/issues/34#issuecomment-1", ForgeItemRef(kind: .issue, repo: "acme/payments", number: 34)),
    ])
    func aPastedLinkNamesItsItem(_ link: String, _ ref: ForgeItemRef) {
        #expect(ForgeItemRef(link: link) == ref)
    }

    @Test(arguments: ["https://gitlab.com/a/b/pull/1", "https://github.com/acme/payments/pull/x", "https://github.com/-x/y/pull/1", "nope"])
    func anythingElseIsNoLink(_ link: String) {
        #expect(ForgeItemRef(link: link) == nil)
    }

    @Test func anIssueBranchNamesItsIssue() {
        let branch = ForgeLinks.issueBranch(number: 34, title: "Partial refunds round down by a cent!")
        #expect(branch == "agent/issue-34-partial-refunds-round-down-by-a")
        #expect(ForgeLinks.issueNumber(ofBranch: branch) == 34 && ForgeLinks.issueNumber(ofBranch: "agent/other") == nil)
    }

    // MARK: Lists

    @Test func pullRequestsFallIntoSectionsAndLinkToThreads() async throws {
        let list = try Self.value(await Self.service().answer(.list(kind: .pullRequest, repo: Self.repo, sections: nil), context: Self.context))
        guard case .list(let list) = list else { Issue.record("not a list"); return }
        #expect(list.viewer == "baily")
        #expect(list.sections.map(\.id) == [.authored, .reviewRequested, .openedByAgents])
        let authored = try #require(list.section(.authored)).pullRequests
        #expect(authored.map(\.ref.number) == [31, 30])
        #expect(authored[0].thread == ForgeThreadLink(agentID: Self.agent, title: "Add refund events", running: true,
                                                      branch: "agent/refund-events", worktreePath: ForgeFixtures.root + "-refund"))
        #expect(list.section(.reviewRequested)?.pullRequests.map(\.ref.number) == [29])
        // #31 is already under Authored by me; #25's branch is no thread's.
        #expect(list.section(.openedByAgents)?.pullRequests.map(\.ref.number) == [26])
    }

    @Test func teamReviewLeavesOutWhatWasAskedOfYou() async throws {
        let result = try Self.value(await Self.service().answer(.list(kind: .pullRequest, repo: Self.repo, sections: [.teamReview]),
                                                                context: Self.context))
        guard case .list(let list) = result else { Issue.record("not a list"); return }
        #expect(list.sections.map(\.id) == [.teamReview])
        #expect(list.sections[0].pullRequests.map(\.ref.number) == [24] && list.sections[0].pullRequests[0].team == "ledger")
        #expect(list.sections[0].pullRequests[0].checks == .running)
    }

    @Test func everyRepositorySearchesGitHubForWhatInvolvesYou() async throws {
        let seen = Locked<[ForgeCommand]>([])
        let search = """
            {"data":{"search":{"nodes":[
              {"number":31,"title":"Add refund events","state":"OPEN","isDraft":false,"headRefName":"agent/refund-events","baseRefName":"main",
               "updatedAt":"2026-01-02T00:00:00Z","author":{"login":"baily"},"repository":{"nameWithOwner":"acme/payments"},
               "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}},
              {"number":5,"title":"Elsewhere","state":"OPEN","isDraft":true,"updatedAt":"2026-01-01T00:00:00Z","author":{"login":"baily"},
               "repository":{"nameWithOwner":"acme/other"},"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}},
              {}
            ]}}}
            """
        let service = try Self.service(seen, answer: { arguments in
            arguments.starts(with: ["gh", "api", "graphql"]) ? (search, 0, "") : ForgeFixtures.answer(arguments)
        })
        let result = try Self.value(await service.answer(.list(kind: .pullRequest, repo: ForgeList.allRepos, sections: [.authored]),
                                                         context: Self.context))
        guard case .list(let list) = result else { Issue.record("not a list"); return }
        let pulls = try #require(list.section(.authored)).pullRequests
        #expect(pulls.map(\.ref.key) == ["acme/payments#31", "acme/other#5"])
        #expect(pulls[0].checks == .failing && pulls[0].thread?.agentID == Self.agent)
        #expect(pulls[1].state == .draft && pulls[1].checks == .none)
        #expect(seen.current.contains { $0.arguments.last == "q=is:pr is:open author:@me archived:false sort:updated-desc" })
        #expect(!seen.current.contains { $0.arguments.contains("list") }, "no per-repository list for your own sections")
    }

    @Test func issuesFallIntoSectionsWithTheirThreadsAndAutomations() async throws {
        let result = try Self.value(await Self.service().answer(.list(kind: .issue, repo: Self.repo, sections: nil), context: Self.context))
        guard case .list(let list) = result else { Issue.record("not a list"); return }
        let assigned = try #require(list.section(.assigned)).issues
        #expect(assigned.map(\.ref.number) == [34, 33])
        #expect(assigned[0].thread?.agentID == AgentID(rawValue: "issue") && assigned[0].progress == .running)
        #expect(assigned[1].progress == .inPullRequest)
        #expect(list.section(.mentioned)?.issues.map(\.ref.number) == [32])
        let automations = try #require(list.section(.fromAutomations)).issues
        #expect(automations.map(\.ref.number) == [40, 41])
        #expect(automations.map(\.automationName) == ["Sentry labels", "Triage Sentry"])
    }

    @Test func readsAreReusedUntilAChange() async throws {
        let seen = Locked<[ForgeCommand]>([])
        let clock = Locked(Date(timeIntervalSince1970: 1_000))
        let service = try Self.service(seen, now: { clock.current })
        let list = RemoteForgeRequest.list(kind: .pullRequest, repo: Self.repo, sections: [.authored])
        _ = await service.answer(list, context: ForgeContext())
        let first = seen.current.count
        _ = await service.answer(list, context: ForgeContext())
        #expect(seen.current.count == first)
        clock.withValue { $0 += ForgeService.ttl }
        _ = await service.answer(list, context: ForgeContext())
        #expect(seen.current.count == first * 2)
        _ = await service.answer(.comment(ref: Self.pr31, body: "x"), context: ForgeContext())
        _ = await service.answer(list, context: ForgeContext())
        #expect(seen.current.count == first * 3 + 1)
    }

    // MARK: Changes

    /// Bodies go to gh on stdin; titles and searches as one `--flag=value` argument, so text
    /// starting with a dash is never an option.
    @Test func untrustedTextIsNeverAnOption() async throws {
        let seen = Locked<[ForgeCommand]>([])
        let service = try Self.service(seen)
        let body = "--delete-branch; $(rm -rf ~)"
        _ = await service.answer(.comment(ref: Self.pr31, body: body), context: ForgeContext())
        _ = await service.answer(.review(ref: Self.pr31, verdict: .requestChanges, body: body), context: ForgeContext())
        _ = await service.answer(.editTitle(ref: Self.pr31, title: "--undo"), context: ForgeContext())
        _ = await service.answer(.search(kind: .issue, repo: Self.repo, query: "-label:x"), context: ForgeContext())
        let commands = seen.current
        #expect(commands[0].arguments == ["gh", "pr", "comment", "31", "--repo=acme/payments", "--body-file", "-"])
        #expect(commands[0].input == Data(body.utf8))
        #expect(commands[1].arguments == ["gh", "pr", "review", "31", "--repo=acme/payments", "--request-changes", "--body-file", "-"])
        #expect(commands[2].arguments.last == "--title=--undo")
        #expect(commands.contains { $0.arguments.contains("--search=-label:x") })
        #expect(!commands.contains { $0.arguments.contains(body) })
    }

    @Test(arguments: [
        (RemoteForgeRequest.merge(ref: ForgeServiceTests.pr31, method: .squash, whenReady: true, deleteBranch: true),
         ["gh", "pr", "merge", "31", "--repo=acme/payments", "--squash", "--auto", "--delete-branch"]),
        (.merge(ref: ForgeServiceTests.pr31, method: .rebase, whenReady: false, deleteBranch: false), ["gh", "pr", "merge", "31", "--repo=acme/payments", "--rebase"]),
        (.setDraft(ref: ForgeServiceTests.pr31, draft: true), ["gh", "pr", "ready", "31", "--repo=acme/payments", "--undo"]),
        (.setDraft(ref: ForgeServiceTests.pr31, draft: false), ["gh", "pr", "ready", "31", "--repo=acme/payments"]),
        (.setOpen(ref: ForgeItemRef(kind: .issue, repo: ForgeServiceTests.repo, number: 34), open: false), ["gh", "issue", "close", "34", "--repo=acme/payments"]),
        (.setOpen(ref: ForgeServiceTests.pr31, open: true), ["gh", "pr", "reopen", "31", "--repo=acme/payments"]),
        (.rerunFailed(repo: ForgeServiceTests.repo, runID: 900), ["gh", "run", "rerun", "900", "--repo=acme/payments", "--failed"]),
        (.review(ref: ForgeServiceTests.pr31, verdict: .approve, body: ""), ["gh", "pr", "review", "31", "--repo=acme/payments", "--approve"]),
        (.edit(ref: ForgeServiceTests.pr31, field: .reviewers, add: ["mara", "devon"], remove: ["kim"]),
         ["gh", "pr", "edit", "31", "--repo=acme/payments", "--add-reviewer=mara,devon", "--remove-reviewer=kim"]),
        (.edit(ref: ForgeItemRef(kind: .issue, repo: ForgeServiceTests.repo, number: 34), field: .labels, add: [], remove: ["bug"]),
         ["gh", "issue", "edit", "34", "--repo=acme/payments", "--remove-label=bug"]),
    ])
    func eachChangeRunsItsCommand(_ request: RemoteForgeRequest, _ expected: [String]) async throws {
        let seen = Locked<[ForgeCommand]>([])
        #expect(try Self.value(await Self.service(seen).answer(request, context: ForgeContext())) == .ok)
        #expect(seen.current.map(\.arguments) == [expected])
    }

    @Test func anIssueOpensAndAReviewPostsItsLines() async throws {
        let seen = Locked<[ForgeCommand]>([])
        let service = try Self.service(seen, answer: { arguments in
            arguments.starts(with: ["gh", "issue", "create"]) ? ("Creating issue in acme/payments\n\nhttps://github.com/acme/payments/issues/52\n", 0, "")
                : ("", 0, "")
        })
        let created = try Self.value(await service.answer(.createIssue(repo: Self.repo, title: " Refunds round ", body: "--body"), context: ForgeContext()))
        #expect(created == .created(ForgeItemRef(kind: .issue, repo: Self.repo, number: 52)))
        #expect(seen.current[0].arguments == ["gh", "issue", "create", "--repo=acme/payments", "--title=Refunds round", "--body-file", "-"])
        #expect(seen.current[0].input == Data("--body".utf8))

        let comments = [ForgeDraftComment(path: "ledger/outbox.go", line: 103, body: "Wrap it"),
                        ForgeDraftComment(path: "ledger/old.go", line: 7, right: false, body: "Why gone?")]
        _ = try Self.value(await service.answer(.postReview(ref: Self.pr31, verdict: .comment, body: "", comments: comments), context: ForgeContext()))
        #expect(seen.current[1].arguments == ["gh", "api", "--method=POST", "repos/acme/payments/pulls/31/reviews", "--input", "-"])
        let posted = try JSONSerialization.jsonObject(with: seen.current[1].input ?? Data()) as? [String: Any]
        let lines = posted?["comments"] as? [[String: Any]]
        #expect(posted?["event"] as? String == "COMMENT")
        #expect(lines?.map { $0["side"] as? String } == ["RIGHT", "LEFT"] && lines?.first?["line"] as? Int == 103)
    }

    @Test func aBrowseReadsPageByPage() async throws {
        let seen = Locked<[ForgeCommand]>([])
        let page = #"{"data":{"search":{"pageInfo":{"hasNextPage":true,"endCursor":"Y3Vy"},"nodes":[{"number":9,"title":"t","state":"OPEN","#
            + #""author":{"login":"mara"},"repository":{"nameWithOwner":"acme/payments"}}]}}}"#
        let service = try Self.service(seen, answer: { arguments in
            arguments.starts(with: ["gh", "api", "graphql"]) ? (page, 0, "") : ForgeFixtures.answer(arguments)
        })
        let filter = ForgeFilter(author: "mara")
        let first = try Self.value(await service.answer(.browse(kind: .issue, repo: Self.repo, filter: filter, after: nil), context: ForgeContext()))
        guard case .list(let list) = first else { Issue.record("not a list"); return }
        #expect(list.next == "Y3Vy" && list.section(.results)?.issues.map(\.ref.number) == [9])
        _ = await service.answer(.browse(kind: .issue, repo: Self.repo, filter: filter, after: "Y3Vy"), context: ForgeContext())
        let searches = seen.current.filter { $0.arguments.starts(with: ["gh", "api", "graphql"]) }.map(\.arguments)
        #expect(searches.first?.last == "q=" + filter.query(kind: .issue, repo: Self.repo))
        #expect(searches.last?.contains("after=Y3Vy") == true && searches.first?.contains("after=Y3Vy") == false)
    }

    @Test func onlyAMergedBranchIsDeleted() async throws {
        let seen = Locked<[ForgeCommand]>([])
        let open = try await Self.service(seen).answer(.deleteBranch(ref: Self.pr31), context: ForgeContext())
        #expect(open == .failure(ForgeError(.invalid, "Only a merged pull request's branch is deleted here.")))
        let merged = try Self.service(seen, answer: { arguments in
            arguments.joined(separator: " ").contains("isCrossRepository")
                ? (#"{"state":"MERGED","headRefName":"agent/refund#1","isCrossRepository":false}"#, 0, "") : ("", 0, "")
        })
        #expect(try Self.value(await merged.answer(.deleteBranch(ref: Self.pr31), context: ForgeContext())) == .ok)
        #expect(seen.current.last?.arguments == ["gh", "api", "--method=DELETE", "repos/acme/payments/git/refs/heads/agent/refund%231"])
    }

    @Test(arguments: [
        RemoteForgeRequest.list(kind: .issue, repo: "--repo=evil/x", sections: nil),
        .comment(ref: ForgeItemRef(kind: .issue, repo: "acme/payments", number: 1), body: "  "),
        .review(ref: ForgeItemRef(kind: .issue, repo: "acme/payments", number: 1), verdict: .approve, body: ""),
        .editTitle(ref: ForgeServiceTests.pr31, title: "two\nlines"),
        .merge(ref: ForgeItemRef(kind: .issue, repo: "acme/payments", number: 1), method: .merge, whenReady: false, deleteBranch: false),
        .pullRequest(ref: ForgeItemRef(kind: .pullRequest, repo: "acme/payments", number: 0)),
        .edit(ref: ForgeServiceTests.pr31, field: .labels, add: ["a,b"], remove: []),
        .edit(ref: ForgeServiceTests.pr31, field: .assignees, add: ["--repo=evil/x"], remove: []),
        .edit(ref: ForgeItemRef(kind: .issue, repo: "acme/payments", number: 1), field: .reviewers, add: ["mara"], remove: []),
        .createIssue(repo: "acme/payments", title: "  ", body: ""),
        .browse(kind: .issue, repo: "acme/payments", filter: ForgeFilter(state: .merged), after: nil),
        .postReview(ref: ForgeServiceTests.pr31, verdict: .comment, body: "", comments: [ForgeDraftComment(path: "x", line: 0, body: "y")]),
    ])
    func whatGhCouldMisreadNeverRuns(_ request: RemoteForgeRequest) async throws {
        let seen = Locked<[ForgeCommand]>([])
        let result = try await Self.service(seen).answer(request, context: ForgeContext())
        guard case .failure(let error) = result else { Issue.record("ran \(request)"); return }
        #expect(error.code == .invalid && seen.current.isEmpty)
    }

    @Test(arguments: [
        (ForgeOutput(errors: "zsh: command not found: gh", status: 127), ForgeError.Code.ghMissing),
        (ForgeOutput(errors: "To get started with GitHub CLI, please run:  gh auth login", status: 4), .signedOut),
        (ForgeOutput(errors: "GraphQL: Could not resolve to a Repository with the name 'acme/nope'.", status: 1), .notFound),
        (ForgeOutput(errors: "API rate limit exceeded for user", status: 1), .rateLimited),
        (ForgeOutput(errors: "timed out", status: -2), .timedOut),
        (ForgeOutput(errors: "Pull request acme/payments#31 is not mergeable: the base branch policy prohibits the merge.", status: 1), .failed),
    ])
    func ghsFailuresReadAsWords(_ output: ForgeOutput, _ code: ForgeError.Code) {
        guard case .failure(let error) = ForgeService.checked(output) else { Issue.record("succeeded"); return }
        #expect(error.code == code && !error.message.isEmpty)
    }

    // MARK: Sidebar

    @Test func pinsPersistNewestFirstAndTheSidebarReadsThem() async throws {
        let service = try Self.service()
        let issue = ForgeItemRef(kind: .issue, repo: Self.repo, number: 34)
        _ = await service.answer(.setPinned(ref: Self.pr31, title: "Add refund events", pinned: true), context: ForgeContext())
        _ = await service.answer(.setPinned(ref: issue, title: "Partial refunds", pinned: true), context: ForgeContext())
        #expect(service.loadPins().map(\.ref) == [issue, Self.pr31])
        let result = try Self.value(await service.answer(.sidebar, context: Self.context))
        guard case .sidebar(let sidebar) = result else { Issue.record("no sidebar"); return }
        #expect(sidebar.pins.map(\.title) == ["Partial refunds round down by a cent", "Add refund events to the ledger outbox"])
        #expect(sidebar.pins[1].pullRequest?.thread?.agentID == Self.agent)
        // #29 to review, #31 with changes requested, #35 new (#34 has a thread here).
        #expect(sidebar.needsYou == 3)
        _ = await service.answer(.setPinned(ref: Self.pr31, title: "", pinned: false), context: ForgeContext())
        #expect(service.loadPins().map(\.ref) == [issue])
    }

    @Test func anOlderPinsFileStillLoads() throws {
        let url = try makeScratchDirectory("forge").appendingPathComponent("forge-pins.json")
        try Data(#"{"pins":[{"ref":{"kind":"issue","repo":"acme/payments","number":3}}]}"#.utf8).write(to: url)
        let pins = ForgeService(pinsURL: url, runner: { _ in ForgeOutput(status: 127) }).loadPins()
        #expect(pins.map(\.title) == [""] && pins.map(\.ref.number) == [3])
    }
}
