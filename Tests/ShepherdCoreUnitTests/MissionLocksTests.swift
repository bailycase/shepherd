import Foundation
import Testing
@testable import ShepherdCore

@Suite("Mission path locks")
struct MissionLocksTests {
    @Test func pathsAndGlobsOverlapOnlyWhereTheyCanNameTheSameFile() {
        #expect(MissionPaths.overlaps("internal/orders/place.go", "internal/orders/**"))
        #expect(MissionPaths.overlaps("internal/orders/**", "internal/**"))
        #expect(MissionPaths.overlaps("migrations/*.sql", "migrations/0042_outbox.sql"))
        #expect(!MissionPaths.overlaps("migrations/*.sql", "migrations/old/0001.sql"), "a single star stays in its folder")
        #expect(!MissionPaths.overlaps("events/v1/order.proto", "events/v1/payment.proto"))
        #expect(!MissionPaths.overlaps("internal/charge/**", "internal/orders/**"))
        #expect(MissionPaths.overlap(["internal/orders/place.go", "migrations/**"], ["internal/orders/**", "internal/outbox/**"]) == ["internal/orders/place.go"])
        #expect(MissionPaths.covers(["internal/orders/**", "go.mod"], "internal/orders/place.go"))
        #expect(MissionPaths.covers(["internal/orders"], "internal/orders/place.go"))
        #expect(!MissionPaths.covers(["internal/orders/**"], "internal/outbox/write.go"))
    }

    @Test func aLaunchedMissionHoldsItsPathsAndAWaitingOneQueuesBehindIt() {
        let orders = SpaceID()
        func mission(_ title: String, paths: [String], phase: MissionRun.Phase, approved: Bool) -> Mission {
            let worker = MissionStation(kind: .worker, laneID: orders, title: title, goal: title, paths: paths)
            return Mission(draft: MissionDraft(title: title, goal: title, plan: MissionPlan(lanes: [.init(spaceID: orders, name: "orders-svc")], stations: [worker])),
                           approvedPlanRevision: approved ? 1 : nil, run: MissionRun(model: "m", phase: phase))
        }
        let funnel = mission("Checkout funnel events", paths: ["internal/orders/**", "internal/outbox/**"], phase: .running, approved: true)
        var idempotent = mission("Idempotent order placement", paths: ["internal/orders/place.go"], phase: .running, approved: true)
        let refunds = mission("Refund events", paths: ["internal/orders/place.go"], phase: .map, approved: false)
        let all = [funnel, idempotent, refunds]

        #expect(all.holders(of: orders, for: idempotent).map(\.mission.id) == [funnel.id])
        idempotent.run?.held = [orders: MissionLaneLock(holder: funnel.id, holderTitle: funnel.draft.title, overlap: ["internal/orders/place.go"], since: 10)]
        #expect(idempotent.holds(orders).isEmpty, "a mission never holds what it waits for")
        #expect([funnel, idempotent, refunds].holders(of: orders, for: funnel).isEmpty)
        let queue = [funnel, idempotent, refunds].queue(orders, paths: ["internal/orders/place.go"])
        #expect(queue.map(\.mission.id) == [funnel.id, idempotent.id, refunds.id])

        idempotent.run?.held?[orders]?.choice = .runAnyway
        #expect(idempotent.run?.held?[orders]?.blocks == false)
        var done = funnel
        done.run?.phase = .done
        #expect(done.holds(orders).isEmpty, "published without a train frees its paths")
    }
}
