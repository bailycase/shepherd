import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Every named `SessionServer` mutation: a success is validated, written to state.json, and
/// broadcast exactly once; a rejection changes nothing and broadcasts nothing.
@Suite("State mutations", .integrationTimeLimit)
struct StateMutationTests {
    // MARK: - Helpers

    /// The committed state after one mutation: on disk and broadcast exactly once.
    @discardableResult
    private func committed(_ h: ScratchServer, sourceLocation: SourceLocation = #_sourceLocation) async throws -> ShepherdState {
        await drainMainQueue()
        let state = h.server.state
        #expect(try h.persisted() == state, "state.json matches memory", sourceLocation: sourceLocation)
        #expect(h.broadcasts.current == [state], "one broadcast of the committed state", sourceLocation: sourceLocation)
        h.broadcasts.withValue { $0.removeAll() }
        return state
    }

    /// Runs a mutation that must fail with `expected`, leaving memory, disk, and observers untouched.
    private func expectRejection(
        _ expected: SessionServerError,
        on h: ScratchServer,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ mutation: () async throws -> Void
    ) async throws {
        let before = h.server.state
        let onDisk = try? Data(contentsOf: h.stateURL)
        let error = await #expect(throws: SessionServerError.self, sourceLocation: sourceLocation) { try await mutation() }
        #expect(error.map(String.init(describing:)) == expected.description, sourceLocation: sourceLocation)
        await drainMainQueue()
        #expect(h.server.state == before, sourceLocation: sourceLocation)
        #expect((try? Data(contentsOf: h.stateURL)) == onDisk, sourceLocation: sourceLocation)
        #expect(h.broadcasts.current.isEmpty, sourceLocation: sourceLocation)
    }

    /// A no-op mutation succeeds without writing or broadcasting.
    private func expectNoChange(on h: ScratchServer, _ mutation: () async throws -> Void) async throws {
        let before = h.server.state
        try await mutation()
        await drainMainQueue()
        #expect(h.server.state == before)
        #expect(h.broadcasts.current.isEmpty)
    }

    // MARK: - putState

    @Test func putStateReplacesTheWholeWorkspace() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let state = Fixture.workspace([Fixture.agent(in: space)], space: space)

        try await h.server.putState(state)
        #expect(try await committed(h) == state)
    }

    @Test func anInvalidPutStateIsRejected() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(ShepherdState(spaces: [space]))
        let orphan = Tab(spaceID: SpaceID(), order: 0, layout: .leaf(LeafPane(cwd: "/tmp")))

        let error = await #expect(throws: SessionServerError.self) {
            try await h.server.putState(ShepherdState(spaces: [space], tabs: [orphan]))
        }
        guard case .persistFailed? = error else { Issue.record("expected persistFailed, got \(String(describing: error))"); return }
        await drainMainQueue()
        #expect(h.server.state == ShepherdState(spaces: [space]))
        #expect(h.broadcasts.current.isEmpty)
    }

    // MARK: - Spaces

    @Test func addSpaceCreatesNoLayout() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()

        try await h.server.addSpace(space)
        #expect(try await committed(h) == ShepherdState(spaces: [space]))
    }

    @Test func addingASpaceTwiceIsAConflict() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(ShepherdState(spaces: [space]))
        try await expectRejection(.conflict("space \(space.id) already exists"), on: h) {
            try await h.server.addSpace(space)
        }
    }

    @Test func updateSpaceReplacesItsRecord() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        var space = Fixture.space()
        try await h.seed(ShepherdState(spaces: [space]))
        space.name = "renamed"
        space.hidden = true

        try await h.server.updateSpace(space)
        #expect(try await committed(h).spaces == [space])
    }

    @Test func updatingAnUnknownSpaceIsRejected() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let stranger = Fixture.space()
        try await expectRejection(.noSuchSpace(stranger.id), on: h) {
            try await h.server.updateSpace(stranger)
        }
    }

    /// A space takes its agents, their layouts and utility terminals, and every process in them;
    /// spaces nested under it by path are independent and stay.
    @Test func deleteSpaceRemovesEverythingInsideItButNotNestedSpaces() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let session = try await h.shell("sleep 30")
        let parent = Fixture.space("ws", path: "/tmp/ws")
        let nested = Fixture.space("project", path: "/tmp/ws/project")
        let doomed = Fixture.agent(in: parent, sessionID: session.id)
        let survivor = Fixture.agent(in: nested)
        let utility = Tab(spaceID: parent.id, order: 1, layout: .leaf(LeafPane(cwd: parent.path)), inspectorFor: doomed.agent.id)
        let automation = Automation(name: "watch", prompt: "p", cwd: parent.path, agentID: doomed.agent.id)
        try await h.seed(ShepherdState(
            spaces: [parent, nested], tabs: [doomed.tab, utility, survivor.tab],
            agents: [doomed.agent, survivor.agent], automations: [automation]))

        try await h.server.deleteSpace(parent.id)
        let state = try await committed(h)
        #expect(state.spaces == [nested])
        #expect(state.agents == [survivor.agent])
        #expect(state.tabs == [survivor.tab])
        #expect(state.automations.map(\.agentID) == [nil])
        try await eventually("the space's session to be killed") { callbacks.exited(session.id) }
    }

    @Test func deletingAnUnknownSpaceIsRejected() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let id = SpaceID()
        try await expectRejection(.noSuchSpace(id), on: h) { try await h.server.deleteSpace(id) }
    }

    // MARK: - Tabs

    @Test func addTabAppendsALayoutToItsSpace() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(ShepherdState(spaces: [space]))
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))

        try await h.server.addTab(tab)
        #expect(try await committed(h).tabs == [tab])
    }

    @Test func addTabRejectsDuplicatesGlobalTabsAndUnknownSpaces() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))
        try await h.seed(ShepherdState(spaces: [space], tabs: [tab]))

        try await expectRejection(.conflict("tab \(tab.id) already exists"), on: h) { try await h.server.addTab(tab) }
        let global = Tab(spaceID: nil, order: 0, layout: .leaf(LeafPane(cwd: "/tmp")))
        try await expectRejection(.conflict("tab \(global.id) belongs to no space"), on: h) { try await h.server.addTab(global) }
        let lost = SpaceID()
        let orphan = Tab(spaceID: lost, order: 0, layout: .leaf(LeafPane(cwd: "/tmp")))
        try await expectRejection(.noSuchSpace(lost), on: h) { try await h.server.addTab(orphan) }
    }

    @Test func updateTabReplacesTheTab() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        var tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))
        try await h.seed(ShepherdState(spaces: [space], tabs: [tab]))
        tab.order = 3

        try await h.server.updateTab(tab)
        #expect(try await committed(h).tabs == [tab])
        let stranger = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))
        try await expectRejection(.noSuchTab(stranger.id), on: h) { try await h.server.updateTab(stranger) }
    }

    @Test func removeTabDeletesAnUnownedLayout() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))
        try await h.seed(ShepherdState(spaces: [space], tabs: [tab]))

        try await h.server.removeTab(tab.id)
        #expect(try await committed(h).tabs.isEmpty)
    }

    @Test func removeTabRefusesALayoutAnAgentOwns() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let owned = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([owned], space: space))

        try await expectRejection(.tabInUse(owned.tab.id), on: h) { try await h.server.removeTab(owned.tab.id) }
        let unknown = TabID()
        try await expectRejection(.noSuchTab(unknown), on: h) { try await h.server.removeTab(unknown) }
    }

    // MARK: - Layouts

    /// A structural write keeps the binding of every pane that survives it, whatever the
    /// incoming tree says; new panes start unbound.
    @Test func updateLayoutStructurePreservesSurvivingPaneBindings() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let bound = SessionID()
        let first = LeafPane(sessionID: bound, cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(first))
        try await h.seed(ShepherdState(spaces: [space], tabs: [tab]))

        let staleCopy = LeafPane(id: first.id, sessionID: SessionID(), cwd: space.path)
        let newcomer = LeafPane(sessionID: SessionID(), cwd: space.path)
        try await h.server.updateLayoutStructure(
            tabID: tab.id, layout: .split(axis: .vertical, ratio: 0.5, first: .leaf(staleCopy), second: .leaf(newcomer)))

        let layout = try #require(try await committed(h).tabs.first?.layout)
        #expect(layout.leaves.map(\.id) == [first.id, newcomer.id])
        #expect(layout.leaf(withID: first.id)?.sessionID == bound)
        #expect(layout.leaf(withID: newcomer.id)?.sessionID == nil)
    }

    @Test func updateLayoutStructureRejectsAnUnknownTab() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let id = TabID()
        try await expectRejection(.noSuchTab(id), on: h) {
            try await h.server.updateLayoutStructure(tabID: id, layout: .leaf(LeafPane(cwd: "/tmp")))
        }
    }

    @Test func updatePaneSessionBindsOnePaneWithoutReplacingTheTree() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let (a, b) = (LeafPane(cwd: space.path), LeafPane(cwd: space.path))
        let tab = Tab(spaceID: space.id, order: 0, layout: .split(axis: .horizontal, ratio: 0.3, first: .leaf(a), second: .leaf(b)))
        try await h.seed(ShepherdState(spaces: [space], tabs: [tab]))
        let session = SessionID()

        try await h.server.updatePaneSession(tabID: tab.id, paneID: b.id, sessionID: session)
        let layout = try #require(try await committed(h).tabs.first?.layout)
        #expect(layout == .split(axis: .horizontal, ratio: 0.3, first: .leaf(a), second: .leaf(LeafPane(id: b.id, sessionID: session, cwd: space.path))))

        try await h.server.updatePaneSession(tabID: tab.id, paneID: b.id, sessionID: nil)
        #expect(try await committed(h).tabs.first?.layout.leaf(withID: b.id)?.sessionID == nil)
    }

    @Test func updatePaneSessionRejectsUnknownTabsAndPanes() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))
        try await h.seed(ShepherdState(spaces: [space], tabs: [tab]))
        let (tabID, paneID) = (TabID(), PaneID())

        try await expectRejection(.noSuchTab(tabID), on: h) {
            try await h.server.updatePaneSession(tabID: tabID, paneID: paneID, sessionID: SessionID())
        }
        try await expectRejection(.noSuchPane(paneID), on: h) {
            try await h.server.updatePaneSession(tabID: tab.id, paneID: paneID, sessionID: SessionID())
        }
    }

    /// Binding and structural writes may be queued in either order; neither loses the other.
    @Test func bindingAndStructuralWritesInterleaveWithoutLosingEither() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let pane = LeafPane(cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        try await h.seed(ShepherdState(spaces: [space], tabs: [tab]))
        let split = PaneNode.split(axis: .vertical, ratio: 0.5, first: .leaf(pane), second: .leaf(LeafPane(cwd: space.path)))
        let session = SessionID()

        async let structural: Void = h.server.updateLayoutStructure(tabID: tab.id, layout: split)
        async let binding: Void = h.server.updatePaneSession(tabID: tab.id, paneID: pane.id, sessionID: session)
        _ = try await (structural, binding)

        let layout = try #require(h.server.state.tabs.first?.layout)
        #expect(layout.leaves.count == 2)
        #expect(layout.leaf(withID: pane.id)?.sessionID == session)
    }

    // MARK: - Agents

    @Test func addAgentWithTabPublishesOneAtomicSnapshot() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(ShepherdState(spaces: [space]))
        let new = Fixture.agent(in: space)

        try await h.server.addAgent(new.agent, withTab: new.tab)
        #expect(try await committed(h) == Fixture.workspace([new], space: space))
    }

    @Test func addAgentWithTabRejectsInconsistentPairs() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let other = Fixture.space("other")
        let existing = Fixture.agent(in: space)
        try await h.seed(ShepherdState(spaces: [space, other], tabs: [existing.tab], agents: [existing.agent]))
        let fresh = Fixture.agent(in: space)

        try await expectRejection(.conflict("agent \(existing.agent.id) already exists"), on: h) {
            try await h.server.addAgent(existing.agent, withTab: fresh.tab)
        }
        try await expectRejection(.conflict("tab \(existing.tab.id) already exists"), on: h) {
            try await h.server.addAgent(fresh.agent, withTab: existing.tab)
        }
        let unhomed = Fixture.agent(in: Fixture.space("gone"))
        try await expectRejection(.noSuchSpace(unhomed.agent.spaceID), on: h) {
            try await h.server.addAgent(unhomed.agent, withTab: unhomed.tab)
        }
        let wrongTab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))
        try await expectRejection(.conflict("agent \(fresh.agent.id) does not reference tab \(wrongTab.id)"), on: h) {
            try await h.server.addAgent(fresh.agent, withTab: wrongTab)
        }
        var elsewhere = fresh.tab
        elsewhere.spaceID = other.id
        try await expectRejection(.conflict("agent and tab belong to different spaces"), on: h) {
            try await h.server.addAgent(fresh.agent, withTab: elsewhere)
        }
    }

    @Test func addAgentJoinsAnExistingLayout() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))
        try await h.seed(ShepherdState(spaces: [space], tabs: [tab]))
        let agent = Agent(name: "a", spaceID: space.id, tabID: tab.id)

        try await h.server.addAgent(agent)
        #expect(try await committed(h).agents == [agent])
        try await expectRejection(.conflict("agent \(agent.id) already exists"), on: h) { try await h.server.addAgent(agent) }
        let homeless = Agent(name: "b", spaceID: space.id, tabID: TabID())
        try await expectRejection(.noSuchTab(homeless.tabID), on: h) { try await h.server.addAgent(homeless) }
        let spaceless = Agent(name: "c", spaceID: SpaceID(), tabID: tab.id)
        try await expectRejection(.noSuchSpace(spaceless.spaceID), on: h) { try await h.server.addAgent(spaceless) }
    }

    @Test func updateAgentReplacesTheRecord() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        var worker = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([worker], space: space))
        worker.agent.model = "anthropic/claude-opus"
        worker.agent.thinkingLevel = .high

        try await h.server.updateAgent(worker.agent)
        #expect(try await committed(h).agents == [worker.agent])
        let stranger = Fixture.agent(in: space).agent
        try await expectRejection(.noSuchAgent(stranger.id), on: h) { try await h.server.updateAgent(stranger) }
    }

    @Test func renameAgentTrimsTheNameAndSettlesIt() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space, name: "clean up the naming code…", nameIsFinal: false)
        try await h.seed(Fixture.workspace([worker], space: space))

        try await h.server.renameAgent(worker.agent.id, to: "  Final title \n")
        let agent = try #require(try await committed(h).agents.first)
        #expect(agent.name == "Final title")
        #expect(agent.nameIsFinal)
    }

    @Test func renamingToABlankOrTheSameNameChangesNothing() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space, name: "kept", nameIsFinal: false)
        try await h.seed(Fixture.workspace([worker], space: space))

        try await expectNoChange(on: h) { try await h.server.renameAgent(worker.agent.id, to: "   ") }
        try await expectNoChange(on: h) { try await h.server.renameAgent(worker.agent.id, to: "kept") }
        let unknown = AgentID()
        try await expectRejection(.noSuchAgent(unknown), on: h) { try await h.server.renameAgent(unknown, to: "x") }
    }

    @Test func reorderAgentMovesItWithinItsSpaceOnly() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (one, two) = (Fixture.space("one"), Fixture.space("two"))
        let a = Fixture.agent(in: one, name: "a"), b = Fixture.agent(in: one, name: "b"), c = Fixture.agent(in: two, name: "c")
        try await h.seed(ShepherdState(spaces: [one, two], tabs: [a.tab, b.tab, c.tab], agents: [a.agent, b.agent, c.agent]))

        try await h.server.reorderAgent(b.agent.id, onto: a.agent.id)
        #expect(try await committed(h).agents.map(\.name) == ["b", "a", "c"])
        try await expectRejection(.conflict("Agents must belong to the same space"), on: h) {
            try await h.server.reorderAgent(c.agent.id, onto: a.agent.id)
        }
        try await expectNoChange(on: h) { try await h.server.reorderAgent(a.agent.id, onto: a.agent.id) }
    }

    /// removeAgent forgets the record only (the layout is the caller's); an automation it was
    /// running stops pointing at it.
    @Test func removeAgentForgetsItAndItsAutomationRunButKeepsTheLayout() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))
        let agent = Agent(name: "worker", spaceID: space.id, tabID: tab.id)
        let automation = Automation(name: "watch", prompt: "p", cwd: space.path, agentID: agent.id)
        try await h.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent], automations: [automation]))

        try await h.server.removeAgent(agent.id)
        let state = try await committed(h)
        #expect(state.agents.isEmpty)
        #expect(state.tabs == [tab])
        #expect(state.automations.first?.agentID == nil)
        try await expectRejection(.noSuchAgent(agent.id), on: h) { try await h.server.removeAgent(agent.id) }
    }

    /// Delete Agent: the agent, its layout, and its utility terminal go in one snapshot; every
    /// process in the layout is then terminated.
    @Test func deleteAgentRemovesItsWholeRuntimeAtomically() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let primary = try await h.shell("sleep 30")
        let auxiliary = try await h.shell("sleep 30")
        let space = Fixture.space()
        let agentID = AgentID()
        let pane = LeafPane(sessionID: primary.id, cwd: space.path, agentID: agentID)
        let tab = Tab(spaceID: space.id, order: 0, layout: .split(
            axis: .vertical, ratio: 0.6, first: .leaf(pane), second: .leaf(LeafPane(sessionID: auxiliary.id, cwd: space.path))))
        let agent = Agent(id: agentID, name: "worker", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        let utility = Tab(spaceID: space.id, order: 1, layout: .leaf(LeafPane(cwd: space.path)), inspectorFor: agentID)
        let bystander = Fixture.agent(in: space, name: "bystander")
        let automation = Automation(name: "watch", prompt: "p", cwd: space.path, agentID: agentID)
        try await h.seed(ShepherdState(spaces: [space], tabs: [tab, utility, bystander.tab],
                                       agents: [agent, bystander.agent], automations: [automation]))

        try await h.server.deleteAgent(agentID)
        let state = try await committed(h)
        #expect(state.agents == [bystander.agent])
        #expect(state.tabs == [bystander.tab])
        #expect(state.automations == [Automation(id: automation.id, name: "watch", prompt: "p", cwd: space.path)])
        try await eventually("both layout sessions to be killed") { callbacks.exited(primary.id) && callbacks.exited(auxiliary.id) }
    }

    @Test func deletingAnUnknownAgentIsRejected() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let id = AgentID()
        try await expectRejection(.noSuchAgent(id), on: h) { try await h.server.deleteAgent(id) }
    }

    // MARK: - Automations

    @Test func addAutomationPersistsIt() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let automation = Automation(name: "pr-watch", prompt: "watch the PR", cwd: "/tmp/repo")

        try await h.server.addAutomation(automation)
        #expect(try await committed(h).automations == [automation])
        try await expectRejection(.conflict("automation \(automation.id) already exists"), on: h) {
            try await h.server.addAutomation(automation)
        }
    }

    @Test func updateAutomationReplacesIt() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        var automation = Automation(name: "pr-watch", prompt: "watch", cwd: "/tmp/repo")
        try await h.seed(ShepherdState(automations: [automation]))
        automation.enabled = false
        automation.prompt = "watch harder"

        try await h.server.updateAutomation(automation)
        #expect(try await committed(h).automations == [automation])
        let stranger = Automation(name: "x", prompt: "y", cwd: "/tmp")
        try await expectRejection(.noSuchAutomation(stranger.id), on: h) { try await h.server.updateAutomation(stranger) }
    }

    /// Removing the saved automation leaves its running agent alone.
    @Test func removeAutomationKeepsItsAgent() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        let automation = Automation(name: "watch", prompt: "p", cwd: space.path, agentID: worker.agent.id)
        try await h.seed(ShepherdState(spaces: [space], tabs: [worker.tab], agents: [worker.agent], automations: [automation]))

        try await h.server.removeAutomation(automation.id)
        let state = try await committed(h)
        #expect(state.automations.isEmpty)
        #expect(state.agents == [worker.agent])
        try await expectRejection(.noSuchAutomation(automation.id), on: h) { try await h.server.removeAutomation(automation.id) }
    }
}
