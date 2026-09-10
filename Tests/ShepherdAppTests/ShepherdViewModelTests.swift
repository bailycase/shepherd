import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdRemote
@testable import ShepherdApp

@Suite("Shepherd view model", .serialized)
@MainActor
struct ShepherdViewModelTests {
    private struct Fixture {
        let dir: URL
        let server: SessionServer

        init() throws {
            dir = URL(fileURLWithPath: "/tmp/shepherd-vm-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
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

    private func seedWorkspace(on server: SessionServer) async throws -> (Space, Tab) {
        let space = Space(name: "workspace", path: "/tmp/workspace")
        let tab = Tab(
            spaceID: space.id,
            order: 0,
            layout: .leaf(LeafPane(cwd: space.path))
        )
        try await server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: []))
        return (space, tab)
    }

    /// A just-created agent wears the launch overlay until pi's status
    /// extension first reports — delivered over the same wiring a real
    /// report takes (session store callback → view model).
    @Test func launchOverlayLiftsOnFirstStatusReport() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let vm = ShepherdViewModel(server: fixture.server)
        let agentID = AgentID()

        vm.beginAgentLaunch(agentID)
        #expect(vm.launchingAgents.contains(agentID))

        vm.sessions.onAgentStatus?(agentID, .idle)
        #expect(vm.launchingAgents.isEmpty)

        // Explicit end (spawn failure, deletion) is idempotent.
        vm.beginAgentLaunch(agentID)
        vm.endAgentLaunch(agentID)
        vm.endAgentLaunch(agentID)
        #expect(vm.launchingAgents.isEmpty)
    }

    @Test func failedDeletionKeepsWorkspaceAndCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let (space, tab) = try await seedWorkspace(on: fixture.server)
        let checkout = fixture.dir.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let marker = checkout.appendingPathComponent("work.txt")
        try "keep me".write(to: marker, atomically: true, encoding: .utf8)
        var agent = Agent(name: "worktree", spaceID: space.id, tabID: tab.id)
        agent.worktreeBranch = "worktree/test"
        agent.worktreePath = checkout.path
        try await fixture.server.addAgent(agent)
        let original = fixture.server.state
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state == original })
        // A directory in place of state.json makes the atomic write fail.
        let stateURL = fixture.dir.appendingPathComponent("state.json")
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        vm.deleteWorktreeAgent(agent.id, removeWorktree: true)
        #expect(await waitUntil { vm.remoteActionError != nil })
        #expect(fixture.server.state == original)
        #expect(vm.state == original)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep me")
    }

    @Test func remoteWorktreeFailureRetainsCheckoutAndStatusSurvivesAgentRetirement() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let repo = fixture.dir.appendingPathComponent("repo").path
        let checkout = fixture.dir.appendingPathComponent("linked").path
        let setup = await LoginShell.run("mkdir \(shellQuoted(repo)) && git -C \(shellQuoted(repo)) init -q && git -C \(shellQuoted(repo)) -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initial && git -C \(shellQuoted(repo)) worktree add -qb worktree/test \(shellQuoted(checkout))", timeout: 10)
        #expect(setup.status == 0)
        let space = Space(name: "test", path: repo)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: checkout)))
        var agent = Agent(name: "worktree", spaceID: space.id, tabID: tab.id)
        agent.worktreeBranch = "worktree/test"
        agent.worktreePath = checkout
        try await fixture.server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.agents.count == 1 })
        guard case .worktreeInfo(let info) = try await vm.handleRemoteWorktree(agent.id, query: .worktreeInfo) else {
            Issue.record("Expected worktree info"); return
        }
        #expect(info.warning != nil)
        let stateURL = fixture.dir.appendingPathComponent("state.json")
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        let id = UUID()
        _ = try await vm.handleRemoteWorktree(agent.id, query: .deleteWorktree(operationID: id, confirmedWarning: info.warning, fingerprint: info.fingerprint))
        #expect(await waitUntil { vm.hostWorktreeOperations[id]?.finished == true })
        #expect(vm.hostWorktreeOperations[id]?.error != nil)
        #expect(FileManager.default.fileExists(atPath: checkout))
        #expect(fixture.server.state.agents.count == 1)
        // Polling and a duplicate operation ID return the saved outcome, never execute again.
        let saved = vm.hostWorktreeOperations[id]
        guard case .worktreeOperation(let duplicate) = try await vm.handleRemoteWorktree(agent.id, query: .deleteWorktree(operationID: id, confirmedWarning: info.warning, fingerprint: info.fingerprint)) else {
            Issue.record("Expected saved operation"); return
        }
        #expect(duplicate == saved)
        // Operation status does not require the agent to remain in the live snapshot.
        try FileManager.default.removeItem(at: stateURL)
        try await fixture.server.deleteAgent(agent.id)
        guard case .worktreeOperation(let status) = try await vm.handleRemoteWorktree(agent.id, query: .worktreeStatus(operationID: id)) else {
            Issue.record("Expected saved status"); return
        }
        #expect(status == saved)
        #expect(FileManager.default.fileExists(atPath: checkout))
    }

    @Test func checkoutApprovalRejectsSameCountChangesAndBusyCreation() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let repo = fixture.dir.appendingPathComponent("repo").path
        let checkout = fixture.dir.appendingPathComponent("linked").path
        let seeded = await LoginShell.run("mkdir \(shellQuoted(repo)) && git -C \(shellQuoted(repo)) init -qb main && git -C \(shellQuoted(repo)) -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initial && git -C \(shellQuoted(repo)) worktree add -qb worktree/safe \(shellQuoted(checkout))", timeout: 10)
        #expect(seeded.status == 0)
        let marker = URL(fileURLWithPath: checkout).appendingPathComponent("work.txt")
        try "first".write(to: marker, atomically: true, encoding: .utf8)
        let space = Space(name: "host", path: repo)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: checkout)))
        var agent = Agent(name: "host", spaceID: space.id, tabID: tab.id)
        agent.worktreeBranch = "worktree/safe"; agent.worktreePath = checkout
        try await fixture.server.putState(.init(spaces: [space], tabs: [tab], agents: [agent]))
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.agents.count == 1 })
        guard case .worktreeInfo(let info) = try await vm.handleRemoteWorktree(agent.id, query: .worktreeInfo) else { Issue.record("Missing info"); return }
        try "second".write(to: marker, atomically: true, encoding: .utf8)
        #expect(try GitWorktree.checkedUnreconciledWork(worktree: checkout, branch: "worktree/safe") == info.warning)
        await #expect(throws: RemoteCreateAgentError.self) {
            _ = try await vm.handleRemoteWorktree(agent.id, query: .deleteWorktree(operationID: UUID(), confirmedWarning: info.warning, fingerprint: info.fingerprint))
        }
        #expect(fixture.server.state.agents.count == 1)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "second")
        vm.hostBusyWorktrees.insert(URL(fileURLWithPath: checkout).resolvingSymlinksInPath().path)
        await #expect(throws: RemoteCreateAgentError.self) {
            _ = try await vm.startAgent(.init(spaceID: space.id, workingDirectory: checkout + "/subdir", model: nil, thinking: .high, initialPrompt: nil))
        }
        await #expect(throws: RemoteCreateAgentError.self) {
            _ = try await vm.openRemoteUtilityTerminal(agent: agent, cwd: checkout, key: "blocked", command: "never")
        }
        #expect(await vm.addSpace(at: URL(fileURLWithPath: checkout), createInitialAgent: false) == nil)
        let shell = Tab(spaceID: space.id, order: 2, layout: .leaf(LeafPane(cwd: checkout)))
        try await fixture.server.addTab(shell)
        vm.sessions.stateDidChange(fixture.server.state)
        let paneSession = vm.sessions.session(for: shell.layout.firstLeaf, in: shell)
        #expect(await waitUntil {
            if case .failed = paneSession.phase { return true }
            return false
        })
        #expect(fixture.server.state.tabs.first { $0.id == shell.id }?.layout.firstLeaf.sessionID == nil)
        try await fixture.server.removeTab(shell.id)
        vm.hostBusyWorktrees.removeAll()
        vm.startingCheckoutUsers[UUID()] = checkout
        #expect(throws: RemoteCreateAgentError.self) { try vm.verifyCheckoutUnused(URL(fileURLWithPath: checkout).resolvingSymlinksInPath().path, except: agent.id) }
        vm.startingCheckoutUsers.removeAll()
        let gitFile = try String(contentsOf: URL(fileURLWithPath: checkout).appendingPathComponent(".git"), encoding: .utf8)
        let gitDirectory = String(gitFile.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst("gitdir: ".count))
        try "ref: refs/heads/main\n".write(to: URL(fileURLWithPath: gitDirectory).appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        #expect(throws: GitWorktree.Failure.self) { try GitWorktree.remove(repo: repo, branch: "worktree/safe", worktree: checkout, fingerprint: info.fingerprint) }
        #expect(FileManager.default.fileExists(atPath: checkout))
    }

    @Test func inspectorPaneControlsNeverTargetParentOrForeignTabs() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let space = Space(name: "host", path: fixture.dir.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))
        let agent = Agent(name: "parent", spaceID: space.id, tabID: tab.id)
        let first = LeafPane(cwd: space.path)
        let second = LeafPane(cwd: space.path)
        let inspector = Tab(spaceID: space.id, order: 1, layout: .split(axis: .vertical, ratio: 0.5, first: .leaf(first), second: .leaf(second)), inspectorFor: agent.id)
        try await fixture.server.putState(.init(spaces: [space], tabs: [tab, inspector], agents: [agent]))
        let vm = ShepherdViewModel(server: fixture.server)
        vm.hostRemoteInspectors["test"] = inspector.id
        #expect(await waitUntil { vm.state.agents.count == 1 })
        await #expect(throws: RemoteCreateAgentError.self) {
            _ = try await vm.handleRemoteInspectorPane(agentID: agent.id, tabID: tab.id, action: .close(paneID: tab.layout.firstLeaf.id))
        }
        await #expect(throws: RemoteCreateAgentError.self) {
            _ = try await vm.handleRemoteInspectorPane(agentID: AgentID(), tabID: inspector.id, action: .close(paneID: first.id))
        }
        _ = try await vm.handleRemoteInspectorPane(agentID: agent.id, tabID: inspector.id, action: .resize(split: inspector.layout, ratio: 0.7))
        #expect(fixture.server.state.tabs.first { $0.id == inspector.id }?.layout == inspector.layout.replacingSplit(inspector.layout, withRatio: 0.7))
        #expect(try await vm.handleRemoteInspectorPane(agentID: agent.id, tabID: inspector.id, action: .close(paneID: second.id)) == .inspectorFocus(first.id))
        await #expect(throws: RemoteCreateAgentError.self) {
            _ = try await vm.handleRemoteInspectorPane(agentID: agent.id, tabID: inspector.id, action: .close(paneID: first.id))
        }
        vm.hostBusyWorktrees.insert(URL(fileURLWithPath: space.path).resolvingSymlinksInPath().path)
        await #expect(throws: RemoteCreateAgentError.self) {
            _ = try await vm.handleRemoteInspectorPane(agentID: agent.id, tabID: inspector.id, action: .split(paneID: first.id, axis: .vertical))
        }
        #expect(fixture.server.state.tabs.first { $0.id == tab.id }?.layout == tab.layout)
    }

    @Test func hostReviewLeavesLoadAndCloseThroughRemoteQueries() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let space = Space(name: "host", path: "/tmp/unused")
        let primary = LeafPane(cwd: space.path)
        let reviewPane = LeafPane(cwd: space.path, isReview: true)
        let tab = Tab(spaceID: space.id, order: 0, layout: .split(axis: .vertical, ratio: 0.5, first: .leaf(primary), second: .leaf(reviewPane)))
        let agent = Agent(name: "parent", spaceID: space.id, tabID: tab.id)
        try await fixture.server.putState(.init(spaces: [space], tabs: [tab], agents: [agent]))
        let suite = "shepherd.host-review.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let remotes = RemoteHostStore(defaults: defaults)
        let vm = ShepherdViewModel(server: fixture.server, remoteHosts: remotes)
        #expect(await waitUntil { vm.state.agents.count == 1 })
        vm.reviewSessions[reviewPane.id] = ReviewSession(agentID: agent.id, paneID: reviewPane.id, cwd: space.path, reference: "origin/main")
        let tokenURL = fixture.dir.appendingPathComponent("remote-token")
        let port = try fixture.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        remotes.addHost(name: "host", host: "127.0.0.1", port: port, token: token)
        let connection = try #require(remotes.connections.first)
        defer { remotes.removeHost(id: connection.id) }
        #expect(await waitUntil { connection.phase == .connected })
        let target = RemoteAgentRef(hostID: connection.id, agentID: agent.id)
        let draft = ReviewSession(agentID: agent.id, paneID: PaneID(), cwd: space.path, reference: nil)
        draft.summary = "draft before host review"
        draft.comments = [.init(fileID: "file", lineID: 1, filePath: "file.swift", lineNumber: 2, text: "preserve this comment")]
        vm.remoteReviews[target] = draft
        vm.remoteFocusedPaneID = draft.paneID
        vm.openRemoteHostReview(target, pane: reviewPane)
        #expect(vm.remoteReviews[target]?.summary == draft.summary)
        #expect(vm.remoteReviews[target]?.comments == draft.comments)
        #expect(vm.remoteFocusedPaneID == reviewPane.id)
        #expect(await waitUntil { vm.remoteReviews[target]?.reference == "origin/main" })
        let review = try #require(vm.remoteReviews[target])
        #expect(review.hostReviewPane)
        #expect(review.summary == draft.summary)
        #expect(review.comments == draft.comments)
        #expect(!review.isLoading)
        vm.cancelReview(try #require(vm.reviewSessions[reviewPane.id]))
        #expect(await waitUntil { vm.reviewSessions[reviewPane.id] == nil && !connection.state.tabs.contains { $0.layout.contains(reviewPane.id) } })
        #expect(vm.remoteReviews[target] === review)
        #expect(!review.hostReviewPane)
        #expect(review.paneID != reviewPane.id)
        #expect(vm.remoteFocusedPaneID == review.paneID)
        #expect(review.summary == draft.summary && review.comments == draft.comments)
        fixture.server.onRemoteAgentQuery = { _, query, completion in
            if case .review(let pullRequest) = query {
                #expect(pullRequest)
                completion(.success(.review(files: Data("[]".utf8), reference: "fresh-base")))
            } else if case .children = query { completion(.success(.children([]))) }
            else { completion(.failure(RemoteCreateAgentError("Stale host review queried"))) }
        }
        vm.openRemoteReview(target, pullRequest: true)
        #expect(await waitUntil { review.reference == "fresh-base" && !review.isLoading })
        #expect(review.loadError == nil)
        #expect(review.comments == draft.comments)
    }

    @Test func delayedRemoteReviewAndInspectorResponsesDoNotReplaceNewerChoices() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let space = Space(name: "host", path: "/tmp/unused")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))
        let agent = Agent(name: "parent", spaceID: space.id, tabID: tab.id)
        try await fixture.server.putState(.init(spaces: [space], tabs: [tab], agents: [agent]))
        let suite = "shepherd.races.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let remotes = RemoteHostStore(defaults: defaults)
        let vm = ShepherdViewModel(server: fixture.server, remoteHosts: remotes)
        var reviews: [(Result<RemoteAgentResult, RemoteCreateAgentError>) -> Void] = []
        var inspectors: [(Result<RemoteAgentResult, RemoteCreateAgentError>) -> Void] = []
        var submissions: [(Result<RemoteAgentResult, RemoteCreateAgentError>) -> Void] = []
        fixture.server.onRemoteAgentQuery = { _, query, completion in
            MainActor.assumeIsolated {
                switch query {
                case .review, .reviewPane: reviews.append(completion)
                case .inspect: inspectors.append(completion)
                case .finishReview: submissions.append(completion)
                default: completion(.success(.children([])))
                }
            }
        }
        let tokenURL = fixture.dir.appendingPathComponent("remote-token")
        let port = try fixture.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        remotes.addHost(name: "host", host: "127.0.0.1", port: port, token: token)
        let connection = try #require(remotes.connections.first)
        defer { remotes.removeHost(id: connection.id) }
        #expect(await waitUntil { connection.phase == .connected && vm.state.agents.count == 1 })
        let target = RemoteAgentRef(hostID: connection.id, agentID: agent.id)
        vm.selectRemoteAgent(hostID: connection.id, agentID: agent.id)
        vm.openRemoteReview(target, pullRequest: false)
        let review = try #require(vm.remoteReviews[target])
        #expect(await waitUntil { reviews.count == 1 })
        vm.reloadReview(review, reference: "pr")
        #expect(await waitUntil { reviews.count == 2 })
        let files = try JSONEncoder().encode([DiffFile]())
        reviews[1](.success(.review(files: files, reference: "new-base")))
        #expect(await waitUntil { review.reference == "new-base" && !review.isLoading })
        reviews[0](.success(.review(files: files, reference: "old-base")))
        try await Task.sleep(for: .milliseconds(50))
        #expect(review.reference == "new-base")
        review.hostReviewPane = true
        vm.submitReview(review)
        vm.submitReview(review)
        #expect(await waitUntil { submissions.count == 1 })
        let replacement = ReviewSession(agentID: agent.id, paneID: PaneID(), cwd: "/remote", reference: nil)
        replacement.summary = "keep these comments"
        vm.remoteReviews[target] = replacement
        submissions[0](.success(.ok))
        #expect(await waitUntil { !review.isSubmitting })
        #expect(vm.remoteReviews[target] === replacement)
        #expect(replacement.summary == "keep these comments")
        vm.openRemoteChild(target, child: .init(runID: "one", label: "one", state: "running"))
        #expect(await waitUntil { inspectors.count == 1 })
        vm.openRemoteChild(target, child: .init(runID: "two", label: "two", state: "running"))
        #expect(await waitUntil { inspectors.count == 2 })
        let inspector = Tab(spaceID: space.id, order: 1, layout: .leaf(LeafPane(cwd: space.path)), inspectorFor: agent.id)
        try await fixture.server.addTab(inspector)
        #expect(await waitUntil { connection.state.tabs.contains { $0.id == inspector.id } })
        inspectors[1](.success(.inspector(inspector.id)))
        #expect(await waitUntil { vm.remoteInspectingAgent == target })
        #expect(vm.remoteFocusedPaneID == inspector.layout.firstLeaf.id)
        vm.focusAdjacentPane(1)
        #expect(vm.remoteFocusedPaneID == inspector.layout.firstLeaf.id)
        #expect(vm.remoteReviews[target] === replacement)
        #expect(replacement.summary == "keep these comments")
        #expect(vm.remoteInspectingAgent == target)
        vm.selectAgent(agent.id)
        inspectors[0](.success(.inspector(TabID())))
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.selectedRemoteAgent == nil)
        #expect(vm.remoteInspectingAgent == nil)
    }

    @Test func remoteWorktreeCreationRejectsAnotherRepositoryBeforeMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let first = fixture.dir.appendingPathComponent("first").path
        let second = fixture.dir.appendingPathComponent("second").path
        for repo in [first, second] {
            let seeded = await LoginShell.run("mkdir \(shellQuoted(repo)) && git -C \(shellQuoted(repo)) init -qb main && git -C \(shellQuoted(repo)) -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initial", timeout: 10)
            #expect(seeded.status == 0)
        }
        let space = Space(name: "first", path: first)
        try await fixture.server.addSpace(space)
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.spaces.contains { $0.id == space.id } })
        let handler = try #require(fixture.server.onRemoteCreateAgent)
        let result = await withCheckedContinuation { continuation in
            handler(.init(spaceID: space.id, cwd: second, model: nil, thinking: nil, initialPrompt: nil,
                          worktreeBranch: "worktree/wrong", worktreeBase: "main", worktreeFetchFirst: false)) {
                continuation.resume(returning: $0)
            }
        }
        guard case .failure(let error) = result else { Issue.record("Cross-repository worktree created"); return }
        #expect(error.message.contains("Choose a directory") && error.message.contains("repository"))
        #expect(fixture.server.state.agents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: GitWorktree.destination(repo: second, branch: "worktree/wrong")))
        let branches = await LoginShell.run("git -C \(shellQuoted(second)) branch --list worktree/wrong", timeout: 10)
        #expect(branches.status == 0 && branches.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func remoteApprovalsAreInvalidatedByEndpointReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let tokenURL = fixture.dir.appendingPathComponent("remote-token")
        let port = try fixture.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let suite = "shepherd.endpoint.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let remotes = RemoteHostStore(defaults: defaults)
        remotes.addHost(name: "host", host: "127.0.0.1", port: port, token: token)
        let connection = try #require(remotes.connections.first)
        defer { remotes.removeHost(id: connection.id) }
        #expect(await waitUntil { connection.phase == .connected })
        let endpoint = connection.endpointID
        let transport = connection.transportID
        connection.phase = .disconnected
        do {
            _ = try await remotes.agentQuery(.init(hostID: connection.id, agentID: AgentID()), query: .deleteKeepingWorktree)
            Issue.record("Disconnected action accepted")
        } catch RemoteHostClientError.rejected(let code, _) { #expect(code == "not_sent") }
        connection.phase = .connected
        remotes.updateHost(id: connection.id, name: "replacement", host: "127.0.0.1", port: port, token: token)
        #expect(await waitUntil { connection.phase == .connected })
        #expect(connection.endpointID != endpoint)
        await #expect(throws: ShepherdRemote.RemoteHostClientError.self) {
            _ = try await remotes.agentQuery(.init(hostID: connection.id, agentID: AgentID()), query: .deleteKeepingWorktree, endpointID: endpoint, transportID: transport)
        }
    }

    @Test func remoteFinalizePreviewUsesHostCheckoutAndSettings() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let repo = fixture.dir.appendingPathComponent("repo").path
        let checkout = fixture.dir.appendingPathComponent("linked").path
        let seeded = await LoginShell.run("mkdir \(shellQuoted(repo)) && git -C \(shellQuoted(repo)) init -qb main && git -C \(shellQuoted(repo)) -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initial && git -C \(shellQuoted(repo)) worktree add -qb worktree/preview \(shellQuoted(checkout)) && git -C \(shellQuoted(checkout)) -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm feature", timeout: 10)
        #expect(seeded.status == 0)
        let space = Space(name: "host", path: repo)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: checkout)))
        var agent = Agent(name: "host feature", spaceID: space.id, tabID: tab.id)
        agent.worktreeBranch = "worktree/preview"
        agent.worktreePath = checkout
        agent.worktreeBase = "origin/main"
        try await fixture.server.putState(.init(spaces: [space], tabs: [tab], agents: [agent]))
        let suite = "shepherd.preview.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(store: defaults)
        settings.worktreeGeneratePRDescription = false
        settings.worktreeAutoCommit = false
        let vm = ShepherdViewModel(server: fixture.server, settings: settings)
        vm.hostPRDescriptionGenerator.runner = { script, cwd, _ in
            #expect(cwd == checkout)
            if script.hasPrefix("exec pi") { return .init(status: 0, stdout: "## Summary\nHost feature", stderr: "") }
            return .init(status: 0, stdout: "- host commit", stderr: "")
        }
        let tokenURL = fixture.dir.appendingPathComponent("remote-token")
        let port = try fixture.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let remotes = RemoteHostStore(defaults: defaults)
        remotes.addHost(name: "host", host: "127.0.0.1", port: port, token: token)
        let connection = try #require(remotes.connections.first)
        defer { remotes.removeHost(id: connection.id) }
        #expect(await waitUntil { connection.phase == .connected })
        let target = RemoteAgentRef(hostID: connection.id, agentID: agent.id)
        #expect(try await remotes.agentQuery(target, query: .worktreeCommitCount(base: "main")) == .worktreeCommitCount(1))
        #expect(try await remotes.agentQuery(target, query: .worktreeCommitCount(base: "missing")) == .worktreeCommitCount(nil))
        #expect(try await remotes.agentQuery(target, query: .worktreeDescription(base: "main", title: "feature")) == .worktreeDescription(body: ""))
        guard case .worktreeInfo(let info) = try await remotes.agentQuery(target, query: .worktreeInfo) else { Issue.record("Missing info"); return }
        #expect(info.defaults.base == "main")
        #expect(!info.defaults.autoCommit)
        #expect(info.generateDescription == false)
        settings.worktreeGeneratePRDescription = true
        #expect(try await remotes.agentQuery(target, query: .worktreeDescription(base: "main", title: "feature")) == .worktreeDescription(body: "## Summary\nHost feature"))
        #expect(FileManager.default.fileExists(atPath: checkout))
    }

    @Test func remoteChildrenRefreshWithoutViewsAndClearOnRetirementAndDisconnect() async throws {
        let local = try Fixture()
        let host = try Fixture()
        defer { local.tearDown(); host.tearDown() }
        let space = Space(name: "host", path: "/tmp/unused")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))
        let agent = Agent(name: "parent", spaceID: space.id, tabID: tab.id)
        let state = ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
        try await host.server.putState(state)
        try await local.server.putState(state)
        let hostVM = ShepherdViewModel(server: host.server)
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        let port = try host.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let suite = "shepherd.children.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let remotes = RemoteHostStore(defaults: defaults)
        remotes.addHost(name: "host", host: "127.0.0.1", port: port, token: token)
        let connection = try #require(remotes.connections.first)
        defer { remotes.removeHost(id: connection.id) }
        let vm = ShepherdViewModel(server: local.server, remoteHosts: remotes, sidebarDefaults: defaults)
        #expect(await waitUntil { connection.phase == .connected && vm.state.agents.count == 1 && hostVM.state.agents.count == 1 })
        vm.collapsedHosts.insert(connection.id)
        let target = RemoteAgentRef(hostID: connection.id, agentID: agent.id)
        hostVM.applyAgentChildren(agent.id, [ChildRun(runID: "run", label: "hidden child", state: "running")])
        #expect(await waitUntil { vm.remoteChildren[target]?.first?.state == "running" })
        #expect(vm.paletteItems.contains { $0.title == "hidden child" })
        hostVM.applyAgentChildren(agent.id, [ChildRun(runID: "run", label: "hidden child", state: "blocked", needsAttention: true)])
        #expect(await waitUntil { vm.remoteChildren[target]?.first?.needsAttention == true })
        #expect(vm.blockedCount == 1)
        var blockedAgent = agent
        blockedAgent.status = .blocked
        try await local.server.updateAgent(blockedAgent)
        try await host.server.updateAgent(blockedAgent)
        #expect(await waitUntil { vm.blockedCount == 3 })
        vm.selectRemoteAgent(hostID: connection.id, agentID: agent.id)
        #expect(vm.waitingQueue?.position == 2)
        #expect(vm.statusCounts.first(where: { $0.status == .blocked })?.count == 2)
        hostVM.applyAgentChildren(agent.id, [])
        #expect(await waitUntil { vm.remoteChildren[target]?.isEmpty == true })
        #expect(!vm.paletteItems.contains { $0.title == "hidden child" })
        hostVM.applyAgentChildren(agent.id, [ChildRun(runID: "next", label: "retire child", state: "running")])
        #expect(await waitUntil { vm.remoteChildren[target]?.isEmpty == false })
        try await host.server.deleteAgent(agent.id)
        #expect(await waitUntil { connection.children[agent.id] == nil })
        remotes.removeHost(id: connection.id)
        #expect(connection.children.isEmpty)
        #expect(vm.blockedCount == 1)
    }

    @Test func remoteNavigationAndActionsNeverUseMatchingLocalIDs() async throws {
        let local = try Fixture()
        let host = try Fixture()
        defer { local.tearDown(); host.tearDown() }
        let space = Space(name: "test", path: "/tmp/test")
        let tabs = (0..<2).map { Tab(spaceID: space.id, order: $0, layout: .leaf(LeafPane(cwd: space.path))) }
        let agents = tabs.enumerated().map { Agent(name: "agent\($0.offset)", spaceID: space.id, tabID: $0.element.id) }
        let original = ShepherdState(spaces: [space], tabs: tabs, agents: agents)
        try await local.server.putState(original)
        try await host.server.putState(original)
        let hostVM = ShepherdViewModel(server: host.server)
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        let port = try host.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let suite = "shepherd.parity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let remotes = RemoteHostStore(defaults: defaults)
        remotes.addHost(name: "host", host: "127.0.0.1", port: port, token: token)
        let connection = try #require(remotes.connections.first)
        defer { remotes.removeHost(id: connection.id) }
        let vm = ShepherdViewModel(server: local.server, remoteHosts: remotes, sidebarDefaults: defaults)
        #expect(await waitUntil { connection.phase == .connected && vm.state == original && hostVM.state == original })
        vm.selectAgent(agents[0].id)
        vm.selectRemoteAgent(hostID: connection.id, agentID: agents[0].id)
        vm.selectAdjacentAgent(1)
        #expect(vm.selectedRemoteAgent?.agentID == agents[1].id)
        #expect(vm.selectedAgentID == agents[0].id)
        vm.selectAgentDigit(1)
        let target = try #require(vm.selectedRemoteAgent)
        vm.openUserReview()
        #expect(vm.remoteReviews[target] != nil)
        #expect(vm.reviewSessions.isEmpty)
        try await remotes.agentAction(target, action: .rename(name: "remote only"))
        #expect(host.server.state.agents[0].name == "remote only")
        #expect(local.server.state == original)
        try await remotes.agentAction(target, action: .reorder(target: agents[1].id))
        #expect(host.server.state.agents.map(\.id) == agents.reversed().map(\.id))
        #expect(!vm.dropRemoteAgent(payload: ShepherdViewModel.dragPayload(agent: agents[0].id), on: target))
        try await remotes.agentAction(target, action: .deleteKeepingWorktree)
        #expect(host.server.state.agents.map(\.id) == [agents[1].id])
        #expect(local.server.state == original)
        _ = hostVM
    }

    @Test func newChildBatchesStartCollapsed() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let vm = ShepherdViewModel(server: fixture.server)
        let agentID = AgentID()
        let child = ChildRun(runID: "run", label: "reviewer", state: "running")

        vm.applyAgentChildren(agentID, [child])
        #expect(vm.collapsedChildren.contains(agentID))

        vm.collapsedChildren.remove(agentID)
        vm.applyAgentChildren(agentID, [child])
        #expect(!vm.collapsedChildren.contains(agentID))

        vm.applyAgentChildren(agentID, [])
        vm.applyAgentChildren(agentID, [child])
        #expect(vm.collapsedChildren.contains(agentID))
    }

    @Test func injectedServerBootstrapsPersistedWorkspace() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let (space, tab) = try await seedWorkspace(on: fixture.server)

        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.spaces == [space] && vm.state.tabs == [tab] })
        #expect(vm.selectedSpaceID == space.id)
        #expect(vm.activeTabID == tab.id)
    }

    /// Cold parking end to end at the view-model seam: a layout hidden past
    /// the delay and outside the hot set unmounts and its pane session is
    /// dropped from the store; selecting it again unparks it immediately.
    @Test func hiddenLayoutsParkAndUnparkOnSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let space = Space(name: "s", path: "/tmp/s")
        var tabs: [Tab] = []
        var agents: [Agent] = []
        for i in 0..<6 {
            let agentID = AgentID()
            let pane = LeafPane(cwd: "/tmp/s", agentID: agentID)
            let tab = Tab(spaceID: space.id, order: i, layout: .leaf(pane))
            tabs.append(tab)
            agents.append(Agent(id: agentID, name: "a\(i)", spaceID: space.id, tabID: tab.id, paneID: pane.id))
        }
        try await fixture.server.putState(ShepherdState(spaces: [space], tabs: tabs, agents: agents))
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.agents.count == 6 })

        // Visit every agent in order (what the workspace view does on each
        // active-tab change), ending on the last one.
        for agent in agents {
            vm.selectAgent(agent.id)
            vm.noteActiveTabVisited()
        }
        // Pane views would normally mount sessions; simulate for the first.
        let firstPane = tabs[0].layout.firstLeaf
        let paneSession = vm.sessions.session(for: firstPane, in: tabs[0])
        #expect(vm.sessions.session(for: firstPane, in: tabs[0]) === paneSession)
        #expect(vm.mountedTabs.count == 6)

        // Nothing parks inside the delay.
        vm.sweepColdPanes()
        #expect(vm.parkedTabIDs.isEmpty)

        // Past the delay: the five hidden layouts minus the four hottest
        // leaves exactly the first-visited one parked.
        vm.sweepColdPanes(now: Date().addingTimeInterval(60))
        #expect(vm.parkedTabIDs == [tabs[0].id])
        #expect(!vm.mountedTabs.contains { $0.id == tabs[0].id })
        // The store dropped the pane session: a remount gets a fresh one.
        #expect(vm.sessions.session(for: firstPane, in: tabs[0]) !== paneSession)

        // Selecting it unparks it and it re-enters the mounted set.
        vm.selectAgent(agents[0].id)
        vm.noteActiveTabVisited()
        #expect(vm.parkedTabIDs.isEmpty)
        #expect(vm.mountedTabs.contains { $0.id == tabs[0].id })
    }

    @Test func remoteSpaceCollapseSurvivesViewModelRestart() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let defaultsName = "shepherd.remote-space-collapse.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let hostID = UUID()
        let otherHostID = UUID()
        let spaceID = SpaceID()

        var vm: ShepherdViewModel? = ShepherdViewModel(
            server: fixture.server,
            remoteHosts: RemoteHostStore(defaults: defaults),
            sidebarDefaults: defaults
        )
        vm?.toggleRemoteSpaceCollapsed(hostID: hostID, spaceID: spaceID)
        #expect(vm?.isRemoteSpaceCollapsed(hostID: hostID, spaceID: spaceID) == true)
        #expect(vm?.isRemoteSpaceCollapsed(hostID: otherHostID, spaceID: spaceID) == false)

        vm = nil
        let restored = ShepherdViewModel(
            server: fixture.server,
            remoteHosts: RemoteHostStore(defaults: defaults),
            sidebarDefaults: defaults
        )
        #expect(restored.isRemoteSpaceCollapsed(hostID: hostID, spaceID: spaceID))
        #expect(!restored.isRemoteSpaceCollapsed(hostID: otherHostID, spaceID: spaceID))
    }

    @Test(arguments: ["available", "missingHost", "missingAgent", "missingTab"])
    func selectedAgentCommandsPreserveLocalWorkspaceWhileRemoteSelected(remoteState: String) async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let remote = try Fixture()
        defer { remote.tearDown() }

        let space = Space(name: "workspace", path: "/tmp/workspace")
        let agentID = AgentID()
        let pane = LeafPane(cwd: space.path, agentID: agentID)
        let auxiliary = LeafPane(cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .split(
            axis: .vertical, ratio: 0.5, first: .leaf(pane), second: .leaf(auxiliary)
        ))
        let agent = Agent(id: agentID, name: "worker", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        let original = ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
        try await fixture.server.putState(original)
        // Matching IDs on different hosts must still remain separate targets.
        try await remote.server.putState(original)
        let tokenURL = remote.dir.appendingPathComponent("remote-token")
        let port = try remote.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultsName = "shepherd.remote.agent-commands.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let remoteHosts = RemoteHostStore(defaults: defaults)
        remoteHosts.addHost(name: "remote", host: "127.0.0.1", port: port, token: token)
        let connection = try #require(remoteHosts.connections.first)
        defer { remoteHosts.removeHost(id: connection.id) }
        let vm = ShepherdViewModel(server: fixture.server, remoteHosts: remoteHosts, sidebarDefaults: defaults)
        #expect(await waitUntil {
            vm.state == original && connection.phase == .connected && connection.state == original
        })
        vm.selectAgent(agent.id)
        vm.focusedPaneID = auxiliary.id
        let renameItem = try #require(vm.paletteItems.first { $0.id == "action.rename" })
        vm.selectRemoteAgent(hostID: connection.id, agentID: agent.id)
        let selectedRemote = vm.selectedRemoteAgent
        switch remoteState {
        case "missingHost": remoteHosts.removeHost(id: connection.id)
        case "missingAgent": connection.state.agents = []
        case "missingTab": connection.state.tabs = []
        default: break
        }

        vm.deleteSelectedAgent()
        vm.renameSelectedAgent()
        vm.runPaletteItem(renameItem)
        #expect(vm.agentRenameTarget == nil)
        #expect(vm.paletteItems.contains { $0.id == "action.rename" } == (remoteState != "missingHost" && remoteState != "missingAgent"))
        vm.focusSelectedAgent()
        #expect(vm.selectedRemoteAgent == selectedRemote)
        #expect(vm.remoteFocusedPaneID == (remoteState == "available" ? pane.id : nil))
        vm.closeFocusedPane()
        await vm.persistenceTail?.value
        #expect(vm.state == original)
        #expect(fixture.server.state == original)
        #expect(remote.server.state == original)
        #expect(vm.selectedAgentID == agent.id)
        #expect(vm.selectedRemoteAgent == selectedRemote)
        #expect(vm.focusedPaneID == auxiliary.id)

        // Returning locally restores the existing menu behavior.
        vm.selectAgent(agent.id)
        vm.focusedPaneID = nil
        vm.focusSelectedAgent()
        #expect(vm.selectedRemoteAgent == nil)
        #expect(vm.focusedPaneID != nil)
        vm.renameSelectedAgent()
        #expect(vm.agentRenameTarget == agent.id)
        vm.deleteSelectedAgent()
        await vm.persistenceTail?.value
        #expect(vm.state.agents.isEmpty)
        #expect(fixture.server.state.agents.isEmpty)
        #expect(fixture.server.state.tabs.isEmpty)
        #expect(remote.server.state == original)
    }

    @Test func quickCreateWhileRemoteSelectedCreatesOnlyOnRemoteHost() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let remoteDir = URL(fileURLWithPath: "/tmp/shepherd-remote-vm-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        let remoteServer = SessionServer(
            socketPath: remoteDir.appendingPathComponent("d.sock").path,
            stateURL: remoteDir.appendingPathComponent("state.json")
        )
        try remoteServer.start()
        defer {
            remoteServer.stop()
            try? FileManager.default.removeItem(at: remoteDir)
        }

        let space = Space(name: "remote", path: "/remote/project")
        let pane = LeafPane(cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(
            name: "remote worker",
            spaceID: space.id,
            tabID: tab.id,
            paneID: pane.id
        )
        try await remoteServer.putState(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))

        let minted = AgentID()
        remoteServer.onRemoteCreateAgent = { request, completion in
            guard request.spaceID == space.id, request.cwd == space.path else {
                completion(.failure(RemoteCreateAgentError("wrong remote checkout")))
                return
            }
            completion(.success(minted))
        }
        let tokenURL = remoteDir.appendingPathComponent("remote-token")
        let port = try remoteServer.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let defaultsName = "shepherd.remote.quick-create.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let remoteHosts = RemoteHostStore(defaults: defaults)
        remoteHosts.addHost(name: "remote", host: "127.0.0.1", port: port, token: token)
        let hostID = try #require(remoteHosts.connections.first?.id)
        defer { remoteHosts.removeHost(id: hostID) }

        let vm = ShepherdViewModel(server: fixture.server, remoteHosts: remoteHosts)
        #expect(await waitUntil {
            remoteHosts.connections.first?.phase == .connected
                && remoteHosts.connections.first?.state.agents.first?.id == agent.id
        })
        vm.selectRemoteAgent(hostID: hostID, agentID: agent.id)

        vm.quickCreateAgent()

        #expect(await waitUntil {
            vm.selectedRemoteAgent == RemoteAgentRef(hostID: hostID, agentID: minted)
        })
        #expect(!vm.showNewAgentSheet)
        #expect(fixture.server.state.agents.isEmpty)
    }

    @Test func addSpaceWithoutInitialAgentCreatesOneAtomicWorkspaceSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let vm = ShepherdViewModel(server: fixture.server)
        let path = fixture.dir.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        let id = await vm.addSpace(at: path, createInitialAgent: false)
        #expect(id != nil)
        #expect(fixture.server.state.spaces.count == 1)
        #expect(fixture.server.state.tabs.count == 1)
        #expect(fixture.server.state.agents.isEmpty)
        #expect(fixture.server.state.tabs.first?.spaceID == id)
        #expect(vm.selectedSpaceID == id)
    }

    @Test func worktreeImportPickerCapturesTheRegisteredWorktreeDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let repo = fixture.dir.appendingPathComponent("repo", isDirectory: true)
        let worktreeFolder = fixture.dir.appendingPathComponent("linked", isDirectory: true)
        let worktree = worktreeFolder.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeFolder, withIntermediateDirectories: true)

        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        try git(["init", "-q"])
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"])
        try git(["worktree", "add", "-q", "-b", "worktree/feature", worktree.path])

        let vm = ShepherdViewModel(server: fixture.server)
        let spaceID = try #require(await vm.addSpace(at: repo, createInitialAgent: false))
        vm.importExistingWorktreeFromPanel(in: spaceID)

        guard case .importWorktree(let target) = vm.spacePickerTarget else {
            Issue.record("expected worktree import picker")
            return
        }
        #expect(target.spaceID == spaceID)
        #expect(target.startPath == worktreeFolder.resolvingSymlinksInPath().path)

        let firstRequest = target.id
        vm.spacePickerTarget = nil
        vm.importExistingWorktreeFromPanel(in: spaceID)
        guard case .importWorktree(let reopened) = vm.spacePickerTarget else {
            Issue.record("expected reopened worktree import picker")
            return
        }
        #expect(reopened.id != firstRequest)
    }

    @Test func importingExistingCheckoutRestoresWorktreeIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let vm = ShepherdViewModel(server: fixture.server)
        let repo = fixture.dir.appendingPathComponent("repo", isDirectory: true)
        let worktree = fixture.dir.appendingPathComponent("migrated-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        try git(["init", "-q"])
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"])
        try git(["worktree", "add", "-q", "-b", "worktree/imported", worktree.path])

        let spaceID = await vm.addSpace(at: repo, createInitialAgent: false)
        let id = await vm.importExistingCheckout(at: worktree, into: spaceID)
        let agent = try #require(fixture.server.state.agents.first)

        #expect(id == agent.id)
        let canonicalRepo = repo.resolvingSymlinksInPath().path
        let canonicalWorktree = worktree.resolvingSymlinksInPath().path
        #expect(fixture.server.state.spaces.first?.path == canonicalRepo)
        #expect(agent.worktreeBranch == "worktree/imported")
        #expect(agent.worktreePath == canonicalWorktree)
        #expect(fixture.server.state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd == canonicalWorktree)
        #expect(vm.selectedAgentID == id)

        #expect(fixture.server.state.spaces.count == 1)
        #expect(fixture.server.state.agents.count == 1)
    }

    @Test func importingWorktreeRejectsAnotherSpacesRepository() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let vm = ShepherdViewModel(server: fixture.server)
        let firstRepo = fixture.dir.appendingPathComponent("first", isDirectory: true)
        let secondRepo = fixture.dir.appendingPathComponent("second", isDirectory: true)
        let worktree = fixture.dir.appendingPathComponent("second-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRepo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRepo, withIntermediateDirectories: true)

        func git(_ arguments: [String], in repo: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        for repo in [firstRepo, secondRepo] {
            try git(["init", "-q"], in: repo)
            try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        }
        try git(["worktree", "add", "-q", "-b", "worktree/wrong-space", worktree.path], in: secondRepo)
        let firstSpaceID = await vm.addSpace(at: firstRepo, createInitialAgent: false)

        #expect(await vm.importExistingCheckout(at: worktree, into: firstSpaceID) == nil)
        #expect(fixture.server.state.agents.isEmpty)
        #expect(fixture.server.state.spaces.count == 1)
    }

    @Test func settingsSectionSurvivesClosingUntilViewModelRestarts() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let vm = ShepherdViewModel(server: fixture.server)

        #expect(vm.settingsSection == .appearance)
        vm.showSettings = true
        vm.settingsSection = .pi
        vm.showSettings = false
        vm.showSettings = true

        #expect(vm.settingsSection == .pi)
    }

    @Test func queuedLayoutWritesStayOrderedAndReconcileRejectedOptimisticState() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let (space, tab) = try await seedWorkspace(on: fixture.server)
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.tabs.first?.id == tab.id })

        let first = LeafPane(cwd: space.path)
        let second = LeafPane(cwd: space.path)
        let committed = PaneNode.split(
            axis: .vertical,
            ratio: 0.6,
            first: .leaf(first),
            second: .leaf(second)
        )
        let rejected = PaneNode.split(
            axis: .vertical,
            ratio: 1.0,
            first: .leaf(first),
            second: .leaf(second)
        )

        vm.setLayout(committed, forTab: tab.id)
        vm.setLayout(rejected, forTab: tab.id)

        #expect(await waitUntil {
            fixture.server.state.tabs.first?.layout == committed
                && vm.state.tabs.first?.layout == committed
        })
    }

    @Test func structuralViewModelLayoutWritePreservesExistingSessionBinding() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let space = Space(name: "workspace", path: "/tmp/workspace")
        let sessionID = SessionID()
        let pane = LeafPane(sessionID: sessionID, cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        try await fixture.server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: []))
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.tabs.first?.id == tab.id })

        let requested = PaneNode.split(
            axis: .vertical,
            ratio: 0.5,
            first: .leaf(LeafPane(id: pane.id, cwd: space.path)),
            second: .leaf(LeafPane(cwd: space.path))
        )
        vm.setLayout(requested, forTab: tab.id)

        #expect(await waitUntil {
            fixture.server.state.tabs.first?.layout.leaf(withID: pane.id)?.sessionID == sessionID
                && fixture.server.state.tabs.first?.layout.leaves.count == 2
        })
    }

    @Test func agentOpenedPaneDoesNotStealTheUsersWorkspaceOrFocus() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let space = Space(name: "workspace", path: "/tmp/workspace")
        let backgroundID = AgentID()
        let visibleID = AgentID()
        let backgroundPane = LeafPane(cwd: space.path, agentID: backgroundID)
        let visiblePane = LeafPane(cwd: space.path, agentID: visibleID)
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

        fixture.server.onPaneRequest?(.open(
            agentID: backgroundID,
            axis: .vertical,
            cwd: nil,
            relativeTo: nil,
            command: nil
        )) { _ in }

        #expect(vm.selectedAgentID == visibleID)
        #expect(vm.focusedPaneID == visiblePane.id)
        #expect(vm.state.tabs.first(where: { $0.id == backgroundTab.id })?.layout.leaves.count == 2)
    }

    @Test func paneControlRejectsForeignAndOwnPaneButClosesAuxiliaryPane() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let space = Space(name: "workspace", path: "/tmp/workspace")
        let agentID = AgentID()
        let primary = LeafPane(cwd: space.path, agentID: agentID)
        let auxiliary = LeafPane(cwd: space.path)
        let tab = Tab(
            spaceID: space.id,
            order: 0,
            layout: .split(
                axis: .vertical,
                ratio: 0.5,
                first: .leaf(primary),
                second: .leaf(auxiliary)
            )
        )
        let agent = Agent(
            id: agentID,
            name: "worker",
            spaceID: space.id,
            tabID: tab.id,
            paneID: primary.id
        )
        try await fixture.server.putState(
            ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
        )
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.agents.first?.id == agentID })

        var ownOutcome: PaneOutcome?
        fixture.server.onPaneRequest?(.close(agentID: agentID, paneID: primary.id)) {
            ownOutcome = $0
        }
        #expect(ownOutcome == .failed(
            code: "not_closable",
            message: "an agent cannot close its own pi pane"
        ))

        let foreignPaneID = PaneID()
        var foreignOutcome: PaneOutcome?
        fixture.server.onPaneRequest?(.close(agentID: agentID, paneID: foreignPaneID)) {
            foreignOutcome = $0
        }
        #expect(foreignOutcome == .failed(
            code: "no_such_pane",
            message: "pane \(foreignPaneID) is not in this agent's layout"
        ))

        var auxiliaryOutcome: PaneOutcome?
        fixture.server.onPaneRequest?(.close(agentID: agentID, paneID: auxiliary.id)) {
            auxiliaryOutcome = $0
        }
        #expect(auxiliaryOutcome == .ok)
        #expect(await waitUntil {
            fixture.server.state.tabs.first?.layout.leaves.map(\.id) == [primary.id]
        })
    }

    @Test func resetSettingsRestoresPreferencesAndRebuildsSurfaces() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let vm = ShepherdViewModel(server: fixture.server)

        let settings = AppSettings.shared
        let originalFontFamily = settings.terminalFontFamily
        let originalFontSize = settings.terminalFontSize
        let originalModel = settings.defaultModel
        let originalThinking = settings.defaultThinking
        let originalAutoName = settings.autoNameAgents
        let originalShell = settings.shellPath
        let keys = KeybindingsStore.shared
        let originalOverrides = keys.overrides
        let originalAppearance = ThemeManager.shared.mode
        defer {
            settings.terminalFontFamily = originalFontFamily
            settings.terminalFontSize = originalFontSize
            settings.defaultModel = originalModel
            settings.defaultThinking = originalThinking
            settings.autoNameAgents = originalAutoName
            settings.shellPath = originalShell
            keys.resetAll()
            for (action, chord) in originalOverrides {
                _ = keys.assign(chord, to: action)
            }
            ThemeManager.shared.select(originalAppearance)
        }

        settings.terminalFontSize = 20
        settings.defaultModel = "openai/gpt-5"
        settings.autoNameAgents = false
        _ = keys.assign(KeyChord(key: "p", command: true), to: .newAgent)
        ThemeManager.shared.select(.light)

        vm.resetSettings()

        #expect(settings.terminalFontFamily == AppSettings.Defaults.terminalFontFamily)
        #expect(settings.terminalFontSize == AppSettings.Defaults.terminalFontSize)
        #expect(settings.defaultModel.isEmpty)
        #expect(settings.defaultThinking == AppSettings.Defaults.thinking)
        #expect(settings.autoNameAgents)
        #expect(settings.shellPath == AppSettings.Defaults.shellPath)
        #expect(keys.overrides.isEmpty)
        let launchTheme = ProcessInfo.processInfo.environment["SHEPHERD_THEME"]
        let launchMode: AppearanceMode = launchTheme == "basalt-light"
            ? .light
            : ["basalt-dark", "shepherd-dark"].contains(launchTheme) ? .dark : .system
        #expect(ThemeManager.shared.mode == launchMode)
    }

    @Test func resetSettingsFailureLeavesIsolatedStoresUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let settingsName = "shepherd.vm.settings.\(UUID().uuidString)"
        let keyName = "shepherd.vm.keys.\(UUID().uuidString)"
        let themeName = "shepherd.vm.theme.\(UUID().uuidString)"
        let settingsDefaults = UserDefaults(suiteName: settingsName)!
        let keyDefaults = UserDefaults(suiteName: keyName)!
        let themeDefaults = UserDefaults(suiteName: themeName)!
        defer {
            settingsDefaults.removePersistentDomain(forName: settingsName)
            keyDefaults.removePersistentDomain(forName: keyName)
            themeDefaults.removePersistentDomain(forName: themeName)
        }

        let settings = AppSettings(store: settingsDefaults)
        settings.terminalFontSize = 20
        settings.defaultModel = "openai/gpt-5"
        settings.autoNameAgents = false
        let keys = KeybindingsStore(store: keyDefaults)
        _ = keys.assign(KeyChord(key: "p", command: true), to: .newAgent)
        let themeManager = ThemeManager(
            store: themeDefaults,
            environmentTheme: nil,
            systemColorScheme: .dark
        )
        themeManager.select(.light)

        let vm = ShepherdViewModel(
            server: fixture.server,
            settings: settings,
            keybindings: keys,
            themeManager: themeManager,
            themeInstaller: { _ in throw NSError(domain: "theme-test", code: 1) }
        )

        vm.resetSettings()

        #expect(settings.terminalFontSize == 20)
        #expect(settings.defaultModel == "openai/gpt-5")
        #expect(settings.autoNameAgents == false)
        #expect(keys.overrides[.newAgent] == KeyChord(key: "p", command: true))
        #expect(themeManager.current.id == "basalt-light")
    }

    /// Worktree agents lead their space's list (stable within each group) so
    /// they read as part of the checkout tree, not standard agents.
    @Test func worktreeAgentsSortFirstInTheirSpace() {
        let space = SpaceID(rawValue: "s")
        let tab = TabID(rawValue: "t")
        let agents = [
            Agent(name: "one", spaceID: space, tabID: tab),
            Agent(name: "wt-1", spaceID: space, tabID: tab, worktreeBranch: "worktree/wt-1"),
            Agent(name: "two", spaceID: space, tabID: tab),
            Agent(name: "wt-2", spaceID: space, tabID: tab, worktreeBranch: "worktree/wt-2"),
            Agent(name: "elsewhere", spaceID: SpaceID(rawValue: "x"), tabID: tab),
        ]
        let ordered = ShepherdViewModel.sidebarAgents(of: space, in: agents)
        #expect(ordered.map(\.name) == ["wt-1", "wt-2", "one", "two"])
    }

    @Test func orderedAgentsOmitsDescendantsOfCollapsedSpace() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let root = Space(name: "root", path: "/tmp/root")
        let child = Space(name: "child", path: "/tmp/root/child")
        let other = Space(name: "other", path: "/tmp/other")
        let rootTab = Tab(spaceID: root.id, order: 0, layout: .leaf(LeafPane(cwd: root.path)))
        let childTab = Tab(spaceID: child.id, order: 0, layout: .leaf(LeafPane(cwd: child.path)))
        let otherTab = Tab(spaceID: other.id, order: 0, layout: .leaf(LeafPane(cwd: other.path)))
        let agents = [
            Agent(name: "root-agent", spaceID: root.id, tabID: rootTab.id),
            Agent(name: "child-agent", spaceID: child.id, tabID: childTab.id),
            Agent(name: "other-agent", spaceID: other.id, tabID: otherTab.id),
        ]
        try await fixture.server.putState(
            ShepherdState(
                spaces: [root, child, other],
                tabs: [rootTab, childTab, otherTab],
                agents: agents
            )
        )
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.orderedAgents.map(\.name) == ["root-agent", "child-agent", "other-agent"] })

        vm.toggleSpaceCollapsed(root.id)

        #expect(vm.orderedAgents.map(\.name) == ["other-agent"])
    }

    @Test func adjacentAgentSelectionFollowsVisibleSidebarOrderAndWraps() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        let space = Space(name: "workspace", path: "/tmp/workspace")
        let tabs = (0..<3).map { Tab(spaceID: space.id, order: $0, layout: .leaf(LeafPane(cwd: space.path))) }
        let agents = zip(["one", "two", "three"], tabs).map { name, tab in
            Agent(name: name, spaceID: space.id, tabID: tab.id)
        }
        try await fixture.server.putState(ShepherdState(spaces: [space], tabs: tabs, agents: agents))
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.orderedAgents.count == 3 })

        vm.selectAgent(agents[0].id)
        vm.selectAdjacentAgent(1)
        #expect(vm.selectedAgentID == agents[1].id)
        vm.selectAdjacentAgent(1)
        vm.selectAdjacentAgent(1)
        #expect(vm.selectedAgentID == agents[0].id)
        vm.selectAdjacentAgent(-1)
        #expect(vm.selectedAgentID == agents[2].id)
    }

    @Test func appearanceModePersistsResetsAndFollowsSystem() {
        let name = "shepherd.theme.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let manager = ThemeManager(
            store: defaults,
            environmentTheme: nil,
            systemColorScheme: .dark
        )
        #expect(manager.mode == .system)
        #expect(manager.current.id == "basalt-dark")

        manager.select(.light)
        #expect(manager.current.id == "basalt-light")
        #expect(defaults.string(forKey: "shepherd.appearance") == "light")

        #expect(manager.resetToDefault().id == "basalt-dark")
        #expect(manager.mode == .system)
        #expect(defaults.object(forKey: "shepherd.appearance") == nil)

        #expect(manager.updateSystemColorScheme(.light)?.id == "basalt-light")
        #expect(manager.current.id == "basalt-light")

        let overridden = ThemeManager(
            store: defaults,
            environmentTheme: "basalt-dark",
            systemColorScheme: .light
        )
        #expect(overridden.mode == .dark)
        #expect(overridden.current.id == "basalt-dark")
        #expect(overridden.resetToDefault().id == "basalt-dark")
    }
}
