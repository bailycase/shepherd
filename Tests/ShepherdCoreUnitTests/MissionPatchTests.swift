import Foundation
import Testing
@testable import ShepherdCore

@Suite("Mission patches")
struct MissionPatchTests {
    private let lane = SpaceID()

    private func base() -> (MissionDraft, decision: MissionStation, fog: MissionStation) {
        let decision = MissionStation(kind: .decision, title: "retention", goal: "30d or 13 mo?")
        let fog = MissionStation(kind: .research, laneID: lane, title: "storage", goal: "storage layout, partitions, rollups")
        let worker = MissionStation(kind: .worker, laneID: lane, title: "checkout", goal: "emit events")
        let validator = MissionStation(kind: .validator, title: "validator", goal: "verify")
        let draft = MissionDraft(title: "Funnel", goal: "Funnel events", requirements: ["joins"],
                                 plan: MissionPlan(lanes: [.init(spaceID: lane, name: "analytics")], stations: [decision, fog, worker, validator],
                                                   dependencies: [.init(source: decision.id, target: fog.id),
                                                                  .init(source: worker.id, target: validator.id, kind: .data, artifact: "branch")],
                                                   estimate: MissionEstimate(tokens: 4_100_000, seconds: 3 * 3600)))
        return (draft, decision, fog)
    }

    @Test func aPatchDiffsAgainstTheCurrentMapAndRefusesOnceTheMapMoves() throws {
        let (current, decision, fog) = base()
        var patched = current
        let analytics = MissionStation(kind: .worker, laneID: lane, title: "analytics", goal: "consumer, migration, monthly partitions")
        patched.plan!.stations.removeAll { $0.id == fog.id }
        patched.plan!.dependencies.removeAll { $0.target == fog.id }
        patched.plan!.stations.append(analytics)
        patched.plan!.dependencies.append(.init(source: decision.id, target: analytics.id))
        patched.plan!.estimate = MissionEstimate(tokens: 4_800_000, seconds: 3 * 3600 + 40 * 60)
        let patch = MissionPatch(proposedAt: 1, base: current, draft: patched, summary: "Monthly partitions.",
                                 question: "Raw events: 30 days or 13 months?", answer: "13 months", resolves: decision.id)
        try patch.validate()

        let diff = patch.diff(from: current)
        #expect(diff.added.map(\.title) == ["analytics"])
        #expect(diff.removed.map(\.title) == ["storage"])
        #expect(diff.changed.isEmpty)
        #expect(diff.addedWires.count == 1 && diff.removedWires.count == 1)
        #expect(patch.applies(to: current))
        #expect(patch.clearsFog)
        #expect(patched.plan!.estimate!.fits(patched.limits))

        var edited = current
        edited.title = "Funnel v2"
        #expect(!patch.applies(to: edited), "an edit after the proposal makes the patch stale")
    }

    @Test func settlingRecordsTheAnswerAsTheDecisionsReceiptAndClearsThePatch() throws {
        let (current, decision, _) = base()
        let patch = MissionPatch(proposedAt: 1, base: current, draft: current, summary: "", question: "q", answer: "13 months", resolves: decision.id)
        var run = MissionRun(model: "m")
        run.patch = patch
        run.settle(patch, at: 100)
        #expect(run.patch == nil)
        let receipt = try #require(run.latest(decision.id))
        #expect(receipt.status == .succeeded && receipt.output == "13 months")
        #expect(run.decisions == [MissionDecisionRecord(station: "retention", answer: "13 months", at: 100)])
        try run.validate()
    }

    @Test func oldRecordsWithoutPatchFieldsStillDecode() throws {
        let json = #"{"id":"\#(UUID().uuidString)","model":"m","phase":"map","messages":[],"checkouts":[],"attempts":[],"elapsedSeconds":0}"#
        let run = try JSONDecoder().decode(MissionRun.self, from: Data(json.utf8))
        #expect(run.patch == nil && run.autoApplyPatches == nil && run.decisions == nil)
    }
}
