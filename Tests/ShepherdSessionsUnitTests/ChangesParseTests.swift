import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

/// git's machine output as the Changes engine reads it, and the engine's pure rules.
@Suite("Changes parsing")
struct ChangesParseTests {
    static func nul(_ fields: [String]) -> Data { Data((fields.joined(separator: "\0") + "\0").utf8) }

    /// `git diff --raw --numstat -z`: statuses from the raw records, counts from numstat, a
    /// rename's two paths, and "-" for a binary file.
    @Test func rawAndNumstatBecomeFiles() {
        let data = Self.nul([
            ":100644 100644 aaaaaaa bbbbbbb M", "ledger/outbox.go",
            ":000000 100644 0000000 ccccccc A", "ledger/refund.go",
            ":100644 000000 ddddddd 0000000 D", "old notes.md",
            ":100644 100644 eeeeeee fffffff R087", "json.go", "codec.go",
            ":100644 100644 1111111 2222222 M", "logo.png",
            "21\t8\tledger/outbox.go",
            "64\t0\tledger/refund.go",
            "0\t12\told notes.md",
            "2\t1\t", "json.go", "codec.go",
            "-\t-\tlogo.png",
        ])
        #expect(ChangesParse.files(rawNumstat: data) == [
            ChangesFile(path: "ledger/outbox.go", status: .modified, added: 21, removed: 8),
            ChangesFile(path: "ledger/refund.go", status: .added, added: 64, removed: 0),
            ChangesFile(path: "old notes.md", status: .deleted, added: 0, removed: 12),
            ChangesFile(path: "codec.go", oldPath: "json.go", status: .renamed, added: 2, removed: 1),
            ChangesFile(path: "logo.png", status: .modified, added: 0, removed: 0, isBinary: true),
        ])
        #expect(ChangesParse.files(rawNumstat: Data()).isEmpty)
    }

    /// A file whose name starts with a colon is still a path, not a record.
    @Test func aPathThatLooksLikeARecordStaysAPath() {
        let data = Self.nul([":100644 100644 aaaaaaa bbbbbbb M", ":weird", "1\t1\t:weird"])
        #expect(ChangesParse.files(rawNumstat: data) == [ChangesFile(path: ":weird", status: .modified, added: 1, removed: 1)])
    }

    /// Hiding whitespace, a file an older git still lists with no counts leaves the list; a mode
    /// change and a binary file stay.
    @Test func hidingWhitespaceDropsAFileWithOnlyWhitespaceChanges() {
        let data = Self.nul([
            ":100644 100644 aaaaaaa bbbbbbb M", "spaces.txt",
            ":100644 100755 ccccccc ccccccc M", "run.sh",
            ":100644 100644 ddddddd eeeeeee M", "long.txt",
            "0\t0\tspaces.txt", "0\t0\trun.sh", "1\t1\tlong.txt",
        ])
        #expect(ChangesParse.files(rawNumstat: data, ignoringWhitespace: true).map(\.path) == ["run.sh", "long.txt"])
        #expect(ChangesParse.files(rawNumstat: data).map(\.path) == ["spaces.txt", "run.sh", "long.txt"])
    }

    @Test func nameStatusPairsEachStatusWithItsPath() {
        let entries = ChangesParse.nameStatus(Self.nul(["M", "a.swift", "A", "new file.swift", "D", "gone.swift"]))
        #expect(entries.map { "\($0.status)\($0.path)" } == ["Ma.swift", "Anew file.swift", "Dgone.swift"])
    }

    /// The base picker: a remote's HEAD is no branch, the current branch carries no worktree tag,
    /// and another worktree's branch does.
    @Test func branchesSkipRemoteHeadsAndTagWorktrees() {
        let text = [
            "refs/heads/agent/refund-events\0agent/refund-events\01758000300\0/w/refund",
            "refs/remotes/origin/HEAD\0origin\01758000200\0",
            "refs/remotes/origin/main\0origin/main\01758000100\0",
            "refs/heads/agent/retry-plan\0agent/retry-plan\01758000000\0/w/retry",
        ].joined(separator: "\n")
        #expect(ChangesParse.branches(text, current: "agent/refund-events") == [
            ChangesBranch(name: "agent/refund-events", isRemote: false, isCurrent: true, committedAt: 1_758_000_300),
            ChangesBranch(name: "origin/main", isRemote: true, committedAt: 1_758_000_100),
            ChangesBranch(name: "agent/retry-plan", isRemote: false, worktree: "/w/retry", committedAt: 1_758_000_000),
        ])
    }

    @Test func commitsReadFromTheLogFormat() {
        let text = "a1c9f2e00\u{1F}a1c9f2e\u{1F}Emit refund events\u{1F}1758000000\u{1E}\n5d11a07aa\u{1F}5d11a07\u{1F}Codec: a | b\u{1F}1757999000\u{1E}\n"
        #expect(ChangesParse.commits(text) == [
            ChangesCommit(id: "a1c9f2e00", shortID: "a1c9f2e", subject: "Emit refund events", date: 1_758_000_000),
            ChangesCommit(id: "5d11a07aa", shortID: "5d11a07", subject: "Codec: a | b", date: 1_757_999_000),
        ])
    }

    @Test(arguments: [
        ("origin/main", "main"),
        ("origin/release/2.4", "release/2.4"),
        ("feat/ledger-v2", "feat/ledger-v2"),
        ("main", "main"),
    ])
    func aRemoteBranchIsNamedWithoutItsRemote(base: String, name: String) {
        #expect(ChangesParse.baseName(base, remotes: ["origin", "upstream"]) == name)
    }

    @Test(arguments: [
        ("Wrap errors with context", "Wrap errors with context"),
        ("  Fix it\nthen the tests", "Fix it"),
        (String(repeating: "x", count: 100), String(repeating: "x", count: 79) + "…"),
        ("", ""),
    ])
    func aTurnIsNamedByItsPromptsFirstLine(text: String, line: String) {
        #expect(ChangesParse.promptLine(text) == line)
    }

    @Test(arguments: [
        ("origin/main", true), ("a1c9f2e", true), ("feat/ledger-v2", true), ("HEAD~2", true),
        ("-", false), ("--output=/tmp/x", false), ("a..b", false), ("main next", false), ("", false), ("a\nb", false),
    ])
    func onlyPlainNamesReachGit(name: String, safe: Bool) {
        #expect(ChangesService.isSafeName(name) == safe)
    }

    // MARK: Turns

    static func record(_ state: ChangesTurn.State, files: Int, id: Int) -> TurnRecord {
        TurnRecord(turn: ChangesTurn(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!, startedAt: Double(id),
                                     state: state, fileCount: files), cwd: "/r", startTree: "aaaa", endTree: "bbbb")
    }

    struct UndoCase: Sendable, CustomTestStringConvertible {
        let states: [ChangesTurn.State]
        let files: [Int]
        let undo: [Bool]
        let redo: [Bool]
        var testDescription: String { states.map(\.rawValue).joined(separator: ", ") }
    }

    /// Undo only on the last turn, once it ended having changed something; Redo only on the
    /// last turn once undone.
    @Test(arguments: [
        UndoCase(states: [.ready, .ready], files: [3, 2], undo: [false, true], redo: [false, false]),
        UndoCase(states: [.ready, .undone], files: [3, 2], undo: [false, false], redo: [false, true]),
        UndoCase(states: [.undone, .running], files: [3, 0], undo: [false, false], redo: [false, false]),
        UndoCase(states: [.ready], files: [0], undo: [false], redo: [false]),
        UndoCase(states: [.unavailable], files: [4], undo: [false], redo: [false]),
    ])
    func undoAndRedoBelongToTheLastTurn(_ c: UndoCase) {
        let records = zip(c.states, c.files).enumerated().map { Self.record($0.element.0, files: $0.element.1, id: $0.offset) }
        let published = TurnStore.published(records)
        #expect(published.map(\.canUndo) == c.undo)
        #expect(published.map(\.canRedo) == c.redo)
    }

    /// The newest turn stays whatever it did; older turns that changed nothing go, and at most
    /// `ChangesLimits.turns` stay.
    @Test func prunedTurnsKeepTheNewestAndTheOnesThatChangedFiles() {
        let records = (0..<14).map { Self.record(.ready, files: $0 % 2, id: $0) } + [Self.record(.ready, files: 0, id: 99)]
        let kept = TurnStore.pruned(records)
        #expect(kept.last?.turn.startedAt == 99)
        #expect(kept.dropLast().allSatisfy { $0.turn.fileCount > 0 })
        #expect(kept.count == 8)
        #expect(TurnStore.pruned((0..<30).map { Self.record(.ready, files: 1, id: $0) }).count == ChangesLimits.turns)
    }

    @Test func aHugeFileIsCutAtItsLineLimit() throws {
        let lines = (0..<30).map { "+line \($0)" }.joined(separator: "\n")
        let file = try #require(DiffFile.parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1,30 @@\n\(lines)\n").first)
        let cut = ChangesService.truncated(file, lines: 12)
        #expect(cut.truncated && cut.file.hunks.flatMap(\.lines).count == 12)
        #expect(!ChangesService.truncated(file, lines: 30).truncated)
        let fitted = ChangesService.fitting(ChangesFileDiff(file: file), bytes: 1_200)
        let encoded = try JSONEncoder().encode(fitted)
        #expect(fitted.truncated && encoded.count <= 1_200)
    }
}
