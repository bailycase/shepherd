import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Mission owner service", .integrationTimeLimit)
struct MissionServiceTests {
    private func draft(in spaces: [Space]) -> MissionDraft {
        let workers = spaces.map { MissionStation(kind: .worker, laneID: $0.id, title: $0.name, goal: "Implement the event join") }
        let validator = MissionStation(kind: .validator, title: "Independent validation", goal: "Replay orders and check for unmatched checkouts")
        return MissionDraft(title: "Checkout events", goal: "Every order joins a checkout", requirements: ["Replaying events creates no duplicate charges"],
                            plan: .init(lanes: spaces.map { .init(spaceID: $0.id, name: $0.name) }, stations: workers + [validator],
                                        dependencies: workers.map { .init(source: $0.id, target: validator.id, kind: .data, artifact: "candidate branch") }))
    }

    @Test func savedMapsUseExactRevisionsInvalidateApprovalAndNeverLaunchWork() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let spaces = [Space(name: "contracts", path: host.dir.path), Space(name: "analytics", path: host.dir.path)]
        try await host.seed(ShepherdState(spaces: spaces))
        let value = draft(in: spaces), id = MissionID()
        let created = try await host.server.createMission(id: id, draft: value)
        #expect(created.revision == 1 && created.approvedPlanRevision == nil)
        #expect(try await host.server.createMission(id: id, draft: value) == created)
        #expect(try await host.server.missions() == [created])
        #expect(try host.persisted().missions == [created])
        try await eventually("mission saved before local publication") { host.broadcasts.current.last?.missions == [created] }

        let approved = try await host.server.approveMissionPlan(id: id, expectedRevision: created.revision)
        #expect(approved.revision == 2 && approved.approvedPlanRevision == 2)
        var changed = value
        changed.goal = "Every order and refund joins a checkout"
        await #expect(throws: MissionError.self) {
            try await host.server.editMission(id: id, expectedRevision: created.revision, draft: changed)
        }
        #expect(try host.persisted().missions == [approved])
        let edited = try await host.server.editMission(id: id, expectedRevision: approved.revision, draft: changed)
        #expect(edited.revision == 3 && edited.approvedPlanRevision == nil)
        await #expect(throws: MissionError.self) { try await host.server.approveMissionPlan(id: id, expectedRevision: approved.revision) }
        await #expect(throws: MissionError.self) { try await host.server.createMission(id: id, draft: value) }
        #expect(try host.persisted().missions == [edited])
        #expect(await host.server.listSessions().isEmpty)
        #expect(host.server.state.agents.isEmpty && host.server.state.tabs.isEmpty)
        host.server.setProjectsEnabled(true)
        _ = try await host.server.logicalProjects(.create(projectID: ProjectID(), name: "Unrelated Project", goal: ""))
        #expect(try host.persisted().missions == [edited], "Staged Project writes must preserve mission plans")

        host.stop(keepFiles: true)
        let restarted = try ScratchServer(dir: host.dir)
        defer { restarted.stop() }
        #expect(try await restarted.server.missions() == [edited])
        #expect(await restarted.server.listSessions().isEmpty)
        #expect(restarted.server.state.agents.isEmpty)
    }

    @Test func unresolvedPlannerQuestionBlocksApprovalOfAnOtherwiseValidMap() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let space = Space(name: "Repo", path: host.dir.path)
        try await host.seed(ShepherdState(spaces: [space]))
        let created = try await host.server.createMission(draft: draft(in: [space]))
        var run = MissionRun(model: "test/model", phase: .map)
        run.pendingQuestion = "Should existing callers keep the old format?"
        let waiting = try await host.server.setMissionRun(id: created.id, expectedRevision: created.revision, run: run)
        await #expect(throws: MissionError.self) { try await host.server.approveMissionPlan(id: waiting.id, expectedRevision: waiting.revision) }
        #expect(try host.persisted().missions == [waiting])
        run.pendingQuestion = nil
        let answered = try await host.server.setMissionRun(id: waiting.id, expectedRevision: waiting.revision, run: run)
        #expect(try await host.server.approveMissionPlan(id: answered.id, expectedRevision: answered.revision).approvedPlanRevision != nil)
    }

    @Test func removingExecutionHistoryCannotReleaseOwnedWorkerThreads() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let created = try await host.server.createMission(draft: .init(title: "Retained", goal: "Keep worker ownership"))
        let agent = AgentID()
        let run = MissionRun(model: "test/model", phase: .stopped,
                             attempts: [MissionAttempt(agentID: agent, status: .interrupted)])
        let stopped = try await host.server.setMissionRun(id: created.id, expectedRevision: created.revision, run: run)
        await #expect(throws: MissionError.self) {
            try await host.server.deleteMission(id: stopped.id, expectedRevision: stopped.revision)
        }
        #expect(host.server.state.isMissionAgent(agent))
        #expect(try host.persisted().missions == [stopped])
    }

    @Test func followUpsRefuseSessionsTheAttemptNeverOwnedWithoutTouchingTheRecord() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let created = try await host.server.createMission(draft: .init(title: "Spec Kit", goal: "Stock commands"))
        let agent = AgentID()
        var fresh = MissionAttempt(agentID: agent)
        fresh.command = .specify
        let run = MissionRun(model: "test/model", phase: .planning, attempts: [fresh])
        let saved = try await host.server.setMissionRun(id: created.id, expectedRevision: created.revision, run: run)
        // Never prompted (no session receipt), its first-turn operation reused, and no thread at all.
        for operation in [UUID(), UUID(uuidString: agent.rawValue)!] {
            await #expect(throws: MissionError.self) {
                try await host.server.sendMissionFollowUp(id: saved.id, runID: run.id, agentID: agent, operationID: operation, text: "/speckit.plan")
            }
        }
        await #expect(throws: MissionError.self) {
            try await host.server.sendMissionFollowUp(id: saved.id, runID: UUID(), agentID: agent, operationID: UUID(), text: "/speckit.plan")
        }
        #expect(try host.persisted().missions == [saved])
        #expect(host.server.state.missions == [saved])
    }

    @Test func specKitMapsRedrawFromArtifactsWithoutSupersedingReceiptsOrChangingScope() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let space = Space(name: "stock", path: host.dir.path)
        try await host.seed(ShepherdState(spaces: [space]))
        let original = MissionDraft(title: "Spec Kit", goal: "Stock commands", plan: .init(lanes: [.init(spaceID: space.id, name: "stock")]))
        let created = try await host.server.createMission(draft: original)
        var redrawn = original
        let station = MissionStation(kind: .research, laneID: space.id, title: "Specify", goal: "/speckit.specify writes spec.md")
        redrawn.plan?.stations = [station]
        redrawn.requirements = ["FR-001"]
        // A map-runner mission never takes a drawn map.
        await #expect(throws: MissionError.self) { try await host.server.projectSpecKitMap(id: created.id, expectedRevision: created.revision, draft: redrawn) }
        var receipt = MissionAttempt(stationID: station.id, status: .succeeded)
        receipt.command = .specify
        var run = MissionRun(model: "test/model", attempts: [receipt])
        run.specKit = MissionSpecKitRun(lanes: [.init(spaceID: space.id)])
        let started = try await host.server.setMissionRun(id: created.id, expectedRevision: created.revision, run: run)
        let drawn = try await host.server.projectSpecKitMap(id: created.id, expectedRevision: started.revision, draft: redrawn)
        #expect(drawn.draft == redrawn && drawn.approvedPlanRevision == nil)
        #expect(drawn.run?.attempts == [receipt], "receipts stay; the map only displays the artifacts")
        var moved = redrawn
        moved.plan?.lanes[0].baseBranch = "refs/heads/other"
        await #expect(throws: MissionError.self) { try await host.server.projectSpecKitMap(id: created.id, expectedRevision: drawn.revision, draft: moved) }
        #expect(try host.persisted().missions == [drawn])
    }

    @Test func runReplacementKeepsEveryRecordedAttemptAndItsAgent() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let created = try await host.server.createMission(draft: .init(title: "Owned", goal: "Keep worker ownership"))
        let agent = AgentID()
        let reserved = MissionAttempt(status: .running)
        var run = MissionRun(model: "test/model", phase: .stopped, attempts: [MissionAttempt(agentID: agent, status: .running), reserved])
        var saved = try await host.server.setMissionRun(id: created.id, expectedRevision: created.revision, run: run)
        // Allowed: status changes, appended attempts, a nil agent getting its reserved ID, a new run identity.
        run.id = UUID()
        run.attempts[0].status = .interrupted
        run.attempts[1].agentID = AgentID()
        run.attempts.append(MissionAttempt(agentID: AgentID()))
        saved = try await host.server.setMissionRun(id: created.id, expectedRevision: saved.revision, run: run)
        #expect(saved.run == run)
        // Refused: dropping an attempt, or rebinding a recorded agent. The record is unchanged.
        var dropped = run; dropped.attempts.removeFirst()
        await #expect(throws: MissionError.self) { try await host.server.setMissionRun(id: created.id, expectedRevision: saved.revision, run: dropped) }
        var rebound = run; rebound.attempts[0].agentID = AgentID()
        await #expect(throws: MissionError.self) { try await host.server.setMissionRun(id: created.id, expectedRevision: saved.revision, run: rebound) }
        var cleared = run; cleared.attempts[1].agentID = nil
        await #expect(throws: MissionError.self) { try await host.server.setMissionRun(id: created.id, expectedRevision: saved.revision, run: cleared) }
        #expect(try host.persisted().missions == [saved])
        #expect(host.server.state.isMissionAgent(agent))
    }

    @Test func finishedMissionStepsAnswerHeldOffWithWhyWhileReservedStepsStillStart() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let space = Space(name: "repo", path: host.dir.path)
        func agent(_ name: String) -> (Agent, Tab) {
            let pane = LeafPane(cwd: host.dir.path)
            let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
            return (Agent(name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id), tab)
        }
        let (finished, finishedTab) = agent("Spec Kit: /speckit.converge")
        let (reserved, reservedTab) = agent("Spec Kit: /speckit.implement")
        try await host.seed(ShepherdState(spaces: [space], tabs: [finishedTab, reservedTab], agents: [finished, reserved]))
        let created = try await host.server.createMission(draft: .init(title: "Owned", goal: "Read history"))
        // Planning is an active phase: the reserved step's pi is on its way, the finished one is stopped for good.
        let run = MissionRun(model: "test/model", phase: .planning,
                             attempts: [MissionAttempt(agentID: finished.id, status: .succeeded), MissionAttempt(agentID: reserved.id, status: .running)])
        _ = try await host.server.setMissionRun(id: created.id, expectedRevision: created.revision, run: run)
        func outcome(_ agent: Agent) async throws -> String? {
            do {
                if case .failure(let code, _) = try await host.server.nativeThread(agentID: agent.id, request: .snapshot()) { return code }
                return nil
            } catch {
                let text = String(describing: error)
                if agent.id == finished.id { #expect(text.contains(SessionServer.finishedMissionStep)) }
                return [NativeThreadCode.unavailable, NativeThreadCode.starting].first { text.hasPrefix($0) }
            }
        }
        #expect(try await outcome(finished) == NativeThreadCode.starting, "a finished step is not serving, as expected (held off), not a lost connection")
        #expect(try await outcome(reserved) == NativeThreadCode.starting, "a reserved step still starts")
    }

    @Test func invalidMapsAndBulkReplacementCannotChangeTheOwnerRecord() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let space = Space(name: "Repo", path: host.dir.path)
        try await host.seed(ShepherdState(spaces: [space]))
        let created = try await host.server.createMission(draft: draft(in: [space]))
        var invalid = created.draft
        invalid.plan?.dependencies.removeAll()
        let disconnected = try await host.server.editMission(id: created.id, expectedRevision: created.revision, draft: invalid)
        let bytes = try Data(contentsOf: host.stateURL)
        await #expect(throws: MissionError.self) { try await host.server.approveMissionPlan(id: disconnected.id, expectedRevision: disconnected.revision) }
        var forged = host.server.state
        forged.missions[0].approvedPlanRevision = disconnected.revision
        await #expect(throws: MissionError.self) { try await host.server.putState(forged) }
        #expect(try host.persisted().missions == [disconnected])

        let missing = Space(name: "Unknown", path: host.dir.path)
        await #expect(throws: MissionError.self) { try await host.server.createMission(draft: draft(in: [missing])) }
        #expect(host.server.state.missions == [disconnected])
        #expect(try Data(contentsOf: host.stateURL) == bytes, "Rejected requests must not write state")
        try await host.server.deleteSpace(space.id)
        #expect(try host.persisted().missions == [disconnected], "Missing lane links remain inspectable")
        await #expect(throws: MissionError.self) { try await host.server.deleteMission(id: created.id, expectedRevision: created.revision) }
        try await host.server.deleteMission(id: created.id, expectedRevision: disconnected.revision)
        #expect(try host.persisted().missions.isEmpty)
    }

    @Test func failedPersistenceNeverPublishesTheEditedPlan() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let created = try await host.server.createMission(draft: .init(title: "Goal", goal: "Describe the outcome"))
        try await eventually("initial mission publication") { host.broadcasts.current.last?.missions == [created] }
        let bytes = try Data(contentsOf: host.stateURL)
        let broadcasts = host.broadcasts.current
        #expect(chmod(host.dir.path, 0o500) == 0)
        defer { _ = chmod(host.dir.path, 0o700) }
        await #expect(throws: SessionServerError.self) {
            try await host.server.editMission(id: created.id, expectedRevision: created.revision,
                                             draft: .init(title: "Must not land", goal: "Different outcome"))
        }
        #expect(host.server.state.missions == [created])
        #expect(try Data(contentsOf: host.stateURL) == bytes)
        #expect(host.broadcasts.current == broadcasts)
    }

    @Test func exhaustedRevisionsRefuseEditsButStillAllowDeletingThePlan() async throws {
        let dir = try makeScratchDirectory("mission")
        let mission = Mission(revision: UInt64.max - 1, draft: .init(title: "Retained", goal: "Inspect this plan"))
        let state = ShepherdState(missions: [mission])
        try JSONEncoder().encode(state).write(to: dir.appendingPathComponent("state.json"))
        let host = try ScratchServer(dir: dir)
        defer { host.stop() }
        await #expect(throws: MissionError.self) {
            try await host.server.editMission(id: mission.id, expectedRevision: mission.revision,
                                             draft: .init(title: "Changed", goal: "Cannot advance this revision"))
        }
        #expect(try host.persisted().missions == [mission])
        try await host.server.deleteMission(id: mission.id, expectedRevision: mission.revision)
        #expect(try host.persisted().missions.isEmpty)
    }

    @Test func fetchedAndBroadcastFleetSnapshotsDoNotExposeMissionDrafts() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let mission = try await remote.server.createMission(draft: .init(title: "Private brief", goal: "Unpublished planning context"))
        let client = try await remote.raw()
        try client.send(.stateFetch(id: 2))
        guard case .state(2, let fetched) = try await client.next() else { Issue.record("Expected fleet snapshot"); return }
        #expect(fetched.missions.isEmpty)
        try await remote.server.addSpace(Space(name: "Other mutation", path: remote.host.dir.path))
        guard case .stateChanged(let pushed) = try await client.next() else { Issue.record("Expected broadcast"); return }
        #expect(pushed.missions.isEmpty)
        #expect(try remote.host.persisted().missions == [mission])
    }
}
