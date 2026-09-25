import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// The review's messages, shared by the Mac and iOS: what Commit sends, and a line's comment.
@Suite("Review messages")
struct ReviewDiffTests {
    static let file = DiffFile.parse("""
    diff --git a/a.swift b/a.swift
    --- a/a.swift
    +++ b/a.swift
    @@ -1,2 +1,2 @@
     let a = 1
    -let b = 2
    +let b = 3
    """)[0]

    @Test func commitWithoutNotesAsksOnlyForTheCommit() {
        #expect(formatCommitRequest(files: [Self.file], comments: [], summary: " \n") == "Commit these changes.")
    }

    @Test func commitWithNotesCarriesTheReviewFirst() {
        let removed = Self.file.hunks[0].lines[1]
        let comment = ReviewComment(text: " keep b \n", line: removed, in: Self.file)
        #expect(formatCommitRequest(files: [Self.file], comments: [comment].compactMap { $0 }, summary: "") == """
        Commit these changes. Address the review below first.

        Diff review (working tree vs HEAD):

        a.swift:2 [- let b = 2]
          keep b
        """)
    }

    @Test(arguments: [(1, 2, "-"), (2, 2, "+"), (0, 1, " ")])
    func aLineCommentQuotesItsLineAndNumber(index: Int, number: Int, marker: String) throws {
        let line = Self.file.hunks[0].lines[index]
        let comment = try #require(ReviewComment(text: "note", line: line, in: Self.file))
        #expect(comment.lineNumber == number)
        #expect(comment.marker == marker)
        #expect(comment.content == line.text)
        #expect(comment.id == "a.swift:\(line.id)")
    }

    @Test func aBlankCommentIsNoComment() {
        #expect(ReviewComment(text: "  \n ", line: Self.file.hunks[0].lines[0], in: Self.file) == nil)
    }
}
