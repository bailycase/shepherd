import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Agents whose pi (the scripted stub) is already running: talking to them through the
/// native thread, renaming, deleting, and their process dying on its own.
@Suite("Agent lifecycle", .runsProcesses)
@MainActor
struct AgentLifecycleTests {
    @Test func aPromptSentFromTheThreadReachesPiAndItsReplyStreamsBack() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let log = app.dir.appendingPathComponent("pi.log")
        let space = Fixture.space(path: app.dir.path)
        let agent = try await app.liveAgent(in: space, log: log)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let store = vm.threadStores.store(for: agent.agent.id)
        let server = app.server, id = agent.agent.id
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to connect") { store.ready }

        store.draft = "list the files"
        await store.send()

        #expect(store.sentCount == 1 && store.draft.isEmpty)
        #expect(AppHarness.prompts(in: log) == ["list the files"])
        try await eventuallyAsync("pi's reply to land in the thread") {
            await store.refresh()
            return store.messages.contains { $0.role == "assistant" && $0.blocks.contains { $0.text.contains("Hello") } }
                && store.messages.contains { $0.toolName == "bash" }
        }
        #expect(store.pending.isEmpty, "the echo settles once pi persists the prompt")
    }

    @Test func answeringPisQuestionFromTheThreadResolvesIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = try await app.liveAgent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let store = vm.threadStores.store(for: agent.agent.id)
        let server = app.server, id = agent.agent.id
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to connect") { store.ready }
        await store.send(text: "ask")
        try await eventuallyAsync("pi's question to reach the thread") {
            await store.refresh()
            return store.snapshot?.dialogs.isEmpty == false
        }
        let snapshot = try #require(store.snapshot)
        let dialog = try #require(snapshot.dialogs.first)

        await store.answer(dialogID: dialog.id, sessionID: snapshot.piSessionID, generation: snapshot.generation, answer: .confirm(value: true))

        try await eventuallyAsync("the answer to settle the turn") {
            await store.refresh()
            return store.snapshot?.dialogs.isEmpty == true && store.snapshot?.running == false
        }
    }

    @Test func renamingAnAgentPersistsTheNameAsFinal() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("provisional", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        vm.renameAgent(agent.agent.id, to: "  Fix the login redirect \n")
        await app.settle()

        let renamed = try #require(app.server.state.agents.first)
        #expect(renamed.name == "Fix the login redirect")
        #expect(renamed.nameIsFinal)
        try await eventuallyOnMain("the rename to reach the view model") { vm.state.agents.first?.name == "Fix the login redirect" }
    }

    @Test func blankRenamesAreIgnored() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("keep me", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        vm.renameAgent(agent.agent.id, to: "   ")
        await app.settle()

        #expect(app.server.state.agents.first?.name == "keep me")
        #expect(app.server.state.agents.first?.nameIsFinal == false)
    }

    @Test func deletingAnAgentStopsItsPiAndRemovesItsLayout() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = try await app.liveAgent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let session = try #require(agent.piPane.sessionID)

        vm.deleteAgent(agent.agent.id)
        await app.settle()

        #expect(app.server.state.agents.isEmpty && app.server.state.tabs.isEmpty)
        #expect(vm.state.agents.isEmpty)
        let server = app.server
        try await eventuallyAsync("the agent's pi to stop") { await server.sessionInfo(sessionID: session)?.isAlive != true }
    }

    @Test func deletingTheSelectedAgentReturnsToThePreviouslySelectedOne() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agents = (0..<3).map { Fixture.agent("a\($0)", in: space, order: $0) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        vm.selectAgent(agents[2].agent.id)
        vm.selectAgent(agents[0].agent.id)
        vm.selectAgent(agents[1].agent.id)

        vm.deleteSelectedAgent()
        await app.settle()

        #expect(vm.selectedAgentID == agents[0].agent.id)
        #expect(vm.state.agents.map(\.id) == [agents[0].agent.id, agents[2].agent.id])
    }

    @Test func aDeletionTheServerCannotPersistKeepsTheAgentAndSaysWhy() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let original = app.server.state
        // A directory where state.json belongs makes the atomic write fail.
        try FileManager.default.removeItem(at: app.scratch.stateURL)
        try FileManager.default.createDirectory(at: app.scratch.stateURL, withIntermediateDirectories: true)

        vm.deleteAgent(agent.agent.id)
        await app.settle()

        #expect(vm.remoteActionError != nil)
        #expect(app.server.state == original)
        #expect(vm.state == original)
    }

    /// pi exiting on its own closes its pane, and an agent whose pi is gone is retired with its
    /// whole layout.
    @Test func anAgentWhosePiExitsIsRetiredWithItsLayout() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = try await app.liveAgent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        let pane = vm.sessions.session(for: agent.piPane, in: agent.tab)
        try await eventuallyOnMain("the pi pane to bind its running process") { pane.phase == .live }
        let snapshot = try await app.readyThread(agent.agent.id)

        _ = try? await app.server.nativeThread(agentID: agent.agent.id, request: .send(
            expectedSessionID: snapshot.piSessionID, generation: snapshot.generation,
            operationID: UUID(), text: "die", delivery: .followUp))

        try await eventuallyOnMain("the pane to see pi exit") { pane.phase == .exited(3) }
        let server = app.server
        try await eventuallyOnMain("the agent to be retired") { server.state.agents.isEmpty && server.state.tabs.isEmpty }
        #expect(vm.state.agents.isEmpty)
        #expect(vm.selectedAgentID == nil)
    }
}

/// Agents launched the way the app launches them: `zsh -l -c "exec pi --mode rpc …"` with
/// the stub standing in for `pi` on PATH. Serialized: PATH, ZDOTDIR, and the support
/// directory are process-global.
@Suite("Agents launched like the app", .serialized, .runsProcesses)
@MainActor
struct AgentLaunchTests {
    @Test func startingAnAgentSpawnsPiOverRPCAndSendsTheOpeningPrompt() async throws {
        let pi = try StubPiOnPath()
        let app = try AppHarness()
        defer { app.stop(); pi.restore() }
        pi.cleansSessions(in: app.dir.path)
        let space = Fixture.space(path: app.dir.path)
        let other = Fixture.agent("other", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [other]))
        vm.selectAgent(other.agent.id)

        let id = try await vm.startAgent(NewAgentConfig(
            spaceID: space.id, workingDirectory: app.dir.path, model: nil, thinking: .high,
            initialPrompt: "  fix   the\nsidebar "), selectAfter: false)

        let agent = try #require(vm.state.agents.first { $0.id == id })
        #expect(agent.name == "fix the sidebar" && !agent.nameIsFinal)
        let tab = try #require(vm.state.tabs.first { $0.id == agent.tabID })
        #expect(tab.layout.leaves.map(\.id) == [agent.paneID], "a new agent is exactly its pi pane")
        #expect(vm.selectedAgentID == other.agent.id, "a background start leaves the selection alone")
        let piPane = try #require(agent.paneID)
        let sessionID = try #require(vm.sessions.liveSession(forPane: piPane))
        let info = try #require(await app.server.sessionInfo(sessionID: sessionID))
        #expect(info.command.last?.contains("exec pi --mode rpc --session-id") == true)
        let server = app.server
        try await eventuallyAsync("pi to receive the opening prompt", timeout: .seconds(20)) {
            guard case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: id, request: .snapshot()) else { return false }
            return snapshot.messages.contains { $0.role == "user" && $0.blocks.contains { $0.text == "  fix   the\nsidebar " } }
        }
    }

    @Test func aRestoredAgentWithoutARunningPiRespawnsWhenItsPaneMounts() async throws {
        let pi = try StubPiOnPath()
        let app = try AppHarness()
        defer { app.stop(); pi.restore() }
        pi.cleansSessions(in: app.dir.path)
        let space = Fixture.space(path: app.dir.path)
        // A layout from a previous run: bound to a session that died with that run.
        let agent = Fixture.agent(in: space, piSession: SessionID())
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        let pane = vm.sessions.session(for: agent.piPane, in: agent.tab)

        #expect(pane.isRPC)
        try await eventuallyOnMain("the pane to respawn pi", timeout: .seconds(20)) { pane.phase == .live }
        #expect(!pane.hasTerminalModel, "an RPC pane never builds a terminal surface")
        _ = try await app.readyThread(agent.agent.id)
    }

    @Test func importingALinkedWorktreeStartsAnAgentCarryingItsIdentity() async throws {
        let pi = try StubPiOnPath()
        let app = try AppHarness()
        defer { app.stop(); pi.restore() }
        let repo = try makeScratchRepo()
        let worktree = repo.deletingLastPathComponent().appendingPathComponent("imported-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: repo); try? FileManager.default.removeItem(at: worktree) }
        try git(["worktree", "add", "-q", "-b", "worktree/imported", worktree.path], in: repo)
        pi.cleansSessions(in: worktree.path)
        let vm = try await app.start()
        let spaceID = try #require(await vm.addSpace(at: repo, createInitialAgent: false))

        let id = try #require(await vm.importExistingCheckout(at: worktree, into: spaceID))

        let agent = try #require(app.server.state.agents.first)
        #expect(agent.id == id && vm.selectedAgentID == id)
        #expect(agent.worktreeBranch == "worktree/imported")
        #expect(agent.worktreePath == canonical(worktree))
        #expect(app.server.state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd == canonical(worktree))
        #expect(app.server.state.spaces.count == 1)
    }
}
