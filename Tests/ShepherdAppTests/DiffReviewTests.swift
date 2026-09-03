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
