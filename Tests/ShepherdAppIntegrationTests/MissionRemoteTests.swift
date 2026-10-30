import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A paired device drives the host's own `MissionController` over the listener (`missions.v1`):
/// create, answer, launch, review and publish, each against the revision and fingerprint it showed.
@Suite("Mission over the remote protocol", .mainActorExclusive)
@MainActor
struct MissionRemoteTests {
    // Executable replacement is process-wide, so the scenario runs in its own isolated child.
    @Test func aPairedDeviceDrivesAMissionToPublishedPRsWithTheHostsGuards() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.remoteScenario() }
        }
        expectScenarioCompleted(result)
    }

    static func remoteScenario() async throws {
        let fixture = try MissionRuntimeFixture(); defer { fixture.stop() }
        try await fixture.start()
        let tokenURL = fixture.root.appendingPathComponent("remote-token")
        let port = try fixture.app.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "phone")
        defer { client.disconnect() }
        try await eventuallyOnMain("the host offers missions") { client.capabilities.contains(RemoteProtocol.missionsCapability) }
        let missions = RemoteMissions(hostID: UUID())
        missions.connect({ try await client.mission($0) }, available: true)
        client.onMissionChanged = { id, revision in MainActor.assumeIsolated { missions.changed(id, revision: revision) } }

        try await missions.loadStartOptions()
        let options = try #require(missions.startOptions)
        #expect(options.models == [MissionRuntimeFixture.model])
        #expect(Set(options.spaces.map(\.id)) == Set(fixture.spaces.map(\.id)))
        let branches = Dictionary(uniqueKeysWithValues: fixture.spaces.map { ($0.id, "refs/heads/main") })
        let id = try await missions.create(goal: "Change result.txt to after in both repositories and verify it independently.",
                                           spaces: fixture.spaces.map(\.id), model: MissionRuntimeFixture.model, branches: branches)
        #expect(fixture.controller.selectedID == nil, "A device's New mission leaves the host's page as it was")
        try await fixture.wait(id, phase: .map)
        try await eventuallyOnMain("the hint brings the drafted map") { missions.record(id)?.revision == (try? fixture.controller.record(id).revision) }

        // The owner answers the planner from the device; the host plans again from its own record.
        let drafted = try #require(missions.record(id))
        try await missions.perform(id, revision: drafted.revision, .answer(text: "Keep the change to result.txt only.", choice: nil, replyTo: nil))
        try await fixture.wait(id, phase: .map)
        #expect(try fixture.controller.record(id).run?.messages.contains { $0.role == .user && $0.text == "Keep the change to result.txt only." } == true)
        try await eventuallyOnMain("the device sees the new map") { missions.record(id)?.revision == (try? fixture.controller.record(id).revision) }

        // A stale revision is refused before anything runs.
        let shown = try #require(missions.record(id))
        await expectRefusal("stale_mission") { try await missions.perform(id, revision: shown.revision - 1, .launch) }
        #expect(try fixture.controller.record(id).approvedPlanRevision == nil)

        try await missions.perform(id, revision: shown.revision, .launch)
        try await fixture.wait(id, phase: .review)
        try await eventuallyOnMain("the device sees review") { missions.record(id)?.run?.phase == .review }
        let reviewed = try #require(missions.record(id))
        try await missions.loadReview(id)
        let repositories = try #require(missions.reviews[id])
        #expect(repositories.count == 2 && repositories.allSatisfy { !$0.files.isEmpty })
        let first = try #require(repositories.first?.files.first)
        let file = try await missions.file(id, space: repositories[0].spaceID, path: first.path)
        #expect(file.hunks.flatMap(\.lines).contains { $0.kind == .added && $0.text == "after" })
        let fingerprint = try #require(RemoteMissionControls.publishable(reviewed, reviews: repositories))
        #expect(fingerprint == reviewed.run?.reviewFingerprint)

        // Publication needs the exact fingerprint shown; another one pushes nothing.
        await expectRefusal("mission_stale_review") { try await missions.perform(id, revision: reviewed.revision, .publish(fingerprint: String(repeating: "0", count: 64))) }
        try fixture.expectUnpublished(id)
        try await missions.perform(id, revision: reviewed.revision, .publish(fingerprint: fingerprint))
        try await fixture.wait(id, phase: .done)
        let published = try #require(fixture.controller.record(id).run)
        #expect(published.publicationApproval == fingerprint)
        #expect(published.checkouts.allSatisfy { $0.prURL == "https://github.invalid/fixture/repo/pull/1" })
        try await eventuallyOnMain("the device sees the PRs") { missions.record(id)?.run?.phase == .done }
    }

    @Test func aPairedDeviceSteersWorkingTurnsTalksInThreadsAndAcceptsCompletionReports() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.specKitScenario() }
        }
        expectScenarioCompleted(result)
    }

    /// A device's client and missions model on `app`'s listener, hearing its hints and live words.
    static func pair(_ app: AppHarness, root: URL) async throws -> (RemoteHostClient, RemoteMissions) {
        let tokenURL = root.appendingPathComponent("remote-token")
        let port = try app.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "phone")
        try await eventuallyOnMain("the host offers missions") { client.capabilities.contains(RemoteProtocol.missionsCapability) }
        let missions = RemoteMissions(hostID: UUID())
        missions.connect({ try await client.mission($0) }, available: true)
        client.onMissionChanged = { id, revision in MainActor.assumeIsolated { missions.changed(id, revision: revision) } }
        client.onMissionLive = { id, live in MainActor.assumeIsolated { missions.liveChanged(id, live) } }
        return (client, missions)
    }

    static func specKitScenario() async throws {
        let fixture = try MissionSpecKitFixture(); defer { fixture.stop() }
        try await fixture.start()
        let controller = try #require(fixture.controller)
        let (client, missions) = try await pair(fixture.app, root: fixture.root)
        defer { client.disconnect() }
        /// The revision the device shows, once it caught up with the host.
        func shown(_ id: MissionID) async throws -> UInt64 {
            try await eventuallyOnMain("the device shows the host's mission") { missions.record(id)?.revision == (try? fixture.revision(id)) }
            return try fixture.revision(id)
        }
        func send(_ agent: AgentID, _ text: String, operation: UUID = UUID(), delivery: NativeThreadDelivery = .followUp) async throws -> NativeThreadResult {
            try await client.nativeThread(agentID: agent, request: .send(expectedSessionID: "", generation: "", operationID: operation,
                                                                          text: text, delivery: delivery))
        }
        let branches = Dictionary(uniqueKeysWithValues: fixture.spaces.map { ($0.id, "refs/heads/main") })
        let id = try await missions.create(goal: "Change result.txt to after.", spaces: fixture.spaces.map(\.id),
                                           model: MissionSpecKitFixture.model, branches: branches)
        try await fixture.wait(id, phase: .map)
        try await missions.loadSpecKit(id)
        let reports = try #require(missions.specKit[id]?.reports)
        for (index, space) in fixture.spaces.enumerated() {
            try await missions.perform(id, revision: try await shown(id), .specKitConsent(spaceID: space.id, fingerprint: try #require(reports[space.id]).consentFingerprint,
                                                                                         continuePlanning: index == fixture.spaces.count - 1))
        }
        try await fixture.wait(id, phase: .map)
        #expect(try controller.record(id).run?.notice?.contains("map is ready") == true)

        // Words typed in a repository's planning thread are the planner's answer, to that repository's conversation
        // only, even when the mission kept nothing that planner said (its messages keep only the newest 40).
        let planners = try #require(try controller.record(id).run?.specKit?.lanes.compactMap(\.plannerAgentID))
        var kept = try #require(try controller.record(id).run)
        kept.messages.removeAll { $0.spaceID == fixture.spaces[0].id }
        _ = try await fixture.app.server.setMissionRun(id: id, expectedRevision: try fixture.revision(id), run: kept)
        let before = try fixture.loggedCalls().count
        let feedback = UUID()
        #expect(try await send(planners[0], "Keep it short.", operation: feedback) == .accepted(operationID: feedback))
        try await fixture.wait(id, phase: .map)
        let replied = try fixture.loggedCalls().dropFirst(before).filter { $0["prompt"] as? String == "Keep it short." }
        #expect(replied.map { $0["agent"] as? String } == [planners[0].rawValue], "only that repository's planner gets the words")
        let answered = try #require(try controller.record(id).run?.messages.last { $0.role == .user })
        #expect(answered.text == "Keep it short." && answered.spaceID == fixture.spaces[0].id)

        // Launch holds both implement turns, so they can be steered: one from its thread, one from the mission.
        try Data().write(to: fixture.root.appendingPathComponent("hold-implement"))
        try await missions.perform(id, revision: try await shown(id), .launch)
        let stations = fixture.spaces.map { SpecKit.stationID(id, $0.id, "phase-0") }
        var working: [MissionAttempt] = []
        try await eventuallyOnMain("both repositories implement", timeout: .seconds(30)) {
            working = stations.compactMap { try? controller.record(id).run?.latest($0) }.filter { $0.status == .running }
            return working.count == 2 && (try? fixture.loggedCalls().filter { ($0["prompt"] as? String) == "/speckit.implement" }.count) == 2
        }
        let (first, second) = (working[0], working[1])
        let firstAgent = try #require(first.agentID)
        guard case .snapshot(let snapshot) = try await client.nativeThread(agentID: firstAgent, request: .snapshot()) else {
            Issue.record("Expected the working thread's snapshot"); return
        }
        #expect(snapshot.supportedActions.contains("send"), "a working mission turn offers its composer")
        // What a working turn says reaches the device, throttled, as the host's page shows it.
        controller.attemptOutput[first.id] = "Editing result.txt"
        try await eventuallyOnMain("the device hears the turn's words") { missions.live[id]?.attempts[first.id] == "Editing result.txt" }
        // The composer's choice holds: a steer goes in now, a queued message waits for the turn to end.
        let threadSteer = UUID(), queued = UUID()
        #expect(try await send(firstAgent, "Thread steer.", operation: threadSteer, delivery: .steer) == .accepted(operationID: threadSteer))
        guard case .failure("mission_steer_waiting", let why) = try await send(firstAgent, "Again.", delivery: .interrupt) else {
            Issue.record("A second steer while one waits must say why"); return
        }
        #expect(why.contains("still waiting to be read"))
        #expect(try await send(firstAgent, "Then check the newline.", operation: queued) == .accepted(operationID: queued))
        #expect(try controller.record(id).run?.attempts.first { $0.id == first.id }?.operationIDs == [threadSteer, queued])
        let steering = Task { try await missions.perform(id, revision: try await shown(id), .steer(attemptID: second.id, text: "Action steer.")) }
        try await eventuallyOnMain("the mission's steer is queued with pi") {
            (try? controller.record(id).run?.attempts.first { $0.id == second.id }?.operationIDs?.count) == 1
        }
        try Data().write(to: fixture.root.appendingPathComponent("release-implement"))
        _ = try await steering.value
        try await fixture.wait(id, phase: .map)
        var mission = try controller.record(id)
        let firstReceipt = try #require(mission.run?.attempts.first { $0.id == first.id })
        #expect(firstReceipt.deliveredOperationIDs == [threadSteer, queued], "pi read the steer, then the queued message")
        #expect(firstReceipt.status == .succeeded, "the attempt settled only after the queued turn")
        let calls = try fixture.loggedCalls()
        let implementCall = try #require(calls.firstIndex { $0["prompt"] as? String == "/speckit.implement" && $0["agent"] as? String == firstAgent.rawValue })
        let queuedCall = try #require(calls.firstIndex { $0["prompt"] as? String == "Then check the newline." })
        #expect(queuedCall > implementCall && calls[queuedCall]["agent"] as? String == firstAgent.rawValue,
                "the queued message is its own turn after the working one, in the same thread")
        #expect(!calls.contains { $0["steer"] as? String == "Then check the newline." }, "a queued message is never steered in")
        #expect(mission.run?.attempts.first { $0.id == second.id }?.deliveredOperationIDs?.count == 1)
        let steers = try fixture.loggedCalls().compactMap { $0["steer"] as? String }
        #expect(steers.contains("Thread steer.") && steers.contains("Action steer.") && !steers.contains("Again."))
        try await eventuallyOnMain("the device's live words clear") { missions.live[id] == nil }

        // Both completion reports wait for the owner. A stale revision is refused; one acceptance starts nothing
        // while the other waits; the last continues to review.
        let reportsWaiting = (mission.run?.specKit?.lanes ?? []).compactMap { $0.convergence }
        #expect(reportsWaiting.count == 2 && reportsWaiting.allSatisfy { !$0.accepted && $0.outcome == .unchanged })
        let quiet = try fixture.loggedCalls().count
        await expectRefusal("stale_mission") {
            try await missions.perform(id, revision: try await shown(id) - 1, .acceptConvergence(attemptID: reportsWaiting[0].attemptID))
        }
        try await missions.perform(id, revision: try await shown(id), .acceptConvergence(attemptID: reportsWaiting[0].attemptID))
        mission = try controller.record(id)
        #expect(mission.run?.phase == .map && mission.run?.specKit?.lanes.filter { $0.convergence?.accepted == true }.count == 1)
        #expect(try fixture.loggedCalls().count == quiet, "accepting one report starts nothing while another waits")
        try await missions.perform(id, revision: try await shown(id), .acceptConvergence(attemptID: reportsWaiting[1].attemptID))
        try await fixture.wait(id, phase: .review)
        try await eventuallyOnMain("the device sees review") { missions.record(id)?.run?.phase == .review }

        // A finished step's thread says why it takes nothing, in words the thread shows.
        guard case .failure("mission_step_finished", let finished) = try await send(firstAgent, "One more thing.") else {
            Issue.record("A finished step must refuse with its reason"); return
        }
        #expect(finished.contains("Message the planner"))
    }

    private static func expectRefusal(_ code: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("Expected \(code)")
        } catch RemoteHostClientError.rejected(let refused, _) {
            #expect(refused == code)
        } catch {
            Issue.record("Expected \(code), got \(error)")
        }
    }
}
