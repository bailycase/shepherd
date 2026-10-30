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
