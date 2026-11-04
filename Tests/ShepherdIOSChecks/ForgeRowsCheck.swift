import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Compiles the iOS Issues & PRs derivations (App/iOS/Forge/ForgeRows.swift): the list's rows and
// counts, an issue row's words, a label's tone, and a pull request page's summary lines.
@main
struct ForgeRowsCheck {
    static func main() {
        let host = UUID()
        let now = Date(timeIntervalSince1970: 1_790_215_200)
        let hour: TimeInterval = 3_600
        func ref(_ kind: ForgeKind, _ number: Int) -> ForgeItemRef { ForgeItemRef(kind: kind, repo: "acme/payments", number: number) }
        let thread = ForgeThreadLink(agentID: AgentID(rawValue: "a"), title: "Fix pay button", running: true)

        // Lists: open items count, Closed doesn't; an on-demand section not read is listed unloaded.
        let pulls = ForgeList(kind: .pullRequest, repo: "acme/payments", sections: [
            ForgeSection(id: .authored, pullRequests: [
                PullRequestSummary(ref: ref(.pullRequest, 31), title: "Refunds", author: "baily", updatedAt: now - 2 * hour, state: .open,
                                   checks: .failing, reviewDecision: .changesRequested, headRef: "h", baseRef: "main"),
            ]),
            ForgeSection(id: .openedByAgents, pullRequests: [
                PullRequestSummary(ref: ref(.pullRequest, 26), title: "Pay button", author: "baily", updatedAt: now - 20 * 60, state: .draft,
                                   headRef: "h", baseRef: "main", thread: thread),
            ]),
            ForgeSection(id: .closed, pullRequests: [
                PullRequestSummary(ref: ref(.pullRequest, 20), title: "Old", author: "mara", updatedAt: now - 72 * hour, state: .merged, headRef: "h", baseRef: "main"),
            ]),
        ])
        let model = ForgeRows.list(pulls, host: host, hostName: "build-01", now: now)
        check(model.count == 2, "open rows count, closed ones don't: \(model.count)")
        check(model.sections.map(\.id) == ForgeSectionID.all(for: .pullRequest), "every section in order")
        check(model.sections.first { $0.id == .teamReview }?.loaded == false, "team review waits to be opened")
        let refunds = model.sections[0].rows[0]
        check(refunds.byline == "#31 · baily · 2h" && refunds.word == "Changes" && refunds.tone == .failed, "a pull request row: \(refunds)")
        let agentRow = model.sections.first { $0.id == .openedByAgents }!.rows[0]
        check(agentRow.byline == "#26 · build-01 · 20m" && agentRow.word == "Draft", "an agent's pull request names its host: \(agentRow.byline)")

        // Issues: New in lantern, a linked pull request and a thread in running blue (MobileIssueList).
        let new = IssueSummary(ref: ref(.issue, 34), title: "Rounding", author: "mara", updatedAt: now - hour, state: .open,
                               labels: [ForgeLabel(name: "bug", color: "d73a4a")], assignedToViewer: true)
        let linked = IssueSummary(ref: ref(.issue, 28), title: "Outbox", author: "baily", updatedAt: now - 72 * hour, state: .open, linkedPullRequests: [31])
        let watched = IssueSummary(ref: ref(.issue, 33), title: "FX", author: "sentry-bot", updatedAt: now - 6 * hour, state: .open, thread: thread,
                                   automationName: "Triage Sentry")
        let rows = [new, linked, watched].map { ForgeRows.issueRow($0, host: host, now: now) }
        check(rows[0].byline == "#34 · mara · 1h · bug" && rows[0].word == "New" && rows[0].tone == .attention, "a new issue: \(rows[0])")
        check(rows[1].byline == "#28 · baily · 3d · linked #31" && rows[1].word == "In PR" && rows[1].tone == .running, "a linked issue: \(rows[1])")
        check(rows[2].byline == "#33 · Triage Sentry · 6h" && rows[2].word == "Thread" && rows[2].tone == .running, "an automation's issue: \(rows[2])")

        // Labels take the nearest status role; grays stay neutral.
        check(ForgeRows.tone(hex: "d73a4a") == .failed, "bug is red")
        check(ForgeRows.tone(hex: "ededed") == .idle, "a gray label is neutral")
        check(ForgeRows.tone(hex: "0e8a16") == .done, "green")
        check(ForgeRows.tone(hex: "1d76db") == .running, "blue")
        check(ForgeRows.tone(hex: "fbca04") == .attention, "yellow")
        check(ForgeRows.tone(hex: "zz") == .idle, "a bad color is neutral")

        // A pull request page: the reviewer who blocks it, then the checks with the failing job's short name.
        let detail = PullRequestDetail(
            summary: PullRequestSummary(ref: ref(.pullRequest, 31), title: "Refunds", author: "baily", updatedAt: now - 2 * hour, state: .open,
                                        checks: .failing, reviewDecision: .changesRequested, headRef: "h", baseRef: "main"),
            createdAt: now - 3 * hour, body: "Body",
            reviewers: [ForgeReviewer(login: "mara", state: .changesRequested)],
            checks: [ForgeCheck(name: "build", state: .passed), ForgeCheck(name: "test (arm64)", state: .failing), ForgeCheck(name: "docs", state: .skipped)],
            events: [ForgeEvent(id: "o", actor: "baily", at: now - 3 * hour, kind: .opened),
                     ForgeEvent(id: "r", actor: "mara", at: now - 40 * 60, kind: .reviewed(state: .changesRequested, body: "", comments: [
                         ForgeLineComment(id: 1, author: "mara", path: "ledger/outbox.go", line: 103, diffHunk: "", body: "Wrap it", createdAt: now - 40 * 60),
                     ]))])
        let page = ForgeRows.pullRequest(detail, hostName: "Studio", now: now)
        check(page.status.map(\.text) == ["mara requested changes", "1 of 2 checks passed"], "summary lines: \(page.status.map(\.text))")
        check(page.status.map(\.trailing) == ["40m", "arm64"], "their times and the failing job: \(page.status.map(\.trailing))")
        check(page.failing.map(\.name) == ["test · arm64"], "the failing check's log card")
        check(page.commentCounts == ["ledger/outbox.go": 1], "line comments per file")
        check(page.activity.count == 1, "the opening isn't repeated; the review is its comment card")
        check(page.primary == .merge && page.blocked == "mara requested changes and test · arm64 is failing.", "Merge…, blocked: \(page.blocked ?? "nil")")
        print("FORGE ROWS CHECK COMPLETE")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAILED: \(message)") }
    }
}
