import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

@Suite("Shepherd state management", .serialized)
struct StateManagementTests {
    private struct Harness {
        let dir: URL
        let socketPath: String
        let server: SessionServer
        var stateChanged: Locked<[ShepherdState]> = Locked([])

        init() throws {
            dir = try makeScratchDirectory()
            socketPath = dir.appendingPathComponent("d.sock").path
            server = SessionServer(
                socketPath: socketPath,
                stateURL: dir.appendingPathComponent("state.json")
            )
            server.onStateChanged = { [stateChanged] state in
                stateChanged.withValue { $0.append(state) }
            }
            try server.start()
        }

        func tearDown() {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test func crudPersistsAndBroadcasts() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let space = Space(name: "demo", path: "/tmp/demo")
        let pane = LeafPane(cwd: "/tmp/demo")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "pi-1", spaceID: space.id, tabID: tab.id, paneID: pane.id)

        // Conflict: adding the same space twice is rejected.
        try await h.server.addSpace(space)
        do {
            try await h.server.addSpace(space)
            Issue.record("expected conflict for duplicate space")
        } catch {}

        // Tab requires its space; agent requires both.
        try await h.server.addTab(tab)
        do {
            try await h.server.addTab(Tab(spaceID: SpaceID(), order: 1, layout: .leaf(pane)))
            Issue.record("expected no_such_space for orphan tab")
        } catch {}

        try await h.server.addAgent(agent)
        do {
            try await h.server.addAgent(agent)
            Issue.record("expected conflict for duplicate agent")
        } catch {}

        // removeTab is rejected while an agent references the tab.
        do {
            try await h.server.removeTab(tab.id)
            Issue.record("expected tab_in_use for removeTab with a referencing agent")
        } catch {}

        // Updates apply and broadcast.
        var updated = agent
        updated.name = "pi-renamed"
        updated.model = "pi-large"
        try await h.server.updateAgent(updated)
        try await h.server.updateSpace(space)
        try await h.server.updateTab(tab)
        try await h.server.updateLayoutStructure(tabID: tab.id, layout: .split(
            axis: .vertical, ratio: 0.5, first: .leaf(pane), second: .leaf(LeafPane(cwd: "/tmp/demo"))
        ))

        var state = h.server.state
        #expect(state.spaces == [space])
        #expect(state.agents == [updated])
        #expect(state.tabs.count == 1)
        #expect(state.tabs[0].layout.leaves.count == 2)

        // Full replace (recovery tooling) works.
        let replacement = ShepherdState(spaces: [space], tabs: [], agents: [])
        try await h.server.putState(replacement)
        #expect(h.server.state == replacement)

        // Cleanup path: removeAgent then removeTab.
        try await h.server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        try await h.server.removeAgent(agent.id)
        try await h.server.removeTab(tab.id)
        state = h.server.state
        #expect(state.spaces == [space])
        #expect(state.tabs.isEmpty)
        #expect(state.agents.isEmpty)

        // Broadcasts hop to the main queue after each server mutation, so the
        // final callback can arrive just after the awaited mutation returns.
        try await waitUntil { h.stateChanged.current.count == 11 }
        #expect(h.stateChanged.current.count == 11)
    }

    @Test func structuralAndBindingWritesInterleaveWithoutLosingPaneSessions() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let space = Space(name: "demo", path: "/tmp/demo")
        let first = LeafPane(cwd: space.path)
        let firstSession = SessionID()
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(first))
        try await h.server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: []))

        let withSplit = PaneNode.split(
            axis: .vertical,
            ratio: 0.5,
            first: .leaf(LeafPane(id: first.id, cwd: space.path)),
            second: .leaf(LeafPane(cwd: space.path))
        )
        try await h.server.updatePaneSession(tabID: tab.id, paneID: first.id, sessionID: firstSession)
        try await h.server.updateLayoutStructure(tabID: tab.id, layout: withSplit)

        #expect(h.server.state.tabs.first?.layout.leaf(withID: first.id)?.sessionID == firstSession)
        let second = try #require(h.server.state.tabs.first?.layout.leaves.first { $0.id != first.id })
        let secondSession = SessionID()
        try await h.server.updatePaneSession(tabID: tab.id, paneID: second.id, sessionID: secondSession)

        let withThird = PaneNode.split(
            axis: .horizontal,
            ratio: 0.6,
            first: withSplit,
            second: .leaf(LeafPane(cwd: space.path))
        )
        try await h.server.updateLayoutStructure(tabID: tab.id, layout: withThird)

        #expect(h.server.state.tabs.first?.layout.leaf(withID: first.id)?.sessionID == firstSession)
        #expect(h.server.state.tabs.first?.layout.leaf(withID: second.id)?.sessionID == secondSession)
    }

    @Test func bindingWrittenBeforeStructuralLayoutStillSurvives() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let space = Space(name: "demo", path: "/tmp/demo")
        let pane = LeafPane(cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        try await h.server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: []))

        let sessionID = SessionID()
        let requested = PaneNode.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(LeafPane(id: pane.id, cwd: space.path)),
            second: .leaf(LeafPane(cwd: space.path))
        )
        try await h.server.updateLayoutStructure(tabID: tab.id, layout: requested)
        try await h.server.updatePaneSession(tabID: tab.id, paneID: pane.id, sessionID: sessionID)

        #expect(h.server.state.tabs.first?.layout.leaf(withID: pane.id)?.sessionID == sessionID)
        #expect(h.server.state.tabs.first?.layout.leaves.count == 2)
    }

    @Test func addSpaceWithTabPublishesOneAtomicSnapshot() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let space = Space(name: "demo", path: "/tmp/demo")
        let tab = Tab(
            spaceID: space.id,
            order: 0,
            layout: .leaf(LeafPane(cwd: space.path))
        )

        try await h.server.addSpace(space, withTab: tab)

        let expected = ShepherdState(spaces: [space], tabs: [tab], agents: [])
        #expect(h.server.state == expected)
        try await waitUntil { h.stateChanged.current.count == 1 }
        #expect(h.stateChanged.current == [expected])
    }

    /// Removing a space takes its agents, layouts, and inspector tabs with
    /// it — but never spaces nested under it by path: those are independent
    /// entities that merely rendered as children.
    @Test func deleteSpaceRemovesItsContentsButNotNestedSpaces() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let parent = Space(name: "workspace", path: "/tmp/ws")
        let nested = Space(name: "project", path: "/tmp/ws/project")
        let parentPane = LeafPane(cwd: parent.path)
        let parentTab = Tab(spaceID: parent.id, order: 0, layout: .leaf(parentPane))
        let nestedTab = Tab(spaceID: nested.id, order: 0, layout: .leaf(LeafPane(cwd: nested.path)))
        let agentPane = LeafPane(cwd: parent.path)
        let agentTab = Tab(spaceID: parent.id, order: 1, layout: .leaf(agentPane))
        let agent = Agent(name: "worker", spaceID: parent.id, tabID: agentTab.id, paneID: agentPane.id)
        let inspectorTab = Tab(spaceID: parent.id, order: 2, layout: .leaf(LeafPane(cwd: parent.path)), inspectorFor: agent.id)
        let shell = Tab(spaceID: nil, order: 0, layout: .leaf(LeafPane(cwd: "/tmp")), name: "~")
        try await h.server.putState(ShepherdState(
            spaces: [parent, nested],
            tabs: [parentTab, nestedTab, agentTab, inspectorTab, shell],
            agents: [agent]
        ))

        try await h.server.deleteSpace(parent.id)

        let final = h.server.state
        #expect(final.spaces.map(\.id) == [nested.id])
        #expect(final.agents.isEmpty)
        #expect(Set(final.tabs.map(\.id)) == [nestedTab.id, shell.id])
    }

    @Test func addAgentWithTabPublishesOneAtomicSnapshot() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let space = Space(name: "demo", path: "/tmp/demo")
        try await h.server.addSpace(space)
        try await waitUntil { h.stateChanged.current.count == 1 }
        h.stateChanged.withValue { $0.removeAll() }

        let pane = LeafPane(cwd: "/tmp/demo")
        let tab = Tab(spaceID: space.id, order: 1, layout: .leaf(pane))
        let agent = Agent(name: "worker", spaceID: space.id, tabID: tab.id, paneID: pane.id)

        try await h.server.addAgent(agent, withTab: tab)

        let expected = ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
        #expect(h.server.state == expected)
        try await waitUntil { h.stateChanged.current.count == 1 }
        #expect(h.stateChanged.current == [expected])
    }

    @Test func invalidPutStateIsRejectedWithoutBroadcastOrMutation() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let space = Space(name: "demo", path: "/tmp/demo")
        try await h.server.addSpace(space)
        try await waitUntil { h.stateChanged.current.count == 1 }
        h.stateChanged.withValue { $0.removeAll() }

        let invalidTab = Tab(
            spaceID: SpaceID(),
            order: 0,
            layout: .leaf(LeafPane(cwd: "/tmp/demo"))
        )
        do {
            try await h.server.putState(ShepherdState(spaces: [space], tabs: [invalidTab], agents: []))
            Issue.record("expected invalid state to be rejected")
        } catch let error as SessionServerError {
            guard case .persistFailed = error else {
                Issue.record("expected persistFailed, got \(error)")
                return
            }
        }

        #expect(h.server.state == ShepherdState(spaces: [space], tabs: [], agents: []))
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.stateChanged.current.isEmpty)
    }

    @Test func renameAgentCommitsTrimmedNameAndPublishesCanonicalState() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let space = Space(name: "demo", path: "/tmp/demo")
        let agentID = AgentID()
        let pane = LeafPane(cwd: "/tmp/demo", agentID: agentID)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: agentID, name: "temporary", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        try await h.server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        try await waitUntil { h.stateChanged.current.count == 1 }
        h.stateChanged.withValue { $0.removeAll() }

        try await h.server.renameAgent(agentID, to: "  final title  \n")
        // Wait on the main-queue push, not just server state: the callback
        // hops queues and lands after the state mutation.
        try await waitUntil { h.stateChanged.current.count == 1 }

        let committed = h.server.state
        #expect(committed.agents.first?.name == "final title")
        #expect(committed.agents.first?.nameIsFinal == true)
        #expect(StateStore(url: h.dir.appendingPathComponent("state.json")).state == committed)
        #expect(h.stateChanged.current.count == 1)
    }

    @Test func deleteAgentRemovesItsWholeRuntimeAtomically() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let primarySession = try await h.server.createSession(params: CreateSessionParams(
            cwd: "/", command: ["/bin/sh", "-c", "sleep 30"]
        ))
        let auxiliarySession = try await h.server.createSession(params: CreateSessionParams(
            cwd: "/", command: ["/bin/sh", "-c", "sleep 30"]
        ))

        let space = Space(name: "demo", path: "/tmp/demo")
        let agentID = AgentID()
        let primaryPane = LeafPane(sessionID: primarySession.id, cwd: "/tmp/demo", agentID: agentID)
        let auxiliaryPane = LeafPane(sessionID: auxiliarySession.id, cwd: "/tmp/demo")
        let tab = Tab(
            spaceID: space.id,
            order: 1,
            layout: .split(
                axis: .vertical,
                ratio: 0.65,
                first: .leaf(primaryPane),
                second: .leaf(auxiliaryPane)
            )
        )
        let agent = Agent(id: agentID, name: "worker", spaceID: space.id, tabID: tab.id, paneID: primaryPane.id)
        try await h.server.putState(ShepherdState(
            spaces: [space],
            tabs: [tab],
            agents: [agent]
        ))
        try await waitUntil { !h.stateChanged.current.isEmpty }
        h.stateChanged.withValue { $0.removeAll() }

        let exited = Locked<Set<SessionID>>([])
        h.server.onSessionExited = { sessionID, _ in
            _ = exited.withValue { $0.insert(sessionID) }
        }

        try await h.server.deleteAgent(agent.id)

        let final = h.server.state
        #expect(final.spaces == [space])
        #expect(final.agents.isEmpty)
        #expect(final.tabs.isEmpty)

        try await waitUntil { h.stateChanged.current.count == 1 }
        #expect(h.stateChanged.current == [final])

        let expectedExits: Set<SessionID> = [primarySession.id, auxiliarySession.id]
        try await waitUntil { exited.current == expectedExits }
        #expect(exited.current == expectedExits)
        #expect(h.stateChanged.current.count == 1)
    }

    @Test func automationCRUDPersistsAndClearsAgentLinks() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let automation = Automation(name: "pr-watch", prompt: "watch the PR", cwd: "/tmp/repo")
        try await h.server.addAutomation(automation)
        #expect(h.server.state.automations == [automation])

        // Duplicate id rejected.
        await #expect(throws: SessionServerError.self) {
            try await h.server.addAutomation(automation)
        }

        // Link to a live agent, then delete the agent: the link clears but
        // the automation survives.
        let space = Space(name: "repo", path: "/tmp/repo")
        let pane = LeafPane(cwd: "/tmp/repo")
        let agentID = AgentID()
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: agentID, name: "watcher", spaceID: space.id, tabID: tab.id)
        try await h.server.addSpace(space)
        try await h.server.addAgent(agent, withTab: tab)

        var linked = automation
        linked.agentID = agentID
        try await h.server.updateAutomation(linked)
        #expect(h.server.state.automations.first?.agentID == agentID)

        try await h.server.deleteAgent(agentID)
        #expect(h.server.state.automations.first?.agentID == nil)
        #expect(h.server.state.automations.count == 1)

        try await h.server.removeAutomation(automation.id)
        #expect(h.server.state.automations.isEmpty)
        await #expect(throws: SessionServerError.self) {
            try await h.server.removeAutomation(automation.id)
        }
    }

    @Test func startClearsStaleAutomationRuns() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stateURL = dir.appendingPathComponent("state.json")
        let socketPath = dir.appendingPathComponent("d.sock").path

        // A previous run left an automation pointing at a (then-live) agent.
        let space = Space(name: "repo", path: "/tmp/repo")
        let pane = LeafPane(cwd: "/tmp/repo")
        let agentID = AgentID()
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: agentID, name: "watcher", spaceID: space.id, tabID: tab.id)
        let automation = Automation(name: "pr-watch", prompt: "watch", cwd: "/tmp/repo", agentID: agentID)
        let first = SessionServer(socketPath: socketPath, stateURL: stateURL)
        try first.start()
        try await first.putState(ShepherdState(spaces: [space], tabs: [tab], agents: [agent], automations: [automation]))
        first.stop()

        // Relaunch: the run died with the app, so the link must clear.
        let second = SessionServer(socketPath: socketPath, stateURL: stateURL)
        try second.start()
        defer { second.stop() }
        #expect(second.state.automations.first?.agentID == nil)
        #expect(second.state.automations.first?.enabled == true)
    }

    @Test func killSessionTerminatesAndIsIdempotent() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let info = try await h.server.createSession(params: CreateSessionParams(
            cwd: "/", command: ["/bin/sh", "-c", "sleep 100"]
        ))
        #expect(info.isAlive)

        // Signaled children exit with a nil code, so track receipt separately.
        let received = Locked(false)
        let exited = Locked<Int32?>(nil)
        h.server.onSessionExited = { _, code in
            exited.withValue { $0 = code }
            received.withValue { $0 = true }
        }

        h.server.killSession(info.id)
        try await waitUntil { received.current }
        // sleep dies to SIGTERM, so no exit code.
        #expect(exited.current == nil)

        let infos = await h.server.listSessions()
        #expect(infos.map(\.id) == [info.id])
        #expect(infos.first?.isAlive == false)

        // A dead session remains available for its final snapshot until the
        // consumer explicitly retires it.
        #expect(await h.server.listSessions().map(\.id) == [info.id])
        await h.server.retireSession(sessionID: info.id)
        #expect(await h.server.listSessions().isEmpty)
        // Retirement is idempotent.
        await h.server.retireSession(sessionID: info.id)
        h.server.killSession(info.id)

        // Unknown and retired sessions are rejected by attach.
        do {
            _ = try await h.server.attach(sessionID: SessionID(), replay: true)
            Issue.record("expected no_such_session")
        } catch {}
        do {
            _ = try await h.server.attach(sessionID: info.id, replay: true)
            Issue.record("expected retired session to reject attach")
        } catch {}
    }

    @Test func statusExtensionReportsAndPersists() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let space = Space(name: "s", path: "/tmp")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: "/tmp")))
        let idleAgent = Agent(name: "a1", spaceID: space.id, tabID: tab.id, status: .idle)
        let doneAgent = Agent(name: "a2", spaceID: space.id, tabID: tab.id, status: .done)
        try await h.server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: [idleAgent, doneAgent]))

        let client = try ExtensionClient(path: h.socketPath)
        defer { client.closeConnection() }
        let statuses = Locked<[AgentID: AgentStatus]>([:])
        h.server.onAgentStatus = { id, status in
            statuses.withValue { $0[id] = status }
        }

        // Unknown agent is silently dropped; the server keeps serving.
        try client.send(.setAgentStatus(agentID: AgentID(), status: .working))

        try client.send(.setAgentStatus(agentID: idleAgent.id, status: .working))
        try await waitUntil { statuses.current[idleAgent.id] == .working }

        // An invalid hop (done -> blocked) still applies; the server only logs.
        try client.send(.setAgentStatus(agentID: doneAgent.id, status: .blocked))
        try await waitUntil { statuses.current[doneAgent.id] == .blocked }

        // Persisted and broadcast.
        let final = h.server.state
        #expect(final.agents.first { $0.id == idleAgent.id }?.status == .working)
        #expect(final.agents.first { $0.id == doneAgent.id }?.status == .blocked)
    }

    /// `/new` and `/resume` move pi to another session; the status extension
    /// reports it so a relaunch reopens what the user was last working in.
    @Test func statusExtensionReportsTheAgentsCurrentSession() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let space = Space(name: "s", path: "/tmp")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: "/tmp")))
        let agent = Agent(name: "a", spaceID: space.id, tabID: tab.id, nameIsFinal: true)
        try await h.server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))

        // Until pi reports otherwise, the agent is in its own session.
        #expect(h.server.state.agents.first?.effectivePiSessionID == agent.id.rawValue)

        let client = try ExtensionClient(path: h.socketPath)
        defer { client.closeConnection() }

        // Unknown agents and blank ids are dropped without disturbing anyone.
        try client.send(.setAgentSession(agentID: AgentID(), piSessionID: "ghost"))
        try client.send(.setAgentSession(agentID: agent.id, piSessionID: "   "))

        try client.send(.setAgentSession(agentID: agent.id, piSessionID: "session-after-new"))
        try await waitUntil {
            h.server.state.agents.first?.piSessionID == "session-after-new"
        }
        #expect(h.server.state.agents.first?.effectivePiSessionID == "session-after-new")
        // A different session is a different conversation: the old name no
        // longer applies, so naming reopens and the namer may retitle.
        #expect(h.server.state.agents.first?.nameIsFinal == false)

        // A later /resume moves it again.
        try client.send(.setAgentSession(agentID: agent.id, piSessionID: "session-after-resume"))
        try await waitUntil {
            h.server.state.agents.first?.piSessionID == "session-after-resume"
        }

        // The namer can now land a title for the resumed conversation.
        try client.send(.setAgentName(agentID: agent.id, name: "Resume sidebar work"))
        try await waitUntil {
            h.server.state.agents.first?.name == "Resume sidebar work"
        }
        #expect(h.server.state.agents.first?.nameIsFinal == true)
    }

    /// The namer replaces a provisional name exactly once; a settled name (a
    /// title that already landed, or a user's manual rename) always wins.
    @Test func namerExtensionTitlesOnlyProvisionalAgents() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let space = Space(name: "s", path: "/tmp")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: "/tmp")))
        let pending = Agent(
            name: "clean up the naming code…", spaceID: space.id, tabID: tab.id, nameIsFinal: false
        )
        let manual = Agent(
            name: "prod-hotfix", spaceID: space.id, tabID: tab.id, nameIsFinal: true
        )
        try await h.server.putState(
            ShepherdState(spaces: [space], tabs: [tab], agents: [pending, manual])
        )

        let client = try ExtensionClient(path: h.socketPath)
        defer { client.closeConnection() }

        // Unknown agents and blank titles are dropped; the server keeps serving.
        try client.send(.setAgentName(agentID: AgentID(), name: "Ghost title"))
        try client.send(.setAgentName(agentID: pending.id, name: "   "))

        try client.send(.setAgentName(agentID: pending.id, name: "Fix plan mode over SSH"))
        try await waitUntil {
            h.server.state.agents.first { $0.id == pending.id }?.name == "Fix plan mode over SSH"
        }
        #expect(h.server.state.agents.first { $0.id == pending.id }?.nameIsFinal == true)

        // A second proposal cannot overwrite the title that already landed,
        // and a hand-typed name is never clobbered. Both are ignored, so a
        // status report queued behind them on the same connection is the
        // barrier proving the server consumed them.
        try client.send(.setAgentName(agentID: pending.id, name: "Something else"))
        try client.send(.setAgentName(agentID: manual.id, name: "Refactor sidebar layout"))
        try client.send(.setAgentStatus(agentID: manual.id, status: .working))
        try await waitUntil {
            h.server.state.agents.first { $0.id == manual.id }?.status == .working
        }

        let final = h.server.state
        #expect(final.agents.first { $0.id == pending.id }?.name == "Fix plan mode over SSH")
        #expect(final.agents.first { $0.id == manual.id }?.name == "prod-hotfix")
    }
}
