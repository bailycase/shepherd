import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// The Changes boards' review (ChangesSplit and its siblings): agent/refund-events against
/// origin/main, five files, outbox.go with three hunks (28 and 55 unmodified lines between
/// them), refund.go and the migration viewed, and a comment on line 103.
@MainActor
enum ChangesBoard {
    static let outbox = """
    diff --git a/ledger/outbox.go b/ledger/outbox.go
    index 1111111..2222222 100644
    --- a/ledger/outbox.go
    +++ b/ledger/outbox.go
    @@ -1,7 +1,10 @@
     package ledger
    \u{20}
     import (
     \t"context"
     \t"database/sql"
    +\t"fmt"
     \t"time"
    +
    +\t"github.com/acme/payments/events"
     )
    @@ -36,5 +39,6 @@
     // Outbox writes events in the same transaction as the ledger change.
     type Outbox struct {
     \tdb    *sql.DB
    -\tnow func() time.Time
    +\tnow   func() time.Time
    +\tcodec events.Codec
     }
    @@ -96,9 +100,14 @@
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
    \u{20}
    +// AppendRefund records refund.created in the same transaction as the refund.
    +func (o *Outbox) AppendRefund(ctx context.Context, tx *sql.Tx, r Refund) error {
    +\treturn o.Append(ctx, tx, Event{Kind: events.RefundCreated, Payload: r})
    +}
    """

    static func added(_ path: String, _ lines: [String]) -> String {
        """
        diff --git a/\(path) b/\(path)
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/\(path)
        @@ -0,0 +1,\(lines.count) @@
        \(lines.map { "+" + $0 }.joined(separator: "\n"))
        """
    }

    static let refund = (1...64).map { index -> String in
        switch index {
        case 1: "package ledger"
        case 3: "// Refund is money going back to the customer: full or partial."
        case 4: "type Refund struct {"
        case 5: "\tID       string"
        case 6: "\tChargeID string"
        case 7: "\tAmount   int64"
        case 8: "}"
        default: index % 7 == 0 ? "" : "\t// refund step \(index): settle, record, emit"
        }
    }

    static let refundTest = (1...96).map { index -> String in
        index == 1 ? "package ledger" : index % 9 == 0 ? "" : "\t{name: \"partial refund \(index)\", amount: \(index * 100)},"
    }

    static let migration = (1...18).map { index -> String in
        index == 1 ? "CREATE TABLE refund_events (" : index == 18 ? ");" : "  column_\(index) TEXT NOT NULL,"
    }

    static let goMod = """
    diff --git a/go.mod b/go.mod
    index 4444444..5555555 100644
    --- a/go.mod
    +++ b/go.mod
    @@ -3,3 +3,4 @@
     go 1.23
    \u{20}
     require github.com/lib/pq v1.10.9
    +require github.com/acme/payments/events v0.4.0
    """

    static var diff: String {
        [outbox, added("ledger/refund.go", refund), added("ledger/refund_test.go", refundTest),
         added("migrations/0042_refund_events.sql", migration), goMod].joined(separator: "\n")
    }

    static var files: [DiffFile] { GitDiff.parse(diff) }

    static func listed(_ files: [DiffFile], scope: ChangesScope, comparison: ChangesComparison) -> ChangesList {
        ChangesList(scope: scope, revision: ChangesRevision(old: "3f2a91c", new: "a1c9f2e"), comparison: comparison,
                    files: files.map { file in
                        ChangesFile(path: file.displayPath, status: file.isNew ? .added : file.isDeleted ? .deleted : .modified,
                                    added: file.addedCount, removed: file.removedCount)
                    })
    }

    static let branchComparison = ChangesComparison(head: "agent/refund-events", base: "origin/main", baseName: "main", mergeBase: "3f2a91c")

    static let now = Date().timeIntervalSince1970

    static let commits = [
        ChangesCommit(id: "a1c9f2e000", shortID: "a1c9f2e", subject: "Emit refund events from the outbox", date: now - 12 * 60),
        ChangesCommit(id: "7be02d1000", shortID: "7be02d1", subject: "Table-driven refund tests", date: now - 18 * 60),
        ChangesCommit(id: "c40e8b3000", shortID: "c40e8b3", subject: "Migration 0042: refund_events", date: now - 26 * 60),
        ChangesCommit(id: "5d11a07000", shortID: "5d11a07", subject: "Codec for outbox payloads", date: now - 31 * 60),
    ]

    static let lastTurn = ChangesTurn(messageTimestamp: 1, prompt: "Wrap errors with context", startedAt: clock(15, 7), endedAt: clock(15, 11),
                                      state: .ready, files: [], fileCount: 2, added: 12, removed: 3, canUndo: true)

    /// Today at `hour`:`minute`, in ms.
    static func clock(_ hour: Int, _ minute: Int) -> Double {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        return date.timeIntervalSince1970 * 1000
    }

    static let overview = ChangesOverview(
        repository: "/Users/baily/payments", branch: "agent/refund-events", head: "a1c9f2e", defaultScope: .branch(base: nil),
        defaultBase: "origin/main",
        entries: [
            .init(scope: .lastTurn, files: 2, added: 12, removed: 3),
            .init(scope: .uncommitted, files: 3, added: 33, removed: 11),
            .init(scope: .unstaged, files: 2, added: 21, removed: 8),
            .init(scope: .staged, files: 1, added: 12, removed: 3),
            .init(scope: .commits(first: "5d11a07000", last: "a1c9f2e000"), count: 4),
            .init(scope: .branch(base: nil), files: 5, added: 200, removed: 8),
            .init(scope: .pullRequest, files: 5, added: 200, removed: 8),
        ],
        commits: commits, commitsBase: "origin/main",
        pullRequest: ChangesPullRequest(number: 31, title: "Add refund events", isDraft: true, state: "OPEN", base: "main",
                                        head: "agent/refund-events", url: "https://github.com/acme/payments/pull/31"),
        lastTurn: lastTurn)

    static let branches = ChangesBranches(
        defaultBase: "origin/main", pullRequestBase: "origin/main", recents: ["origin/release/2.4"],
        branches: [
            ChangesBranch(name: "origin/main", isRemote: true, committedAt: now),
            ChangesBranch(name: "origin/release/2.4", isRemote: true, committedAt: now - 100),
            ChangesBranch(name: "feat/ledger-v2", isRemote: false, committedAt: now - 200),
            ChangesBranch(name: "agent/pay-button-jump", isRemote: false, worktree: "/tmp/pay", committedAt: now - 300),
            ChangesBranch(name: "fix/outbox-retry", isRemote: false, committedAt: now - 400),
            ChangesBranch(name: "agent/retry-plan", isRemote: false, worktree: "/tmp/retry", committedAt: now - 500),
            ChangesBranch(name: "agent/refund-events", isRemote: false, isCurrent: true, committedAt: now - 600),
        ])

    /// An engine that answers from the fixture.
    static func engine(_ files: [DiffFile], list: ChangesList) -> ChangesEngine {
        ChangesEngine(overview: { overview }, list: { _, _ in list }, diffs: { _, _ in (files, []) },
                      file: { _, file, _ in ChangesFileDiff(file: files.first { $0.id == file.id }!) },
                      branches: { branches }, patch: { _, _ in ("", false) })
    }

    /// The board's review of the branch: loaded, two files viewed, the comment on line 103.
    static func session(comment: Bool = true) -> ReviewSession {
        let files = files
        let list = listed(files, scope: .branch(base: nil), comparison: branchComparison)
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/Users/baily/payments", reference: nil)
        session.engine = engine(files, list: list)
        session.scope = .branch(base: nil)
        session.list = list
        session.overview = overview
        session.branches = branches
        session.files = files
        session.viewed = ["ledger/refund.go", "migrations/0042_refund_events.sql"]
        if comment { session.comments = [commentOn103(files)] }
        return session
    }

    static func commentOn103(_ files: [DiffFile]) -> ReviewComment {
        let outbox = files[0]
        let line = outbox.hunks.flatMap(\.lines).first { $0.newLine == 103 }!
        return ReviewComment(fileID: outbox.id, lineID: line.id, filePath: outbox.displayPath, lineNumber: 103, marker: "+",
                             content: line.text, text: "Wrap the error with the refund id too — the on-call runbook greps for it.")
    }

    /// Just the agent's last turn (ChangesLastTurn): outbox.go's third hunk and refund.go's first lines.
    static func lastTurnSession() -> ReviewSession {
        let outbox = """
        diff --git a/ledger/outbox.go b/ledger/outbox.go
        index 1111111..2222222 100644
        --- a/ledger/outbox.go
        +++ b/ledger/outbox.go
        @@ -96,9 +100,10 @@
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
        \u{20}
        +// AppendRefund records refund.created in the same transaction as the refund.
        """
        let files = GitDiff.parse([outbox, added("ledger/refund.go", Array(refund.prefix(3)))].joined(separator: "\n"))
        let list = listed(files, scope: .lastTurn,
                          comparison: ChangesComparison(head: "End of turn", base: "Start of turn", turn: lastTurn))
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/Users/baily/payments", reference: nil)
        session.engine = engine(files, list: list)
        session.scope = .lastTurn
        session.list = list
        session.overview = overview
        session.files = files
        return session
    }
}
