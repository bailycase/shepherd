import Foundation
import Testing
@testable import ShepherdCore

@Suite("Mission templates")
struct MissionTemplateTests {
    @Test func aFinishedMissionBecomesATemplateOfTheRouteItTookAndWhatItLearned() throws {
        let lane = SpaceID()
        let key = MissionStation(kind: .decision, title: "join key", goal: "order_id or payment_id?")
        let worker = MissionStation(kind: .worker, laneID: lane, title: "consumer", goal: "Land events")
        let check = MissionStation(kind: .check, laneID: lane, title: "go test", goal: "tests", command: "go test ./...")
        let registry = MissionStation(kind: .research, title: "registry", goal: "Buf registry route")
        let validator = MissionStation(kind: .validator, title: "validator", goal: "verify")
        var run = MissionRun(model: "m", phase: .done, elapsedSeconds: 9_600)
        run.attempts = [MissionAttempt(stationID: key.id, status: .succeeded, output: "checkout_id"),
                        MissionAttempt(stationID: worker.id, status: .succeeded, tokens: 400_000),
                        MissionAttempt(stationID: check.id, status: .failed), MissionAttempt(stationID: check.id, status: .succeeded),
                        MissionAttempt(stationID: validator.id, status: .succeeded)]
        let mission = Mission(draft: MissionDraft(title: "Checkout funnel events", goal: "Funnel events", requirements: ["Every events.last joins events.first"],
                                                  plan: MissionPlan(lanes: [.init(spaceID: lane, name: "analytics-ingest", baseBranch: "refs/heads/main")],
                                                                    stations: [key, worker, check, registry, validator],
                                                                    dependencies: [.init(source: registry.id, target: worker.id),
                                                                                   .init(source: worker.id, target: check.id, kind: .data, artifact: "consumer"),
                                                                                   .init(source: check.id, target: validator.id, kind: .data, artifact: "tested")])),
                              run: run)
        let template = MissionTemplate.from(mission, name: "Add an event across services", summary: "Events land in a consumer's table.", at: 5)
        try template.validate()
        #expect(template.id == "add-an-event-across-services")
        #expect(!template.plan.stations.contains { $0.id == registry.id }, "a route never taken is dropped")
        #expect(template.plan.lanes.first?.baseBranch == nil)
        #expect(template.inputs.map(\.name) == ["goal", "analytics-ingest", "join key"])
        #expect(template.inputs.last?.filledBy == .you && template.inputs.last?.example == "checkout_id")
        #expect(template.learned.map(\.text) == ["Ask for join key before drafting", "go test needed a retry; keep retry ≤2"])
        #expect(template.runs == 1 && template.seconds == 9_600 && template.tokens == 400_000)
        let changes = template.changes(from: mission)
        #expect(changes.first?.name == "join key" && changes.first?.learned == true)
        #expect(changes.last?.name == "registry" && changes.last?.sign == "−")
        #expect(try JSONDecoder().decode(MissionTemplate.self, from: template.encoded) == template)
    }
}
