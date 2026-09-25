import Foundation
import ShepherdRemote
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The diff review against real scratch repositories: an agent asking for review over the
/// extension socket, the diff git produces, sending the review to pi, and reverting files.
@Suite("Diff review", .mainActorExclusive)
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

    /// An agent's `review_diff` readies its Changes tab without opening the side pane or moving
    /// the user: the tab and the agent's header button take pi's dot instead (PaneStates:
    /// nothing opens by itself).
    @Test func anAgentsReviewRequestWaitsInItsChangesTabWithoutMovingTheUser() async throws {
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
        #expect(text.hasPrefix("Review ready in the side pane's Changes tab"))
        let session = try #require(vm.reviewSessions.values.first)
        #expect(session.agentID == background.agent.id)
        #expect(vm.selectedAgentID == visible.agent.id && vm.focusedPaneID == visible.piPane.id)
        let owner = SidePaneOwner.local(background.agent.id)
        #expect(!vm.subagentInspector.open.contains(owner), "the pane stays closed")
        #expect(vm.subagentInspector.news[owner] == [.changes])
        #expect(vm.sidePaneButton(for: owner).news == "pi opened a review in Changes")
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
        #expect(text.hasPrefix("Review reloaded in the side pane's Changes tab"))
        #expect(vm.reviewSessions.count == 1 && vm.reviewSessions.values.first === first)

        vm.selectAgent(agent.agent.id)
        vm.toggleRightPane()
        #expect(vm.rightPaneContent == .review && vm.reviewSessions.values.first === first, "the pane opens on the agent's review")
        let again = try await app.extensionRequest(.requestReview(id: 3, agentID: agent.agent.id, cwd: nil, reference: nil))
        guard case .reviewResult(3, let shown) = again else { Issue.record("unexpected reply \(again)"); return }
        #expect(shown.hasPrefix("Review pane already open; reloaded."))
        #expect(vm.subagentInspector.news.isEmpty, "a tab on screen takes no dot")
    }

    /// `review_diff` with `cwd` reviews another repository or worktree in the agent's one
    /// review; without it, the agent's own directory. Comments belong to the diff they were
    /// made on, so a new target starts over and the same target keeps them.
    @Test func anAgentsReviewFollowsTheRequestedRepositoryAndStartsOverWhenItChanges() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let own = try dirtyRepo()
        let other = try makeScratchRepo(files: ["other.txt": "before\n"])
        defer { for repo in [own, other] { try? FileManager.default.removeItem(at: repo) } }
        try "after\n".write(to: other.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        let space = Fixture.space(path: own.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        _ = try await app.extensionRequest(.requestReview(id: 1, agentID: agent.agent.id, cwd: nil, reference: nil))
        let session = try #require(vm.reviewSessions.values.first)
        try await eventuallyOnMain("the agent's diff to load") { !session.isLoading }

        for (id, cwd, files) in [(2, other.path, ["other.txt"]), (3, nil, ["file.txt", "new.txt"])] as [(Int, String?, [String])] {
            session.comments = [ReviewComment(fileID: "f", lineID: 0, filePath: "f", lineNumber: 1, text: "on the old target")]
            session.summary = "old summary"
            session.viewed = ["f"]

            let reply = try await app.extensionRequest(.requestReview(id: id, agentID: agent.agent.id, cwd: cwd, reference: nil))

            guard case .reviewResult(id, let text) = reply else { Issue.record("unexpected reply \(reply)"); return }
            #expect(text.hasPrefix("Review reloaded"))
            #expect(vm.reviewSessions.count == 1 && vm.reviewSessions.values.first === session)
            #expect(session.cwd == (cwd ?? agent.piPane.cwd))
            #expect(session.comments.isEmpty && session.summary.isEmpty && session.viewed.isEmpty)
            try await eventuallyOnMain("the new target's diff to load") { !session.isLoading }
            #expect(session.files.map(\.displayPath) == files)
        }
        #expect(app.server.state.tabs.map(\.layout) == [agent.tab.layout], "a review never touches the layout")

        session.comments = [try comment(on: session, "same target")]
        _ = try await app.extensionRequest(.requestReview(id: 4, agentID: agent.agent.id, cwd: own.path, reference: nil))
        #expect(session.comments.map(\.text) == ["same target"])
    }

    /// A diff still loading from the old target never lands in the retargeted review, whether
    /// it finishes last or fails.
    @Test(arguments: [false, true])
    func retargetingIgnoresTheOldTargetsPendingDiff(failing: Bool) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let loads = HeldLists()
        vm.changesEngineOverride = { _, cwd in loads.engine(key: { _ in cwd }) }
        vm.openReview(agentID: agent.agent.id, path: nil)
        let session = try #require(vm.reviewSessions.values.first)
        try await loads.waitFor(agent.piPane.cwd)

        _ = try await app.extensionRequest(.requestReview(id: 1, agentID: agent.agent.id, cwd: "~/review-target", reference: nil))
        let target = ("~/review-target" as NSString).expandingTildeInPath
        try await loads.waitFor(target)
        #expect(session.cwd == target)
        await loads.finish(target)
        try await eventuallyOnMain("the new target's diff to land") { !session.isLoading && session.list?.comparison.head == target }
        await loads.finish(agent.piPane.cwd, failing: failing)
        for _ in 0..<5 { await Task.yield() }

        #expect(session.list?.comparison.head == target && session.loadError == nil && !session.isLoading)
    }

    /// While a subagent is inspected over the pane, an agent's request leaves it there: the
    /// Changes tab takes the dot, closing the inspector goes back to it, and showing it clears it.
    @Test func anAgentsRequestNeverTakesThePaneFromAnInspectedSubagent() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try dirtyRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let space = Fixture.space(path: repo.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        vm.toggleRightPane()
        vm.subagentInspector.runByAgent[agent.agent.id] = "run-1"
        #expect(vm.rightPaneContent == .inspector(runID: "run-1"))

        _ = try await app.extensionRequest(.requestReview(id: 2, agentID: agent.agent.id, cwd: nil, reference: nil))

        let owner = SidePaneOwner.local(agent.agent.id)
        #expect(vm.rightPaneContent == .inspector(runID: "run-1"))
        #expect(vm.sidePaneButton(for: owner) == (true, "pi opened a review in Changes"))
        vm.closeInspector(owner)
        #expect(vm.rightPaneContent == .review, "closing the inspector goes back to Changes")
        #expect(vm.subagentInspector.news[owner] == [.changes], "the tab keeps its dot until it is shown")
        vm.selectSidePaneTab(.changes)
        #expect(vm.subagentInspector.news[owner] == nil)
        #expect(vm.selectedAgentID == agent.agent.id && vm.focusedPaneID == agent.piPane.id)
    }

    /// ⇧⌘B shows the pane on Changes (a review starts) and hides it again (the review is
    /// discarded); ⌃1 brings Changes in front of an inspected subagent.
    @Test func theHeaderButtonShowsAndHidesTheSidePane() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.changesEngineOverride = { _, _ in ChangesEngine.fixed([]) }
        vm.selectAgent(agent.agent.id)
        let owner = SidePaneOwner.local(agent.agent.id)
        #expect(vm.sidePaneButton(for: owner) == (false, nil))

        vm.toggleRightPane()
        #expect(vm.rightPaneContent == .review && vm.reviewSessions.count == 1)
        #expect(vm.sidePaneButton(for: owner) == (true, nil))
        vm.toggleRightPane()
        #expect(vm.rightPaneContent == nil && vm.reviewSessions.isEmpty)

        vm.subagentInspector.runByAgent[agent.agent.id] = "run-1"
        #expect(vm.sidePaneButton(for: owner) == (true, nil), "the inspector is the pane")
        vm.selectSidePaneTab(.changes)
        #expect(vm.rightPaneContent == .review && vm.subagentInspector.runByAgent.isEmpty)
        vm.subagentInspector.runByAgent[agent.agent.id] = "run-1"
        vm.toggleRightPane()
        #expect(vm.rightPaneContent == nil && vm.subagentInspector.runByAgent.isEmpty && vm.reviewSessions.isEmpty,
                "hiding the pane closes the inspector over it too")
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

    /// Send to agent: the comments go as the agent's next message under the scope they were
    /// written against; the pane stays, its comments cleared.
    @Test func sendingTheReviewMakesItTheAgentsNextPromptAndClearsItsComments() async throws {
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
        _ = try await app.readyThread(agent.agent.id)

        vm.submitReview(session)

        try await eventuallyOnMain("the comments to clear once sent") { session.comments.isEmpty && !session.isSubmitting }
        #expect(vm.reviewSessions.values.first === session && vm.subagentInspector.open.contains(.local(agent.agent.id)),
                "the Changes tab stays")
        #expect(session.sentAt != nil, "the agent's reply turns the pane to Last turn")
        #expect(AppHarness.prompts(in: log) == ["""
        Diff review (Uncommitted):

        file.txt:1 [+ after]
          name this constant
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

        try await eventuallyOnMain("the comments to clear once sent") { session.comments.isEmpty && !session.isSubmitting }
        let prompt = try #require(AppHarness.prompts(in: log).first)
        // The files under review are named, an untracked one too, so the agent can't decide
        // nothing is left to commit.
        let (files, review) = try #require(prompt.firstRange(of: "\n\n").map { (prompt[..<$0.lowerBound], prompt[$0.upperBound...]) })
        #expect(Set(files.components(separatedBy: "\n")) == ["Commit these changes:", "- file.txt", "- new.txt (new)"])
        #expect(review.hasPrefix("Before committing, address the review below.\n\nDiff review (Uncommitted):"))
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

        vm.revertReviewFile(session, file: try #require(session.files.first { $0.displayPath == "file.txt" }), in: session.cwd)
        try await eventuallyOnMain("the tracked file to drop out of the diff") { !session.isLoading && session.files.map(\.displayPath) == ["new.txt"] }
        vm.revertReviewFile(session, file: try #require(session.files.first), in: session.cwd)
        try await eventuallyOnMain("the diff to empty") { !session.isLoading && session.files.isEmpty }

        #expect(try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8) == "before\n")
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("new.txt").path))
        #expect(session.comments.isEmpty)
    }

    /// A Revert confirmed on one repository's diff acts there, even if an agent retargeted the
    /// review before it ran: the new repository's file and the new diff's comments are untouched.
    @Test func aConfirmedRevertActsOnTheRepositoryItsDiffCameFrom() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let own = try dirtyRepo()
        let other = try dirtyRepo()
        defer { for repo in [own, other] { try? FileManager.default.removeItem(at: repo) } }
        let space = Fixture.space(path: own.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.openReview(agentID: agent.agent.id, path: nil)
        let session = try #require(vm.reviewSessions.values.first)
        try await eventuallyOnMain("the agent's diff to load") { !session.isLoading }
        let confirmed = try #require(session.files.first { $0.displayPath == "file.txt" })
        let confirmedIn = session.cwd
        _ = try await app.extensionRequest(.requestReview(id: 1, agentID: agent.agent.id, cwd: other.path, reference: nil))
        try await eventuallyOnMain("the other repository's diff to load") { !session.isLoading && session.cwd == other.path }
        session.comments = [try comment(on: session, "about the other repository")]

        vm.revertReviewFile(session, file: confirmed, in: confirmedIn)

        try await eventuallyOnMain("the confirmed repository's file to return to HEAD") {
            (try? String(contentsOf: own.appendingPathComponent("file.txt"), encoding: .utf8)) == "before\n"
        }
        #expect(try String(contentsOf: other.appendingPathComponent("file.txt"), encoding: .utf8) == "after\n")
        #expect(session.cwd == other.path && session.comments.map(\.text) == ["about the other repository"])
        #expect(session.files.map(\.displayPath) == ["file.txt", "new.txt"])
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

        #expect(vm.reviewSessions.isEmpty && vm.subagentInspector.open.isEmpty)
    }

    /// Switching scopes quickly starts overlapping loads; only the newest may land, whether an
    /// older one finishes first or last, and whether it succeeds or fails.
    @Test func aStaleDiffLoadNeverReplacesTheNewestOne() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let loads = HeldLists()
        vm.changesEngineOverride = { _, _ in loads.engine(key: { $0.label }) }
        vm.openReview(agentID: agent.agent.id, path: nil)
        let session = try #require(vm.reviewSessions.values.first)
        try await loads.waitFor("Uncommitted")

        vm.setChangesScope(session, .staged)
        try await loads.waitFor("Staged")
        vm.setChangesScope(session, .unstaged)
        try await loads.waitFor("Unstaged")
        await loads.finish("Staged", failing: true)
        await loads.finish("Uncommitted")
        #expect(session.isLoading && session.loadError == nil)
        await loads.finish("Unstaged")
        try await eventuallyOnMain("the newest load to land") { !session.isLoading && session.list?.comparison.head == "Unstaged" }

        vm.setChangesScope(session, .pullRequest)
        try await loads.waitFor("Pull request")
        vm.setChangesScope(session, .lastTurn)
        try await loads.waitFor("Last turn")
        await loads.finish("Last turn")
        try await eventuallyOnMain("the latest load to land") { !session.isLoading && session.list?.comparison.head == "Last turn" }
        await loads.finish("Pull request")
        for _ in 0..<5 { await Task.yield() }
        #expect(session.list?.comparison.head == "Last turn" && session.loadError == nil)
    }
}

/// Changes lists the test releases one at a time, keyed by what `key` makes of the scope; each
/// names its key as the compare row's head.
@MainActor
private final class HeldLists {
    private var pending: [String: (ChangesScope, CheckedContinuation<ChangesList, any Error>)] = [:]

    func engine(key: @escaping (ChangesScope) -> String) -> ChangesEngine {
        var engine = ChangesEngine.fixed([])
        engine.list = { [self] scope, _ in
            try await withCheckedThrowingContinuation { self.pending[key(scope)] = (scope, $0) }
        }
        engine.overview = { throw ChangesError(ChangesError.unavailable, "no overview here") }
        return engine
    }

    func waitFor(_ key: String) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while pending[key] == nil {
            guard ContinuousClock.now < deadline else { throw TimedOut(what: "a diff load for \(key)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func finish(_ key: String, failing: Bool = false) {
        guard let (scope, continuation) = pending.removeValue(forKey: key) else { return }
        if failing { continuation.resume(throwing: ChangesError(ChangesError.gitFailed, "stale load failed")) }
        else {
            continuation.resume(returning: ChangesList(scope: scope, revision: ChangesRevision(old: "aaaa", new: "bbbb"),
                                                       comparison: ChangesComparison(head: key, base: "HEAD"), files: []))
        }
    }
}

