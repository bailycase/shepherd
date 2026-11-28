import Foundation
import ShepherdProtocol
import ShepherdRemote
import Testing
@testable import ShepherdApp

/// The Files tab's view of the thread's changes (GXPaneFiles): letters in the tree, the footer's note, the line under the path.
@Suite("File changes")
struct FileChangesTests {
    private static func file(_ path: String, isNew: Bool = false, added: [Int] = []) -> DiffFile {
        let lines = added.map { DiffLine(kind: .added, text: "x", oldLine: nil, newLine: $0, id: $0) }
        return DiffFile(oldPath: isNew ? nil : path, newPath: path, displayPath: path, isNew: isNew, isDeleted: false,
                        isRenamed: false, isBinary: false, hunks: [DiffHunk(header: "@@", lines: lines)])
    }

    private static let changes = FileChanges(files: [
        "ledger/codec.go": file("ledger/codec.go", isNew: true, added: Array(8...18)),
        "ledger/outbox.go": file("ledger/outbox.go", added: [30]),
    ], isLastTurn: true)

    @Test func lettersFollowTheDiffForFilesUnderTheTreesRoot() {
        let changes = Self.changes
        #expect(changes.letter(at: "/work/payments/ledger/codec.go", root: "/work/payments") == .added)
        #expect(changes.letter(at: "/work/payments/ledger/outbox.go", root: "/work/payments/") == .modified)
        #expect(changes.letter(at: "/work/payments/ledger/refund.go", root: "/work/payments") == nil, "an unchanged file has no letter")
        #expect(changes.letter(at: "/elsewhere/ledger/codec.go", root: "/work/payments") == nil, "outside the tree's root")
        #expect(FileChanges(files: nil, isLastTurn: false).letter(at: "/work/payments/ledger/codec.go", root: "/work/payments") == nil, "still loading")
    }

    @Test func theFooterSaysWhereTheFilesAreAndHowManyChanged() {
        #expect(Self.changes.note(agentFile: nil) == "The thread\u{2019}s worktree on This Mac, live. 2 changed.")
        #expect(FileChanges(host: "build-01", files: nil, isLastTurn: false).note(agentFile: nil) == "The thread\u{2019}s worktree on build-01, live.")
        #expect(Self.changes.note(agentFile: "/work/payments/ledger/codec.go")
                == "The agent is editing codec.go. Your edits stay yours until you save.")
    }

    @Test func theLineUnderThePathNamesTheChangeAndTheGreenLines() throws {
        let codec = try #require(Self.changes.files?["ledger/codec.go"])
        #expect(Self.changes.subtitle(for: codec, lines: 25, language: "Go", marksLines: true)
                == "Added by this thread, 25 lines, Go. Green lines changed in the last turn.")
        let outbox = try #require(Self.changes.files?["ledger/outbox.go"])
        let other = FileChanges(files: Self.changes.files, isLastTurn: false)
        #expect(other.subtitle(for: outbox, lines: 1, language: nil, marksLines: false) == "Changed by this thread, 1 line.")
        #expect(FileChanges.addedLines(of: codec) == Set(8...18))
    }

    /// Every realized tree row asks for its letter, and every body pass of the Files tab for the open file's added lines:
    /// a thread with thousands of changed files still draws the tree in the time it took without them.
    @Test(.timingSensitive) func lookingUpLettersForAThousandRowsCostsLittle() {
        var files: [String: DiffFile] = [:]
        for index in 0..<5_000 { files["src/module\(index / 50)/file\(index).swift"] = Self.file("src/module\(index / 50)/file\(index).swift") }
        let changes = FileChanges(files: files, isLastTurn: false)
        let rows = (0..<1_000).map { "/work/app/src/module\($0 / 50)/file\($0).swift" }
        let time = (0..<5).map { _ in
            ContinuousClock().measure { for row in rows { _ = changes.letter(at: row, root: "/work/app") } }
        }.min() ?? .zero
        #expect(rows.allSatisfy { changes.letter(at: $0, root: "/work/app") == .modified })
        #expect(time < .milliseconds(10), "1,000 rows took \(time) against 5,000 changed files")
    }
}
