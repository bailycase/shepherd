import Foundation
import Testing
@testable import ShepherdCore

@Suite("Mission plans")
struct MissionTests {
    private func draft() -> MissionDraft {
        let contracts = SpaceID(), service = SpaceID()
        let schema = MissionStation(kind: .worker, laneID: contracts, title: "Schema", goal: "Add checkout_id")
        let consumer = MissionStation(kind: .worker, laneID: service, title: "Consumer", goal: "Join events by checkout_id")
        let docs = MissionStation(kind: .research, title: "Docs", goal: "Read the existing deployment guide")
        let validator = MissionStation(kind: .validator, title: "Validate", goal: "Verify event joins independently")
        return MissionDraft(title: "Checkout events", goal: "Every order joins its checkout",
                            requirements: ["No unmatched orders after replay"], context: ["ANL-214"],
                            plan: MissionPlan(lanes: [.init(spaceID: contracts, name: "contracts"), .init(spaceID: service, name: "analytics")],
                                              stations: [schema, consumer, docs, validator], dependencies: [
                                                .init(source: schema.id, target: consumer.id, kind: .data, artifact: "events module"),
                                                .init(source: schema.id, target: docs.id),
                                                .init(source: consumer.id, target: validator.id, kind: .data, artifact: "consumer branch"),
                                                .init(source: docs.id, target: validator.id)
                                              ]))
    }

    @Test func dependenciesOrderWorkAndOnlyDataWiresIdentifyAffectedConsumers() throws {
        let value = draft(), plan = try #require(value.plan)
        let ids = plan.stations.map(\.id)
        try value.validateForApproval()
        #expect(try plan.orderedStations() == ids)
        #expect(try plan.dataConsumers(of: [ids[0]]) == [ids[1], ids[3]])
        #expect(try plan.dataConsumers(of: [ids[2]]) == [])
        #expect(throws: MissionError.self) { try plan.dataConsumers(of: [MissionStationID()]) }
    }

    @Test func mapEditsKeepTheGraphValidAndRewireAroundABypassedStation() throws {
        let plan = try #require(draft().plan)
        let ids = plan.stations.map(\.id)
        let removed = plan.removing(ids[1])
        #expect(removed.stations.map(\.id) == [ids[0], ids[2], ids[3]])
        #expect(!removed.dependencies.contains { $0.source == ids[1] || $0.target == ids[1] })
        let bypassed = plan.bypassing(ids[1])
        try bypassed.validate()
        // schema → consumer (data) and consumer → validator (data) become one data wire, named for the delivered output.
        #expect(bypassed.dependencies.contains(.init(source: ids[0], target: ids[3], kind: .data, artifact: "consumer branch")))
        let flow = plan.bypassing(ids[2])
        #expect(flow.dependencies.contains(.init(source: ids[0], target: ids[3])))
        let lane = plan.lanes[0].spaceID, copyID = MissionStationID()
        let duplicated = plan.duplicating(ids[1], to: lane, as: copyID)
        try duplicated.validate()
        #expect(duplicated.stations.map(\.id) == [ids[0], ids[1], copyID, ids[2], ids[3]])
        #expect(duplicated.stations[2].laneID == lane)
        #expect(duplicated.dependencies.filter { $0.source == copyID || $0.target == copyID }.count == 2)
    }

    @Test(arguments: ["cycle", "dangling", "duplicate", "missing lane", "unnamed output", "command on worker"])
    func invalidMapsCannotBeApproved(_ fault: String) throws {
        var value = draft(), plan = try #require(value.plan)
        let ids = plan.stations.map(\.id)
        switch fault {
        case "cycle": plan.dependencies.append(.init(source: ids[3], target: ids[0]))
        case "dangling": plan.dependencies.append(.init(source: MissionStationID(), target: ids[0]))
        case "duplicate": plan.stations.append(plan.stations[0])
        case "missing lane": plan.stations[0].laneID = SpaceID()
        case "unnamed output": plan.dependencies[0].artifact = nil
        case "command on worker": plan.stations[0].command = "git push"
        default: Issue.record("Unknown fixture")
        }
        value.plan = plan
        #expect(throws: MissionError.self) { try value.validateForApproval() }
    }

    @Test func everyWorkerNeedsADataPathToIndependentValidation() throws {
        var value = draft()
        value.plan?.dependencies.removeFirst()
        #expect(throws: MissionError.self) { try value.validateForApproval() }
        value = draft()
        value.plan?.stations[3].kind = .research
        #expect(throws: MissionError.self) { try value.validateForApproval() }
        value = draft()
        value.requirements = []
        #expect(throws: MissionError.self) { try value.validateForApproval() }
    }

    @Test func limitsAndPlanningCapacityAreBounded() throws {
        let limits = MissionLimits()
        #expect(limits.tokens == 6_000_000 && limits.seconds == 14_400)
        #expect(limits.concurrentStations == 3 && limits.retries == 2)
        for invalid in [MissionLimits(tokens: 0), MissionLimits(seconds: .infinity), MissionLimits(seconds: 0),
                        MissionLimits(concurrentStations: 0), MissionLimits(concurrentStations: 17), MissionLimits(retries: -1), MissionLimits(retries: 11), MissionLimits(dollars: 0), MissionLimits(dollars: .infinity)] {
            #expect(throws: MissionError.self) { try invalid.validate() }
        }
        var plan = MissionPlan(stations: (0..<128).map { _ in .init(kind: .research, title: "Read", goal: "Read code") })
        #expect(try plan.orderedStations().count == 128)
        plan.stations.append(.init(kind: .research, title: "Extra", goal: "Read more code"))
        #expect(throws: MissionError.self) { try plan.validate() }
        var large = draft()
        large.context = Array(repeating: String(repeating: "x", count: 4_000), count: 32)
        #expect(throws: MissionError.self) { try Mission(draft: large).validate() }
        let many = (0..<33).map { _ in Mission(draft: .init(title: "Plan", goal: "Outcome")) }
        #expect(throws: MissionError.self) { try ShepherdState(missions: many).validate() }
        let largeCollection = (0..<32).map { _ in Mission(draft: .init(title: "Plan", goal: String(repeating: "x", count: 9_000), context: Array(repeating: String(repeating: "x", count: 4_000), count: 8))) }
        #expect(throws: MissionError.self) { try ShepherdState(missions: largeCollection).validate() }
    }

    @Test func planApprovalSurvivesReceiptRevisionsButCannotComeFromTheFuture() throws {
        var mission = Mission(revision: 4, draft: draft(), approvedPlanRevision: 4)
        try mission.validate()
        let data = try JSONEncoder().encode(mission)
        #expect(try JSONDecoder().decode(Mission.self, from: data) == mission)
        mission.revision += 1
        try mission.validate()
        mission.approvedPlanRevision = mission.revision + 1
        #expect(throws: MissionError.self) { try mission.validate() }
        mission.approvedPlanRevision = nil
        try mission.validate()
    }

    @Test func runtimeHitsEachDefaultBoundAndPausingStopsItsClock() throws {
        let limits = MissionLimits()
        var run = MissionRun(model: "test/model", phase: .running, activeSince: 100)
        #expect(run.exhausted(limits, at: 101) == nil)
        run.attempts = [.init(tokens: limits.tokens)]
        #expect(run.exhausted(limits, at: 101)?.contains("Token limit") == true)
        run.attempts = [.init(cost: limits.dollars)]
        #expect(run.exhausted(limits, at: 101)?.contains("Spending limit") == true)
        run.attempts = []
        #expect(run.exhausted(limits, at: 100 + limits.seconds)?.contains("Time limit") == true)
        run.transition(to: .paused, at: 110)
        #expect(run.elapsed(at: 1_000_000) == 10 && run.activeSince == nil)
        let legacy = Data(#"{"tokens":6000000,"seconds":14400,"concurrentStations":3,"retries":2}"#.utf8)
        #expect(try JSONDecoder().decode(MissionLimits.self, from: legacy).dollars == limits.dollars)
        #expect(try JSONDecoder().decode(MissionRun.self, from: JSONEncoder().encode(run)) == run)
    }

    @Test func legacyWorkspacesDecodeAndLocalPlansStayOutOfRemoteProjection() throws {
        let old = Data(#"{"spaces":[],"tabs":[],"agents":[]}"#.utf8)
        #expect(try JSONDecoder().decode(ShepherdState.self, from: old).missions.isEmpty)
        let state = ShepherdState(missions: [Mission(draft: draft())])
        try state.validate() // Lane references remain inspectable after a Space is removed.
        let data = try JSONEncoder().encode(state.persisted)
        #expect(try JSONDecoder().decode(ShepherdState.self, from: data).missions == state.missions)
        #expect(state.withoutMissions.missions.isEmpty)
        #expect(state.missions.count == 1)
        var duplicate = state
        duplicate.missions += state.missions
        #expect(throws: ShepherdStateValidationError.self) { try duplicate.validate() }
    }
}
