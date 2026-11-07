import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// A client's agent queries served by `SessionServer` with no app (`serveAgentQueries`), over
/// `host.sock`: a worktree thread is read and deleted with its checkout, a thread's change is
/// committed (each as an operation polled by id), and a thread's subagents, transcript and
/// working tree are read.
@Suite("Worktrees hosted by the server", .mainActorExclusive)
@MainActor
struct WorktreeHostingTests {
    private struct Hosted {
        let scratch: ScratchServer
        let client: RemoteHostClient
        let queries: WorktreeQueries
        let repo: URL
        let space: Space

        func stop() {
            client.disconnect()
            scratch.stop()
        }
    }

    private func host() async throws -> Hosted {
        let h = try ScratchServer.fresh()
        let queries = h.server.serveAgentQueries(WorktreeHosting(defaults: {
            .init(autoCommit: true, deleteLocalBranch: true, autoMergePR: false, mergeMethod: "squash", generateDescription: false)
        }, deleteAgent: { id, _ in try await h.server.deleteAgent(id) }))
        // `sh`, not the login shell, as the app's commit tests run it.
        queries.commitRunner = { script, cwd in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { return .init(status: 127, stdout: "", stderr: "\(error)") }
            let stdout = out.fileHandleForReading.readDataToEndOfFile(), stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return .init(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
        }
        let repo = h.dir.appendingPathComponent("acme-web")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "# acme-web\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Acme Tests"],
                     ["config", "user.email", "tests@example.com"], ["add", "."], ["commit", "-qm", "initial"]] {
            try git(args, in: repo)
        }
        let space = Space(name: "acme-web", path: repo.path)
        try await h.server.addSpace(space)
        let path = h.dir.appendingPathComponent("h.sock").path
        let tokenURL = h.dir.appendingPathComponent("remote-token")
        try h.server.startLocalListener(path: path, tokenURL: tokenURL)
        let client = RemoteHostClient(localSocket: path)
        _ = try await client.connect(host: "", port: 0, token: try String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), clientName: "Shepherd")
        return Hosted(scratch: h, client: client, queries: queries, repo: repo, space: space)
    }

    private func addAgent(_ name: String, cwd: String, in hosted: Hosted, branch: String? = nil, piSessionID: String? = nil) async throws -> AgentID {
        let pane = LeafPane(cwd: cwd)
        let tab = ShepherdCore.Tab(spaceID: hosted.space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: name, spaceID: hosted.space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true, piSessionID: piSessionID,
                          worktreeBranch: branch, worktreeBase: branch == nil ? nil : "main", worktreePath: branch == nil ? nil : cwd)
        try await hosted.scratch.server.addAgent(agent, withTab: tab)
        return agent.id
    }

    /// The operation as the client polls it, once the host has finished it.
    private func finished(_ id: UUID, agentID: AgentID, in hosted: Hosted) async throws -> RemoteWorktreeOperation {
        let queries = hosted.queries
        try await eventuallyOnMain("the host to finish the operation") { queries.operations[id]?.finished == true }
        guard case .worktreeOperation(let operation) = try await hosted.client.agentQuery(agentID: agentID, query: .worktreeStatus(operationID: id)) else {
            throw RemoteCreateAgentError("expected an operation")
        }
        return operation
    }

    @Test func aClientReadsAWorktreeThreadThenDeletesItWithItsCheckout() async throws {
        let hosted = try await host()
        defer { hosted.stop() }
        let checkout = try GitWorktree.add(repo: hosted.repo.path, branch: "agent/fix-login")
        let agentID = try await addAgent("fix-login", cwd: checkout, in: hosted, branch: "agent/fix-login")

        guard case .worktreeInfo(let info) = try await hosted.client.agentQuery(agentID: agentID, query: .worktreeInfo) else {
            Issue.record("expected worktree info"); return
        }
        #expect(info.branch == "agent/fix-login" && info.defaults.base == "main")
        #expect(info.warning == "1 commits not on a remote", "with no remote, the initial commit is the loss the client confirms")

        let id = UUID()
        _ = try await hosted.client.agentQuery(agentID: agentID, query: .deleteWorktree(operationID: id, confirmedWarning: info.warning, fingerprint: info.fingerprint))
        let operation = try await finished(id, agentID: agentID, in: hosted)

        #expect(operation.error == nil)
        #expect(!hosted.scratch.server.state.agents.contains { $0.id == agentID })
        #expect(!FileManager.default.fileExists(atPath: checkout))
        #expect(!(try git(["branch", "--format=%(refname:short)"], in: hosted.repo)).contains("agent/fix-login"))
    }

    @Test func aClientCommitsAThreadsChangeThroughTheHost() async throws {
        let hosted = try await host()
        defer { hosted.stop() }
        try "changed\n".write(to: hosted.repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "new\n".write(to: hosted.repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let agentID = try await addAgent("docs", cwd: hosted.repo.path, in: hosted)

        guard case .commitInfo(let info) = try await hosted.client.agentQuery(agentID: agentID, query: .commitInfo) else {
            Issue.record("expected commit info"); return
        }
        #expect(info.files.map(\.path) == ["README.md", "notes.txt"])
        guard case .commitMessage(let title, _, let drafted) = try await hosted.client.agentQuery(agentID: agentID, query: .commitMessage(paths: ["notes.txt"])) else {
            Issue.record("expected a message"); return
        }
        #expect(title == "Add notes.txt" && !drafted, "with drafting off the host writes it from the file list")

        let id = UUID()
        let options = RemoteCommitOptions(head: info.head, files: info.files.filter { $0.path == "README.md" }, title: "Update the readme",
                                          body: "", push: .none)
        _ = try await hosted.client.agentQuery(agentID: agentID, query: .commit(operationID: id, options: options))
        let operation = try await finished(id, agentID: agentID, in: hosted)

        #expect(operation.error == nil)
        #expect(try git(["log", "-1", "--format=%s"], in: hosted.repo).hasPrefix("Update the readme"))
        #expect(try git(["status", "--porcelain"], in: hosted.repo) == "?? notes.txt\n")
    }

    @Test func aClientReadsAThreadsSubagentsTranscriptAndWorkingTree() async throws {
        let hosted = try await host()
        defer { hosted.stop() }
        let agentID = try await addAgent("docs", cwd: hosted.repo.path, in: hosted, piSessionID: "sess-docs")
        try "changed\n".write(to: hosted.repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let sessions = PiSessionFile.projectDirectory(forCwd: hosted.repo.path, sessionsRoot: hosted.scratch.server.pi.sessionsRoot)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try (#"{"type":"message","message":{"role":"user","content":"Tidy the marmalade docs"}}"# + "\n")
            .write(to: sessions.appendingPathComponent("2026_sess-docs.jsonl"), atomically: true, encoding: .utf8)
        let rows = [ChildRun(runID: "run-1", label: "worker: restyle", state: "running")]
        // Seen once the host has taken the rows: its own handler runs first.
        let published = Locked(false)
        let hostHandler = hosted.scratch.server.onAgentChildren
        hosted.scratch.server.onAgentChildren = { hostHandler?($0, $1); published.withValue { $0 = true } }
        let pi = try ExtensionClient(path: hosted.scratch.socketPath)
        try pi.send(.setAgentChildren(agentID: agentID, children: rows))
        try await eventuallyOnMain("the host to take the published subagents") { published.withValue { $0 } }
        let client = hosted.client
        guard case .children(let children) = try await client.agentQuery(agentID: agentID, query: .children) else {
            Issue.record("expected subagents"); return
        }
        #expect(children == rows)

        guard case .search(let snippet) = try await client.agentQuery(agentID: agentID, query: .search(query: "marmalade")) else {
            Issue.record("expected a search answer"); return
        }
        #expect(snippet?.contains("marmalade") == true)
        guard case .review(let data, let reference) = try await client.agentQuery(agentID: agentID, query: .review(pullRequest: false)) else {
            Issue.record("expected a review"); return
        }
        #expect(reference == nil)
        #expect(try JSONDecoder().decode([DiffFile].self, from: data).map(\.displayPath) == ["README.md"])
    }
}
