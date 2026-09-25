import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote

@Suite("Changes presentation")
struct ChangesPresentationTests {
    static func comment(_ path: String, line: Int, _ text: String) -> ReviewComment {
        ReviewComment(fileID: path, lineID: line, filePath: path, lineNumber: line, marker: "+", content: "code", text: text)
    }

    @Test(arguments: [(1, "Send 1 comment"), (3, "Send 3 comments")])
    func theSendButtonCountsComments(count: Int, title: String) {
        #expect(reviewSendTitle(comments: count) == title)
    }

    @Test func theSendBarNamesTheFileOrCountsFiles() {
        let one = [Self.comment("ledger/outbox.go", line: 103, "Wrap it")]
        #expect(reviewPendingText(one) == ("1 comment", "on outbox.go, not sent yet"))
        let two = one + [Self.comment("ledger/refund.go", line: 3, "Name it")]
        #expect(reviewPendingText(two) == ("2 comments", "on 2 files, not sent yet"))
    }

    /// Comments go in the pane's file order, under the scope they were written against, with no
    /// overall comment.
    @Test func theReviewIsTheCommentsInFileOrderUnderTheScope() {
        let comments = [Self.comment("b.go", line: 2, "second"), Self.comment("a.go", line: 9, "first")]
        #expect(formatChangesReview(fileIDs: ["a.go", "b.go"], comments: comments, scopeTitle: "Branch · vs main") == """
        Diff review (Branch · vs main):

        a.go:9 [+ code]
          first

        b.go:2 [+ code]
          second
        """)
    }

    @Test func aRecordedTurnBecomesTheCard() throws {
        let turn = ChangesTurn(messageTimestamp: 42, startedAt: 1, state: .ready,
                               files: [ChangesFile(path: "ledger/outbox.go", status: .modified, added: 9, removed: 3),
                                       ChangesFile(path: "ledger/refund.go", status: .added, added: 3, removed: 0),
                                       ChangesFile(path: "codec.go", oldPath: "json.go", status: .renamed, added: 0, removed: 0)],
                               fileCount: 5, added: 12, removed: 3)
        let card = try #require(NativeTurnChanges(turn: turn))
        #expect(card.files.map(\.status) == [.modified, .added, .modified])
        #expect(card.files.first?.directory == "ledger/" && card.files.first?.name == "outbox.go")
        #expect(card.added == 12 && card.removed == 3)
        #expect(card.title == "Edited 5 files" && card.fileCount == 5 && card.turnID == turn.id, "every file counts, three listed")
        var undone = turn
        undone.state = .undone
        undone.canRedo = true
        let after = try #require(NativeTurnChanges(turn: undone))
        #expect(after.undone && after.canRedo && after.title == "Undid the agent’s edits to 5 files")
        #expect(NativeTurnChanges(turn: ChangesTurn(startedAt: 1, state: .ready)) == nil)
        #expect(changesTurn(forMessageAt: 42, in: [turn])?.id == turn.id)
        #expect(changesTurn(forMessageAt: 41, in: [turn]) == nil)
    }
}
