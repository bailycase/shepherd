import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite(.integrationTimeLimit)
struct StatePersistenceTests {
    @Test func aStagedRenameKeepsTheServerResponsiveAndPreservesConcurrentLiveState() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space(), agent = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([agent], space: space))
        let before = h.server.state
        let preparations = Locked(0)
        try await h.server.enqueue { h.server.stateWritePrepared = { preparations.withValue { $0 += 1 } } }
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let save = Task { try await h.server.renameAgent(agent.agent.id, to: "Renamed") }
        try await eventually("candidate captured without blocking the server") { preparations.current == 1 }
        #expect(h.server.state == before)
        #expect(try h.persisted() == before)
        let checkout = AgentCheckout(branch: "live", changedFiles: 3)
        await h.server.setAgentCheckout(agent.agent.id, checkout)
        #expect(h.server.state.agents.first?.checkout == checkout)
        gate.signal()
        try await save.value
        #expect(h.server.state.agents.first?.name == "Renamed")
        #expect(h.server.state.agents.first?.checkout == checkout)
        #expect(preparations.current == 2, "A live change forces a fresh candidate, not a stale overwrite")
        #expect(try h.persisted() == h.server.state)
    }

    @Test func stagedBindingAndNameKeepOrderingWithoutBlockingOtherAgents() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space(), agent = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([agent], space: space))
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let session = SessionID(), pane = try #require(agent.agent.paneID)
        let binding = Task { try await h.server.updatePaneSession(tabID: agent.tab.id, paneID: pane, sessionID: session) }
        try await eventually("binding admitted") { try await h.server.enqueue { h.server.stateWritesInFlight == 1 } }
        let naming = Task { try await h.server.renameAgent(agent.agent.id, to: "After binding") }
        try await eventually("name admitted behind binding") { try await h.server.enqueue { h.server.stateWritesInFlight == 2 } }
        await h.server.setAgentCheckout(agent.agent.id, .init(branch: "live", changedFiles: 1))
        #expect(h.server.state.tabs.first?.layout.firstLeaf.sessionID == nil)
        gate.signal()
        try await binding.value
        try await naming.value
        #expect(h.server.state.tabs.first?.layout.firstLeaf.sessionID == session)
        #expect(try h.persisted().agents.first?.name == "After binding")
        #expect(try h.persisted() == h.server.state)
    }

    @Test func cancelledStagedWriteNeverPublishes() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space(), agent = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([agent], space: space))
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let before = h.server.state
        let save = Task { try await h.server.renameAgent(agent.agent.id, to: "Cancelled") }
        try await eventually("save admitted") { try await h.server.enqueue { h.server.stateWritesInFlight == 1 } }
        save.cancel()
        gate.signal()
        await #expect(throws: CancellationError.self) { try await save.value }
        #expect(h.server.state == before)
        #expect(try h.persisted() == before)
    }

    @Test func stagedWorkspaceSavesHaveBoundedAdmission() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space(), agent = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([agent], space: space))
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let saves = (0..<SessionServer.maximumStateWrites).map { _ in
            Task { try await h.server.renameAgent(agent.agent.id, to: "Saved") }
        }
        try await eventually("save admission limit reached") {
            try await h.server.enqueue { h.server.stateWritesInFlight == SessionServer.maximumStateWrites }
        }
        await #expect(throws: SessionServerError.self) { try await h.server.renameAgent(agent.agent.id, to: "Overflow") }
        gate.signal()
        for save in saves { try await save.value }
        #expect(h.server.state.agents.first?.name == "Saved")
        try await eventually("admission slots released") { try await h.server.enqueue { h.server.stateWritesInFlight == 0 } }
    }

    @Test func anInvalidStagedCandidatePublishesNothing() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space(), agent = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([agent], space: space))
        let before = h.server.state
        let bytes = try Data(contentsOf: h.stateURL)
        await #expect(throws: SessionServerError.self) {
            try await h.server.mutateStateOffQueue { $0.agents[0].spaceID = SpaceID() }
        }
        await drainMainQueue()
        #expect(h.server.state == before)
        #expect(try Data(contentsOf: h.stateURL) == bytes)
        #expect(h.broadcasts.current.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.dir.path).allSatisfy { !$0.hasPrefix(".logical-project-state-") })
    }

    @Test func failedRenamePublishesNothingCleansUpAndAllowsRecovery() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space(), agent = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([agent], space: space))
        let before = h.server.state
        let backup = h.dir.appendingPathComponent("before.json")
        try FileManager.default.moveItem(at: h.stateURL, to: backup)
        try FileManager.default.createDirectory(at: h.stateURL, withIntermediateDirectories: false)
        await #expect(throws: SessionServerError.self) { try await h.server.renameAgent(agent.agent.id, to: "Unwritten") }
        await drainMainQueue()
        #expect(h.server.state == before && h.broadcasts.current.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.dir.path).allSatisfy { !$0.hasPrefix(".logical-project-state-") })
        try await eventually("failed writer releases admission") { try await h.server.enqueue { h.server.stateWritesInFlight == 0 } }
        try FileManager.default.removeItem(at: h.stateURL)
        try FileManager.default.moveItem(at: backup, to: h.stateURL)
        try await h.server.renameAgent(agent.agent.id, to: "Recovered")
        #expect(try h.persisted().agents.first?.name == "Recovered")
    }

    @Test func repeatedConflictsStopAtTheRetryLimit() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space(), agent = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([agent], space: space))
        let attempts = Locked(0)
        try await h.server.enqueue {
            h.server.stateWritePrepared = { [weak server = h.server] in
                let number = attempts.withValue { $0 += 1; return $0 }
                server?.store.updateLive { $0.agents[0].checkout = AgentCheckout(branch: "concurrent", changedFiles: number) }
            }
        }
        await #expect(throws: SessionServerError.self) { try await h.server.renameAgent(agent.agent.id, to: "Never committed") }
        #expect(attempts.current == SessionServer.maximumStateWriteAttempts)
        #expect(h.server.state.agents.first?.name == agent.agent.name)
        #expect(h.server.state.agents.first?.checkout?.changedFiles == attempts.current)
        #expect(try h.persisted().agents.first?.name == agent.agent.name)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.dir.path).allSatisfy { !$0.hasPrefix(".logical-project-state-") })
        try await eventually("exhausted writer releases admission") { try await h.server.enqueue { h.server.stateWritesInFlight == 0 } }
    }

    @Test func conflictingSavesKeepTheirAdmissionOrder() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space(), agent = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([agent], space: space))
        let preparations = Locked(0)
        try await h.server.enqueue { h.server.stateWritePrepared = { preparations.withValue { $0 += 1 } } }
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let first = Task { try await h.server.renameAgent(agent.agent.id, to: "First") }
        try await eventually("first candidate prepared") { preparations.current == 1 }
        let second = Task { try await h.server.renameAgent(agent.agent.id, to: "Second") }
        try await eventually("second save admitted") { try await h.server.enqueue { h.server.stateWritesInFlight == 2 } }
        await h.server.setAgentCheckout(agent.agent.id, AgentCheckout(branch: "concurrent", changedFiles: 1))
        gate.signal()
        try await first.value
        try await second.value
        #expect(h.server.state.agents.first?.name == "Second")
        #expect(preparations.current == 3, "First restages before Second prepares")
    }

    @Test func aStoppedLifecycleCannotCommitItsStagedRename() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space(), agent = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([agent], space: space))
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let save = Task { try await h.server.renameAgent(agent.agent.id, to: "Stale") }
        try await eventually("save admitted") { try await h.server.enqueue { h.server.stateWritesInFlight == 1 } }
        h.server.stop()
        try h.server.start()
        gate.signal()
        await #expect(throws: SessionServerError.self) { try await save.value }
        #expect(h.server.state.agents.first?.name == agent.agent.name)
    }
}
