import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// The Changes pane (iPadReview, iPadReviewSplit, iPadCommit; MobileChanges, MobileDiff): a host
// that answers the Changes engine's reads (`changes.v1`: the overview, a scope's list, a file's
// hunks, the base picker's branches, a patch) from fixed diffs. The iPad boards review the
// ledger's refund events; the phone boards (ReviewFixtures) the thread view's labels. Undo and
// Redo are refused as mutations (FixtureHost), so the card's states are staged in the thread.
extension FixtureCatalog {
    static var changes: [FixtureScreen] {
        let ref = FixtureData.ref(FixtureData.preview)
        let thread = MobileRoute.thread(ref)
        let changes = MobileRoute.review(.changes(ref, file: nil))
        return [
            // iPadReview: the thread with its "Edited 5 files" card, the pane beside it.
            FixtureScreen(name: "changes-pad", hosts: ChangesFixture.hosts(), routes: [thread, changes], prepare: ChangesFixture.annotate),
            // iPadReviewSplit: full screen, the file list and the split diff.
            FixtureScreen(name: "changes-pad-full", hosts: ChangesFixture.hosts(), routes: [thread, changes], prepare: { app in
                await ChangesFixture.annotate(app)
                ChangesFixture.store.padLayout = .full
            }),
            // iPadCommit: Commit… open over the full-screen review.
            FixtureScreen(name: "changes-pad-commit", hosts: ChangesFixture.hosts(), routes: [thread, changes], prepare: { app in
                await ChangesFixture.annotate(app)
                ChangesFixture.store.padLayout = .full
                CommitStores.shared.popover = ref
                let commit = CommitStores.shared.store(for: ref, hosts: app.hosts)
                await ReviewFixture.until { commit.stage == .form && commit.drafted && !commit.drafting }
            }),
            // The base picker (ChangesStates › BasePicker) from the compare row.
            FixtureScreen(name: "changes-pad-base", hosts: ChangesFixture.hosts(), routes: [thread, changes], prepare: { app in
                await ChangesFixture.annotate(app)
                ChangesFixture.store.pickingBase = true
                await ReviewFixture.until { ChangesFixture.store.branches != nil }
            }),
            // Last turn: what the agent changed since the last message (ChangesLastTurn).
            FixtureScreen(name: "changes-pad-turn", hosts: ChangesFixture.hosts(), routes: [thread, changes], prepare: { _ in
                let store = ChangesFixture.store
                await ReviewFixture.loaded(store)
                store.pick(.lastTurn)
                await ReviewFixture.until { store.list?.scope == .lastTurn && !store.loading }
                await ChangesFixture.filesLoaded(store)
            }),
            // Every file folded (Collapse all), and the unified diff forced wide.
            FixtureScreen(name: "changes-pad-collapsed", hosts: ChangesFixture.hosts(), routes: [thread, changes], prepare: { _ in
                let store = ChangesFixture.store
                await ReviewFixture.loaded(store)
                store.toggleCollapseAll()
            }),
            // The phone's thread card after Undo, and a host that records no turns (no Undo).
            FixtureScreen(name: "thread-undone", hosts: ChangesFixture.previewThread(FixtureData.thread(turn: FixtureData.previewTurn(state: .undone))),
                          routes: [thread]),
            FixtureScreen(name: "thread-card-legacy", hosts: ChangesFixture.previewThread(FixtureData.thread(turn: nil)), routes: [thread]),
            // The iPad thread's card on its own (iPadThread with the ledger's turn).
            FixtureScreen(name: "changes-card", hosts: ChangesFixture.hosts(), routes: [thread]),
        ]
    }
}

enum ChangesFixture {
    @MainActor static var store: ReviewStore { ReviewStores.shared.store(for: FixtureData.ref(FixtureData.preview)) }

    static let branch = "agent/refund-events"
    static let base = "origin/main"

    /// The boards' change: refund events through the ledger's outbox.
    static let diff = """
    diff --git a/ledger/outbox.go b/ledger/outbox.go
    --- a/ledger/outbox.go
    +++ b/ledger/outbox.go
    @@ -96,9 +96,14 @@ func (o *Outbox) Append(ctx context.Context, tx *sql.Tx, e Event) error {
     func (o *Outbox) Append(ctx context.Context, tx *sql.Tx, e Event) error {
    -\tpayload, err := json.Marshal(e.Payload)
    +\tpayload, err := o.codec.Encode(e.Kind, e.Payload)
     \tif err != nil {
    -\t\treturn err
    +\t\treturn fmt.Errorf("outbox: encode %s: %w", e.Kind, err)
     \t}
     \t_, err = tx.ExecContext(ctx, insertEvent, e.Kind, payload, o.now())
     \treturn err
     }
    +
    +// AppendRefund records refund.created in the same transaction as the refund.
    +func (o *Outbox) AppendRefund(ctx context.Context, tx *sql.Tx, r Refund) error {
    +\treturn o.Append(ctx, tx, Event{Kind: "refund.created", Payload: r})
    +}
    diff --git a/ledger/refund.go b/ledger/refund.go
    new file mode 100644
    --- /dev/null
    +++ b/ledger/refund.go
    @@ -0,0 +1,12 @@
    +package ledger
    +
    +import "time"
    +
    +// Refund is money going back to a customer, in full or in part.
    +type Refund struct {
    +\tID        string
    +\tPaymentID string
    +\tAmount    int64
    +\tPartial   bool
    +\tSettledAt *time.Time
    +}
    diff --git a/ledger/refund_test.go b/ledger/refund_test.go
    new file mode 100644
    --- /dev/null
    +++ b/ledger/refund_test.go
    @@ -0,0 +1,9 @@
    +package ledger
    +
    +import "testing"
    +
    +func TestRefundEvents(t *testing.T) {
    +\tfor _, partial := range []bool{false, true} {
    +\t\tt.Run(name(partial), func(t *testing.T) { appendRefund(t, partial) })
    +\t}
    +}
    diff --git a/migrations/0042_refund_events.sql b/migrations/0042_refund_events.sql
    new file mode 100644
    --- /dev/null
    +++ b/migrations/0042_refund_events.sql
    @@ -0,0 +1,5 @@
    +CREATE TABLE refund_events (
    +  id TEXT PRIMARY KEY,
    +  refund_id TEXT NOT NULL,
    +  kind TEXT NOT NULL
    +);
    diff --git a/go.mod b/go.mod
    --- a/go.mod
    +++ b/go.mod
    @@ -3,3 +3,4 @@ module github.com/acme/payments
     go 1.23
     require (
     \tgithub.com/lib/pq v1.10.9
    +\tgithub.com/acme/payments/events v0.4.0
    """

    static let files = DiffFile.parse(diff)

    static let turn = ChangesTurn(
        id: UUID(uuidString: "7E000000-0000-4000-8000-0000000000A1")!, messageTimestamp: FixtureData.start,
        prompt: "Add refund events to the ledger outbox and cover them with tests.", startedAt: FixtureData.start,
        endedAt: FixtureData.start + 21 * 60_000, state: .ready,
        files: files.map(listed), added: files.reduce(0) { $0 + $1.addedCount }, removed: files.reduce(0) { $0 + $1.removedCount },
        canUndo: true)

    static func listed(_ file: DiffFile) -> ChangesFile {
        ChangesFile(path: file.id, status: file.isNew ? .added : file.isDeleted ? .deleted : .modified,
                    added: file.addedCount, removed: file.removedCount, isBinary: file.isBinary)
    }

    /// The thread the iPad boards show beside the pane.
    static func thread() -> NativeThreadSnapshot {
        FixtureData.snapshot([
            FixtureData.user("c1", "Add refund events to the ledger outbox and cover them with tests."),
            FixtureData.tool("c2", "edit", args: #"{"path":"ledger/outbox.go","oldText":"a","newText":"b"}"#, output: "Edited", at: 60_000),
            FixtureData.assistant("c3", "The outbox emits `refund.created` and `refund.settled` through a codec now, with a migration for the new table. Tests cover full and partial refunds.",
                                  at: 21 * 60_000),
        ], turnChanges: [turn])
    }

    /// Studio serving the refund agent: its thread, the engine's reads and the commit's.
    static func hosts() -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        if let index = hosts[0].state.agents.firstIndex(where: { $0.id == FixtureData.preview }) {
            hosts[0].state.agents[index].name = "Add refund events"
            hosts[0].state.agents[index].worktreeBranch = branch
            hosts[0].state.agents[index].worktreeBase = base
            hosts[0].state.agents[index].checkout = AgentCheckout(branch: branch, changedFiles: files.count)
        }
        hosts[0].threads[FixtureData.preview] = thread()
        let changes = reply(Repo(files: files, branch: branch, base: base, baseName: "main", mergeBase: "3f2a91c", lastTurn: turn,
                                 turnFiles: files.map(\.id)))
        let info = RemoteCommitInfo(repository: "/Users/dev/payments", branch: branch, head: "a1c9f2e", upstream: nil, pushRemote: "origin",
                                    defaultBranch: "main", files: files.map {
                                        RemoteCommitFile(path: $0.id, status: $0.isNew ? "A" : "M", added: $0.addedCount, removed: $0.removedCount,
                                                         fingerprint: $0.id)
                                    },
                                    title: "Emit refund events", body: "", draftsMessage: true, agentWorking: false, blocked: nil)
        hosts[0].reply = { request in
            guard case .agentQuery(let id, let agentID, let query) = request, agentID == FixtureData.preview else { return nil }
            switch query {
            case .commitInfo:
                return .agentResult(id: id, result: .commitInfo(info))
            case .commitMessage:
                return .agentResult(id: id, result: .commitMessage(
                    title: "Emit refund events from the ledger outbox",
                    body: "Adds refund.created and refund.settled through an events codec, a migration for the refund_events table, and table-driven tests for full and partial refunds.",
                    drafted: true))
            default:
                return changes(request)
            }
        }
        return hosts
    }

    /// The shared hosts with `snapshot` as the preview agent's thread.
    static func previewThread(_ snapshot: NativeThreadSnapshot) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        hosts[0].threads[FixtureData.preview] = snapshot
        return hosts
    }

    struct Repo: Sendable {
        var files: [DiffFile]
        var branch: String
        var base: String
        var baseName: String
        var mergeBase: String
        var lastTurn: ChangesTurn?
        /// The files the last turn changed.
        var turnFiles: [String]
        var listError: String? = nil
    }

    static let revision = ChangesRevision(old: "3f2a91c0d4", new: "9b8e7d60aa")

    /// Answers the engine's reads for the preview agent from `repo`.
    static func reply(_ repo: Repo) -> @Sendable (RemoteRequest) -> RemoteReply? {
        { request in
            guard case .agentQuery(let id, let agentID, let query) = request, agentID == FixtureData.preview else { return nil }
            let result: RemoteAgentResult
            switch query {
            case .changesOverview:
                result = .changesOverview(overview(repo))
            case .changesList(let scope, _):
                if let error = repo.listError { return .error(id: id, code: ChangesError.gitFailed, message: error) }
                result = .changesList(list(repo, scope: scope))
            case .changesFile(_, let path, _, _):
                guard let file = repo.files.first(where: { $0.id == path }) else {
                    return .error(id: id, code: ChangesError.invalid, message: "\(path) is not in this diff.")
                }
                result = .changesFile(ChangesFileDiff(file: file))
            case .changesBranches:
                result = .changesBranches(branches(repo))
            case .changesPatch:
                result = .changesPatch(text: "", truncated: false)
            default:
                return nil
            }
            return .agentResult(id: id, result: result)
        }
    }

    static func overview(_ repo: Repo) -> ChangesOverview {
        let all = repo.files.map(listed)
        let stat = { (files: [ChangesFile]) in (files.count, files.reduce(0) { $0 + $1.added }, files.reduce(0) { $0 + $1.removed }) }
        let (n, added, removed) = stat(all)
        let turn = stat(all.filter { repo.turnFiles.contains($0.id) })
        let now = Date().timeIntervalSince1970
        return ChangesOverview(
            repository: "/Users/dev/payments", branch: repo.branch, head: "a1c9f2e", defaultScope: .branch(base: nil), defaultBase: repo.base,
            entries: [
                .init(scope: .lastTurn, files: turn.0, added: turn.1, removed: turn.2),
                .init(scope: .uncommitted, files: 2, added: 33, removed: 11),
                .init(scope: .unstaged, files: 1, added: 21, removed: 8),
                .init(scope: .staged, files: 1, added: 12, removed: 3),
                .init(scope: .commits(first: "c40e8b3", last: "a1c9f2e"), count: 4),
                .init(scope: .branch(base: nil), files: n, added: added, removed: removed),
                .init(scope: .pullRequest, files: n, added: added, removed: removed),
            ],
            commits: [
                ChangesCommit(id: "a1c9f2e11", shortID: "a1c9f2e", subject: "Emit refund events from the outbox", date: now - 12 * 60),
                ChangesCommit(id: "7be02d122", shortID: "7be02d1", subject: "Table-driven refund tests", date: now - 18 * 60),
                ChangesCommit(id: "c40e8b333", shortID: "c40e8b3", subject: "Migration 0042: refund_events", date: now - 26 * 60),
                ChangesCommit(id: "5d11a0744", shortID: "5d11a07", subject: "Codec for outbox payloads", date: now - 31 * 60),
            ],
            commitsBase: repo.base,
            pullRequest: ChangesPullRequest(number: 31, title: "Refund events", isDraft: true, state: "OPEN", base: "main", head: repo.branch,
                                            url: "https://github.com/acme/payments/pull/31"),
            lastTurn: repo.lastTurn)
    }

    static func list(_ repo: Repo, scope: ChangesScope) -> ChangesList {
        let all = repo.files.map(listed)
        switch scope {
        case .lastTurn, .turn:
            return ChangesList(scope: scope, revision: revision,
                               comparison: ChangesComparison(head: "Working tree", base: "Turn start", turn: repo.lastTurn),
                               files: all.filter { repo.turnFiles.contains($0.id) })
        case .uncommitted, .unstaged:
            return ChangesList(scope: scope, revision: revision, comparison: ChangesComparison(head: "Working tree", base: "HEAD"),
                               files: Array(all.prefix(2)))
        case .staged:
            return ChangesList(scope: scope, revision: revision, comparison: ChangesComparison(head: "Index", base: "HEAD"), files: [])
        case .commits(let first, let last):
            return ChangesList(scope: scope, revision: revision,
                               comparison: ChangesComparison(head: String(last.prefix(7)), base: String(first.prefix(7)) + "^"), files: all)
        case .branch(let base):
            let name = base ?? repo.base
            return ChangesList(scope: scope, revision: revision,
                               comparison: ChangesComparison(head: repo.branch, base: name,
                                                             baseName: name.hasPrefix("origin/") ? String(name.dropFirst(7)) : name,
                                                             mergeBase: repo.mergeBase),
                               files: all)
        case .pullRequest:
            return ChangesList(scope: scope, revision: revision,
                               comparison: ChangesComparison(head: repo.branch, base: repo.base, baseName: repo.baseName, mergeBase: repo.mergeBase),
                               files: all)
        }
    }

    static func branches(_ repo: Repo) -> ChangesBranches {
        let now = Date().timeIntervalSince1970
        return ChangesBranches(defaultBase: repo.base, pullRequestBase: repo.base, recents: ["origin/release/2.4"], branches: [
            ChangesBranch(name: repo.base, isRemote: true, committedAt: now - 3_600),
            ChangesBranch(name: "origin/release/2.4", isRemote: true, committedAt: now - 7_200),
            ChangesBranch(name: "feat/ledger-v2", isRemote: false, committedAt: now - 9_000),
            ChangesBranch(name: "agent/pay-button-jump", isRemote: false, worktree: "/Users/dev/payments/.worktrees/pay", committedAt: now - 10_000),
            ChangesBranch(name: "fix/outbox-retry", isRemote: false, committedAt: now - 20_000),
            ChangesBranch(name: "agent/retry-plan", isRemote: false, worktree: "/Users/dev/payments/.worktrees/retry", committedAt: now - 30_000),
            ChangesBranch(name: repo.branch, isRemote: false, isCurrent: true, committedAt: now - 600),
        ])
    }

    /// outbox.go's comment on its wrapped error, refund.go and the migration viewed (folded), as
    /// the boards have them, once every file's hunks are in.
    @MainActor static func annotate(_ app: MobileApp) async {
        let store = store
        await ReviewFixture.loaded(store)
        await filesLoaded(store)
        store.toggleViewed("ledger/refund.go")
        store.toggleViewed("migrations/0042_refund_events.sql")
        guard let file = store.diff("ledger/outbox.go"),
              let line = file.hunks.lazy.flatMap(\.lines).first(where: { $0.kind == .added && $0.text.contains("fmt.Errorf") }) else { return }
        store.select(fileID: file.id, lineID: line.id)
        store.draft = "Wrap the error with the refund id too \u{2014} the on-call runbook greps for it."
        store.saveDraft()
    }

    /// Waits for every listed file's hunks and prepared text.
    @MainActor static func filesLoaded(_ store: ReviewStore) async {
        for entry in store.entries { store.ensure(entry.id) }
        await ReviewFixture.until { store.entries.allSatisfy { store.diffs[$0.id] != nil && store.texts[$0.id] != nil } }
    }
}
