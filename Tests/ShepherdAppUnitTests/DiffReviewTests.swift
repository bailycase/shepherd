import Foundation
import Testing
@testable import ShepherdApp

/// Unified diff text → files, hunks, and numbered lines. Running git is the integration tier;
/// this is the parser alone, on fixture text.
@Suite("Git diff parsing")
struct GitDiffParseTests {
    @Test func aModificationKeepsBothSidesLineNumbers() throws {
        let file = try #require(GitDiff.parse("""
        diff --git a/file.txt b/file.txt
        index 1111111..2222222 100644
        --- a/file.txt
        +++ b/file.txt
        @@ -1,3 +1,4 @@ heading
         first
        -old
        +new
        +extra
         last
        """).first)

        #expect(file.oldPath == "file.txt" && file.newPath == "file.txt" && file.displayPath == "file.txt")
        #expect(!file.isNew && !file.isDeleted && !file.isRenamed && !file.isBinary)
        #expect(file.addedCount == 2 && file.removedCount == 1)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.header == "@@ -1,3 +1,4 @@ heading")
        #expect(hunk.lines.map(\.kind) == [.context, .removed, .added, .added, .context])
        #expect(hunk.lines.map(\.text) == ["first", "old", "new", "extra", "last"])
        #expect(hunk.lines.map(\.oldLine) == [1, 2, nil, nil, 3])
        #expect(hunk.lines.map(\.newLine) == [1, nil, 2, 3, 4])
    }

    @Test func aNewFileHasNoOldSide() throws {
        let file = try #require(GitDiff.parse("""
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..abcdef0
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +one
        +two
        """).first)

        #expect(file.oldPath == nil && file.newPath == "new.txt" && file.displayPath == "new.txt")
        #expect(file.isNew && !file.isDeleted)
        #expect(file.hunks.first?.lines.map(\.newLine) == [1, 2])
        #expect(file.hunks.first?.lines.map(\.oldLine) == [nil, nil])
    }

    @Test func aDeletedFileIsShownByItsOldPath() throws {
        let file = try #require(GitDiff.parse("""
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        --- a/old.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two
        """).first)

        #expect(file.oldPath == "old.txt" && file.newPath == nil && file.displayPath == "old.txt")
        #expect(file.isDeleted && !file.isNew)
        #expect(file.removedCount == 2)
        #expect(file.hunks.first?.lines.map(\.oldLine) == [1, 2])
    }

    @Test func aPureRenameHasNoHunks() throws {
        let file = try #require(GitDiff.parse("""
        diff --git a/old-name.txt b/new-name.txt
        similarity index 100%
        rename from old-name.txt
        rename to new-name.txt
        """).first)

        #expect(file.oldPath == "old-name.txt" && file.newPath == "new-name.txt" && file.displayPath == "new-name.txt")
        #expect(file.isRenamed && file.hunks.isEmpty)
    }

    @Test func binaryFilesAreFlaggedFromEitherGitSpelling() throws {
        let changed = try #require(GitDiff.parse("""
        diff --git a/image.bin b/image.bin
        index 1111111..2222222 100644
        Binary files a/image.bin and b/image.bin differ
        """).first)
        #expect(changed.isBinary && changed.hunks.isEmpty && changed.displayPath == "image.bin")

        let added = try #require(GitDiff.parse("""
        diff --git a/new.bin b/new.bin
        new file mode 100644
        GIT binary patch
        literal 0
        """).first)
        #expect(added.isBinary && added.isNew && added.oldPath == nil && added.newPath == "new.bin")
    }

    @Test func lineIDsAreUniqueAcrossTheFilesHunks() throws {
        let file = try #require(GitDiff.parse("""
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -2,2 +2,2 @@ first
         one
        -two
        +two changed
        @@ -10,1 +10,2 @@ second
         ten
        +eleven
        """).first)

        #expect(file.hunks.map { $0.lines.map(\.id) } == [[0, 1, 2], [3, 4]])
        #expect(file.hunks[1].lines.map(\.oldLine) == [10, nil])
        #expect(file.hunks[1].lines.map(\.newLine) == [10, 11])
        #expect(Set(file.hunks.map(\.id)).count == 2)
    }

    @Test func noNewlineMarkersAreNotLines() throws {
        let file = try #require(GitDiff.parse("""
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """).first)
        #expect(file.hunks.first?.lines.map(\.text) == ["old", "new"])
    }

    @Test func multipleFilesSplitOnTheirHeaders() {
        let files = GitDiff.parse("""
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -a
        +A
        diff --git a/b.txt b/b.txt
        --- a/b.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -b
        +B
        """)
        #expect(files.map(\.displayPath) == ["a.txt", "b.txt"])
        #expect(files.map(\.addedCount) == [1, 1])
    }

    /// Output without a `diff --git` header still parses from its ---/+++ markers, and CRLF
    /// line endings never leak `\r` into line text.
    @Test func headerlessDiffsAndCRLFLinesParse() throws {
        let file = try #require(GitDiff.parse("--- /dev/null\r\n+++ b/untracked.txt\r\n@@ -0,0 +1 @@\r\n+hello\r\n").first)
        #expect(file.displayPath == "untracked.txt" && file.isNew)
        #expect(file.hunks.first?.lines.map(\.text) == ["hello"])
    }

    @Test func quotedPathsLoseTheirQuotes() throws {
        let file = try #require(GitDiff.parse("""
        diff --git "a/with space.txt" "b/with space.txt"
        --- "a/with space.txt"
        +++ "b/with space.txt"
        @@ -1 +1 @@
        -x
        +y
        """).first)
        #expect(file.displayPath == "with space.txt")
    }

    @Test func emptyInputHasNoFiles() {
        #expect(GitDiff.parse("").isEmpty)
    }
}

@Suite("Review rows")
struct ReviewRowsTests {
    private func lines(_ kind: DiffLine.Kind, _ range: ClosedRange<Int>, idOffset: Int = 0) -> [DiffLine] {
        range.map { n in
            DiffLine(kind: kind, text: "line \(n)",
                     oldLine: kind == .added ? nil : n, newLine: kind == .removed ? nil : n, id: idOffset + n)
        }
    }

    private func folds(_ rows: [ReviewRow]) -> [(count: Int, kind: DiffLine.Kind, range: String)] {
        rows.compactMap { row in
            guard case .collapsed(_, let count, let kind, let range) = row.kind else { return nil }
            return (count, kind, range)
        }
    }

    /// More than eight changed lines in a row keep five at the head and one at the tail.
    @Test func aLongChangedRunFoldsItsMiddle() throws {
        let removed = lines(.removed, 20...32)
        let added = lines(.added, 1...3, idOffset: 100)
        let file = Fixture.diffFile("a.swift", hunks: [DiffHunk(header: "@@ -20,13 +1,3 @@", lines: removed + added)])

        let rows = reviewRows(file, expandedRuns: [])

        let fold = try #require(folds(rows).first)
        #expect(folds(rows).count == 1)
        #expect(fold.count == 7 && fold.kind == .removed && fold.range == "25–31")
        #expect(rows.count == 1 + 5 + 1 + 1 + 3)
        #expect(Set(rows.map(\.id)).count == rows.count, "row ids must be unique for ForEach")
    }

    /// Unchanged context folds more symmetrically: three lines each side.
    @Test func aLongContextRunKeepsThreeLinesEachSide() throws {
        let file = Fixture.diffFile("a.swift", hunks: [DiffHunk(header: "@@ -1,12 +1,12 @@", lines: lines(.context, 1...12))])
        let fold = try #require(folds(reviewRows(file, expandedRuns: [])).first)
        #expect(fold.count == 6 && fold.range == "4–9")
    }

    @Test func runsAtTheThresholdStayWhole() {
        let file = Fixture.diffFile("a.swift", hunks: [DiffHunk(header: "@@ -1,8 +0,0 @@", lines: lines(.removed, 1...8))])
        #expect(folds(reviewRows(file, expandedRuns: [])).isEmpty)
    }

    @Test func expandingAFoldShowsEveryLine() throws {
        let file = Fixture.diffFile("a.swift", hunks: [DiffHunk(header: "@@ -1,13 +0,0 @@", lines: lines(.removed, 1...13))])
        let key = try #require(reviewRows(file, expandedRuns: []).compactMap { row -> String? in
            if case .collapsed(let key, _, _, _) = row.kind { return key }
            return nil
        }.first)

        #expect(reviewRows(file, expandedRuns: [key]).count == 1 + 13)
        #expect(reviewRows(file, expandedRuns: nil).count == 1 + 13, "nil expands everything")
    }

    @Test func everyHunkStartsWithItsHeaderRow() {
        let file = Fixture.diffFile("a.swift", hunks: [
            DiffHunk(header: "@@ -1 +1 @@", lines: lines(.added, 1...1)),
            DiffHunk(header: "@@ -9 +9 @@", lines: lines(.added, 9...9)),
        ])
        let headers = reviewRows(file, expandedRuns: nil).compactMap { row -> String? in
            if case .hunk(let header) = row.kind { return header }
            return nil
        }
        #expect(headers == ["@@ -1 +1 @@", "@@ -9 +9 @@"])
    }
}

/// A tool call reports an absolute or cwd-relative path; diff paths are repository-relative.
@Suite("Review file matching")
struct ReviewFileMatchingTests {
    private let files = [Fixture.diffFile("Sources/App.swift"), Fixture.diffFile("README.md")]

    @Test(arguments: [
        ("Sources/App.swift", "Sources/App.swift"),
        ("/Users/me/repo/Sources/App.swift", "Sources/App.swift"),
        ("App.swift", "Sources/App.swift"),
        ("README.md", "README.md"),
        ("pp.swift", nil),
        ("Other.swift", nil),
    ] as [(String, String?)])
    func pathsMatchExactlyOrOnAPathComponentBoundary(path: String, match: String?) {
        #expect(reviewFile(matching: path, in: files)?.id == match)
    }
}

/// The review the agent receives: every comment with its line for context, in file order.
@Suite("Review formatting")
@MainActor
struct ReviewFormattingTests {
    @Test func commentsFollowFileThenLineOrderWithTheirDiffLine() {
        let files = [Fixture.diffFile("Sources/Foo.swift"), Fixture.diffFile("Sources/Bar.swift")]
        let comments = [
            ReviewComment(fileID: "Sources/Bar.swift", lineID: 0, filePath: "Sources/Bar.swift", lineNumber: 7,
                          marker: "-", content: "old", text: "remove this branch"),
            ReviewComment(fileID: "Sources/Foo.swift", lineID: 3, filePath: "Sources/Foo.swift", lineNumber: 42,
                          marker: "+", content: "let x = 1", text: "prefer a named constant\nand document it"),
            ReviewComment(fileID: "Sources/Foo.swift", lineID: 1, filePath: "Sources/Foo.swift", lineNumber: 2,
                          marker: " ", content: "import Foo", text: "   "),
        ]

        #expect(formatReview(files: files, comments: comments, summary: "  ship it \n") == """
        Diff review (working tree vs HEAD):

        Sources/Foo.swift:42 [+ let x = 1]
          prefer a named constant
          and document it

        Sources/Bar.swift:7 [- old]
          remove this branch

        Overall: ship it
        """)
    }

    @Test func aReviewWithoutCommentsSaysSo() {
        #expect(formatReview(files: [], comments: [], summary: "looks good") == """
        Diff review (working tree vs HEAD):

        No line comments.

        Overall: looks good
        """)
    }

    @Test func theHeaderNamesTheReferenceAndABlankSummaryIsOmitted() {
        #expect(formatReview(files: [], comments: [], summary: " \n", reference: "main..HEAD") == """
        Diff review (main..HEAD):

        No line comments.
        """)
    }

    @Test(arguments: [(DiffLine.Kind.context, " "), (.added, "+"), (.removed, "-")])
    func lineKindsMapToUnifiedDiffMarkers(kind: DiffLine.Kind, marker: String) {
        #expect(kind.reviewMarker == marker)
    }
}
