import Foundation
import Testing
import ShepherdCore
import ShepherdSessions
@testable import ShepherdApp

@Suite("Diff review", .serialized)
@MainActor
struct DiffReviewTests {
    private struct Fixture {
        let dir: URL
        let server: SessionServer

        init() throws {
            dir = URL(fileURLWithPath: "/tmp/shepherd-review-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            server = SessionServer(
                socketPath: dir.appendingPathComponent("d.sock").path,
                stateURL: dir.appendingPathComponent("state.json")
            )
            try server.start()
        }

        func tearDown() {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private actor DelayedLoads {
        var pending: [String: CheckedContinuation<(files: [DiffFile], reference: String?), any Error>] = [:]

        func load(_ reference: String?) async throws -> (files: [DiffFile], reference: String?) {
            try await withCheckedThrowingContinuation { pending[reference ?? "local"] = $0 }
        }

        func waitFor(_ reference: String) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while pending[reference] == nil {
                guard ContinuousClock.now < deadline else { throw GitWorktree.Failure(message: "Loader was not called for \(reference)") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func finish(_ reference: String, failing: Bool = false) {
            guard let continuation = pending.removeValue(forKey: reference) else { return }
            if failing { continuation.resume(throwing: GitWorktree.Failure(message: "stale load failed")) }
            else { continuation.resume(returning: ([], reference)) }
        }
    }

    @Test func hostReviewLoadsIgnoreStaleSuccessFailureAndLoadingState() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let space = Space(name: "host", path: "/host/not-executed")
        let pane = LeafPane(cwd: space.path, isReview: true)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "host", spaceID: space.id, tabID: tab.id)
        try await fixture.server.putState(.init(spaces: [space], tabs: [tab], agents: [agent]))
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.agents.count == 1 })
        let session = ReviewSession(agentID: agent.id, paneID: pane.id, cwd: space.path, reference: nil)
        vm.reviewSessions[session.paneID] = session
        let loads = DelayedLoads()
        vm.reviewDiffLoader = { _, reference in try await loads.load(reference) }
        vm.reloadReview(session, reference: "old")
        try await loads.waitFor("old")
        vm.reloadReview(session, reference: "new")
        try await loads.waitFor("new")
        await loads.finish("old", failing: true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.isLoading)
        #expect(session.loadError == nil)
        await loads.finish("new")
        #expect(await waitUntil { !session.isLoading && session.reference == "new" })

        vm.reloadReview(session, reference: "slow")
        try await loads.waitFor("slow")
        vm.reloadReview(session, reference: "latest")
        try await loads.waitFor("latest")
        await loads.finish("latest")
        #expect(await waitUntil { session.reference == "latest" && !session.isLoading })
        await loads.finish("slow")
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.reference == "latest")
        #expect(session.loadError == nil)
    }

    @Test func formatReviewIncludesLineContextAcrossFiles() {
        let firstLine = DiffLine(kind: .added, text: "let x = 1", oldLine: nil, newLine: 42, id: 0)
        let secondLine = DiffLine(kind: .removed, text: "old", oldLine: 7, newLine: nil, id: 0)
        let files = [
            DiffFile(
                oldPath: "Sources/Foo.swift",
                newPath: "Sources/Foo.swift",
                displayPath: "Sources/Foo.swift",
                isNew: false,
                isDeleted: false,
                isRenamed: false,
                isBinary: false,
                hunks: [DiffHunk(header: "@@ -41 +42 @@", lines: [firstLine])]
            ),
            DiffFile(
                oldPath: "Sources/Bar.swift",
                newPath: "Sources/Bar.swift",
                displayPath: "Sources/Bar.swift",
                isNew: false,
                isDeleted: false,
                isRenamed: false,
                isBinary: false,
                hunks: [DiffHunk(header: "@@ -7 +7 @@", lines: [secondLine])]
            ),
        ]
        let comments = [
            ReviewComment(
                fileID: files[1].id,
                lineID: secondLine.id,
                filePath: files[1].displayPath,
                lineNumber: 7,
                marker: "-",
                content: "old",
                text: "remove this branch"
            ),
            ReviewComment(
                fileID: files[0].id,
                lineID: firstLine.id,
                filePath: files[0].displayPath,
                lineNumber: 42,
                marker: "+",
                content: "let x = 1",
                text: "prefer a named constant"
            ),
        ]

        #expect(formatReview(files: files, comments: comments, summary: "") == """
        Diff review (working tree vs HEAD):

        Sources/Foo.swift:42 [+ let x = 1]
          prefer a named constant

        Sources/Bar.swift:7 [- old]
          remove this branch
        """)
    }

    @Test func formatReviewHandlesEmptyCommentsAndSummary() {
        #expect(formatReview(files: [], comments: [], summary: "looks good") == """
        Diff review (working tree vs HEAD):

        No line comments.

        Overall: looks good
        """)
    }

    @Test func formatReviewHeaderNamesTheReference() {
        #expect(formatReview(files: [], comments: [], summary: "", reference: "master..HEAD") == """
        Diff review (master..HEAD):

        No line comments.
        """)
    }

    @Test func formatReviewHandlesEmptyEverything() {
        #expect(formatReview(files: [], comments: [], summary: "   \n") == """
        Diff review (working tree vs HEAD):

        No line comments.
        """)
    }

    @Test func agentReviewStaysInBackgroundAndSubmitsThenCloses() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let repo = fixture.dir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: repo)
        try runGit(["config", "user.name", "Shepherd Tests"], in: repo)
        try runGit(["config", "user.email", "tests@example.com"], in: repo)
        let source = repo.appendingPathComponent("file.txt")
        try "before\n".write(to: source, atomically: true, encoding: .utf8)
        try runGit(["add", "file.txt"], in: repo)
        try runGit(["commit", "-q", "-m", "initial"], in: repo)
        try "after\n".write(to: source, atomically: true, encoding: .utf8)

        let space = Space(name: "workspace", path: repo.path)
        let backgroundID = AgentID()
        let visibleID = AgentID()
        let backgroundPane = LeafPane(cwd: repo.path, agentID: backgroundID)
        let visiblePane = LeafPane(cwd: repo.path, agentID: visibleID)
        let backgroundTab = Tab(spaceID: space.id, order: 0, layout: .leaf(backgroundPane))
        let visibleTab = Tab(spaceID: space.id, order: 1, layout: .leaf(visiblePane))
        let backgroundAgent = Agent(
            id: backgroundID,
            name: "background",
            spaceID: space.id,
            tabID: backgroundTab.id,
            paneID: backgroundPane.id
        )
        let visibleAgent = Agent(
            id: visibleID,
            name: "visible",
            spaceID: space.id,
            tabID: visibleTab.id,
            paneID: visiblePane.id
        )
        try await fixture.server.putState(ShepherdState(
            spaces: [space],
            tabs: [backgroundTab, visibleTab],
            agents: [backgroundAgent, visibleAgent]
        ))
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.agents.count == 2 })
        vm.selectAgent(visibleID)
        vm.focusedPaneID = visiblePane.id

        var outcome: ReviewOutcome?
        fixture.server.onReviewRequest?(.start(agentID: backgroundID, cwd: repo.path, reference: nil)) {
            outcome = $0
        }

        #expect(await waitUntil { vm.reviewSessions.count == 1 })
        let session = try #require(vm.reviewSessions.values.first)

        // A second agent request must not split another pane — it reloads
        // the open one.
        var secondOutcome: ReviewOutcome?
        fixture.server.onReviewRequest?(.start(agentID: backgroundID, cwd: repo.path, reference: nil)) {
            secondOutcome = $0
        }
        #expect(vm.reviewSessions.count == 1)
        #expect(vm.state.tabs.first(where: { $0.id == backgroundTab.id })?.layout.leaves.count == 2)
        if case .submitted = try #require(secondOutcome) {} else {
            Issue.record("expected the duplicate request to be acknowledged, got \(String(describing: secondOutcome))")
        }

        // The tool is acknowledged immediately; the review text arrives later
        // as a typed prompt message.
        if case .submitted = try #require(outcome) {} else {
            Issue.record("expected an immediate submitted acknowledgment, got \(String(describing: outcome))")
        }
        #expect(vm.selectedAgentID == visibleID)
        #expect(vm.focusedPaneID == visiblePane.id)
        #expect(vm.state.tabs.first(where: { $0.id == backgroundTab.id })?.layout.leaves.count == 2)
        #expect(vm.state.tabs.first(where: { $0.id == backgroundTab.id })?.layout.leaf(withID: session.paneID)?.isReview == true)

        // The pane opens instantly; the diff fills in asynchronously.
        #expect(await waitUntil { !session.isLoading })
        let line = try #require(session.files.first?.hunks.first?.lines.first)
        let file = try #require(session.files.first)
        session.comments = [ReviewComment(
            fileID: file.id,
            lineID: line.id,
            filePath: file.displayPath,
            lineNumber: line.newLine ?? line.oldLine ?? 0,
            marker: line.kind.reviewMarker,
            content: line.text,
            text: "please check this"
        )]
        vm.submitReview(session)

        #expect(vm.reviewSessions.isEmpty)
        #expect(vm.state.tabs.first(where: { $0.id == backgroundTab.id })?.layout.leaves.map(\.id) == [backgroundPane.id])
    }

    @Test func explicitReviewTargetsRetargetOnePaneAndDefaultBackToAgentDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let repos = ["agent", "external", "worktree"].map { fixture.dir.appendingPathComponent($0) }
        for repo in repos {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try runGit(["init", "-q"], in: repo)
            try runGit(["config", "user.name", "Shepherd Tests"], in: repo)
            try runGit(["config", "user.email", "tests@example.com"], in: repo)
            let source = repo.appendingPathComponent("\(repo.lastPathComponent).txt")
            try "before\n".write(to: source, atomically: true, encoding: .utf8)
            try runGit(["add", "."], in: repo)
            try runGit(["commit", "-q", "-m", "initial"], in: repo)
            try "after\n".write(to: source, atomically: true, encoding: .utf8)
        }
        let space = Space(name: "workspace", path: repos[0].path)
        let agentID = AgentID()
        let piPane = LeafPane(cwd: space.path, agentID: agentID)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(piPane))
        let agent = Agent(id: agentID, name: "agent", spaceID: space.id, tabID: tab.id, paneID: piPane.id)
        try await fixture.server.putState(.init(spaces: [space], tabs: [tab], agents: [agent]))
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.agents.count == 1 })
        vm.selectAgent(agentID)
        var reviewPaneID: PaneID?

        for requestedCwd in [repos[1].path, repos[2].path, nil] as [String?] {
            vm.focusedPaneID = piPane.id
            fixture.server.onReviewRequest?(.start(agentID: agentID, cwd: requestedCwd, reference: nil)) { _ in }
            let session = try #require(vm.reviewSessions.values.first)
            let expectedCwd = requestedCwd ?? piPane.cwd
            if let reviewPaneID { #expect(session.paneID == reviewPaneID) }
            reviewPaneID = session.paneID
            #expect(vm.reviewSessions.count == 1)
            #expect(session.cwd == expectedCwd)
            #expect(session.comments.isEmpty)
            #expect(session.commentsByLine.isEmpty)
            #expect(session.summary.isEmpty)
            #expect(vm.selectedAgentID == agentID)
            #expect(vm.focusedPaneID == session.paneID)
            #expect(await waitUntil { !session.isLoading })
            #expect(session.loadError == nil)
            let file = try #require(session.files.first)
            #expect(session.files.map(\.displayPath) == [URL(fileURLWithPath: expectedCwd).lastPathComponent + ".txt"])
            let layout = try #require(vm.state.tabs.first(where: { $0.id == tab.id })?.layout)
            #expect(layout.leaves.count == 2)
            #expect(layout.leaf(withID: session.paneID)?.cwd == expectedCwd)
            #expect(layout.leaf(withID: piPane.id) == piPane)
            #expect(await waitUntil {
                fixture.server.state.tabs.first(where: { $0.id == tab.id })?.layout.leaf(withID: session.paneID)?.cwd == expectedCwd
            })
            session.comments = [ReviewComment(fileID: file.id, lineID: 0, filePath: file.displayPath, lineNumber: 1, text: "old target")]
            session.summary = "old target summary"
        }

        let session = try #require(vm.reviewSessions.values.first)
        let comments = session.comments
        vm.focusedPaneID = piPane.id
        fixture.server.onReviewRequest?(.start(agentID: agentID, cwd: nil, reference: nil)) { _ in }
        #expect(vm.focusedPaneID == session.paneID)
        #expect(session.comments == comments)
        #expect(session.summary == "old target summary")
        #expect(await waitUntil { !session.isLoading })
    }

    @Test(arguments: [false, true])
    func retargetIgnoresPendingOldDiff(failing: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let space = Space(name: "workspace", path: "/agent/not-executed")
        let agentID = AgentID()
        let piPane = LeafPane(cwd: space.path, agentID: agentID)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(piPane))
        let agent = Agent(id: agentID, name: "agent", spaceID: space.id, tabID: tab.id, paneID: piPane.id)
        try await fixture.server.putState(.init(spaces: [space], tabs: [tab], agents: [agent]))
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.agents.count == 1 })
        let loads = DelayedLoads()
        vm.reviewDiffLoader = { cwd, _ in try await loads.load(cwd) }
        fixture.server.onReviewRequest?(.start(agentID: agentID, cwd: nil, reference: nil)) { _ in }
        try await loads.waitFor(piPane.cwd)
        let session = try #require(vm.reviewSessions.values.first)
        session.comments = [ReviewComment(fileID: "file", lineID: 0, filePath: "file", lineNumber: 1, text: "old repo")]
        session.summary = "old repo"

        let target = ("~/review-target" as NSString).expandingTildeInPath
        fixture.server.onReviewRequest?(.start(agentID: agentID, cwd: "~/review-target", reference: nil)) { _ in }
        try await loads.waitFor(target)
        #expect(vm.reviewSessions[session.paneID] === session)
        #expect(session.cwd == target)
        #expect(session.comments.isEmpty)
        #expect(session.summary.isEmpty)
        await loads.finish(target)
        #expect(await waitUntil { !session.isLoading && session.reference == target })
        await loads.finish(piPane.cwd, failing: failing)
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.reference == target)
        #expect(session.loadError == nil)
        #expect(!session.isLoading)
        #expect(session.comments.isEmpty)
    }

    @Test func cancellingReviewDiscardsTheSession() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let session = ReviewSession(
            agentID: AgentID(),
            paneID: PaneID(),
            cwd: "/tmp",
            reference: nil
        )
        let vm = ShepherdViewModel(server: fixture.server)
        vm.reviewSessions[session.paneID] = session
        vm.cancelReview(session)
        #expect(vm.reviewSessions.isEmpty)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["HOME"] = directory.path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DiffReviewTests", code: Int(process.terminationStatus))
        }
    }
}
