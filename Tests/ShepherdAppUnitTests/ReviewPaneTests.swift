import Foundation
import ShepherdCore
import ShepherdProtocol
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

    /// The header names the reviewed directory only when it is not the agent's own; a remote
    /// review (no agent directory) never does.
    @Test(arguments: [
        ("/src/app", "/src/app", nil),
        ("/src/app/", "/src/app", nil),
        ("/src/app-worktree", "/src/app", "app-worktree"),
        ("/src/app/sub", "/src/app", "sub"),
        ("/src/other", nil, nil),
    ] as [(String, String?, String?)])
    func aReviewOfAnotherDirectoryNamesIt(cwd: String, agentCwd: String?, name: String?) {
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: cwd, agentCwd: agentCwd, reference: nil)
        #expect(session.otherDirectoryName == name)
        session.retarget(cwd: "/src/elsewhere")
        #expect(session.otherDirectoryName == (agentCwd == nil ? nil : "elsewhere"))
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
    @Test func jAndKStepThroughFilesByAskingTheDiffToScroll() {
        let model = ReviewSample.model()
        let before = model.session.focusRequest
        #expect(model.handleKey("j"))
        #expect(model.session.focusFile == "b.txt" && model.session.focusRequest != before)
        #expect(model.takeFocusRequest() == "b.txt")
        #expect(model.currentFile == "b.txt" && model.session.focusFile == nil)
        #expect(model.handleKey("j") && model.takeFocusRequest() == "b.txt", "the last file stays put")
        #expect(model.handleKey("k") && model.takeFocusRequest() == "a.go")
    }

    /// n/p walk every change across files: each run of changed rows, by its first row.
    @Test func nAndPWalkEveryChangeAcrossFiles() {
        let model = ReviewSample.model()
        let changes = ReviewSample.files.flatMap { file in model.changes(in: file).map { (file.id, $0.row) } }
        #expect(changes.count == 3, "two in a.go, one in b.txt")
        for (file, row) in changes { #expect(model.handleKey("n") && model.currentChange == row && model.currentFile == file) }
        #expect(model.handleKey("n") && model.currentChange == changes.last?.1, "the last change stays put")
        #expect(model.handleKey("p") && model.currentChange == changes[1].1 && model.currentFile == "a.go")
    }

    @Test func optionUSwitchesTheLayoutAndKeepsTheChoice() {
        let model = ReviewSample.model()
        model.noteWidth(1200)
        #expect(model.layout == .split, "900pt and up is split")
        #expect(model.handleKey("u", option: true) && model.layout == .unified)
        model.noteWidth(1400)
        #expect(model.layout == .unified, "the reader's choice holds at any width")
        #expect(!model.handleKey("x", option: true))
    }

    @Test func vTogglesTheCurrentFileViewedWhichFoldsIt() {
        let model = ReviewSample.model()
        model.currentFile = "a.go"
        #expect(model.handleKey("v"))
        #expect(model.session.viewed == ["a.go"] && model.isFolded("a.go"))
        model.toggleFolded("a.go")
        #expect(!model.isFolded("a.go") && model.session.viewed.isEmpty, "unfolding a viewed file unmarks it")
    }

    @Test func cCommentsOnTheCurrentChangesFirstChangedLine() throws {
        let model = ReviewSample.model()
        #expect(model.handleKey("n") && model.handleKey("n"))
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

    /// A file's rows are built once per state: the same array until a fold opens.
    @Test func rowsAreReusedUntilAFoldOpens() throws {
        let lines = ReviewSample.lines(.context, 1...20) + [DiffLine(kind: .added, text: "new", oldLine: nil, newLine: 21, id: 100)]
            + ReviewSample.lines(.context, 21...40).map { DiffLine(kind: .context, text: $0.text, oldLine: $0.oldLine, newLine: ($0.newLine ?? 0) + 1, id: $0.id) }
        let file = Fixture.diffFile("a.txt", hunks: [DiffHunk(header: "@@ -1,40 +1,41 @@", lines: lines)])
        let model = ReviewSample.model(files: [file])
        let first = model.rows(for: file)
        #expect(first.withUnsafeBufferPointer { a in model.rows(for: file).withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } })
        let fold = try #require(first.first { if case .fold = $0 { true } else { false } })

        model.reveal(fold.id, .all, in: file.id)

        #expect(model.rows(for: file).count > first.count)
    }

    /// Lines between hunks came without the diff: opening their fold fetches the file whole.
    @Test func openingAFoldBetweenHunksFetchesTheFileWhole() throws {
        var fetched: [String] = []
        var actions = ReviewActions(setPullRequest: { _ in }, requestChanges: {}, commit: {}, close: {})
        actions.loadWholeFile = { fetched.append($0) }
        let model = ReviewSample.model(actions: actions)
        let fold = try #require(model.rows(for: ReviewSample.files[0]).first { if case .fold = $0 { true } else { false } })
        model.reveal(fold.id, .down, in: "a.go")
        #expect(fetched == ["a.go"])
        #expect(model.revealed["a.go"] == IndexSet(integersIn: 3..<20), "the 20 lines at its top edge, as far as the fold goes")
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

        #expect(model.highlights["b.txt"]?.lines.isEmpty == true, "no grammar: word diffs only")
        let highlight = try #require(model.highlights["a.go"])
        let lines = ReviewSample.files[0].hunks.flatMap(\.lines)
        #expect(Set(highlight.lines.keys) == Set(lines.map(\.id)))
        let keyword = try #require(highlight.lines[lines[1].id])
        #expect(keyword.runs.contains { $0.foregroundColor == style.keyword })
        guard case .line(let row)? = model.rows(for: ReviewSample.files[0]).first(where: { $0.id.hasSuffix("\u{0}\(lines[1].id)") }) else {
            Issue.record("expected the line's row"); return
        }
        #expect(row.text.runs.map(\.foregroundColor) == keyword.runs.map(\.foregroundColor), "rows pick the colors up")
        // The changed word ("1" became "2") sits on a second layer of the line's tint.
        let tinted = row.text.runs.filter { $0.backgroundColor != nil }.map { String(row.text[$0.range].characters) }
        #expect(tinted == ["1"])
        model.session.wordDiffs = false
        guard case .line(let plain)? = model.rows(for: ReviewSample.files[0]).first(where: { $0.id == row.id }) else { return }
        #expect(plain.text == keyword, "without word diffs, just the colors")
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

@Suite("Review touched paths")
@MainActor
struct ReviewTouchedPathsTests {
    private func message(_ id: String, _ role: String, tool: String? = nil, path: String? = nil) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: role, blocks: [], toolName: tool, argumentsText: path.map { #"{"path":"\#($0)"}"# })
    }

    private var turn: [NativeThreadMessage] {
        [message("u1", "user"), message("t1", "toolResult", tool: "edit", path: "a.swift"),
         message("t2", "toolResult", tool: "read", path: "b.swift"), message("t3", "toolResult", tool: "write", path: "c.swift")]
    }

    @Test func theRunningTurnsEditsAndWritesAreTouched() {
        let touched = ReviewTouchedPaths()
        #expect(touched.paths(turn, running: true) == nativeTouchedPaths(turn, running: true))
        #expect(touched.paths(turn, running: true) == ["a.swift", "c.swift"])
        #expect(touched.paths(turn, running: false).isEmpty)
    }

    /// The host re-renders on every thread publish; only a change to the turn's edit and write
    /// calls reparses their arguments.
    @Test func argumentsAreReparsedOnlyWhenTheTurnsEditsChange() {
        var parses = 0
        let touched = ReviewTouchedPaths { messages, running in
            parses += 1
            return nativeTouchedPaths(messages, running: running)
        }
        var messages = turn
        _ = touched.paths(messages, running: true)
        _ = touched.paths(messages, running: true)
        messages.append(message("a1", "assistant"))
        _ = touched.paths(messages, running: true)
        #expect(parses == 1, "an unchanged turn, or new prose, reuses the paths")

        messages.append(message("t4", "toolResult", tool: "edit", path: "d.swift"))
        #expect(touched.paths(messages, running: true).contains("d.swift"))
        messages[messages.count - 1].argumentsText = #"{"path":"e.swift"}"#
        #expect(touched.paths(messages, running: true).contains("e.swift"))
        #expect(parses == 3)

        _ = touched.paths(messages, running: false)
        _ = touched.paths(messages, running: true)
        #expect(parses == 4, "a new run starts fresh")
    }
}
