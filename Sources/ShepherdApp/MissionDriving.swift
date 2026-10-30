import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// What the Missions page reads and asks: This Mac's `MissionController`, or a connected host's
/// missions (`RemoteMissionDriver`, docs/missions.md › Remote). Both run the owner's methods on the
/// host that owns the mission, against the revision the page displayed.
@MainActor
protocol MissionDriving: AnyObject, Observable {
    var records: [Mission] { get }
    var selectedID: MissionID? { get set }
    var error: String? { get set }
    var liveOutput: [MissionID: String] { get }
    var attemptOutput: [UUID: String] { get }
    var reviews: [MissionID: [MissionRepositoryReview]] { get }
    var viewed: [MissionID: Set<String>] { get set }
    var availableModels: [String] { get }
    var defaultModel: String? { get }
    var availableSpaces: [Space] { get }
    var branchChoices: [SpaceID: [String]] { get }
    var defaultBranches: [SpaceID: String] { get }
    var specKitReports: [MissionID: [SpaceID: SpecKitPreflight]] { get }
    /// The sidebar's New mission asked for the start page.
    var startRequested: Bool { get set }
    func refreshModels() async
    func create(goal: String, spaces: [SpaceID], model: String, branches: [SpaceID: String]) async throws -> MissionID
    /// A mission opened on the page: what it shows beyond the record is read.
    func opened(_ id: MissionID) async
    func thread(for attemptID: UUID) -> MissionThreadSource?
    func isLive(_ agent: AgentID) -> Bool
    func openThread(_ id: AgentID)
    /// One action of the page, against the displayed revision.
    func perform(_ action: MissionUIAction, id: MissionID, revision: UInt64) async throws
}

extension MissionController: MissionDriving {
    var startRequested: Bool {
        get { vm?.missionStartRequested ?? false }
        set { vm?.missionStartRequested = newValue }
    }

    func create(goal: String, spaces: [SpaceID], model: String, branches: [SpaceID: String]) async throws -> MissionID {
        try await create(goal: goal, spaces: spaces, model: model, branches: branches, backend: nil)
    }

    func opened(_ id: MissionID) async {}

    func isLive(_ agent: AgentID) -> Bool { vm?.state.agents.contains { $0.id == agent } == true }

    func perform(_ action: MissionUIAction, id: MissionID, revision: UInt64) async throws {
        switch action {
        case .plan(let feedback): try await plan(id: id, feedback: feedback)
        case .answer(let text, let choice, let replyTo): try await answer(id: id, revision: revision, text: text, choice: choice, replyTo: replyTo)
        case .specKitConsent(let space, let fingerprint, let continuePlanning):
            try await grantSpecKitConsent(id: id, revision: revision, space: space, fingerprint: fingerprint, continuePlanning: continuePlanning)
        case .specKitSetUp(let space): try await setUpSpecKit(id: id, revision: revision, space: space)
        case .acceptConvergence(let attempt): try await acceptConvergence(id: id, revision: revision, attemptID: attempt)
        case .save(let draft, let editedRevision): try await saveDraft(id: id, revision: editedRevision, draft: draft)
        case .launch: try await launch(id: id, revision: revision)
        case .pause: try await pause(id: id, revision: revision)
        case .stop: try await stop(id: id, revision: revision)
        case .changes(let text): try await requestChanges(id: id, revision: revision, text: text)
        case .publish(let approval): try await publish(id: approval.id, revision: approval.revision, fingerprint: approval.fingerprint)
        case .refresh: try await refreshReview(id: id)
        case .revalidate: try await revalidate(id: id, revision: revision)
        case .runAgain: selectedID = try await runAgain(id: id)
        }
    }
}

/// A connected host's missions behind the Missions page. Every action is a `missions.v1` request
/// carrying the revision, consent fingerprint or review fingerprint the page displayed; station
/// threads are read through the host's native-thread snapshots.
@MainActor @Observable
final class RemoteMissionDriver: MissionDriving {
    let hostID: UUID
    let missions: RemoteMissions
    var selectedID: MissionID?
    var error: String?
    var viewed: [MissionID: Set<String>] = [:]
    var startRequested = false
    /// Each review read, with every file's hunks.
    private(set) var reviews: [MissionID: [MissionRepositoryReview]] = [:]
    @ObservationIgnored private weak var vm: ShepherdViewModel?

    init(connection: RemoteHostStore.Connection, vm: ShepherdViewModel) {
        hostID = connection.id
        missions = connection.missions
        self.vm = vm
    }

    private var connection: RemoteHostStore.Connection? { vm?.remoteHosts.connections.first { $0.id == hostID } }
    var records: [Mission] { missions.records }
    var liveOutput: [MissionID: String] { [:] }
    var attemptOutput: [UUID: String] { [:] }
    var availableModels: [String] { missions.startOptions?.models ?? [] }
    var defaultModel: String? { missions.startOptions?.defaultModel }
    var availableSpaces: [Space] { missions.startOptions?.spaces ?? [] }
    var branchChoices: [SpaceID: [String]] { missions.startOptions?.branchChoices ?? [:] }
    var defaultBranches: [SpaceID: String] { missions.startOptions?.defaultBranches ?? [:] }
    var specKitReports: [MissionID: [SpaceID: SpecKitPreflight]] { missions.specKit.mapValues(\.reports) }

    func refreshModels() async {
        do { try await missions.loadStartOptions() } catch { self.error = RemoteMissions.describe(error) }
    }

    func create(goal: String, spaces: [SpaceID], model: String, branches: [SpaceID: String]) async throws -> MissionID {
        try await remote { try await self.missions.create(goal: goal, spaces: spaces, model: model, branches: branches) }
    }

    func opened(_ id: MissionID) async {
        guard missions.record(id)?.run?.specKit != nil else { return }
        try? await missions.loadSpecKit(id)
    }

    func isLive(_ agent: AgentID) -> Bool { connection?.state.agents.contains { $0.id == agent } == true }

    func openThread(_ id: AgentID) { vm?.selectRemoteAgent(hostID: hostID, agentID: id) }

    func thread(for attemptID: UUID) -> MissionThreadSource? {
        guard let vm, let (mission, attempt) = missions.records.lazy.compactMap({ mission in
            mission.run?.attempts.first { $0.id == attemptID }.map { (mission, $0) }
        }).first, let agentID = attempt.agentID, isLive(agentID) else { return nil }
        let ref = RemoteAgentRef(hostID: hostID, agentID: agentID), missions = missions, missionID = mission.id, hosts = vm.remoteHosts
        let request: NativeThreadStore.Request = { value in
            switch value {
            case .snapshot, .image, .subagentTranscript:
                let result = try await hosts.nativeThread(ref, request: value)
                // As on the host: the composer may send while the mission can steer this turn, only through `send`.
                let run = missions.record(missionID)?.run
                guard case .snapshot(var snapshot) = result, run?.phase.active == true,
                      run?.attempts.first(where: { $0.id == attemptID })?.status == .running else { return result }
                snapshot.supportedActions.append("send")
                return .snapshot(value: snapshot)
            default: throw MissionError("mission_thread", "Mission threads take messages through the mission.")
            }
        }
        let steerable = attempt.status == .running && mission.run?.phase.active == true
        return MissionThreadSource(agentID: agentID, store: vm.remoteThreadStores.store(for: ref), request: request, preview: nil,
                                   send: steerable ? { [weak self] text in
                                       guard let self, let current = self.missions.record(missionID) else { return }
                                       try await self.remote { _ = try await self.missions.perform(missionID, revision: current.revision, .steer(attemptID: attemptID, text: text)) }
                                   } : nil)
    }

    func perform(_ action: MissionUIAction, id: MissionID, revision: UInt64) async throws {
        let wire: RemoteMissionAction
        var shown = revision
        switch action {
        case .refresh: return try await remote { try await self.refreshReview(id) }
        case .plan(let feedback): wire = .plan(feedback: feedback)
        case .answer(let text, let choice, let replyTo): wire = .answer(text: text, choice: choice, replyTo: replyTo)
        case .specKitConsent(let space, let fingerprint, let continuePlanning):
            wire = .specKitConsent(spaceID: space, fingerprint: fingerprint, continuePlanning: continuePlanning)
        case .specKitSetUp(let space): wire = .specKitSetUp(spaceID: space)
        case .acceptConvergence(let attempt): wire = .acceptConvergence(attemptID: attempt)
        case .save(let draft, let editedRevision): wire = .save(draft: draft); shown = editedRevision
        case .launch: wire = .launch
        case .pause: wire = .pause
        case .stop: wire = .stop
        case .changes(let text): wire = .changes(text: text)
        case .publish(let approval): wire = .publish(fingerprint: approval.fingerprint); shown = approval.revision
        case .revalidate: wire = .revalidate
        case .runAgain: wire = .runAgain
        }
        let made = try await remote { try await self.missions.perform(id, revision: shown, wire) }
        if let made { selectedID = made }
        if missions.record(id)?.run?.specKit != nil { try? await missions.loadSpecKit(id) }
    }

    /// The review as the page draws it: every repository's files, each read with its hunks.
    private func refreshReview(_ id: MissionID) async throws {
        try await missions.loadReview(id)
        var built: [MissionRepositoryReview] = []
        for repository in missions.reviews[id] ?? [] {
            var files: [DiffFile] = []
            // ponytail: one file at a time; a review of hundreds of files waits for each read.
            for file in repository.files { files.append(try await missions.file(id, space: repository.spaceID, path: file.path)) }
            built.append(MissionRepositoryReview(spaceID: repository.spaceID, name: repository.name, path: repository.path,
                                                 branch: repository.branch, head: repository.head, fingerprint: repository.fingerprint, files: files))
        }
        if reviews[id] != built { reviews[id] = built }
    }

    /// A host's refusal reads as the host wrote it.
    private func remote<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch RemoteHostClientError.rejected(let code, let message) { throw MissionError(code, message) }
    }
}
