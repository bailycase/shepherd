import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The ChangesSplit board's outbox.go: three hunks with 28 and 55 unmodified lines between them.
private enum Outbox {
    static let diff = """
    diff --git a/ledger/outbox.go b/ledger/outbox.go
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
     // Outbox writes events
     type Outbox struct {
     \tdb    *sql.DB
    -\tnow func() time.Time
    +\tnow   func() time.Time
    +\tcodec events.Codec
     }
    @@ -96,4 +100,4 @@
     func (o *Outbox) Append() error {
    -\tpayload, err := json.Marshal(e.Payload)
    +\tpayload, err := o.codec.Encode(e.Kind, e.Payload)
     \treturn err
     }
    """

    static var file: DiffFile { GitDiff.parse(diff)[0] }

    static func rows(_ layout: ChangesLayout, revealed: IndexSet = []) -> [NWChangesRow] {
        ChangesRows.rows(file, layout: layout, revealed: revealed, truncated: false, colors: nil, words: nil, tints: (.green, .red))
    }

    static func folds(_ rows: [NWChangesRow]) -> [NWDiffFold] {
        rows.compactMap { if case .fold(let fold) = $0 { fold } else { nil } }
    }
}

/// A whole file's diff (Load full files): one hunk, a change at line 30 of 60.
private enum WholeFile {
    static var file: DiffFile {
        var lines: [DiffLine] = (1...60).map { DiffLine(kind: .context, text: "line \($0)", oldLine: $0, newLine: $0 < 30 ? $0 : $0 + 1, id: $0) }
        lines.insert(DiffLine(kind: .added, text: "new", oldLine: nil, newLine: 30, id: 100), at: 29)
        return Fixture.diffFile("whole.txt", hunks: [DiffHunk(header: "@@ -1,60 +1,61 @@", lines: lines)])
    }

    static func rows(revealed: IndexSet = []) -> [NWChangesRow] {
        ChangesRows.rows(file, layout: .unified, revealed: revealed, truncated: false, colors: nil, words: nil, tints: (.green, .red))
    }
}

@Suite("Changes rows")
struct ChangesRowsTests {
    /// Lines between hunks fold as "N unmodified lines": 28 and 55 on the board.
    @Test func linesBetweenHunksFoldWithTheirCount() {
        let folds = Outbox.folds(Outbox.rows(.split))
        #expect(folds.map(\.count) == [28, 55])
        #expect(folds.map(\.label) == ["28 unmodified lines", "55 unmodified lines"])
        #expect(folds.allSatisfy { $0.revealsUp && $0.revealsDown }, "between two hunks, both ways")
        let spans = folds.compactMap { ChangesRows.span(ofFold: $0.id) }
        #expect(spans == [ChangesFoldSpan(lines: 8...35, loaded: false), ChangesFoldSpan(lines: 41...95, loaded: false)])
    }

    /// Split pairs each run of removals with the additions after it; the longer side's extra
    /// lines sit against filler, and unchanged lines sit beside themselves.
    @Test func splitPairsRemovalsWithTheAdditionsAfterThem() throws {
        let pairs = Outbox.rows(.split).compactMap { row -> (Int?, Int?)? in
            if case .pair(_, let old, let new) = row { (old?.oldNumber, new?.newNumber) } else { nil }
        }
        // The first hunk: five unchanged, "fmt" against filler, "time", two additions against filler, ")".
        let first = Array(pairs.prefix(10))
        #expect(first.map(\.0) == [1, 2, 3, 4, 5, nil, 6, nil, nil, 7])
        #expect(first.map(\.1) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        // The second: the changed field beside its new form, then the added field against filler.
        let changed = try #require(pairs.firstIndex { $0.0 == 39 })
        #expect(pairs[changed].1 == 42 && pairs[changed + 1].0 == nil && pairs[changed + 1].1 == 43)
    }

    @Test func unifiedKeepsEveryLineInOrder() {
        let lines = Outbox.rows(.unified).compactMap { if case .line(let line) = $0 { line } else { nil } }
        #expect(lines.count == Outbox.file.hunks.reduce(0) { $0 + $1.lines.count })
        #expect(lines.map(\.id) == Outbox.file.hunks.flatMap(\.lines).map { "ledger/outbox.go\u{0}\($0.id)" })
    }

    /// A whole file keeps three unchanged lines beside a change and folds the rest: the top fold
    /// opens only upward, the last only downward.
    @Test func aWholeFileFoldsTheUnchangedRunsAroundItsChange() {
        let folds = Outbox.folds(WholeFile.rows())
        #expect(folds.map(\.count) == [26, 28])
        #expect(folds[0].revealsUp && !folds[0].revealsDown)
        #expect(!folds[1].revealsUp && folds[1].revealsDown)
        #expect(folds.compactMap { ChangesRows.span(ofFold: $0.id) }
            == [ChangesFoldSpan(lines: 1...26, loaded: true), ChangesFoldSpan(lines: 33...60, loaded: true)])
    }

    @Test func revealedLinesShowAndTheFoldShrinks() {
        let folds = Outbox.folds(WholeFile.rows(revealed: IndexSet(integersIn: 7..<27)))
        #expect(folds.map(\.count) == [6, 28], "20 lines opened at the top fold's bottom edge")
    }

    @Test(arguments: [
        (NWDiffReveal.up, 16...35), (.down, 8...27), (.all, 8...35),
    ] as [(NWDiffReveal, ClosedRange<Int>)])
    func aRevealShowsTwentyLinesAtAnEdgeOrAll(reveal: NWDiffReveal, lines: ClosedRange<Int>) {
        #expect(ChangesFoldSpan(lines: 8...35, loaded: false).revealed(reveal) == lines)
    }

    @Test func aShortFoldRevealsNoMoreThanItHides() {
        #expect(ChangesFoldSpan(lines: 3...9, loaded: true).revealed(.up) == 3...9)
    }

    @Test(arguments: [
        ChangesFoldSpan(lines: 8...35, loaded: false), ChangesFoldSpan(lines: 1...1, loaded: true),
    ])
    func aFoldsIdNamesItsSpan(span: ChangesFoldSpan) {
        #expect(ChangesRows.span(ofFold: ChangesRows.foldID(fileID: "a/b-c.go", span: span)) == span)
    }

    @Test func aBinaryFileIsANotice() {
        let file = DiffFile(oldPath: "a.png", newPath: "a.png", displayPath: "a.png", isNew: false, isDeleted: false, isRenamed: false,
                            isBinary: true, hunks: [])
        let rows = ChangesRows.rows(file, layout: .split, revealed: [], truncated: false, colors: nil, words: nil, tints: (.green, .red))
        #expect(rows.map(\.id) == ["a.png\u{0}binary"])
    }

    @Test func aTruncatedFileSaysSoAtItsEnd() {
        let rows = ChangesRows.rows(Outbox.file, layout: .unified, revealed: [], truncated: true, colors: nil, words: nil, tints: (.green, .red))
        guard case .notice(_, let text)? = rows.last else { Issue.record("expected the notice last"); return }
        #expect(text.contains("too long"))
    }

    /// Word diffs tint only the changed words of a modified line.
    @Test func wordDiffsTintTheChangedWords() throws {
        let file = Outbox.file
        let words = DiffWords.changes(in: file)
        let rows = ChangesRows.rows(file, layout: .unified, revealed: [], truncated: false, colors: nil, words: words, tints: (.green, .red))
        let added = try #require(rows.lazy.compactMap { row -> NWDiffLineContent? in
            if case .line(let line) = row, line.newNumber == 101 { line } else { nil }
        }.first)
        let tinted = added.text.runs.filter { $0.backgroundColor != nil }.map { String(added.text[$0.range].characters) }
        #expect(!tinted.isEmpty && !tinted.contains(added.source), "some words, never the whole line: \(tinted)")
    }

    /// Each unchanged line's number sits beside it; a hunk that only adds starts after the old
    /// line its header names.
    @Test func aHunkThatOnlyAddsStartsAfterItsHeadersOldLine() {
        #expect(ChangesRows.oldStart("@@ -12,0 +13,5 @@ func x()") == 12)
        let hunk = DiffHunk(header: "@@ -12,0 +13,2 @@", lines: [DiffLine(kind: .added, text: "a", oldLine: nil, newLine: 13, id: 1)])
        #expect(ChangesRows.firstOldLine(hunk) == 13 && ChangesRows.lastOldLine(hunk) == 12)
    }

    /// A comment follows its line into a file fetched again (whole): the same side, number and
    /// text; a comment whose line is gone keeps its text and cite.
    @Test func commentsReanchorToTheirLineInAFileFetchedAgain() throws {
        let file = Outbox.file
        let line = try #require(file.hunks[2].lines.first { $0.kind == .added })
        let comment = ReviewComment(fileID: file.id, lineID: 999, filePath: file.displayPath, lineNumber: 101, marker: "+",
                                    content: line.text, text: "Wrap it")
        let gone = ReviewComment(fileID: file.id, lineID: 998, filePath: file.displayPath, lineNumber: 5, marker: "+", content: "x", text: "Gone")
        let moved = ChangesRows.reanchor([comment, gone], in: file)
        #expect(moved[0].lineID == line.id && moved[0].text == "Wrap it")
        #expect(moved[1] == gone)
    }
}

@Suite("Changes pane copy")
@MainActor
struct ChangesTextTests {
    @Test(arguments: [(900.0, ChangesLayout.split), (899.0, .unified)] as [(Double, ChangesLayout)])
    func splitFromNineHundredPoints(width: Double, layout: ChangesLayout) {
        #expect(ChangesLayoutChoice.automatic.resolved(width: width) == layout)
        #expect(ChangesLayoutChoice.unified.resolved(width: 2000) == .unified)
        #expect(ChangesLayoutChoice.split.resolved(width: 300) == .split)
    }

    @Test func aTurnsTimesShareTheirHalfOfTheDay() {
        let start = ChangesTimeFixture.at(15, 7), end = ChangesTimeFixture.at(15, 11)
        #expect(changesTimeRange(start: start, end: end) == "\(nativeClockText(start).dropLast(3))–\(nativeClockText(end))")
        let morning = ChangesTimeFixture.at(11, 58), noon = ChangesTimeFixture.at(12, 4)
        #expect(changesTimeRange(start: morning, end: noon) == "\(nativeClockText(morning))–\(nativeClockText(noon))")
    }

    @Test func aTurnsDetailNamesTheMessageThatStartedIt() {
        let turn = ChangesTurn(prompt: "Wrap errors with context\nand log them", startedAt: ChangesTimeFixture.at(15, 7),
                               endedAt: ChangesTimeFixture.at(15, 11), state: .ready)
        #expect(ChangesText.turnDetail(turn).hasSuffix(" · after “Wrap errors with context”"))
        let running = ChangesTurn(startedAt: ChangesTimeFixture.at(15, 7), state: .running)
        #expect(ChangesText.turnDetail(running).hasPrefix("since "))
    }

    @Test(arguments: [(30.0, "1m"), (12 * 60, "12m"), (3 * 3600, "3h"), (2 * 86_400, "2d")] as [(Double, String)])
    func aCommitsAgeIsShort(ago: Double, text: String) {
        #expect(changesAge(1_000_000 - ago, now: 1_000_000) == text)
    }

    @Test func theScopeButtonNamesTheScope() {
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp", reference: nil)
        #expect(ChangesText.scopeButton(session) == "Uncommitted", "a legacy review's working tree")
        session.isPRMode = true
        #expect(ChangesText.scopeButton(session) == "Pull request")
        session.engine = ChangesEngine.unused
        session.scope = .branch(base: nil)
        #expect(ChangesText.scopeButton(session) == "Branch")
        session.scope = .commits(first: "a1c9f2e", last: "a1c9f2e")
        #expect(ChangesText.scopeButton(session) == "Commit")
        session.scope = .lastTurn
        #expect(ChangesText.scopeButton(session) == "Last turn")
    }

    /// The compare row: head → base on Branch, a turn's times on Last turn, nothing before the
    /// list arrives.
    @Test func theCompareRowFollowsTheScope() {
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp", reference: nil)
        session.engine = ChangesEngine.unused
        #expect(ChangesText.compareLead(session) == nil)
        session.list = ChangesList(scope: .branch(base: nil), revision: ChangesRevision(old: "a", new: "b"),
                                   comparison: ChangesComparison(head: "agent/refund-events", base: "origin/main", mergeBase: "3f2a91c"), files: [])
        #expect(ChangesText.compareLead(session) == .compare(head: "agent/refund-events", base: "origin/main"))
        let turn = ChangesTurn(startedAt: 1, endedAt: 2, state: .ready)
        session.list = ChangesList(scope: .lastTurn, revision: ChangesRevision(old: "a", new: "b"),
                                   comparison: ChangesComparison(head: "End of turn", base: "Start of turn", turn: turn), files: [])
        #expect(ChangesText.compareLead(session) == .turn(title: "The agent’s last turn", detail: ChangesText.turnDetail(turn)))
    }

    @Test func copyingAPatchAsACommandWrapsItInAHereDocument() {
        #expect(changesApplyCommand("diff --git a/x b/x\n") == "git apply --3way <<'SHEPHERD_PATCH'\ndiff --git a/x b/x\nSHEPHERD_PATCH\n")
        #expect(changesApplyCommand("SHEPHERD_PATCH").hasPrefix("git apply --3way <<'SHEPHERD_PATCH_'"), "a marker the patch never holds")
    }

    @Test func aRefusedUndoNamesWhatChanged() {
        let error = ChangesError(ChangesError.changedSince, "changed", files: ["ledger/outbox.go", "a/b.go", "c.go", "d.go"])
        #expect(changesTurnRefusal(error, redo: false) == "Didn’t undo: outbox.go, b.go, c.go and 1 more changed after the turn. Nothing was touched.")
        #expect(changesTurnRefusal(ChangesError(ChangesError.unavailable, "No turn yet."), redo: true) == "No turn yet.")
    }

    /// The agent's reply to a sent review turns the pane to Last turn; any other settled turn
    /// reloads a scope it can change.
    @Test func theReplyToASentReviewTurnsThePaneToLastTurn() {
        var scopes: [ChangesScope] = []
        var refreshes = 0
        var actions = ReviewActions(setPullRequest: { _ in }, requestChanges: {}, commit: {}, close: {})
        actions.setScope = { scopes.append($0) }
        actions.refresh = { refreshes += 1 }
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp", reference: nil)
        session.engine = ChangesEngine.unused
        session.scope = .branch(base: nil)
        session.sentAt = 100
        let running = ChangesTurn(startedAt: 150, state: .running)
        ChangesFollow.turnChanged(session, old: nil, turn: running, actions: actions)
        #expect(scopes.isEmpty && refreshes == 0, "nothing until it settles")
        var done = running
        done.state = .ready
        ChangesFollow.turnChanged(session, old: running, turn: done, actions: actions)
        #expect(scopes == [.lastTurn] && session.sentAt == nil)
        var undone = done
        undone.state = .undone
        ChangesFollow.turnChanged(session, old: done, turn: undone, actions: actions)
        #expect(refreshes == 1, "an Undo reloads a working-tree scope")
    }
}

enum ChangesTimeFixture {
    /// Today at `hour`:`minute`, in ms.
    static func at(_ hour: Int, _ minute: Int) -> Double {
        (Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()).timeIntervalSince1970 * 1000
    }
}

extension ChangesEngine {
    /// An engine for tests that never ask it anything.
    static var unused: ChangesEngine {
        let never = ChangesError(ChangesError.unavailable, "unused")
        return ChangesEngine(overview: { throw never }, list: { _, _ in throw never }, diffs: { _, _ in throw never },
                             file: { _, _, _ in throw never }, branches: { throw never }, patch: { _, _ in throw never })
    }
}
