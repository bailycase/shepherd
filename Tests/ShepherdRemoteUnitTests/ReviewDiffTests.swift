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

    static func file(_ path: String, new: Bool = false, deleted: Bool = false, from old: String? = nil) -> DiffFile {
        DiffFile(oldPath: old ?? path, newPath: path, displayPath: path, isNew: new, isDeleted: deleted,
                 isRenamed: old != nil, isBinary: false, hunks: [])
    }

    @Test func commitWithoutNotesNamesEveryFileUnderReview() {
        let files = [Self.file, Self.file("NOTES.md", new: true), Self.file("old.txt", deleted: true),
                     Self.file("Sources/b.swift", from: "Sources/a.swift")]
        #expect(formatCommitRequest(files: files, comments: [], summary: " \n") == """
        Commit these changes:
        - a.swift
        - NOTES.md (new)
        - old.txt (deleted)
        - Sources/b.swift (renamed from Sources/a.swift)
        """)
    }

    @Test func commitWithNotesNamesTheFilesThenCarriesTheReview() {
        let removed = Self.file.hunks[0].lines[1]
        let comment = ReviewComment(text: " keep b \n", line: removed, in: Self.file)
        #expect(formatCommitRequest(files: [Self.file], comments: [comment].compactMap { $0 }, summary: "") == """
        Commit these changes:
        - a.swift

        Before committing, address the review below.

        Diff review (working tree vs HEAD):

        a.swift:2 [- let b = 2]
          keep b
        """)
    }

    @Test func aLongCommitRequestCountsTheFilesPastItsLimit() {
        let files = (0..<(reviewCommitRequestFileLimit + 3)).map { Self.file("f\($0).txt") }
        let lines = formatCommitRequest(files: files, comments: [], summary: "").components(separatedBy: "\n")
        #expect(lines.count == reviewCommitRequestFileLimit + 2)
        #expect(lines.last == "- and 3 more")
    }

    @Test func aCommitRequestWithNoFilesStillAsks() {
        #expect(formatCommitRequest(files: [], comments: [], summary: "") == "Commit these changes.")
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
