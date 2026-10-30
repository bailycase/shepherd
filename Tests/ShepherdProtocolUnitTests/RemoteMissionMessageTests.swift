import Foundation
import Testing
import ShepherdCore
@testable import ShepherdProtocol

enum RemoteMissionSamples {
    static let space = SpaceID(rawValue: "00000000-0000-0000-0000-0000000000a1")
    static let attempt = UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!
    static let mission: Mission = {
        var run = MissionRun(model: "test/model", phase: .review, messages: [.init(role: .user, text: "Ship it")], reviewFingerprint: "f00d")
        run.attempts = [MissionAttempt(id: attempt, agentID: AgentID(rawValue: "agent-1"), status: .succeeded)]
        run.specKit = MissionSpecKitRun(lanes: [MissionSpecKitLane(spaceID: space, plannerAgentID: AgentID(rawValue: "planner-1"))])
        return Mission(id: MissionID(rawValue: "00000000-0000-0000-0000-0000000000c1"), revision: 4,
                       draft: MissionDraft(title: "Checkout events", goal: "Every order joins a checkout",
                                           plan: MissionPlan(lanes: [MissionLane(spaceID: space, name: "checkout", baseBranch: "refs/heads/main")])),
                       run: run)
    }()
    static let file = DiffFile(oldPath: "a.txt", newPath: "a.txt", displayPath: "a.txt", isNew: false, isDeleted: false, isRenamed: false,
                               isBinary: false, hunks: [DiffHunk(header: "@@ -1 +1 @@", lines: [
                                   DiffLine(kind: .removed, text: "before", oldLine: 1, newLine: nil, id: 0),
                                   DiffLine(kind: .added, text: "after", oldLine: nil, newLine: 1, id: 1)])])
    static let actions: [RemoteMissionAction] = [
        .plan(feedback: "Split the worker"), .answer(text: "Yes", choice: "Yes", replyTo: attempt),
        .answer(text: "No", choice: nil, replyTo: nil),
        .specKitConsent(spaceID: space, fingerprint: "abc", continuePlanning: true), .specKitSetUp(spaceID: space),
        .acceptConvergence(attemptID: attempt), .save(draft: mission.draft), .launch, .pause, .stop, .changes(text: "Rename it"),
        .publish(fingerprint: "f00d"), .revalidate, .runAgain, .steer(attemptID: attempt, text: "Use the new API"),
    ]
    static let requests: [RemoteMissionRequest] = [
        .list, .get(missionID: mission.id), .startOptions,
        .create(goal: "Ship", spaceIDs: [space], model: "test/model", branches: [space: "refs/heads/main"]),
        .review(missionID: mission.id), .reviewFile(missionID: mission.id, spaceID: space, path: "a.txt"), .specKit(missionID: mission.id),
    ] + actions.map { .action(missionID: mission.id, revision: 4, action: $0) }
    static let results: [RemoteMissionResult] = [
        .list([RemoteMissionSummary(mission)]), .mission(mission),
        .mission(mission, live: RemoteMissionLive(output: "Planning", attempts: [attempt: "Editing result.txt"])),
        .startOptions(RemoteMissionStartOptions(models: ["test/model"], defaultModel: "test/model",
                                                spaces: [Space(id: space, name: "checkout", path: "/repo")],
                                                branchChoices: [space: ["refs/heads/main"]], defaultBranches: [space: "refs/heads/main"])),
        .created(missionID: mission.id), .done(mission: mission), .done(mission: nil),
        .review([RemoteMissionReview(spaceID: space, name: "checkout", path: "/wt", branch: "mission/a", head: "abc", fingerprint: "fp",
                                     files: [RemoteMissionReviewFile(file)])]),
        .reviewFile(file), .specKit(RemoteMissionSpecKit(settingUp: true)),
    ]
}

@Suite("Remote mission messages")
struct RemoteMissionMessageTests {
    @Test(arguments: RemoteMissionSamples.requests)
    func everyRequestRoundTrips(_ request: RemoteMissionRequest) throws {
        #expect(try Wire.roundTrip(RemoteRequest.mission(id: 3, request: request)) == .mission(id: 3, request: request))
    }

    @Test(arguments: RemoteMissionSamples.results)
    func everyResultRoundTrips(_ result: RemoteMissionResult) throws {
        #expect(try Wire.roundTrip(RemoteReply.mission(id: 3, result: result)) == .mission(id: 3, result: result))
    }

    @Test func aRemovedMissionsHintCarriesNoRevision() throws {
        let reply = RemoteReply.missionChanged(missionID: RemoteMissionSamples.mission.id, revision: nil)
        #expect(try Wire.roundTrip(reply) == reply)
        #expect(try Wire.object(reply)["revision"] == nil)
    }

    @Test func aSummaryNamesEveryAgentTheMissionOwnsOnce() {
        let summary = RemoteMissionSummary(RemoteMissionSamples.mission)
        #expect(summary.agentIDs == [AgentID(rawValue: "agent-1"), AgentID(rawValue: "planner-1")])
        #expect(summary.revision == 4 && summary.phase == .review)
    }

    @Test func liveWordsAreBoundedPerTextAndAttempt() {
        let long = String(repeating: "é", count: RemoteMissionLive.textBytes)
        let attempts = Dictionary(uniqueKeysWithValues: (0..<40).map { _ in (UUID(), long) })
        let live = RemoteMissionLive(output: long, attempts: attempts.merging([UUID(): ""]) { first, _ in first })
        #expect(live.output.utf8.count <= RemoteMissionLive.textBytes && live.output.hasPrefix("é"))
        #expect(live.attempts.count == RemoteMissionLive.maximumAttempts)
        #expect(live.attempts.values.allSatisfy { !$0.isEmpty && $0.utf8.count <= RemoteMissionLive.textBytes })
        #expect(RemoteMissionLive().isEmpty && !live.isEmpty)
    }

    @Test func aReviewFileCarriesNoHunks() throws {
        let file = RemoteMissionReviewFile(RemoteMissionSamples.file)
        #expect(file.added == 1 && file.removed == 1 && file.path == "a.txt")
        #expect(try Wire.object(file)["hunks"] == nil)
    }

    @Test func bothSidesListMissionsAndOnlyASteerWaitsForTheAgent() {
        #expect(RemoteProtocol.capabilities.contains(RemoteProtocol.missionsCapability))
        #expect(RemoteProtocol.clientCapabilities.contains(RemoteProtocol.missionsCapability))
        #expect(RemoteMissionRequest.action(missionID: RemoteMissionSamples.mission.id, revision: 1,
                                            action: .steer(attemptID: RemoteMissionSamples.attempt, text: "x")).timeout > 300)
        #expect(RemoteMissionRequest.list.timeout <= 10)
    }
}
