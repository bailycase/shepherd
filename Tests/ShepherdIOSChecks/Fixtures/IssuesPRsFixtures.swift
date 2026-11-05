import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Issues & PRs' screens (MobileIPList, MobileIssueList, MobilePRDetail, -Changes, -Checks, -Review,
// -Merge, MobileIssue, MobilePRStates; iPadIPReview, iPadIssue, iPadPRChanges, iPadPRStates;
// DuoBookPR, DuoBookPRMerge, DuoBookIssue, DuoClosedIPList, DuoClosedPR). Studio serves
// acme/payments, the fictional repository of Tests/ShepherdTestKit/ForgeFixtures.swift, through
// the same models the host derives from gh. Run the Duo ones posed (`run-simulator.sh -f book`).
extension FixtureCatalog {
    static var forge: [FixtureScreen] {
        let pr = IssuesPRsFixture.key(.pullRequest, 31)
        let issue = IssuesPRsFixture.key(.issue, 34)
        let list: (ForgeKind) -> @MainActor (MobileApp) async -> Void = { kind in
            { app in await IssuesPRsFixture.showList(app, kind: kind) }
        }
        let open: (ForgeItemKey, ForgeTab, ForgeSheet.Kind?) -> @MainActor (MobileApp) async -> Void = { key, tab, sheet in
            { app in await IssuesPRsFixture.open(app, key, tab: tab, sheet: sheet) }
        }
        return [
            FixtureScreen(name: "forge-pulls", hosts: IssuesPRsFixture.hosts(), routes: [.forge(.list)], prepare: list(.pullRequest)),
            FixtureScreen(name: "forge-issues", hosts: IssuesPRsFixture.hosts(), routes: [.forge(.list)], prepare: list(.issue)),
            FixtureScreen(name: "forge-team", hosts: IssuesPRsFixture.hosts(), routes: [.forge(.list)], prepare: { app in
                await IssuesPRsFixture.showList(app, kind: .pullRequest)
                await ForgeStore.of(app.hosts).expand(.teamReview)
            }),
            // Everything in every repository, filtered to one author, with more to load.
            FixtureScreen(name: "forge-filtered", hosts: IssuesPRsFixture.hosts(), routes: [.forge(.list)], prepare: { app in
                let store = ForgeStore.of(app.hosts)
                await IssuesPRsFixture.showList(app, kind: .pullRequest)
                store.filter.author = "baily"
                await FixtureCheck.wait("the browse", seconds: 15) { store.results?.value != nil }
            }),
            FixtureScreen(name: "forge-empty", hosts: IssuesPRsFixture.hosts(.open, empty: true), routes: [.forge(.list)], prepare: list(.pullRequest)),
            FixtureScreen(name: "forge-older", hosts: IssuesPRsFixture.olderHosts(), routes: [.forge(.list)], prepare: { app in
                let store = ForgeStore.of(app.hosts)
                await FixtureCheck.wait("the older host's state", seconds: 10) { !store.olderHosts.isEmpty }
            }),
            FixtureScreen(name: "forge-pr", hosts: IssuesPRsFixture.hosts(), routes: [.forge(.list)], prepare: open(pr, .summary, nil)),
            FixtureScreen(name: "forge-pr-changes", hosts: IssuesPRsFixture.hosts(), routes: [.forge(.list)], prepare: open(pr, .changes, nil)),
            FixtureScreen(name: "forge-pr-checks", hosts: IssuesPRsFixture.hosts(), routes: [.forge(.list)], prepare: open(pr, .checks, nil)),
            FixtureScreen(name: "forge-pr-review", hosts: IssuesPRsFixture.hosts(), routes: [.forge(.list)], prepare: open(pr, .summary, .review)),
            FixtureScreen(name: "forge-pr-merge", hosts: IssuesPRsFixture.hosts(), routes: [.forge(.list)], prepare: open(pr, .summary, .merge)),
            FixtureScreen(name: "forge-pr-draft", hosts: IssuesPRsFixture.hosts(.draft), routes: [.forge(.list)], prepare: open(pr, .summary, nil)),
            FixtureScreen(name: "forge-pr-merged", hosts: IssuesPRsFixture.hosts(.merged), routes: [.forge(.list)], prepare: open(pr, .summary, nil)),
            FixtureScreen(name: "forge-pr-closed", hosts: IssuesPRsFixture.hosts(.closed), routes: [.forge(.list)], prepare: open(pr, .summary, nil)),
            FixtureScreen(name: "forge-pr-loading", hosts: IssuesPRsFixture.hosts(.open, holds: true), routes: [.forge(.list)], prepare: { app in
                await IssuesPRsFixture.showList(app, kind: .pullRequest)
                ForgeHooks.open(pr, store: ForgeStore.of(app.hosts), navigator: app.navigator)
            }),
            // iPad: a pull request beside its diff (iPadPRChanges); iPhone pushes the file.
            FixtureScreen(name: "forge-pr-diff", hosts: IssuesPRsFixture.hosts(), routes: [.forge(.list)], prepare: { app in
                await IssuesPRsFixture.open(app, pr, tab: .changes, sheet: nil)
                let store = ForgeStore.of(app.hosts)
                await FixtureCheck.wait("the diff", seconds: 10) { store.files[pr]?.value != nil }
                if app.navigator.layout == .pad {
                    store.padFile = "ledger/outbox.go"
                } else {
                    app.navigator.open(.forge(.file(host: pr.host, ref: pr.ref, path: "ledger/outbox.go")))
                }
            }),
            // Two line comments waiting to be posted, under the pull request's diff.
            FixtureScreen(name: "forge-pr-line-comments", hosts: IssuesPRsFixture.hosts(), routes: [.forge(.list)], prepare: { app in
                await IssuesPRsFixture.open(app, pr, tab: .changes, sheet: nil)
                let store = ForgeStore.of(app.hosts)
                await FixtureCheck.wait("the diff", seconds: 10) { store.files[pr]?.value != nil }
                let path = "ledger/outbox.go"
                if app.navigator.layout == .pad { store.padFile = path } else { app.navigator.open(.forge(.file(host: pr.host, ref: pr.ref, path: path))) }
                let lines = store.files[pr]?.value?.file(path)?.file.hunks.flatMap(\.lines).filter { $0.kind == .added } ?? []
                if let first = lines.first, let number = first.newLine {
                    store.selectLine(pr, path: path, lineKey: first.id, line: number, right: true)
                    store.lineDraft = "Wrap this with the event ID too."
                    store.saveLineDraft()
                }
                if lines.count > 2, let number = lines[2].newLine {
                    store.selectLine(pr, path: path, lineKey: lines[2].id, line: number, right: true)
                    store.lineDraft = "Does this need a retry?"
                    store.saveLineDraft()
                }
            }),
            FixtureScreen(name: "forge-issue", hosts: IssuesPRsFixture.hosts(), routes: [.forge(.list)], prepare: open(issue, .summary, nil)),
            // Home's Issues & PRs row (iPhone) and the iPad sidebar's row with its pins.
            FixtureScreen(name: "forge-home", hosts: IssuesPRsFixture.hosts(), prepare: { app in
                let store = ForgeStore.of(app.hosts)
                await FixtureCheck.wait("the pins", seconds: 10) { !store.pins.isEmpty }
            }),
        ]
    }
}

@MainActor
enum IssuesPRsFixture {
    nonisolated static let repo = "acme/payments"
    nonisolated static let root = "/Users/dev/payments"
    static let payments = Space(id: SpaceID(rawValue: "space-payments"), name: "payments", path: root)
    nonisolated static let refunds = AgentID(rawValue: "agent-refund-events")

    static func key(_ kind: ForgeKind, _ number: Int) -> ForgeItemKey {
        ForgeItemKey(host: FixtureData.studio, ref: ForgeItemRef(kind: kind, repo: repo, number: number))
    }

    static func showList(_ app: MobileApp, kind: ForgeKind) async {
        let store = ForgeStore.of(app.hosts)
        store.kind = kind
        await FixtureCheck.wait("the lists", seconds: 15) { store.list(kind)?.value != nil }
    }

    static func open(_ app: MobileApp, _ key: ForgeItemKey, tab: ForgeTab, sheet: ForgeSheet.Kind?) async {
        await showList(app, kind: key.ref.kind)
        let store = ForgeStore.of(app.hosts)
        store.tabs[key] = tab
        ForgeHooks.open(key, store: store, navigator: app.navigator)
        await FixtureCheck.wait("the page", seconds: 15) {
            key.ref.kind == .pullRequest ? store.pullRequests[key]?.value != nil : store.issues[key]?.value != nil
        }
        if let sheet {
            try? await Task.sleep(for: .milliseconds(400))
            store.sheet = ForgeSheet(key: key, kind: sheet)
        }
    }

    /// Studio serves acme/payments; build-01 and the laptop are as everywhere else.
    static func hosts(_ state: PullRequestState = .open, empty: Bool = false, holds: Bool = false) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        hosts[0].state.spaces.append(payments)
        hosts[0].state.agents.append(FixtureData.agent(refunds, "Add refund events", .working, space: payments, worktree: "agent/refund-events", changed: 5))
        hosts[0].forgeHoldsPages = holds
        hosts[0].forge = { request in answer(request, state: state, empty: empty) }
        return hosts
    }

    /// Studio from before Issues & PRs.
    static func olderHosts() -> [FixtureHostData] {
        Array(FixtureData.hosts().prefix(1))
    }

    // MARK: Answers

    nonisolated static func answer(_ request: RemoteForgeRequest, state: PullRequestState, empty: Bool) -> RemoteForgeResult? {
        switch request {
        case .repos: return .repos([ForgeRepo(nameWithOwner: repo, path: root)])
        case .list(let kind, _, let sections):
            let ids = sections ?? ForgeSectionID.defaults(for: kind)
            return .list(ForgeList(kind: kind, repo: repo, viewer: "baily",
                                   sections: ForgeSectionID.all(for: kind).filter(ids.contains).map { empty ? ForgeSection(id: $0) : section($0) }))
        case .search(let kind, _, let query):
            let rows = ForgeSectionID.all(for: kind).map(section)
            let pulls = rows.flatMap(\.pullRequests).filter { $0.title.localizedCaseInsensitiveContains(query) }
            let issues = rows.flatMap(\.issues).filter { $0.title.localizedCaseInsensitiveContains(query) }
            return .list(ForgeList(kind: kind, repo: repo, viewer: "baily", sections: [ForgeSection(id: .results, pullRequests: pulls, issues: issues)]))
        case .browse(let kind, let scope, let filter, let after):
            let rows = ForgeSectionID.all(for: kind).map(section)
            var seen = Set<String>()
            let pulls = rows.flatMap(\.pullRequests).filter { pull in
                seen.insert(pull.id).inserted && (filter.author.map { $0 == "@me" ? pull.author == "baily" : pull.author == $0 } ?? true)
                    && (filter.text.isEmpty || pull.title.localizedCaseInsensitiveContains(filter.text))
            }
            let issues = rows.flatMap(\.issues).filter { issue in
                seen.insert(issue.id).inserted && (filter.label.map { label in issue.labels.contains { $0.name == label } } ?? true)
                    && (filter.text.isEmpty || issue.title.localizedCaseInsensitiveContains(filter.text))
            }
            return .list(ForgeList(kind: kind, repo: scope, viewer: "baily",
                                   sections: [ForgeSection(id: .results, pullRequests: pulls, issues: issues)], next: after == nil ? "page-2" : nil))
        case .people: return .people(ForgeRepoPeople(labels: [ForgeLabel(name: "bug", color: "d73a4a")], assignable: ["baily", "devon", "mara"]))
        case .pullRequest(let ref) where ref.number == 31: return .pullRequest(pull31(state))
        case .pullRequestFiles(let ref) where ref.number == 31:
            return .files(PullRequestFiles(ref: ref, files: DiffFile.parse(diff31).map { ChangesFileDiff(file: $0) }))
        case .issue(let ref) where ref.number == 34: return .issue(issue34)
        case .checkLog: return .checkLog("--- FAIL: TestRefundSettled/partial\nrefund_test.go:58: amount = 4999, want 5000")
        case .sidebar: return .sidebar(sidebar(state))
        default: return nil
        }
    }

    nonisolated static func ago(_ minutes: Double) -> Date { Date().addingTimeInterval(-minutes * 60) }
    nonisolated static func ref(_ kind: ForgeKind, _ number: Int) -> ForgeItemRef { ForgeItemRef(kind: kind, repo: repo, number: number) }

    nonisolated static var refundThread: ForgeThreadLink {
        ForgeThreadLink(agentID: refunds, title: "Add refund events", running: true, branch: "agent/refund-events",
                        worktreePath: root + "/.worktrees/refund-events")
    }

    nonisolated static func summary31(_ state: PullRequestState) -> PullRequestSummary {
        PullRequestSummary(ref: ref(.pullRequest, 31), title: "Add refund events to the ledger outbox", author: "baily", updatedAt: ago(120),
                           state: state, checks: .failing, reviewDecision: .changesRequested, headRef: "agent/refund-events", baseRef: "main",
                           additions: 200, deletions: 8, thread: refundThread)
    }

    nonisolated static func section(_ id: ForgeSectionID) -> ForgeSection {
        func pull(_ number: Int, _ title: String, _ author: String, _ minutes: Double, state: PullRequestState = .open,
                  checks: ForgeChecksState = .passed, decision: ForgeReviewDecision? = .reviewRequired, team: String? = nil,
                  thread: ForgeThreadLink? = nil) -> PullRequestSummary {
            PullRequestSummary(ref: ref(.pullRequest, number), title: title, author: author, updatedAt: ago(minutes), state: state,
                               checks: checks, reviewDecision: decision, headRef: "branch-\(number)", baseRef: "main", team: team, thread: thread)
        }
        func issue(_ number: Int, _ title: String, _ author: String, _ minutes: Double, labels: [ForgeLabel] = [], mine: Bool = false,
                   linked: [Int] = [], thread: ForgeThreadLink? = nil, automation: String? = nil) -> IssueSummary {
            IssueSummary(ref: ref(.issue, number), title: title, author: author, updatedAt: ago(minutes), state: .open, labels: labels,
                         assignees: mine ? ["baily"] : [], assignedToViewer: mine, linkedPullRequests: linked, thread: thread, automationName: automation)
        }
        switch id {
        case .authored:
            return ForgeSection(id: id, pullRequests: [
                summary31(.open),
                pull(30, "Split payout reports by currency", "baily", 1_440, decision: .approved),
            ])
        case .reviewRequested:
            return ForgeSection(id: id, pullRequests: [
                pull(29, "Retry failed webhooks with jittered backoff", "devon", 300),
                pull(27, "Move currency rounding into the money package", "mara", 1_440, checks: .running),
            ])
        case .openedByAgents:
            return ForgeSection(id: id, pullRequests: [
                pull(26, "Fix pay button jump on slow networks", "baily", 20, state: .draft, checks: .none, decision: nil,
                     thread: ForgeThreadLink(agentID: FixtureData.buffer, title: "Fix pay button", running: false, branch: "agent/pay-button")),
            ])
        case .teamReview:
            return ForgeSection(id: id, pullRequests: [
                pull(24, "Batch settlement writes per merchant", "mara", 240, checks: .running, team: "ledger"),
                pull(23, "Add idempotency keys to payout API", "devon", 1_440, team: "ledger"),
                pull(22, "Fix flaky ledger reconcile test", "build-01", 2_880, checks: .failing, team: "ledger"),
            ])
        case .assigned:
            return ForgeSection(id: id, issues: [
                issue(34, "Partial refunds round down by a cent", "mara", 60,
                      labels: [ForgeLabel(name: "bug", color: "d73a4a"), ForgeLabel(name: "ledger", color: "ededed")], mine: true),
                issue(33, "Refund events skip the outbox", "baily", 4_320, mine: true, linked: [31]),
            ])
        case .mentioned:
            return ForgeSection(id: id, issues: [issue(32, "Payout CSV has no currency column", "devon", 2_880)])
        case .fromAutomations:
            return ForgeSection(id: id, issues: [
                issue(40, "Sentry: nil pointer in webhook retry worker", "sentry-bot", 30, mine: true, automation: "Triage Sentry"),
                issue(41, "Sentry: timeout calling the FX rates API", "sentry-bot", 360,
                      thread: ForgeThreadLink(agentID: FixtureData.preview, title: "Sentry: FX rates timeout", running: true), automation: "Triage Sentry"),
            ])
        case .closed, .results:
            return ForgeSection(id: id)
        }
    }

    nonisolated static func pull31(_ state: PullRequestState) -> PullRequestDetail {
        let checks = [
            ForgeCheck(name: "build", workflow: "CI", state: .passed, startedAt: ago(30), completedAt: ago(30).addingTimeInterval(72), runID: 900, jobID: 1),
            ForgeCheck(name: "lint", workflow: "CI", state: .passed, startedAt: ago(30), completedAt: ago(30).addingTimeInterval(38), runID: 900, jobID: 2),
            ForgeCheck(name: "test (amd64)", workflow: "CI", state: .passed, startedAt: ago(30), completedAt: ago(30).addingTimeInterval(160), runID: 900, jobID: 3),
            ForgeCheck(name: "test (arm64)", workflow: "CI", state: .failing, startedAt: ago(30), completedAt: ago(30).addingTimeInterval(178), runID: 900, jobID: 4),
        ]
        let comment = ForgeLineComment(id: 501, author: "mara", path: "ledger/outbox.go", line: 103, diffHunk: "@@ -90,6 +90,14 @@\n+\treturn wrap(err)",
                                       body: "Can we wrap with the event ID too? Kind alone won't tell us which refund failed.", createdAt: ago(40))
        var events = [
            ForgeEvent(id: "opened", actor: "baily", at: ago(180), kind: .opened),
            ForgeEvent(id: "push", actor: "agent", at: ago(12), kind: .pushed(commits: 1)),
            ForgeEvent(id: "review", actor: "mara", at: ago(40), kind: .reviewed(state: .changesRequested, body: "", comments: [comment])),
        ]
        switch state {
        case .merged: events.append(ForgeEvent(id: "merged", actor: "baily", at: ago(5), kind: .merged))
        case .closed: events.append(ForgeEvent(id: "closed", actor: "baily", at: ago(5), kind: .closed))
        default: break
        }
        return PullRequestDetail(
            summary: summary31(state), createdAt: ago(180),
            body: """
            Refund events went out as raw JSON. They now go through the outbox codec like every other ledger event.

            - Emit `refund.created` and `refund.settled` through the codec.
            - Add migration `0042_refund_events`.
            - Wrap encode errors with the event ID.
            """,
            changedFiles: 5,
            reviewers: [ForgeReviewer(login: "mara", state: .changesRequested), ForgeReviewer(login: "devon", state: .pending)],
            checks: checks, events: events, mergeable: .mergeable, mergeMethods: [.squash, .merge, .rebase], defaultMergeMethod: .squash,
            mergeCommit: state == .merged ? "7d41c0a9e2" : nil, closesIssues: state == .merged ? [28] : [], viewer: "baily")
    }

    nonisolated static var issue34: IssueDetail {
        let summary = section(.assigned).issues[0]
        return IssueDetail(summary: summary, createdAt: ago(60), body: """
            Refunding 50.00 of a 99.99 charge settles 49.99. The split uses float math before `money.Round`.

            Seen on three refunds since Tuesday. The arm64 test in #31 fails on the same case.
            """,
            events: [
                ForgeEvent(id: "opened", actor: "mara", at: ago(60), kind: .opened),
                ForgeEvent(id: "assigned", actor: "mara", at: ago(60), kind: .assigned(login: "baily")),
                ForgeEvent(id: "c1", actor: "devon", at: ago(45), kind: .commented(body: "Payouts have the same split. Worth fixing both in one place.")),
            ],
            linkedPullRequests: [], viewer: "baily")
    }

    nonisolated static func sidebar(_ state: PullRequestState) -> ForgeSidebar {
        let webhooks = section(.reviewRequested).pullRequests[0]
        let refunds = section(.assigned).issues[0]
        return ForgeSidebar(pins: [
            ForgePinnedItem(pin: ForgePin(ref: ref(.pullRequest, 31), title: "Add refund events", pinnedAt: ago(10)), pullRequest: summary31(state)),
            ForgePinnedItem(pin: ForgePin(ref: webhooks.ref, title: "Retry failed webhooks", pinnedAt: ago(20)), pullRequest: webhooks),
            ForgePinnedItem(pin: ForgePin(ref: refunds.ref, title: "Partial refunds round down", pinnedAt: ago(30)), issue: refunds),
        ], needsYou: 3)
    }

    nonisolated static let diff31 = """
    diff --git a/ledger/outbox.go b/ledger/outbox.go
    index 1111111..2222222 100644
    --- a/ledger/outbox.go
    +++ b/ledger/outbox.go
    @@ -96,9 +96,17 @@ func (o *Outbox) Publish(ctx context.Context, event Event) error {
     \tpayload, err := o.codec.Encode(event)
     \tif err != nil {
    -\t\treturn err
    +\t\treturn fmt.Errorf("encode %s: %w", event.Kind, err)
     \t}
    -\treturn o.store.Append(ctx, payload)
    +\tif err := o.store.Append(ctx, payload); err != nil {
    +\t\treturn fmt.Errorf("append %s: %w", event.Kind, err)
    +\t}
    +\treturn nil
     }
    diff --git a/ledger/refund.go b/ledger/refund.go
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/ledger/refund.go
    @@ -0,0 +1,4 @@
    +package ledger
    +
    +// RefundCreated is published when a refund is first recorded.
    +type RefundCreated struct{ ID, ChargeID string; Amount int64 }
    diff --git a/ledger/refund_test.go b/ledger/refund_test.go
    new file mode 100644
    index 0000000..4444444
    --- /dev/null
    +++ b/ledger/refund_test.go
    @@ -0,0 +1,3 @@
    +package ledger
    +
    +func TestRefundSettled(t *testing.T) {}
    diff --git a/ledger/migrations/0042_refund_events.sql b/ledger/migrations/0042_refund_events.sql
    new file mode 100644
    index 0000000..5555555
    --- /dev/null
    +++ b/ledger/migrations/0042_refund_events.sql
    @@ -0,0 +1,2 @@
    +CREATE TABLE refund_events (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
    +CREATE INDEX refund_events_created ON refund_events (id);
    diff --git a/go.mod b/go.mod
    index 6666666..7777777 100644
    --- a/go.mod
    +++ b/go.mod
    @@ -3,3 +3,4 @@ module acme/payments
     go 1.23
     require (
     \tgithub.com/google/uuid v1.6.0
    +\tgithub.com/shopspring/decimal v1.4.0
    """
}
