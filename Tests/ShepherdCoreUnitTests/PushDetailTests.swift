import Foundation
import Testing
@testable import ShepherdCore

@Suite("Push detail")
struct PushDetailTests {
    /// Four lanes of three stations: done, one testing, one waiting at the join, one stuck (NotifPhoneRich).
    static func stuckMission() -> Mission {
        let names = ["contracts", "analytics", "checkout", "orders"]
        let lanes = names.map { MissionLane(spaceID: SpaceID(), name: $0) }
        var stations: [MissionStation] = [], attempts: [MissionAttempt] = []
        for (index, lane) in lanes.enumerated() {
            for step in ["write", "build", index == 1 ? "go test" : "test"] {
                let station = MissionStation(kind: .worker, laneID: lane.spaceID, title: step, goal: step)
                stations.append(station)
                let last = step != "write" && step != "build"
                let status: MissionAttempt.Status = !last ? .succeeded : [.succeeded, .running, .superseded, .failed][index]
                attempts.append(MissionAttempt(stationID: station.id, status: status, output: "ok", planRevision: 3))
            }
        }
        // The stuck station's earlier tries, oldest first, and one from an older plan.
        let stuck = stations.last!.id
        attempts.removeLast()
        attempts += ["Old plan", "Wrote OrderPlaced after InsertOrder\nmore", "Wrapped the test in a savepoint · same failure",
                     "Reset the outbox · same failure"].enumerated().map { index, output in
            MissionAttempt(stationID: stuck, status: .failed, output: output, planRevision: index == 0 ? 2 : 3)
        }
        var run = MissionRun(model: "test/model", phase: .paused)
        run.attempts = attempts
        run.notice = "test reached its attempt limit.\nThe outbox opens its own connection."
        return Mission(draft: MissionDraft(title: "Checkout funnel events", goal: "Every order joins the funnel",
                                           plan: MissionPlan(lanes: lanes, stations: stations)),
                       approvedPlanRevision: 3, run: run)
    }

    @Test func aBlockedMissionShowsEachLaneTheStuckLanesLastTriesAndTheNotice() throws {
        let detail = try #require(PushDetail.blocked(Self.stuckMission()))
        #expect(detail.lanes == [
            .init(name: "contracts", states: [.done, .done, .done], status: "done"),
            .init(name: "analytics", states: [.done, .done, .running], status: "go test"),
            .init(name: "checkout", states: [.done, .done, .waiting], status: "waiting"),
            .init(name: "orders", states: [.done, .done, .failed], status: "stuck"),
        ])
        #expect(detail.stuck == .init(lane: "orders", count: 3, tries: [
            "Wrote OrderPlaced after InsertOrder", "Wrapped the test in a savepoint · same failure", "Reset the outbox · same failure"]))
        #expect(detail.read == "test reached its attempt limit. The outbox opens its own connection.")
    }

    @Test func aReviewListsReposInLaneOrderWithChangesAndTheChecksTally() throws {
        let contracts = SpaceID(), orders = SpaceID()
        let check = MissionStation(kind: .check, laneID: orders, title: "go test", goal: "tests pass")
        let validator = MissionStation(kind: .validator, title: "Validate", goal: "joins hold")
        var run = MissionRun(model: "test/model", phase: .review)
        var second = MissionCheckout(spaceID: contracts, repo: "/src/contracts", path: "/w/c", branch: "m", base: "main", head: "a",
                                     prURL: "https://github.com/acme/contracts/pull/412")
        second.added = 38; second.removed = 2
        run.checkouts = [MissionCheckout(spaceID: orders, repo: "/src/orders-svc", path: "/w/o", branch: "m", base: "main", head: "b"), second]
        run.attempts = [MissionAttempt(stationID: check.id, status: .succeeded), MissionAttempt(stationID: validator.id, status: .failed)]
        let mission = Mission(draft: MissionDraft(title: "Checkout funnel events", goal: "g", plan: MissionPlan(
            lanes: [.init(spaceID: contracts, name: "contracts"), .init(spaceID: orders, name: "orders")], stations: [check, validator])), run: run)
        let detail = try #require(PushDetail.review(mission))
        #expect(detail.repos == [.init(name: "contracts", pr: 412, added: 38, removed: 2), .init(name: "orders-svc")])
        #expect(detail.contract == .init(passed: 1, total: 2))
    }

    @Test func optionsAreButtonsOnlyWhenEveryOneFitsWholeAndRedactionKeepsBounds() {
        #expect(PushDetail.question(options: ["Use checkout_id", "Use order_id"])?.options == ["Use checkout_id", "Use order_id"])
        #expect(PushDetail.question(options: []) == nil)
        #expect(PushDetail.question(options: ["a", "b", "c", "d", "e"]) == nil)
        #expect(PushDetail.question(options: ["ok", String(repeating: "x", count: 41)]) == nil)
        // The relay counts code points: a family emoji is one Character but seven scalars.
        #expect(PushDetail.clip(String(repeating: "👨‍👩‍👧‍👦", count: 10), 12).unicodeScalars.count == 12)
        let redacted = PushDetail(read: "secret", options: ["secret"]).mapText { $0 == "secret" ? "[redacted]" : $0 }
        #expect(redacted.read == "[redacted]")
        #expect(redacted.options == nil, "a changed option would answer something else")
    }
}
