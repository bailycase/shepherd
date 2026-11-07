import Foundation
import Testing
@testable import ShepherdCore

@Suite("Mission merge train")
struct MissionTrainTests {
    private let contracts = SpaceID(), analytics = SpaceID(), checkout = SpaceID()

    /// contracts' protos feed both services; the services share no wire.
    private func plan() -> MissionPlan {
        let schema = MissionStation(kind: .worker, laneID: contracts, title: "schema", goal: "protos")
        let ingest = MissionStation(kind: .worker, laneID: analytics, title: "analytics", goal: "consume")
        let emit = MissionStation(kind: .worker, laneID: checkout, title: "checkout", goal: "produce")
        return MissionPlan(lanes: [.init(spaceID: analytics, name: "analytics-ingest"), .init(spaceID: checkout, name: "checkout-svc"),
                                   .init(spaceID: contracts, name: "contracts")],
                           stations: [schema, ingest, emit],
                           dependencies: [.init(source: schema.id, target: ingest.id, kind: .data, artifact: "events v1.8.0"),
                                          .init(source: schema.id, target: emit.id, kind: .data, artifact: "events v1.8.0")])
    }

    @Test func theOrderPutsWhatOthersTakeFirstThenTheSmallerDiff() {
        let order = MissionTrainOrder(plan: plan(), sizes: [analytics: 430, checkout: 107, contracts: 40])
        #expect(order.lanes == [contracts, checkout, analytics])
        #expect(order.reasons.first?.title == "contracts first")
        #expect(order.reasons.first?.text.contains("events v1.8.0") == true)
        #expect(order.reasons.last?.lanes == [checkout, analytics])
        #expect(MissionTrainOrder.allows([contracts, analytics, checkout], plan: plan()))
        #expect(!MissionTrainOrder.allows([analytics, contracts, checkout], plan: plan()), "a consumer can't merge before what it takes")
    }

    @Test func stepsFollowTheRulesAndPausingPutsARunningStepBack() throws {
        #expect(MissionTrain.steps(.init(between: .mergeOnly)).map(\.kind) == [.update, .ci, .merge])
        #expect(MissionTrain.steps(.init(between: .stagingSoak)).map(\.kind) == [.update, .ci, .merge, .staging, .soak])
        var train = MissionTrain(order: [contracts, checkout], rules: .init(between: .soak), startedAt: 0)
        train.cars[0].steps[0].status = .done
        train.cars[0].steps[1].status = .running
        #expect(train.current == 0)
        train.pause("Paused.")
        #expect(train.status == .paused && train.cars[0].steps[1].status == .pending)
        for step in train.cars[0].steps.indices { train.cars[0].steps[step].status = .done }
        #expect(train.current == 1 && train.merged == 1)
        try train.validate()
    }

    @Test func theMergeWindowIsWeekdayWorkingHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let rules = MissionTrain.Rules(window: .weekdays)
        let tuesdayMorning = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: 10)))
        let tuesdayEvening = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: 17)))
        let saturday = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 10)))
        #expect(rules.open(at: tuesdayMorning, calendar: calendar))
        #expect(!rules.open(at: tuesdayEvening, calendar: calendar))
        #expect(!rules.open(at: saturday, calendar: calendar))
        #expect(MissionTrain.Rules().open(at: saturday, calendar: calendar))
    }
}
