import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// A deleted agent's turn records, prepared baseline and capture queue go when it does, not at the
/// next launch: the engine holds them per agent, and a host that creates and deletes threads all
/// day would otherwise grow by one of each per thread.
@Suite("Changes forget deleted agents", .integrationTimeLimit)
struct ChangesForgetTests {
    /// A repository whose stub-pi gate files (`tool-*`) are no agent's work.
    static func repo() throws -> ChangesRepo {
        let repo = try ChangesRepo(files: ["a.txt": "one\n"])
        try "tool-*\n".write(to: repo.url.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        return repo
    }

    /// An agent in `repo` with a turn that has recorded its baseline and waits at `tool-1`.
    static func startTurn(on host: ScratchServer, in repo: ChangesRepo) async throws -> PiAgent {
        let pi = try await PiAgent.launch(on: host, cwd: repo.url)
        let idle = try await pi.ready()
        #expect(try await pi.send("tools:1 refactor the ledger", from: idle).failureCode == nil)
        try await eventually("the baseline of \(pi.agent.id)") { host.server.changes.turnStore.latest(pi.agent.id)?.startTree != nil }
        return pi
    }

    /// Lets the turns waiting in `repo` end, and waits for each agent's card.
    static func finishTurns(of agents: [PiAgent], in repo: ChangesRepo) async throws {
        FileManager.default.createFile(atPath: repo.url.appendingPathComponent("tool-1").path, contents: nil)
        for pi in agents {
            try await eventually("the turn of \(pi.agent.id) to end") { pi.host.server.changes.turns(agentID: pi.agent.id).last?.state == .ready }
        }
    }

    /// The agents `turns.json` holds right now, once pending saves are written.
    static func savedAgents(_ changes: ChangesService) -> Set<String>? {
        changes.turnStore.flush()
        guard let data = try? Data(contentsOf: changes.directory.appendingPathComponent("turns.json")),
              let saved = try? JSONDecoder().decode([String: [TurnRecord]].self, from: data) else { return nil }
        return Set(saved.keys)
    }

    enum Removal: String, CaseIterable, CustomTestStringConvertible {
        case deleteAgent, removeAgent
        var testDescription: String { rawValue }

        func apply(to server: SessionServer, _ agent: AgentID) async throws {
            switch self {
            case .deleteAgent: try await server.deleteAgent(agent)
            case .removeAgent: try await server.removeAgent(agent)
            }
        }
    }

    @Test(arguments: Removal.allCases)
    func deletingAnAgentForgetsItsTurnsAndCaptureQueue(_ removal: Removal) async throws {
        let t = try await ChangesTurnTests.agentTurn()
        defer { t.host.stop() }
        let elsewhere = try Self.repo()
        let bystander = try await Self.startTurn(on: t.host, in: elsewhere)
        try await Self.finishTurns(of: [bystander], in: elsewhere)
        let kept = t.changes.turns(agentID: bystander.agent.id)
        #expect(!t.turns().isEmpty && !kept.isEmpty)
        let queues = t.changes.captureQueueCount
        // A baseline taken for a prompt whose turn has not started.
        let agent = t.agent
        t.changes.preparedTurns.withValue { $0[agent] = (t.repo.path, .success("tree")) }

        try await removal.apply(to: t.host.server, t.agent)

        try await eventually("the agent's turns to go") { t.turns().isEmpty }
        try await eventually("its capture queue to go") { t.changes.captureQueueCount == queues - 1 }
        #expect(t.changes.preparedTurns.withValue { $0[agent] } == nil, "its prepared baseline went with it")
        #expect(t.changes.turns(agentID: bystander.agent.id) == kept, "another agent's turns stay")
        try await eventually("turns.json to lose the agent") { Self.savedAgents(t.changes) == [bystander.agent.id.rawValue] }
    }

    @Test func deletingASpaceForgetsEveryAgentInIt() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let shared = try Self.repo(), apart = try Self.repo()
        let first = try await Self.startTurn(on: host, in: shared)
        let second = try await Self.startTurn(on: host, in: shared)
        let bystander = try await Self.startTurn(on: host, in: apart)
        try await Self.finishTurns(of: [first, second], in: shared)
        try await Self.finishTurns(of: [bystander], in: apart)
        let changes = host.server.changes
        let space = first.agent.spaceID
        #expect(second.agent.spaceID == space && bystander.agent.spaceID != space)
        let kept = changes.turns(agentID: bystander.agent.id)
        let queues = changes.captureQueueCount

        try await host.server.deleteSpace(space)

        try await eventually("every agent in the space to be forgotten") {
            changes.turns(agentID: first.agent.id).isEmpty && changes.turns(agentID: second.agent.id).isEmpty
        }
        try await eventually("their capture queues to go") { changes.captureQueueCount == queues - 2 }
        #expect(changes.turns(agentID: bystander.agent.id) == kept)
        try await eventually("turns.json to hold only the other space") { Self.savedAgents(changes) == [bystander.agent.id.rawValue] }
    }

    /// A design's agents are held for its undo window, because Undo brings them back with their cards.
    private struct Drawn {
        let host: ScratchServer
        let design: Design
        let drawer: AgentID
        var changes: ChangesService { host.server.changes }
    }

    private func drawnDesign(window: TimeInterval, in repo: ChangesRepo) async throws -> Drawn {
        let host = try ScratchServer.fresh()
        host.server.designUndoWindow = window
        let design = Design(name: "Checkout funnel", createdAt: 1_000)
        _ = try await host.server.createDesign(design)
        let space = try await host.server.designsSpaceID()
        let id = AgentID()
        let pane = LeafPane(sessionID: nil, cwd: repo.path, agentID: id)
        let tab = ShepherdCore.Tab(spaceID: space, order: 1, layout: .leaf(pane))
        var state = host.server.state
        state.tabs.append(tab)
        state.agents.append(Agent(id: id, name: design.name, spaceID: space, tabID: tab.id, paneID: pane.id, designID: design.id))
        try await host.server.putState(state)
        let changes = host.server.changes
        changes.turnStarted(agentID: id)
        await ChangesTurnTests.drain(changes, id)
        changes.turnSettled(agentID: id)
        await ChangesTurnTests.drain(changes, id)
        #expect(changes.turns(agentID: id).last?.state == .ready)
        return Drawn(host: host, design: design, drawer: id)
    }

    @Test func undoingADesignDeletionKeepsItsAgentsTurns() async throws {
        let d = try await drawnDesign(window: 60, in: try Self.repo())
        defer { d.host.stop() }
        let kept = d.changes.turns(agentID: d.drawer)

        _ = try await d.host.server.deleteDesign(d.design.id)
        #expect(!d.host.server.state.agents.contains { $0.id == d.drawer })
        await ChangesTurnTests.drain(d.changes, d.drawer)
        #expect(d.changes.turns(agentID: d.drawer) == kept, "held while Undo can still bring the agent back")

        try await d.host.server.undoDesignDeletion(d.design.id)
        #expect(d.host.server.state.agents.contains { $0.id == d.drawer })
        await ChangesTurnTests.drain(d.changes, d.drawer)
        #expect(d.changes.turns(agentID: d.drawer) == kept, "back with its cards")
    }

    @Test(arguments: [true, false])
    func aDesignDeletionThatCannotBeUndoneForgetsItsAgentsTurns(undoable: Bool) async throws {
        let d = try await drawnDesign(window: 0.2, in: try Self.repo())
        defer { d.host.stop() }
        let queues = d.changes.captureQueueCount
        #expect(queues == 1)

        _ = try await d.host.server.deleteDesign(d.design.id, undoable: undoable)

        try await eventually("the agent's turns to go") { d.changes.turns(agentID: d.drawer).isEmpty }
        try await eventually("its capture queue to go") { d.changes.captureQueueCount == 0 }
        try await eventually("turns.json to lose the agent") { Self.savedAgents(d.changes) == [] }
    }

    /// Launch still drops agents deleted while Shepherd was closed.
    @Test func aRestartStillPrunesAgentsDeletedWhileShepherdWasClosed() async throws {
        let t = try await ChangesTurnTests.agentTurn()
        let agent = t.agent
        #expect(!t.turns().isEmpty)
        t.changes.turnStore.flush()
        let dir = t.host.dir
        t.host.stop(keepFiles: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var state = try t.host.persisted()
        let tab = try #require(state.agents.first { $0.id == agent }?.tabID)
        state.agents.removeAll { $0.id == agent }
        state.tabs.removeAll { $0.id == tab }
        try JSONEncoder().encode(state).write(to: t.host.stateURL)

        let restarted = try ScratchServer(dir: dir)
        defer { restarted.stop() }
        #expect(restarted.server.changes.turns(agentID: agent).isEmpty)
        try await eventually("turns.json to lose the agent") { Self.savedAgents(restarted.server.changes) == [] }
    }

    /// A turn that settled while another thread was writing is re-cut when a late writer is heard
    /// of, which would queue work for an agent that no longer exists.
    @Test func aForgottenAgentsSettledTurnIsNeverRecutAgain() async throws {
        let p = try ChangesTurnTests.Pair(files: ["a.txt": "a\n"])
        let started = ChangesService.nowMs()
        p.service.turnStarted(agentID: p.agent, at: started)
        await ChangesTurnTests.drain(p.service, p.agent)
        try p.edit(p.agent, "a.txt", id: "mine", text: "a edited\n")
        _ = try await p.settle()
        #expect(p.service.captureQueueCount == 1)

        p.service.forget([p.agent])
        try await eventually("the capture queue to go") { p.service.captureQueueCount == 0 }
        #expect(p.service.turns(agentID: p.agent).isEmpty)

        p.service.callStarted(agentID: p.other, callID: "theirs", path: "a.txt", at: started)
        #expect(p.service.captureQueueCount == 0, "nothing to re-cut for a deleted agent")
    }
}
