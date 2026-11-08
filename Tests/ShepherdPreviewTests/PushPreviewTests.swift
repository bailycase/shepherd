import Foundation
import ShepherdCore
import ShepherdUI
import SwiftUI
import Testing

/// A push opened with a long press (NotifPhoneRich, NotifPhoneReview), from what the host sends:
/// `PushDetail` built from a mission, through JSON, decoded the way the extension decodes it.
/// The notification's platter and the buttons under it are the system's: `card` stands in for the platter.
@Suite("Push previews", .serialized, .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR to render previews"))
@MainActor
struct PushPreviewTests {
    static func wire(_ detail: PushDetail?) throws -> SHPushDetail? {
        try detail.map { try JSONDecoder().decode(SHPushDetail.self, from: JSONEncoder().encode($0)) }
    }

    /// Four lanes: done, testing, waiting at the join, and one stuck after three tries.
    static func stuck() -> Mission {
        let lanes = ["contracts", "analytics", "checkout", "orders"].map { MissionLane(spaceID: SpaceID(), name: $0) }
        var stations: [MissionStation] = [], attempts: [MissionAttempt] = []
        for (index, lane) in lanes.enumerated() {
            for step in ["write", "build", index == 1 ? "go test" : "test"] {
                let station = MissionStation(kind: .worker, laneID: lane.spaceID, title: step, goal: step)
                stations.append(station)
                let status: MissionAttempt.Status = step != "go test" && step != "test" ? .succeeded : [.succeeded, .running, .superseded, .failed][index]
                if status != .failed { attempts.append(MissionAttempt(stationID: station.id, status: status, planRevision: 1)) }
            }
        }
        attempts += ["Wrote OrderPlaced after InsertOrder", "Wrapped the test in a savepoint · same failure",
                     "Reset the outbox · same failure"].map {
            MissionAttempt(stationID: stations.last!.id, status: .failed, output: $0, planRevision: 1)
        }
        var run = MissionRun(model: "test/model", phase: .paused)
        run.attempts = attempts
        run.notice = "The outbox opens its own connection, so the event survives a rollback."
        return Mission(draft: MissionDraft(title: "Checkout funnel events", goal: "Every order joins the funnel",
                                           plan: MissionPlan(lanes: lanes, stations: stations)), approvedPlanRevision: 1, run: run)
    }

    static func review() -> Mission {
        let names: [(String, Int, Int, Int)] = [("contracts", 412, 38, 2), ("analytics-ingest", 97, 412, 18),
                                                ("checkout-svc", 231, 96, 11), ("orders-svc", 318, 171, 9)]
        let lanes = names.map { MissionLane(spaceID: SpaceID(), name: $0.0) }
        var run = MissionRun(model: "test/model", phase: .review)
        run.checkouts = zip(lanes, names).map { lane, value in
            var checkout = MissionCheckout(spaceID: lane.spaceID, repo: "/src/\(value.0)", path: "/w", branch: "mission", base: "main",
                                           head: "a", prURL: "https://github.com/acme/\(value.0)/pull/\(value.1)")
            checkout.added = value.2; checkout.removed = value.3
            return checkout
        }
        let checks = (1...10).map { MissionStation(kind: .check, laneID: lanes[0].spaceID, title: "check \($0)", goal: "passes") }
        run.attempts = checks.map { MissionAttempt(stationID: $0.id, status: .succeeded) }
        return Mission(draft: MissionDraft(title: "Checkout funnel events", goal: "g", plan: MissionPlan(lanes: lanes, stations: checks)), run: run)
    }

    func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(width: 370)
            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @Test func richAndReview() async throws {
        let now = Date()
        let rich = try Self.wire(PushDetail.blocked(Self.stuck()))
        let review = try Self.wire(PushDetail.review(Self.review()))
        try await Preview.render("push-preview", size: CGSize(width: 1200, height: 560)) {
            HStack(alignment: .top, spacing: SH.Space.xxl) {
                card { SHPushPreview(title: "Checkout funnel events", subtitle: "Blocked", body: nil, date: now, detail: rich) }
                card { SHPushPreview(title: "Checkout funnel events", subtitle: "Ready to review",
                                     body: "4 pull requests merge in this order.", date: now, detail: review) }
                card { SHPushPreview(title: "Refunds in the ledger", subtitle: "Planner question",
                                     body: "Which key joins a refund to the funnel?", date: now,
                                     detail: try? Self.wire(PushDetail.question(options: ["checkout_id", "order_id"]))) }
            }
            .padding(SH.Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.sh.bgBase)
        }
        #expect(rich?.stuck?.tries.count == 3)
        #expect(review?.repos?.first == .init(name: "contracts", pr: 412, added: 38, removed: 2))
    }
}
