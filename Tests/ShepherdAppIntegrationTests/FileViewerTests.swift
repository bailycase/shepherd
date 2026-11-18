import Foundation
import ShepherdProtocol
import ShepherdRemote
import AppKit
import ShepherdTestSupport
import ShepherdUI
import Testing
@testable import ShepherdSessions
@testable import ShepherdApp

/// The changes card's file viewer (OutsideFileE): what git shows for a file in its own repository, and which lines the
/// viewer marks as the change's.
@Suite("File viewer", .integrationTimeLimit)
struct FileViewerTests {
    @Test func gitShowsUncommittedEditsThenTheLastCommitThenAnUntrackedFileWhole() throws {
        let repo = try makeScratchRepo(files: ["docs/README.md": "a\nb\nc\nd\ne\nf\ng\nh\n"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let readme = repo.appendingPathComponent("docs/README.md").path
        let initial = try git(["log", "-1", "--format=%h"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(GitDiff.fileChange(path: readme)?.source == .commit(shortID: initial, subject: "initial"))

        try "a\nB\nc\nd\ne\nf\ng\nh\n".write(toFile: readme, atomically: true, encoding: .utf8)
        let edited = try #require(GitDiff.fileChange(path: readme))
        #expect(edited.source == .uncommitted)
        #expect(edited.file.addedCount == 1 && edited.file.removedCount == 1)
        // The whole file comes, so the viewer's folds open without asking git again.
        #expect(edited.file.hunks.flatMap(\.lines).filter { $0.kind != .removed }.map(\.text) == ["a", "B", "c", "d", "e", "f", "g", "h"])

        _ = try git(["commit", "-qam", "Capitalize b"], in: repo)
        let committed = try #require(GitDiff.fileChange(path: readme))
        let head = try git(["log", "-1", "--format=%h"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(committed.source == .commit(shortID: head, subject: "Capitalize b"))
        #expect(committed.file.addedCount == 1 && committed.file.removedCount == 1)

        let notes = repo.appendingPathComponent("notes.md").path
        try "one\ntwo\n".write(toFile: notes, atomically: true, encoding: .utf8)
        let untracked = try #require(GitDiff.fileChange(path: notes))
        #expect(untracked.source == .untracked && untracked.file.addedCount == 2)
    }

    @Test func aFileNoRepositoryHoldsHasNoGitChange() throws {
        let folder = try makeScratchDirectory("plain")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("SKILL.md").path
        try "# Retro\n".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(GitDiff.fileChange(path: file) == nil)
    }

    @MainActor @Test func theFileShowsFirstAndMarksTheChangeOnlyWhileTheDiffMatchesTheDisk() async throws {
        let diff = try #require(DiffFile.parse("""
            diff --git a/README.md b/README.md
            --- a/README.md
            +++ b/README.md
            @@ -1,3 +1,3 @@
             a
            -b
            +B
             c

            """).first)
        let disk = ["/r/README.md": "a\nB\nc\n", "/r/other.md": "x\ny\n"]
        let state = FileViewerState(paths: ["/r/README.md", "/r/other.md"], index: 0, loader: FileViewerLoader(
            read: { .text(disk[$0] ?? "") },
            diff: { $0 == "/r/README.md" ? .ready(diff, source: "Uncommitted changes") : .none("No diff to show.") }))
        defer { state.close() }

        try await eventuallyOnMain("README's diff") { state.stat != nil }
        guard case .file(let lines) = state.content else { Issue.record("expected the file"); return }
        #expect(lines.map(\.added) == [false, true, false])
        #expect(state.source == "On disk now · marked: Uncommitted changes")
        #expect(state.position == "1 of 2" && state.hasNext && !state.hasPrevious)

        state.toggleMode()
        guard case .diff(let rows, _) = state.content else { Issue.record("expected the diff"); return }
        #expect(!rows.isEmpty && state.source == "Uncommitted changes")

        state.next()
        try await eventuallyOnMain("the other file") { if case .message = state.content { true } else { false } }
        state.toggleMode()
        guard case .file(let other) = state.content else { Issue.record("expected the other file"); return }
        #expect(other.map(\.added) == [false, false] && state.source == "On disk now")
    }

    @MainActor @Test func aFileChangedSinceTheDiffGetsNoMarks() async throws {
        let diff = try #require(DiffFile.parse("""
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1 +1 @@
            -old
            +new

            """).first)
        let state = FileViewerState(paths: ["/r/a.txt"], index: 0, loader: FileViewerLoader(
            read: { _ in .text("newer\n") }, diff: { _ in .ready(diff, source: "This turn’s edits") }))
        defer { state.close() }
        try await eventuallyOnMain("the diff") { state.stat != nil }
        guard case .file(let lines) = state.content else { Issue.record("expected the file"); return }
        #expect(lines.map(\.added) == [false] && state.source == "On disk now")
        #expect(state.position == nil)
    }

    @Test func cardPathsResolveAgainstTheirBase() {
        #expect(FileViewerState.absolute("README.md", base: "/repo") == "/repo/README.md")
        #expect(FileViewerState.absolute("/elsewhere/../toolkit/SKILL.md", base: "/repo") == "/toolkit/SKILL.md")
        #expect(FileViewerState.absolute("~/notes.md", base: "/repo") == (NSHomeDirectory() as NSString).appendingPathComponent("notes.md"))
    }
}

/// The viewer pressed the way VoiceOver presses it, in a window that is never shown: ‹ › step through the card's files,
/// File | Diff switches, and close closes. Each scenario runs in its own process for the accessibility tree (`ControlPress`).
@Suite("File viewer, controls", .mainActorExclusive)
struct FileViewerControlTests {
    @Test func theViewerStepsSwitchesAndCloses() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.viewing() }
        }
        expectScenarioCompleted(result)
    }

    @MainActor
    static func viewing() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let state = FileViewerState(paths: ["/r/skills/retro/SKILL.md", "/r/README.md"], index: 0, loader: FileViewerLoader(
            read: { .text($0.hasSuffix("SKILL.md") ? "# Retro\n" : "# toolkit\n") }, diff: { _ in .none("No diff to show.") }))
        vm.fileViewer = state
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), dark: true, FileViewerOverlay(vm: vm))
        defer { window.close() }
        let labels = window.controls().compactMap(\.label)
        #expect(labels.contains("Open in editor") && labels.contains("Next file"), "the header's controls are drawn: \(labels)")
        #expect(throws: ControlPressError.self, "the first file's ‹ is drawn disabled, so it takes no press") { try window.press("Previous file") }
        try window.press("Next file")
        try await eventuallyOnMain("the second file") { state.path == "/r/README.md" }
        try window.press("Diff", role: ControlRole.radioButton)
        try await eventuallyOnMain("Diff") { state.mode == .diff }
        try window.press("Close")
        try await eventuallyOnMain("the viewer to close") { vm.fileViewer == nil }
    }

    @Test func aChangesCardsFileRowOpensTheViewerOnThatFileWithTheCardsOthers() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.cardRow() }
        }
        expectScenarioCompleted(result)
    }

    /// A turn that edited outside its folder (no turn recorded, so the card is the calls'): its file row asks to view the
    /// file, not to review it.
    @MainActor
    static func cardRow() async throws {
        AccessibilityNode.enable()
        typealias T = ThreadBlankScreenTests
        let at = T.base
        let messages = [T.user("u", "Add the retro skill.", at: at),
                        T.tool("c1", "write", ["path": "/toolkit/skills/retro/SKILL.md", "content": "# Retro\n"], output: "Wrote it.", at: at + 1000),
                        T.tool("c2", "edit", ["path": "/toolkit/README.md", "oldText": "a", "newText": "a\nb"], output: "Replaced.", at: at + 2000),
                        T.reply("a", "Added the retro skill.", at: at + 3000)]
        let host = QueueFixture(T.snapshot(messages, revision: 1))
        let store = NativeThreadStore()
        var viewed: [(UUID?, String, [String])] = [], reviewed: [String?] = []
        let window = OffscreenWindow(size: CGSize(width: 900, height: 700), dark: true)
        defer { store.stop(); window.close() }
        window.show(ThreadView(store: store, active: true, isFocused: false, request: { [host] in host.answer($0) }, commandKey: "viewer",
                               turnActions: TurnChangesActions(review: { reviewed.append($1) }, undo: { _ in nil }, redo: { _ in nil },
                                                               view: { viewed.append(($0, $1, $2)) }),
                               listModels: { .empty }))
        try await eventuallyOnMain("the card's rows") { window.layout(); return window.controls().contains { $0.label?.hasPrefix("/toolkit/README.md") == true } }
        let row = try #require(window.controls().first { $0.label?.hasPrefix("/toolkit/README.md") == true }?.label)
        try window.press(row)
        #expect(viewed.count == 1 && reviewed.isEmpty)
        #expect(viewed.first?.0 == nil && viewed.first?.1 == "/toolkit/README.md")
        #expect(viewed.first?.2 == ["/toolkit/skills/retro/SKILL.md", "/toolkit/README.md"])
    }
}
