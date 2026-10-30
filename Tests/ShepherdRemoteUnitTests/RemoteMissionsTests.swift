import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import Testing

@Suite("A host's missions on a client") @MainActor
struct RemoteMissionsTests {
    nonisolated static let space = SpaceID(rawValue: "00000000-0000-0000-0000-0000000000a1")

    nonisolated static func mission(_ revision: UInt64, phase: MissionRun.Phase = .map, agent: String = "agent-1",
                        id: MissionID = MissionID(rawValue: "00000000-0000-0000-0000-0000000000c1")) -> Mission {
        var run = MissionRun(model: "test/model", phase: phase)
        run.attempts = [MissionAttempt(agentID: AgentID(rawValue: agent), status: .succeeded)]
        return Mission(id: id, revision: revision, draft: MissionDraft(title: "Checkout", goal: "Ship",
                                                                      plan: MissionPlan(lanes: [MissionLane(spaceID: space, name: "checkout")])), run: run)
    }

    /// A fake host: answers from `records`, logging every request.
    final class Host {
        var records: [Mission]
        var requests: [RemoteMissionRequest] = []
        var gate: CheckedContinuation<Void, Never>?
        var holdsGets = false
        init(_ records: [Mission]) { self.records = records }

        @MainActor func transport(_ request: RemoteMissionRequest) async throws -> RemoteMissionResult {
            requests.append(request)
            switch request {
            case .list: return .list(records.map(RemoteMissionSummary.init))
            case .get(let id):
                // Read as the request arrives; a held answer is what the host had then.
                let mission = records.first(where: { $0.id == id })
                if holdsGets { await withCheckedContinuation { gate = $0 } }
                guard let mission else {
                    throw RemoteHostClientError.rejected(code: "mission_missing", message: "Mission no longer exists.")
                }
                return .mission(mission)
            case .action(let id, let revision, _):
                guard let index = records.firstIndex(where: { $0.id == id }), records[index].revision == revision else {
                    throw RemoteHostClientError.rejected(code: "stale_mission", message: "This mission changed on the host.")
                }
                records[index].revision += 1
                return .done(mission: records[index])
            default: throw RemoteHostClientError.rejected(code: "unsupported", message: "no")
            }
        }
    }

    @Test func listingReadsEachRecordAndNamesItsAgents() async {
        let host = Host([Self.mission(3)])
        let model = RemoteMissions(hostID: UUID())
        model.connect(host.transport, available: true)
        await model.refresh()
        #expect(model.available && model.records == host.records)
        #expect(model.agentIDs == [AgentID(rawValue: "agent-1")])
        // Unchanged revisions are not read again.
        await model.refresh()
        #expect(host.requests.filter { if case .get = $0 { true } else { false } }.count == 1)
    }

    @Test func aHintReadsTheNewRevisionOnceAndAGoneMissionLeavesWithItsAgents() async throws {
        let host = Host([Self.mission(3)])
        let model = RemoteMissions(hostID: UUID())
        model.connect(host.transport, available: true)
        await model.refresh()
        model.changed(host.records[0].id, revision: 3)
        #expect(host.requests.count == 2, "A hint at the revision held reads nothing")
        host.records[0] = Self.mission(4, phase: .running, agent: "agent-2")
        model.changed(host.records[0].id, revision: 4)
        try await waitUntil { model.records.first?.revision == 4 }
        #expect(model.agentIDs == [AgentID(rawValue: "agent-2")])
        model.changed(host.records[0].id, revision: nil)
        #expect(model.records.isEmpty && model.agentIDs.isEmpty)
    }

    @Test func hintsDuringAReadAreCoalescedIntoOneMoreRead() async throws {
        let host = Host([Self.mission(1)])
        let model = RemoteMissions(hostID: UUID())
        model.connect(host.transport, available: true)
        host.holdsGets = true
        let id = host.records[0].id
        model.changed(id, revision: 1)
        try await waitUntil { host.gate != nil }
        host.records[0].revision = 3
        model.changed(id, revision: 2)
        model.changed(id, revision: 3)
        host.holdsGets = false
        host.gate?.resume(); host.gate = nil
        try await waitUntil { model.records.first?.revision == 3 }
        #expect(host.requests.filter { if case .get = $0 { true } else { false } }.count == 2)
    }

    @Test func anActionCarriesTheShownRevisionAndAdoptsTheHostsAnswer() async throws {
        let host = Host([Self.mission(5)])
        let model = RemoteMissions(hostID: UUID())
        model.connect(host.transport, available: true)
        await model.refresh()
        try await model.perform(host.records[0].id, revision: 5, .launch)
        #expect(model.records.first?.revision == 6)
        await #expect(throws: RemoteHostClientError.self) { try await model.perform(host.records[0].id, revision: 5, .pause) }
        guard case .action(_, 5, .pause) = host.requests.last ?? .list else {
            Issue.record("the refused pause should still have named revision 5"); return
        }
    }

    @Test func aHostThatStopsOfferingMissionsClearsThemButKeepsItsAgentsHidden() async {
        let host = Host([Self.mission(2)])
        let model = RemoteMissions(hostID: UUID())
        model.connect(host.transport, available: true)
        await model.refresh()
        model.connect(nil, available: false)
        #expect(!model.available && model.records.count == 1, "Disconnected: the last read stays")
        model.connect(host.transport, available: false)
        #expect(model.records.isEmpty && model.agentIDs == [AgentID(rawValue: "agent-1")])
        await #expect(throws: RemoteHostClientError.self) { try await model.loadStartOptions() }
    }

    @Test func aHostsMissionAgentsLeaveItsThreadListWithTheirTabs() {
        let space = Space(name: "s", path: "/s")
        let worker = Agent(name: "Station", spaceID: space.id, tabID: TabID()), thread = Agent(name: "Ordinary", spaceID: space.id, tabID: TabID())
        let state = ShepherdState(spaces: [space], tabs: [Tab(id: worker.tabID, spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: "/s"))),
                                                           Tab(id: thread.tabID, spaceID: space.id, order: 1, layout: .leaf(LeafPane(cwd: "/s")))],
                                  agents: [worker, thread])
        let shown = state.withoutAgents([worker.id])
        #expect(shown.agents == [thread] && shown.tabs.map(\.id) == [thread.tabID])
        #expect(state.withoutAgents([]) == state)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() { await Task.yield() }
        #expect(condition())
    }
}

@Suite("A host's mission controls")
struct RemoteMissionControlsTests {
    typealias M = RemoteMissionsTests

    static func plannedMap(_ phase: MissionRun.Phase = .map) -> Mission {
        var mission = M.mission(2, phase: phase)
        mission.draft.plan?.stations = [MissionStation(kind: .worker, laneID: M.space, title: "Work", goal: "Do it")]
        return mission
    }

    @Test func aDraftedMapLaunchesAndARunningOnePausesOrStops() {
        #expect(RemoteMissionControls(Self.plannedMap()).primary == .launch)
        let running = RemoteMissionControls(Self.plannedMap(.running))
        #expect(running.primary == nil && running.pause && running.stop == "Stop mission")
    }

    @Test func aPendingQuestionBlocksLaunchAndNamesTheMessageItAnswers() {
        var mission = Self.plannedMap()
        let asked = MissionChatMessage(role: .assistant, text: "Which?", question: "Which branch?", choices: ["main", "release"])
        mission.run?.messages = [asked]
        mission.run?.pendingQuestion = "Which branch?"
        mission.run?.pendingChoices = ["main", "release"]
        let controls = RemoteMissionControls(mission)
        #expect(controls.primary == nil)
        #expect(controls.question == .init(text: "Which branch?", choices: ["main", "release"], replyTo: asked.id))
    }

    @Test func specKitConsentBindsToTheFingerprintAsReadAndOnlyTheLastContinuesPlanning() throws {
        var mission = Self.plannedMap()
        let other = SpaceID(rawValue: "00000000-0000-0000-0000-0000000000a2")
        mission.draft.plan?.lanes.append(MissionLane(spaceID: other, name: "analytics"))
        mission.run?.specKit = MissionSpecKitRun(lanes: [MissionSpecKitLane(spaceID: M.space), MissionSpecKitLane(spaceID: other, consentFingerprint: "old")])
        let ready = try JSONDecoder().decode(SpecKitPreflight.self, from: Data("""
        {"status":"ready","testedVersion":"1","matchesTestedRelease":true,"integrations":[],"missingCommands":[],"customizedFiles":[],
         "hooks":[],"ownershipConflicts":[],"warnings":[],"consentFingerprint":"new"}
        """.utf8))
        var unready = ready; unready.status = .notInitialized
        let controls = RemoteMissionControls(mission, reports: [M.space: ready, other: ready])
        #expect(controls.consents.map(\.fingerprint) == ["new", "new"])
        #expect(controls.consents.map(\.changed) == [false, true])
        #expect(controls.consents.allSatisfy { !$0.last }, "Neither grant alone leaves every repository allowed")
        #expect(controls.primary == nil, "Spec Kit waits for consent")
        let setUp = RemoteMissionControls(mission, reports: [M.space: unready])
        #expect(setUp.setUps.map(\.spaceID) == [M.space] && setUp.consents.isEmpty)
    }

    @Test func publishingNeedsTheReviewThatValidationSaw() {
        var mission = Self.plannedMap(.review)
        mission.run?.reviewFingerprint = "fp"
        mission.run?.checkouts = [MissionCheckout(spaceID: M.space, repo: "/r", path: "/wt", branch: "mission/a", base: "main", head: "h1", fingerprint: "c1")]
        let review = RemoteMissionReview(spaceID: M.space, name: "checkout", path: "/wt", branch: "mission/a", head: "h1", fingerprint: "c1", files: [])
        #expect(RemoteMissionControls.publishable(mission, reviews: [review]) == "fp")
        var moved = review; moved.fingerprint = "c2"
        #expect(RemoteMissionControls.publishable(mission, reviews: [moved]) == nil)
        #expect(RemoteMissionControls.publishable(mission, reviews: []) == nil)
        let controls = RemoteMissionControls(mission)
        #expect(controls.review && controls.changes && controls.revalidate)
    }
}
