import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The diff review against real scratch repositories: an agent asking for review over the
/// extension socket, the diff git produces, sending the review to pi, and reverting files.
@Suite("Diff review", .integrationTimeLimit, .mainActorExclusive)
@MainActor
struct ReviewFlowTests {
    /// A repo with `file.txt` modified and `new.txt` untracked.
    private func dirtyRepo() throws -> URL {
        let repo = try makeScratchRepo(files: ["file.txt": "before\n"])
        try "after\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "fresh\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        return repo
    }

    private func comment(on session: ReviewSession, _ text: String) throws -> ReviewComment {
        let file = try #require(session.files.first { $0.displayPath == "file.txt" })
        let line = try #require(file.hunks.flatMap(\.lines).first { $0.kind == .added })
        return ReviewComment(fileID: file.id, lineID: line.id, filePath: file.displayPath,
                             lineNumber: line.newLine ?? 0, marker: line.kind.reviewMarker, content: line.text, text: text)
    }

    @Test func anAgentsReviewRequestDocksBesideItsThreadWithoutMovingTheUser() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try dirtyRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let space = Fixture.space(path: repo.path)
        let background = Fixture.agent("background", in: space, order: 0)
        let visible = Fixture.agent("visible", in: space, order: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [background, visible]))
        vm.selectAgent(visible.agent.id)

        let reply = try await app.extensionRequest(.requestReview(id: 1, agentID: background.agent.id, cwd: repo.path, reference: nil))

        guard case .reviewResult(1, let text) = reply else { Issue.record("unexpected reply \(reply)"); return }
        #expect(text.hasPrefix("Review pane opened."))
        let session = try #require(vm.reviewSessions.values.first)
        #expect(session.agentID == background.agent.id)
        #expect(vm.selectedAgentID == visible.agent.id && vm.focusedPaneID == visible.piPane.id)
        #expect(app.server.state.tabs.map(\.layout) == [background.tab.layout, visible.tab.layout], "a review never touches the layout")
        try await eventuallyOnMain("the diff to load") { !session.isLoading }
        #expect(session.files.map(\.displayPath) == ["file.txt", "new.txt"])
        #expect(session.files.last?.isNew == true)
    }

    @Test func aRepeatedRequestReloadsTheOpenReviewInsteadOfOpeningAnother() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try dirtyRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let space = Fixture.space(path: repo.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        _ = try await app.extensionRequest(.requestReview(id: 1, agentID: agent.agent.id, cwd: nil, reference: nil))
        let first = try #require(vm.reviewSessions.values.first)

        let reply = try await app.extensionRequest(.requestReview(id: 2, agentID: agent.agent.id, cwd: nil, reference: nil))

        guard case .reviewResult(2, let text) = reply else { Issue.record("unexpected reply \(reply)"); return }
        #expect(text.hasPrefix("Review pane already open; reloaded."))
        #expect(vm.reviewSessions.count == 1 && vm.reviewSessions.values.first === first)
    }

    @Test func aReviewFromASubdirectoryShowsRepositoryRelativePaths() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try makeScratchRepo(files: ["sub/tracked.txt": "before\n", "top.txt": "top\n"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let sub = repo.appendingPathComponent("sub")
        try "after\n".write(to: sub.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: sub.appendingPathComponent("fresh.txt"), atomically: true, encoding: .utf8)
        let space = Fixture.space(path: repo.path)
        let agent = Fixture.agent(in: space, cwd: sub.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        vm.openReview(agentID: agent.agent.id, path: nil)

        let session = try #require(vm.reviewSessions.values.first)
        try await eventuallyOnMain("the diff to load") { !session.isLoading }
        #expect(Set(session.files.map(\.displayPath)) == ["sub/tracked.txt", "sub/fresh.txt"])
    }

    @Test func requestingChangesSendsTheReviewAsTheAgentsNextPromptAndCloses() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try dirtyRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let log = app.dir.appendingPathComponent("pi.log")
        let space = Fixture.space(path: repo.path)
        let agent = try await app.liveAgent(in: space, log: log)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.openReview(agentID: agent.agent.id, path: nil)
        let session = try #require(vm.reviewSessions.values.first)
        try await eventuallyOnMain("the diff to load") { !session.isLoading }
        session.comments = [try comment(on: session, "name this constant")]
        session.summary = "otherwise fine"
        _ = try await app.readyThread(agent.agent.id)

        vm.submitReview(session)

        try await eventuallyOnMain("the review to close once sent") { vm.reviewSessions.isEmpty }
        #expect(AppHarness.prompts(in: log) == ["""
        Diff review (working tree vs HEAD):

        file.txt:1 [+ after]
          name this constant

        Overall: otherwise fine
        """])
    }

    @Test func committingAsksTheAgentToCommitAndCarriesTheReview() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try dirtyRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let log = app.dir.appendingPathComponent("pi.log")
        let space = Fixture.space(path: repo.path)
        let agent = try await app.liveAgent(in: space, log: log)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.openReview(agentID: agent.agent.id, path: nil)
        let session = try #require(vm.reviewSessions.values.first)
        try await eventuallyOnMain("the diff to load") { !session.isLoading }
        session.comments = [try comment(on: session, "tidy first")]
        _ = try await app.readyThread(agent.agent.id)

        vm.commitReview(session)

        try await eventuallyOnMain("the review to close once sent") { vm.reviewSessions.isEmpty }
        let prompt = try #require(AppHarness.prompts(in: log).first)
        #expect(prompt.hasPrefix("Commit these changes. Address the review below first.\n\nDiff review (working tree vs HEAD):"))
        #expect(prompt.contains("tidy first"))
    }

    @Test func submittingWhilePiIsNotRunningKeepsTheReviewAndItsComments() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try dirtyRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let space = Fixture.space(path: repo.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.openReview(agentID: agent.agent.id, path: nil)
        let session = try #require(vm.reviewSessions.values.first)
        try await eventuallyOnMain("the diff to load") { !session.isLoading }
        session.comments = [try comment(on: session, "please check this")]

        vm.submitReview(session)

        try await eventuallyOnMain("the send to fail") { vm.remoteActionError != nil && !session.isSubmitting }
        #expect(vm.reviewSessions.values.first === session)
        #expect(session.comments.map(\.text) == ["please check this"])
    }

    @Test func revertingFilesRestoresTrackedOnesRemovesNewOnesAndReloads() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try dirtyRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let space = Fixture.space(path: repo.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.openReview(agentID: agent.agent.id, path: nil)
        let session = try #require(vm.reviewSessions.values.first)
        try await eventuallyOnMain("the diff to load") { !session.isLoading }
        session.comments = [try comment(on: session, "dropped with the file")]

        vm.revertReviewFile(session, file: try #require(session.files.first { $0.displayPath == "file.txt" }))
        try await eventuallyOnMain("the tracked file to drop out of the diff") { !session.isLoading && session.files.map(\.displayPath) == ["new.txt"] }
        vm.revertReviewFile(session, file: try #require(session.files.first))
        try await eventuallyOnMain("the diff to empty") { !session.isLoading && session.files.isEmpty }

        #expect(try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8) == "before\n")
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("new.txt").path))
        #expect(session.comments.isEmpty)
    }

    @Test func openingAReviewAtAPathReplacesTheInspectorAndFocusesTheFile() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try dirtyRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let space = Fixture.space(path: repo.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.openReview(agentID: agent.agent.id, path: nil)
        let session = try #require(vm.reviewSessions.values.first)
        vm.subagentInspector.runByAgent[agent.agent.id] = "run-1"
        let before = session.focusRequest

        vm.openReview(agentID: agent.agent.id, path: "\(repo.path)/file.txt")

        #expect(vm.subagentInspector.runByAgent[agent.agent.id] == nil)
        #expect(vm.reviewSessions.count == 1)
        #expect(session.focusFile == "\(repo.path)/file.txt" && session.focusRequest != before)
    }

    @Test func closingAReviewDiscardsIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.openReview(agentID: agent.agent.id, path: nil)

        vm.cancelReview(try #require(vm.reviewSessions.values.first))

        #expect(vm.reviewSessions.isEmpty)
    }

    /// Switching modes quickly starts overlapping loads; only the newest may land, whether an
    /// older one finishes first or last, and whether it succeeds or fails.
    @Test func aStaleDiffLoadNeverReplacesTheNewestOne() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let loads = HeldLoads()
        vm.reviewDiffLoader = { _, reference in try await loads.load(reference) }
        vm.openReview(agentID: agent.agent.id, path: nil)
        let session = try #require(vm.reviewSessions.values.first)
        try await loads.waitFor("local")

        vm.reloadReview(session, reference: "old")
        try await loads.waitFor("old")
        vm.reloadReview(session, reference: "new")
        try await loads.waitFor("new")
        await loads.finish("old", failing: true)
        await loads.finish("local")
        #expect(session.isLoading && session.loadError == nil)
        await loads.finish("new")
        try await eventuallyOnMain("the newest load to land") { !session.isLoading && session.reference == "new" }

        vm.reloadReview(session, reference: "slow")
        try await loads.waitFor("slow")
        vm.reloadReview(session, reference: "latest")
        try await loads.waitFor("latest")
        await loads.finish("latest")
        try await eventuallyOnMain("the latest load to land") { !session.isLoading && session.reference == "latest" }
        await loads.finish("slow")
        for _ in 0..<5 { await Task.yield() }
        #expect(session.reference == "latest" && session.loadError == nil)
    }
}

/// Diff loads the test releases one at a time.
private actor HeldLoads {
    private var pending: [String: CheckedContinuation<(files: [DiffFile], reference: String?), any Error>] = [:]

    func load(_ reference: String?) async throws -> (files: [DiffFile], reference: String?) {
        try await withCheckedThrowingContinuation { pending[reference ?? "local"] = $0 }
    }

    func waitFor(_ reference: String) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while pending[reference] == nil {
            guard ContinuousClock.now < deadline else { throw TimedOut(what: "a diff load for \(reference)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func finish(_ reference: String, failing: Bool = false) {
        guard let continuation = pending.removeValue(forKey: reference) else { return }
        if failing { continuation.resume(throwing: GitWorktree.Failure(message: "stale load failed")) }
        else { continuation.resume(returning: ([], reference)) }
    }
}
