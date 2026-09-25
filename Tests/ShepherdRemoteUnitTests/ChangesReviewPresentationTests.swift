import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote

@Suite("Changes review presentation")
struct ChangesReviewPresentationTests {
    static func file(_ path: String, _ status: ChangesFileStatus = .modified, added: Int = 1, removed: Int = 0) -> ChangesFile {
        ChangesFile(path: path, status: status, added: added, removed: removed)
    }

    static let turn = ChangesTurn(
        id: UUID(uuidString: "7E000000-0000-4000-8000-000000000001")!, messageTimestamp: 42, startedAt: 1, state: .ready,
        files: [file("ledger/outbox.go", added: 21, removed: 8), file("ledger/refund.go", .added, added: 64),
                file("ledger/refund_test.go", .added, added: 96), file("migrations/0042.sql", .added, added: 18)],
        fileCount: 5, added: 200, removed: 8, canUndo: true)

    // MARK: The card

    /// Three files as plain paths, the folder apart and a created one marked new, then "2 more".
    @Test func aRecordedTurnShowsThreeFilesThenHowManyMore() throws {
        let card = try #require(NativeChangesCard(turn: Self.turn))
        #expect(card.title == "Edited 5 files")
        #expect(card.rows.map(\.name) == ["outbox.go", "refund.go", "refund_test.go"])
        #expect(card.rows.map(\.directory) == ["ledger/", "ledger/", "ledger/"])
        #expect(card.rows.map(\.isNew) == [false, true, true])
        #expect(card.moreText == "2 more")
        #expect(card.turnID == Self.turn.id && card.canUndo && card.state == .ready)
    }

    @Test(arguments: [ChangesTurn.State.running, .unavailable])
    func aTurnStillRunningOrUnrecordedHasNoCard(state: ChangesTurn.State) {
        var turn = Self.turn
        turn.state = state
        #expect(NativeChangesCard(turn: turn) == nil)
    }

    @Test func anUndoneTurnOffersRedo() throws {
        var turn = Self.turn
        turn.state = .undone
        turn.canUndo = false
        turn.canRedo = true
        let card = try #require(NativeChangesCard(turn: turn))
        #expect(card.state == .undone && card.canRedo && !card.canUndo)
        #expect(card.title == "Undid the agent\u{2019}s edits to 5 files")
    }

    /// A host that records no turns still gets the card, from the turn's own edits, without Undo.
    @Test func withoutARecordTheCardComesFromTheEditsWithoutUndo() throws {
        let edits = try #require(NativeTurnChanges(turn: ChangesTurn(startedAt: 1, state: .ready, files: [
            Self.file("App/iOS/ThreadView.swift", added: 0, removed: 4)], removed: 4)))
        let card = try #require(nativeChangesCard(turn: nil, changes: edits))
        #expect(card.title == "Edited 1 file" && card.turnID == nil && !card.canUndo && card.moreText == nil)
        #expect(nativeChangesCard(turn: Self.turn, changes: edits)?.turnID == Self.turn.id)
        #expect(nativeChangesCard(turn: nil, changes: nil) == nil)
    }

    // MARK: The scope menu

    static let overview = ChangesOverview(
        repository: "/r", branch: "agent/refund-events", head: "a1c9f2e", defaultScope: .branch(base: nil), defaultBase: "origin/main",
        entries: [
            .init(scope: .lastTurn, files: 2, added: 12, removed: 3),
            .init(scope: .uncommitted, files: 2, added: 33, removed: 11),
            .init(scope: .unstaged, files: 1, added: 21, removed: 8),
            .init(scope: .staged, unavailable: "The index has conflicts"),
            .init(scope: .commits(first: "c", last: "a"), count: 2),
            .init(scope: .branch(base: nil), files: 5, added: 200, removed: 8),
            .init(scope: .pullRequest, files: 5, added: 200, removed: 8),
        ],
        commits: [ChangesCommit(id: "a1", shortID: "a1c9f2e", subject: "Emit refund events", date: 1_000 - 12 * 60),
                  ChangesCommit(id: "c4", shortID: "c40e8b3", subject: "Migration 0042", date: 1_000 - 26 * 60)],
        commitsBase: "3f2a91c",
        pullRequest: ChangesPullRequest(number: 31, title: "Refunds", isDraft: true, state: "OPEN", base: "main", head: "x", url: "u"))

    @Test func theScopeMenuListsEveryScopeInTheBoardsGroups() {
        let options = changesScopeOptions(Self.overview, selected: .branch(base: nil), base: nil)
        #expect(options.map(\.title) == ["Last turn", "Uncommitted", "Unstaged", "Staged", "Commits", "Branch", "Pull request"])
        #expect(options.filter(\.startsGroup).map(\.kind) == [.uncommitted, .commits])
        #expect(options.filter(\.selected).map(\.kind) == [.branch])
        let branch = options.first { $0.kind == .branch }
        #expect(branch?.detail == "agent/refund-events vs origin/main" && branch?.added == 200 && branch?.removed == 8)
        #expect(options.first { $0.kind == .pullRequest }?.trailing == "#31 draft")
        #expect(options.first { $0.kind == .commits }?.scope == .commits(first: "c4", last: "a1"))
        #expect(options.first { $0.kind == .staged }?.available == false)
    }

    @Test func aPickedBaseIsWhatBranchCompares() {
        let branch = changesScopeOptions(Self.overview, selected: nil, base: "origin/release/2.4").first { $0.kind == .branch }
        #expect(branch?.scope == .branch(base: "origin/release/2.4"))
        #expect(branch?.detail == "agent/refund-events vs origin/release/2.4")
    }

    @Test func theCommitsMenuOffersTheWholeBranchThenEachCommit() {
        let options = changesCommitOptions(Self.overview, selected: .commits(first: "a1", last: "a1"), now: Date(timeIntervalSince1970: 1_000))
        #expect(options.map(\.title) == ["All commits on the branch", "Emit refund events", "Migration 0042"])
        #expect(options.map(\.detail) == [nil, "a1c9f2e · 12m", "c40e8b3 · 26m"])
        #expect(options.filter(\.selected).map(\.id) == ["a1"])
    }

    @Test func withoutABaseTheCommitsMenuOffersRecentCommits() {
        var overview = Self.overview
        overview.commitsBase = nil
        #expect(changesCommitOptions(overview, selected: nil, now: Date(timeIntervalSince1970: 1_000)).first?.title == "Recent commits")
    }

    @Test(arguments: [(30.0, "now"), (12 * 60, "12m"), (3 * 3600, "3h"), (2 * 86_400, "2d")] as [(Double, String)])
    func aCommitsAgeIsShort(ago: Double, text: String) {
        #expect(changesAgeText(Date(timeIntervalSince1970: 1_000_000 - ago), now: Date(timeIntervalSince1970: 1_000_000)) == text)
    }

    // MARK: The base picker

    static let branches = ChangesBranches(defaultBase: "origin/main", pullRequestBase: "origin/main", recents: ["origin/release/2.4"], branches: [
        ChangesBranch(name: "origin/main", isRemote: true, committedAt: 50),
        ChangesBranch(name: "feat/ledger-v2", isRemote: false, committedAt: 90),
        ChangesBranch(name: "origin/release/2.4", isRemote: true, committedAt: 10),
        ChangesBranch(name: "agent/pay-button-jump", isRemote: false, worktree: "/w", committedAt: 80),
        ChangesBranch(name: "agent/refund-events", isRemote: false, isCurrent: true, committedAt: 100),
    ])

    /// The default first, then recents, then the rest by last commit; never the checked-out branch.
    @Test func theBasePickerPutsTheDefaultAndRecentsFirst() {
        let options = changesBaseOptions(Self.branches, selected: nil)
        #expect(options.map(\.name) == ["origin/main", "origin/release/2.4", "feat/ledger-v2", "agent/pay-button-jump"])
        #expect(options.map(\.tag) == ["default", nil, nil, "worktree"])
        #expect(options.filter(\.selected).map(\.name) == ["origin/main"])
    }

    @Test(arguments: [("LEDGER", ["feat/ledger-v2"]), ("origin", ["origin/main", "origin/release/2.4"]), ("nothing", [])])
    func theBasePickerFiltersByName(query: String, names: [String]) {
        #expect(changesBaseOptions(Self.branches, selected: "feat/ledger-v2", query: query).map(\.name) == names)
    }

    // MARK: The list

    @Test func aListedFileIsARowBeforeItsHunksArrive() {
        let (rows, totals) = reviewSummaries(listed: [Self.file("a/b.go", added: 3, removed: 1), Self.file("c.go", .added, added: 5)],
                                             comments: [ReviewComment(fileID: "c.go", lineID: 1, filePath: "c.go", lineNumber: 1, text: "x")],
                                             viewed: ["a/b.go"])
        #expect(rows.map(\.name) == ["b.go", "c.go"] && rows.map(\.directory) == ["a/", ""])
        #expect(rows.map(\.status) == [.modified, .added] && rows.map(\.comments) == [0, 1] && rows.map(\.viewed) == [true, false])
        #expect(totals == ReviewTotals(files: 2, added: 8, removed: 1, viewed: 1))
    }

    /// iPadReview's "95 unmodified lines": the lines before each hunk, none past a file's start.
    @Test func eachHunkCountsTheUnchangedLinesBeforeIt() {
        let file = DiffFile.parse("""
        diff --git a/x.go b/x.go
        --- a/x.go
        +++ b/x.go
        @@ -96,2 +96,2 @@
         a
        -b
        +c
        @@ -120,1 +120,2 @@
         d
        +e
        """)[0]
        #expect(reviewHunkGaps(file).values.sorted() == [22, 95])
        let top = DiffFile.parse("diff --git a/n.go b/n.go\n--- /dev/null\n+++ b/n.go\n@@ -0,0 +1,1 @@\n+x")[0]
        #expect(reviewHunkGaps(top).values.sorted() == [0])
    }

    @Test func theCompareRowNamesTheMergeBaseOrTheTurnsMessage() {
        let branch = ChangesList(scope: .branch(base: nil), revision: ChangesRevision(old: "aaaa", new: "bbbb"),
                                 comparison: ChangesComparison(head: "agent/refund-events", base: "origin/main", mergeBase: "3f2a91c"), files: [])
        #expect(changesCompareText(branch) == ChangesCompareText(head: "agent/refund-events", base: "origin/main",
                                                                  trailing: "merge base 3f2a91c", basePicks: true))
        var turn = Self.turn
        turn.prompt = "Wrap errors with context\nand more"
        let last = ChangesList(scope: .lastTurn, revision: ChangesRevision(old: "aaaa", new: "bbbb"),
                               comparison: ChangesComparison(head: "Working tree", base: "Turn start", turn: turn), files: [])
        #expect(changesCompareText(last).trailing == "after \u{201C}Wrap errors with context\u{201D}")
        #expect(!changesCompareText(last).basePicks)
    }
}
