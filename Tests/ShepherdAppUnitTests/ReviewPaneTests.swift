import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Two files: `a.go` with a context line, a removal, and an addition in each of two hunks, and a
/// new `b.txt`.
private enum ReviewSample {
    static let files = GitDiff.parse(diff)
    static let diff = """
    diff --git a/a.go b/a.go
    --- a/a.go
    +++ b/a.go
    @@ -1,2 +1,2 @@ first
     package main
    -var x = 1
    +var x = 2
    @@ -20,2 +20,2 @@ second
     func f() {}
    -var y = "old"
    +var y = "new"
    diff --git a/b.txt b/b.txt
    new file mode 100644
    --- /dev/null
    +++ b/b.txt
    @@ -0,0 +1 @@
    +hello
    """

    static func lines(_ kind: DiffLine.Kind, _ range: ClosedRange<Int>) -> [DiffLine] {
        range.map { DiffLine(kind: kind, text: "line \($0)", oldLine: kind == .added ? nil : $0, newLine: kind == .removed ? nil : $0, id: $0) }
    }

    @MainActor
    static func model(files: [DiffFile] = files, actions: ReviewActions? = nil) -> ReviewPaneModel {
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp/repo", reference: nil, files: files)
        return ReviewPaneModel(session: session, actions: actions ?? ReviewActions(setPullRequest: { _ in }, requestChanges: {}, commit: {}, close: {}))
    }
}

@Suite("Review diff rows")
struct ReviewDiffRowTests {
    /// Lines keep their ids and numbers, and take their colors from the highlight when it has
    /// them; folds and hunk headers carry through.
    @Test func linesTakeTheirHighlightedTextAndEverythingElseCarriesThrough() throws {
        let file = Fixture.diffFile("a.swift", hunks: [DiffHunk(header: "@@ -1,13 +0,0 @@", lines: ReviewSample.lines(.removed, 1...13))])
        var colored = AttributedString("line 1")
        colored.foregroundColor = .red

        let rows = diffRows(reviewRows(file, expandedRuns: []), highlight: [1: colored])

        #expect(rows.map(\.id) == reviewRows(file, expandedRuns: []).map(\.id))
        guard case .hunk(_, let header) = rows[0] else { Issue.record("expected the hunk header first"); return }
        #expect(header == "@@ -1,13 +0,0 @@")
        guard case .line(let first) = rows[1], case .line(let second) = rows[2] else { Issue.record("expected lines"); return }
        #expect(first.text == colored && first.key == 1 && first.kind == .removed && first.oldNumber == 1 && first.newNumber == nil)
        #expect(second.text == AttributedString("line 2") && second.source == "line 2", "no highlight yet: plain text")
        let fold = try #require(rows.first { if case .fold = $0 { true } else { false } })
        guard case .fold(_, let count, let kind, let range) = fold else { return }
        #expect(count == 7 && kind == .removed && range == "6–12")
    }

    @Test(arguments: [
        (false, false, false, NWFileStatus.modified), (true, false, false, .added), (false, true, false, .deleted), (false, false, true, .renamed),
    ])
    func filesMapToTheirStatusLetter(isNew: Bool, isDeleted: Bool, isRenamed: Bool, status: NWFileStatus) {
        let file = DiffFile(oldPath: "a", newPath: "a", displayPath: "a", isNew: isNew, isDeleted: isDeleted, isRenamed: isRenamed,
                            isBinary: false, hunks: [])
        #expect(file.reviewStatus == status)
    }

    @Test(arguments: [(DiffLine.Kind.context, NWDiffLineKind.context), (.added, .added), (.removed, .removed)])
    func lineKindsMapToTheirDiffKind(kind: DiffLine.Kind, diffKind: NWDiffLineKind) {
        #expect(kind.diffKind == diffKind)
    }

    @Test(arguments: [(0.0, "just now"), (59, "just now"), (60, "1m ago"), (3599, "59m ago")])
    func aCommentsAgeReadsRelativelyForAnHour(seconds: Double, text: String) {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(reviewCommentAge(now.addingTimeInterval(-seconds), now: now) == text)
    }

    @Test func anOlderCommentShowsItsClockTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let written = now.addingTimeInterval(-7200)
        #expect(reviewCommentAge(written, now: now) == nativeClockText(written.timeIntervalSince1970 * 1000))
    }
}

@Suite("Review session")
@MainActor
struct ReviewSessionTests {
    private func comment(_ file: String, _ line: Int, _ text: String) -> ReviewComment {
        ReviewComment(fileID: file, lineID: line, filePath: file, lineNumber: line, text: text)
    }

    @Test func commentsAreIndexedByFileThenLine() {
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp", reference: nil,
                                    comments: [comment("a", 1, "one"), comment("a", 4, "four"), comment("b", 1, "bee")])
        #expect(session.commentsByFile["a"]?.mapValues(\.text) == [1: "one", 4: "four"])
        #expect(session.commentsByFile["b"]?[1]?.text == "bee")
        #expect(session.commentsByFile["c"] == nil)
    }

    @Test func settingACommentReplacesTheLinesCommentAndNilRemovesIt() {
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp", reference: nil, comments: [comment("a", 1, "one")])
        session.setComment(comment("a", 1, "edited"), fileID: "a", lineID: 1)
        #expect(session.comments.map(\.text) == ["edited"])
        session.setComment(nil, fileID: "a", lineID: 1)
        #expect(session.comments.isEmpty && session.commentsByFile.isEmpty)
    }

    @Test func totalsFollowTheFiles() {
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp", reference: nil, files: ReviewSample.files)
        #expect(session.addedCount == 3 && session.removedCount == 2)
        session.files = []
        #expect(session.addedCount == 0 && session.removedCount == 0)
    }
}

@Suite("Review pane model")
@MainActor
struct ReviewPaneModelTests {
    @Test func nAndPStepThroughFilesByAskingTheDiffToScroll() {
        let model = ReviewSample.model()
        let before = model.session.focusRequest
        #expect(model.handleKey("n"))
        #expect(model.session.focusFile == "b.txt" && model.session.focusRequest != before)
        #expect(model.takeFocusRequest() == "b.txt")
        #expect(model.currentFile == "b.txt" && model.session.focusFile == nil)
        #expect(model.handleKey("n") && model.takeFocusRequest() == "b.txt", "the last file stays put")
        #expect(model.handleKey("p") && model.takeFocusRequest() == "a.go")
    }

    @Test func jAndKWalkEveryHunkAcrossFiles() {
        let model = ReviewSample.model()
        let hunks = ReviewSample.files.flatMap { file in file.hunks.map { "\(file.id)\u{0}\($0.id)" } }
        for expected in hunks { #expect(model.handleKey("j") && model.currentHunk == expected) }
        #expect(model.handleKey("j") && model.currentHunk == hunks.last, "the last hunk stays put")
        #expect(model.currentFile == "b.txt")
        #expect(model.handleKey("k") && model.currentHunk == hunks[1] && model.currentFile == "a.go")
    }

    @Test func vTogglesTheCurrentFileViewedWhichFoldsIt() {
        let model = ReviewSample.model()
        model.currentFile = "a.go"
        #expect(model.handleKey("v"))
        #expect(model.session.viewed == ["a.go"] && model.isFolded("a.go"))
        model.toggleFolded("a.go")
        #expect(!model.isFolded("a.go") && model.session.viewed.isEmpty, "unfolding a viewed file unmarks it")
    }

    @Test func cCommentsOnTheCurrentHunksFirstChangedLine() throws {
        let model = ReviewSample.model()
        #expect(model.handleKey("j") && model.handleKey("j"))
        #expect(model.handleKey("c"))
        let second = try #require(ReviewSample.files.first?.hunks.last)
        #expect(model.editing == ReviewSession.CommentKey(fileID: "a.go", lineID: try #require(second.lines.first { $0.kind != .context }).id))
    }

    @Test func otherKeysAndAnEmptyDiffAreNotHandled() {
        #expect(!ReviewSample.model().handleKey("x"))
        #expect(!ReviewSample.model(files: []).handleKey("j"))
    }

    @Test func savingACommentRecordsItsLineAndBlankTextRemovesIt() throws {
        let model = ReviewSample.model()
        let line = try #require(ReviewSample.files.first?.hunks.first?.lines.first { $0.kind == .added })
        model.startComment(fileID: "a.go", lineID: line.id)

        model.saveComment("  name this  ", fileID: "a.go", lineID: line.id)

        let comment = try #require(model.session.comments.first)
        #expect(model.editing == nil)
        #expect(comment.text == "name this" && comment.lineNumber == 2 && comment.marker == "+" && comment.content == "var x = 2")
        model.saveComment(" ", fileID: "a.go", lineID: line.id)
        #expect(model.session.comments.isEmpty)
    }

    @Test func deletingTheCommentBeingEditedClosesTheEditor() {
        let model = ReviewSample.model()
        model.session.comments = [ReviewComment(fileID: "a.go", lineID: 1, filePath: "a.go", lineNumber: 1, text: "x")]
        model.startComment(fileID: "a.go", lineID: 1)
        model.deleteComment(fileID: "a.go", lineID: 1)
        #expect(model.session.comments.isEmpty && model.editing == nil)
    }

    /// A file's rows are built once per state: the same array until its folds change.
    @Test func rowsAreReusedUntilAFoldOpens() throws {
        let file = Fixture.diffFile("a.txt", hunks: [DiffHunk(header: "@@ -1,13 +0,0 @@", lines: ReviewSample.lines(.removed, 1...13))])
        let model = ReviewSample.model(files: [file])
        let first = model.rows(for: file)
        #expect(first.withUnsafeBufferPointer { a in model.rows(for: file).withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } })
        let fold = try #require(first.first { if case .fold = $0 { true } else { false } })

        model.expandFold(fold.id, in: file.id)

        #expect(model.rows(for: file).count == 1 + 13)
    }

    @Test func optionClickingAFoldOpensTheWholeFile() {
        let lines = ReviewSample.lines(.removed, 1...13) + ReviewSample.lines(.context, 20...32)
        let file = Fixture.diffFile("a.txt", hunks: [DiffHunk(header: "@@ -1,26 +1,13 @@", lines: lines)])
        let model = ReviewSample.model(files: [file])
        model.expandFile(file.id)
        #expect(model.rows(for: file).count == 1 + 26)
    }

    @Test func expandAndCollapseAllFoldEveryFileOrNone() {
        let model = ReviewSample.model()
        model.collapseAllFiles()
        #expect(model.isFolded("a.go") && model.isFolded("b.txt"))
        model.session.viewed = ["a.go"]
        model.expandAllFiles()
        #expect(!model.isFolded("a.go") && !model.isFolded("b.txt") && model.session.viewed.isEmpty)
    }

    @Test func aFocusRequestMatchesAToolsAbsolutePathAndUnfoldsTheFile() {
        let model = ReviewSample.model()
        model.collapseAllFiles()
        model.session.focusFile = "/tmp/repo/b.txt"
        #expect(model.takeFocusRequest() == "b.txt")
        #expect(!model.isFolded("b.txt") && model.isFolded("a.go"))
        model.session.focusFile = "elsewhere.txt"
        #expect(model.takeFocusRequest() == nil)
    }

    @Test func thePRControlAsksTheHostToReload() {
        var requested: [Bool] = []
        let model = ReviewSample.model(actions: ReviewActions(setPullRequest: { requested.append($0) }, requestChanges: {}, commit: {}, close: {}))
        model.pullRequestMode = true
        #expect(requested == [true] && !model.session.isPRMode, "the mode flips once the host reloads")
    }

    /// Syntax colors arrive per file, keyed by line id; files without a grammar get none.
    @Test func highlightingColorsEachLineOfASupportedFile() async throws {
        let model = ReviewSample.model()
        let style = CodeHighlight.Style.theme
        await model.highlightFiles(style: style)

        #expect(model.highlights["b.txt"] == nil)
        let highlight = try #require(model.highlights["a.go"])
        let lines = ReviewSample.files[0].hunks.flatMap(\.lines)
        #expect(Set(highlight.lines.keys) == Set(lines.map(\.id)))
        let keyword = try #require(highlight.lines[lines[1].id])
        #expect(keyword.runs.contains { $0.foregroundColor == style.keyword })
        guard case .line(let row)? = model.rows(for: ReviewSample.files[0]).first(where: { $0.id.hasSuffix("l\(lines[1].id)") }) else {
            Issue.record("expected the line's row"); return
        }
        #expect(row.text == keyword, "rows pick the colors up")
    }

    /// Reloading (after a revert, or a repeated review request) keeps what did not change.
    @Test func aReloadKeepsTheColorsOfUnchangedFilesAndDropsChangedOnes() async throws {
        let model = ReviewSample.model()
        await model.highlightFiles(style: .theme)
        let colored = model.rows(for: ReviewSample.files[0])

        model.session.files = GitDiff.parse(ReviewSample.diff)
        #expect(model.rows(for: model.session.files[0]) == colored, "same content: same rows, colors and all")
        await model.highlightFiles(style: .theme)
        #expect(model.highlights["a.go"]?.version == model.session.filesVersion)

        model.session.files = GitDiff.parse(ReviewSample.diff.replacingOccurrences(of: "var x = 2", with: "const x = 2"))
        let changed = model.rows(for: model.session.files[0])
        #expect(changed != colored)
        #expect(changed.allSatisfy { row in
            guard case .line(let line) = row else { return true }
            return line.text.runs.allSatisfy { $0.foregroundColor == nil }
        }, "stale colors never show on changed content")
    }
}
