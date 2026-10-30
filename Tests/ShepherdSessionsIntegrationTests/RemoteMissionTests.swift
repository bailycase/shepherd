import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// `missions.v1` over the listener: the host offers it only while served with an owner installed,
/// only to a client that lists it; reads come from the store, everything else reaches the owner
/// exactly as sent; mutations are hinted, never carried in `stateChanged`.
@Suite("Remote missions", .integrationTimeLimit)
struct RemoteMissionTests {
    /// The GUI's owner, as the server sees it: every request it was handed, answered from `answer`.
    final class Owner: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [RemoteMissionRequest] = []
        var requests: [RemoteMissionRequest] { lock.withLock { seen } }
        func install(on server: SessionServer, answer: @escaping (RemoteMissionRequest) -> Result<RemoteMissionResult, MissionError>) {
            server.onRemoteMission = { [self] request, reply in
                lock.withLock { seen.append(request) }
                reply(answer(request))
            }
        }
    }

    private static let draft = MissionDraft(title: "Private brief", goal: "Unpublished planning context")

    private func next(_ client: RawRemote, matching: (RemoteReply) -> Bool) async throws -> RemoteReply {
        try await client.frames(until: matching).last!
    }

    @Test func aClientWithoutMissionsGetsNoneInStateRequestsOrPushes() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let owner = Owner()
        owner.install(on: remote.server) { _ in .success(.done(mission: nil)) }
        remote.server.setMissionsServed(true)
        let mission = try await remote.server.createMission(draft: Self.draft)
        let client = try RawRemote(port: remote.port)
        let offered = try await client.hello(token: remote.token, capabilities: RemoteProtocol.clientCapabilities.filter { $0 != RemoteProtocol.missionsCapability })
        #expect(!offered.contains(RemoteProtocol.missionsCapability))
        try client.send(.stateFetch(id: 2))
        guard case .state(2, let fetched) = try await client.next() else { Issue.record("Expected fleet snapshot"); return }
        #expect(fetched.missions.isEmpty)
        try client.send(.mission(id: 3, request: .get(missionID: mission.id)))
        guard case .error(3, "unsupported", _) = try await client.next() else { Issue.record("Expected a refusal"); return }
        _ = try await remote.server.setMissionRun(id: mission.id, expectedRevision: mission.revision, run: MissionRun(model: "test/model"))
        try await remote.server.addSpace(Space(name: "Other mutation", path: remote.host.dir.path))
        // The mission's change, then the space push: state frames without missions and no hint.
        let frames = try await client.frames(until: { if case .stateChanged(let state) = $0 { state.spaces.count == 1 } else { false } })
        #expect(!frames.contains { if case .missionChanged = $0 { true } else { false } })
        for case .stateChanged(let state) in frames { #expect(state.missions.isEmpty) }
        #expect(owner.requests.isEmpty)
        #expect(try remote.host.persisted().missions.first?.draft == Self.draft)
    }

    @Test func aCapableClientListsReadsAndHearsOfChangesWhileTheHostServesMissions() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let owner = Owner()
        let client = try RawRemote(port: remote.port)
        // Nothing offered before the owner is installed and the experiment is on.
        #expect(!(try await client.hello(token: remote.token, capabilities: RemoteProtocol.clientCapabilities)).contains(RemoteProtocol.missionsCapability))
        try client.send(.mission(id: 2, request: .list))
        guard case .error(2, "unsupported", _) = try await client.next() else { Issue.record("Expected a refusal"); return }
        owner.install(on: remote.server) { _ in .success(.done(mission: nil)) }
        remote.server.setMissionsServed(true)
        guard case .capabilitiesChanged(let now) = try await next(client, matching: { if case .capabilitiesChanged = $0 { true } else { false } }) else { return }
        #expect(now.contains(RemoteProtocol.missionsCapability))

        let mission = try await remote.server.createMission(draft: Self.draft)
        let made = try await client.frames(until: { if case .missionChanged = $0 { true } else { false } })
        guard case .missionChanged(mission.id, mission.revision) = made.last else { Issue.record("Expected a hint for the new mission"); return }
        for case .stateChanged(let state) in made { #expect(state.missions.isEmpty, "Missions never ride stateChanged") }
        try client.send(.mission(id: 3, request: .list))
        guard case .mission(3, .list(let summaries)) = try await next(client, matching: { if case .mission(3, _) = $0 { true } else { false } }) else {
            Issue.record("Expected summaries"); return
        }
        #expect(summaries == [RemoteMissionSummary(mission)])
        try client.send(.mission(id: 4, request: .get(missionID: mission.id)))
        guard case .mission(4, .mission(let read)) = try await next(client, matching: { if case .mission(4, _) = $0 { true } else { false } }) else { return }
        #expect(read == mission)
        try await remote.server.deleteMission(id: mission.id, expectedRevision: mission.revision)
        guard case .missionChanged(mission.id, nil) = try await next(client, matching: { if case .missionChanged = $0 { true } else { false } }) else {
            Issue.record("Expected a hint that it went"); return
        }
        #expect(owner.requests.isEmpty, "Reads never reach the owner")

        // The experiment going off is told, and refused from then on.
        remote.server.setMissionsServed(false)
        guard case .capabilitiesChanged(let off) = try await next(client, matching: { if case .capabilitiesChanged = $0 { true } else { false } }) else { return }
        #expect(!off.contains(RemoteProtocol.missionsCapability))
        try client.send(.mission(id: 5, request: .list))
        guard case .error(5, "unsupported", _) = try await next(client, matching: { if case .error(5, _, _) = $0 { true } else { false } }) else { return }
    }

    @Test func actionsReachTheOwnerExactlyAsSentAndItsRefusalsComeBackAsSent() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let mission = try await remote.server.createMission(draft: Self.draft)
        let owner = Owner()
        owner.install(on: remote.server) { request in
            if case .action(_, let revision, .publish(let fingerprint)) = request, revision == mission.revision, fingerprint == "shown" {
                return .success(.done(mission: mission))
            }
            return .failure(MissionError("mission_stale_review", "Review the current validated changes before publishing."))
        }
        remote.server.setMissionsServed(true)
        let client = try await remote.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.missionsCapability))
        #expect(try await client.mission(.action(missionID: mission.id, revision: mission.revision, action: .publish(fingerprint: "shown"))) == .done(mission: mission))
        do {
            _ = try await client.mission(.action(missionID: mission.id, revision: mission.revision, action: .publish(fingerprint: "other")))
            Issue.record("A different fingerprint must be refused")
        } catch RemoteHostClientError.rejected(let code, _) {
            #expect(code == "mission_stale_review")
        }
        #expect(owner.requests == [
            .action(missionID: mission.id, revision: mission.revision, action: .publish(fingerprint: "shown")),
            .action(missionID: mission.id, revision: mission.revision, action: .publish(fingerprint: "other")),
        ])
    }

    @Test func anAnswerPastTheFrameCapIsRefusedNotSent() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        RemoteMissionTests.Owner().install(on: remote.server) { _ in
            .success(.reviewFile(DiffFile(oldPath: nil, newPath: "big", displayPath: "big", isNew: true, isDeleted: false, isRenamed: false, isBinary: false,
                                          hunks: [DiffHunk(header: "@@", lines: (0..<20_000).map { DiffLine(kind: .added, text: String(repeating: "x", count: 80), oldLine: nil, newLine: $0, id: $0) })])))
        }
        remote.server.setMissionsServed(true)
        let client = try await remote.typed()
        defer { client.disconnect() }
        do {
            _ = try await client.mission(.reviewFile(missionID: MissionID(), spaceID: SpaceID(), path: "big"))
            Issue.record("Expected too_large")
        } catch RemoteHostClientError.rejected(let code, _) {
            #expect(code == "too_large")
        }
        // The connection stays: the next request is answered.
        await #expect(throws: RemoteHostClientError.self) { _ = try await client.mission(.reviewFile(missionID: MissionID(), spaceID: SpaceID(), path: "big")) }
    }

    @Test func theExtensionSocketCannotDriveMissions() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await remote.host.seed(Fixture.workspace([worker], space: space))
        let mission = try await remote.server.createMission(draft: Self.draft)
        let owner = Owner()
        owner.install(on: remote.server) { _ in .success(.done(mission: nil)) }
        remote.server.setMissionsServed(true)
        let pi = try ExtensionClient(path: remote.host.socketPath)
        try pi.sendRaw(NDJSON.encode(RemoteRequest.mission(id: 1, request: .action(missionID: mission.id, revision: mission.revision, action: .launch))))
        // A later message on the same connection is served: the mission line was read and dropped.
        try pi.send(.setAgentStatus(agentID: worker.agent.id, status: .working))
        try await eventually("the later status") { remote.server.state.agents.first?.status == .working }
        #expect(owner.requests.isEmpty)
        #expect(try remote.host.persisted().missions == [mission])
    }
}
