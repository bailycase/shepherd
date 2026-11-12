import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// A Save in the Files tab changes the working tree the branch chip and the Changes tab read: the
/// chip counts the file at once, and the Changes tab (hidden while the person edits) lists it the
/// next time it shows. A turn that ended while the tab was hidden is shown the same way. A Save or
/// a Revert made while an agent's turn runs is the person's, not the turn's.
@Suite("Changes after a Files-tab save", .mainActorExclusive)
@MainActor
struct ChangesAfterSaveTests {
    /// One agent in a scratch repository whose `notes.txt` is open in its Files tab.
    @MainActor private struct Setup {
        let app: AppHarness
        let vm: ShepherdViewModel
        let repo: URL
        let agentID: AgentID
        let tree: FileTreeModel
        var file: String { repo.appendingPathComponent("notes.txt").path }

        /// Types `text` over the open file and presses Save.
        func save(_ text: String) async {
            tree.setText(text, for: file)
            await tree.save()
        }

        func close() {
            app.stop()
            try? FileManager.default.removeItem(at: repo)
        }
    }

    private func open() async throws -> Setup {
        let app = try AppHarness()
        let repo = try makeScratchRepo(files: ["notes.txt": "before\n"])
        let space = Fixture.space(path: repo.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let id = agent.agent.id
        try await eventuallyOnMain("the first checkout read") {
            vm.state.agents.first?.checkout == AgentCheckout(branch: "main", changedFiles: 0)
        }
        vm.ensureFileTree(.local(id))
        let tree = try #require(vm.fileTree(for: id))
        await tree.loadRoot()
        await tree.select(path: repo.appendingPathComponent("notes.txt").path)
        return Setup(app: app, vm: vm, repo: repo, agentID: id, tree: tree)
    }

    /// The agent's Changes review, loaded and empty (a clean checkout).
    private func loadedReview(_ setup: Setup) async throws -> ReviewSession {
        setup.vm.beginReview(agentID: setup.agentID, cwd: nil, reference: nil)
        let session = try #require(setup.vm.reviewSessions.values.first)
        try await eventuallyOnMain("the clean review to load") { !session.isLoading && session.list != nil }
        #expect(session.files.isEmpty)
        return session
    }

    private func pane(_ setup: Setup, _ session: ReviewSession, turn: ChangesTurn? = nil,
                      counting refreshes: Counter? = nil) -> ReviewPane {
        var actions = setup.vm.reviewActions(for: session, remote: false)
        if let refreshes {
            let refresh = actions.refresh
            actions.refresh = { refreshes.count += 1; refresh() }
        }
        return ReviewPane(session: session, actions: actions, latestTurn: turn)
    }

    final class Counter { var count = 0 }

    @Test func aFilesTabSaveRefreshesTheBranchChip() async throws {
        let setup = try await open()
        defer { setup.close() }

        await setup.save("after\n")

        try await eventuallyOnMain("the chip to count the saved file") {
            setup.vm.state.agents.first?.checkout == AgentCheckout(branch: "main", changedFiles: 1)
        }
    }

    @Test func aSaveReloadsTheChangesTabWhenItShowsAgain() async throws {
        let setup = try await open()
        defer { setup.close() }
        let session = try await loadedReview(setup)
        let window = OffscreenWindow(size: CGSize(width: 520, height: 700), dark: false, pane(setup, session))
        defer { window.close() }
        window.show(EmptyView())

        await setup.save("after\n")
        window.show(pane(setup, session))

        try await eventuallyOnMain("the saved file to be listed") { session.files.map(\.displayPath) == ["notes.txt"] }
        #expect(!session.workingTreeChanged, "the reload spends the mark")
    }

    @Test func aSaveWhileTheChangesTabShowsReloadsItAtOnce() async throws {
        let setup = try await open()
        defer { setup.close() }
        let session = try await loadedReview(setup)
        let window = OffscreenWindow(size: CGSize(width: 520, height: 700), dark: false, pane(setup, session))
        defer { window.close() }

        await setup.save("after\n")

        try await eventuallyOnMain("the saved file to be listed") { session.files.map(\.displayPath) == ["notes.txt"] }
    }

    @Test func aTurnThatEndedWhileTheTabWasHiddenReloadsItWhenShown() async throws {
        let setup = try await open()
        defer { setup.close() }
        let session = try await loadedReview(setup)
        try "fresh\n".write(to: setup.repo.appendingPathComponent("made-by-bash.txt"), atomically: true, encoding: .utf8)
        let ended = ChangesTurn(startedAt: 1, endedAt: 2, state: .ready)
        let refreshes = Counter()
        let window = OffscreenWindow(size: CGSize(width: 520, height: 700), dark: false,
                                     pane(setup, session, turn: ended, counting: refreshes))
        defer { window.close() }

        try await eventuallyOnMain("the turn's file to be listed") { session.files.map(\.displayPath) == ["made-by-bash.txt"] }
        #expect(refreshes.count == 1)

        window.show(EmptyView())
        window.show(pane(setup, session, turn: ended, counting: refreshes))
        for _ in 0..<5 {
            window.layout()
            await Task.yield()
        }
        #expect(refreshes.count == 1, "a turn the pane already followed doesn't reload it again")
    }

    /// The person's Save while an agent's turn runs is theirs, not the turn's: the card lists only
    /// what the agent changed, and its Undo leaves the saved text alone.
    @Test func aFilesTabSaveDuringARunningTurnStaysOutOfItsUndo() async throws {
        let held = try await HeldTurn.start(in: try makeScratchRepo(files: ["notes.txt": "before\n", "a.txt": "one\n"]))
        defer { held.close() }
        let vm = held.vm, id = held.agentID
        vm.ensureFileTree(.local(id))
        let tree = try #require(vm.fileTree(for: id))
        await tree.loadRoot()
        let notes = held.repo.appendingPathComponent("notes.txt").path
        await tree.select(path: notes)
        try "one\ntwo\n".write(to: held.repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        tree.setText("after\n", for: notes)
        await tree.save()
        let turn = try await held.release()

        #expect(turn.files.map(\.path) == ["a.txt"])
        #expect(await vm.undoTurn(.local(id), turnID: turn.id) == nil)
        #expect(try String(contentsOf: held.repo.appendingPathComponent("a.txt"), encoding: .utf8) == "one\n")
        #expect(try String(contentsOfFile: notes, encoding: .utf8) == "after\n", "the person's Save is not the agent's to undo")
    }

    /// The Changes pane's Revert is the person's too: the file it put back is not the turn's, and
    /// the agent's Undo does not bring the person's discarded draft back.
    @Test func aPaneRevertDuringARunningTurnStaysOutOfItsUndo() async throws {
        let repo = try makeScratchRepo(files: ["notes.txt": "committed\n", "a.txt": "one\n"])
        try "a draft\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let held = try await HeldTurn.start(in: repo)
        defer { held.close() }
        let vm = held.vm
        vm.beginReview(agentID: held.agentID, cwd: nil, reference: nil)
        let session = try #require(vm.reviewSessions.values.first)
        try await eventuallyOnMain("the review to load") { !session.isLoading && session.list != nil }
        try "one\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let notes = DiffFile(oldPath: "notes.txt", newPath: "notes.txt", displayPath: "notes.txt", isNew: false, isDeleted: false,
                             isRenamed: false, isBinary: false, hunks: [])
        vm.revertReviewFile(session, file: notes, in: session.cwd)
        try await eventuallyOnMain("notes.txt to return to HEAD") {
            (try? String(contentsOf: repo.appendingPathComponent("notes.txt"), encoding: .utf8)) == "committed\n"
        }
        let turn = try await held.release()

        #expect(turn.files.map(\.path) == ["a.txt"])
        #expect(await vm.undoTurn(.local(held.agentID), turnID: turn.id) == nil)
        #expect(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8) == "one\n")
        #expect(try String(contentsOf: repo.appendingPathComponent("notes.txt"), encoding: .utf8) == "committed\n", "the discarded draft stays discarded")
    }
}
