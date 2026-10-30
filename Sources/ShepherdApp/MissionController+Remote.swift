import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// Missions for a paired device (`missions.v1`, docs/missions.md › Remote): every request runs the
/// same owner method the Missions page runs, with its guards, against the revision, consent
/// fingerprint and review fingerprint the device displayed. Nothing is defaulted host-side.
extension MissionController {
    /// Installed once at startup. The server offers missions only while Settings ▸ Experiments ▸
    /// Missions is on here, and tells connected clients when that changes.
    func installRemote() {
        server.onRemoteMission = { [weak self] request, reply in
            MainActor.assumeIsolated {
                guard let self else { reply(.failure(MissionError("mission_unavailable", "Host is shutting down."))); return }
                Task { @MainActor in
                    do { reply(.success(try await self.remote(request))) }
                    catch let error as MissionError { reply(.failure(error)) }
                    catch { reply(.failure(MissionError("mission_failed", Self.safeText(String(describing: error))))) }
                }
            }
        }
        serveRemoteWhileEnabled()
    }

    private func serveRemoteWhileEnabled() {
        let on = withObservationTracking { vm?.settings.missionsEnabled == true } onChange: {
            Task { @MainActor [weak self] in self?.serveRemoteWhileEnabled() }
        }
        server.setMissionsServed(on)
    }

    func remote(_ request: RemoteMissionRequest) async throws -> RemoteMissionResult {
        guard vm?.settings.missionsEnabled == true else { throw MissionError("missions_off", RemoteMissionRefusal.off) }
        switch request {
        case .list: return .list(records.map(RemoteMissionSummary.init))
        case .get(let id): return .mission(try record(id))
        case .startOptions:
            await refreshModels()
            return .startOptions(startOptions)
        case .create(let goal, let spaces, let model, let branches):
            // What the host's page would offer now; a device never names a repository or model it doesn't list.
            await refreshModels()
            return .created(missionID: try await keepingSelection { try await self.create(goal: goal, spaces: spaces, model: model, branches: branches) })
        case .action(let id, let revision, let action):
            if let made = try await remoteAction(id: id, revision: revision, action: action) { return .created(missionID: made) }
            return .done(mission: try? record(id))
        case .review(let id):
            try await refreshReview(id: id)
            return .review((reviews[id] ?? []).map {
                RemoteMissionReview(spaceID: $0.spaceID, name: $0.name, path: $0.path, branch: $0.branch, head: $0.head,
                                    fingerprint: $0.fingerprint, files: $0.files.map(RemoteMissionReviewFile.init))
            })
        case .reviewFile(let id, let space, let path):
            if reviews[id] == nil { try await refreshReview(id: id) }
            guard let file = reviews[id]?.first(where: { $0.spaceID == space })?.files.first(where: { $0.displayPath == path }) else {
                throw MissionError("mission_review_file", "That file is not in the current review. Refresh the review.")
            }
            return .reviewFile(file)
        case .specKit(let id):
            let reports = try await specKitPreflight(id: id)
            return .specKit(RemoteMissionSpecKit(reports: reports, phases: specKitPhases[id] ?? [:], settingUp: specKitSettingUp.contains(id)))
        }
    }

    /// What New mission offers, each repository's branch list bounded so the answer fits a frame.
    var startOptions: RemoteMissionStartOptions {
        RemoteMissionStartOptions(models: availableModels, defaultModel: defaultModel, spaces: availableSpaces,
                                  branchChoices: branchChoices.mapValues { Array($0.prefix(2_000)) }, defaultBranches: defaultBranches)
    }

    /// The Missions page's `submit`, for a device: the displayed revision, the publication guard, the same calls.
    /// Returns the mission Run again made.
    private func remoteAction(id: MissionID, revision: UInt64, action: RemoteMissionAction) async throws -> MissionID? {
        let mission = try record(id)
        if mission.run?.publicationApproval != nil {
            switch action {
            case .plan, .answer, .save, .launch, .revalidate, .changes, .specKitConsent, .specKitSetUp, .acceptConvergence:
                throw MissionError("mission_published", "Publication was already authorized. These receipts cannot be reused for new work.")
            default: break
            }
        }
        // Pause and Stop only halt: a running mission's receipts move its revision on every turn, and
        // refusing a halt over that would keep the work going. Every other action needs the shown revision.
        let halting: Bool = switch action { case .pause, .stop: mission.run?.phase.active == true; default: false }
        if case .steer = action {} else if !halting, mission.revision != revision {
            throw MissionError("stale_mission", "This mission changed on the host. Review it again before acting.")
        }
        let current = halting ? mission.revision : revision
        switch action {
        case .plan(let feedback): try await plan(id: id, feedback: feedback)
        case .answer(let text, let choice, let replyTo): try await answer(id: id, revision: current, text: text, choice: choice, replyTo: replyTo)
        case .specKitConsent(let space, let fingerprint, let continuePlanning):
            try await grantSpecKitConsent(id: id, revision: current, space: space, fingerprint: fingerprint, continuePlanning: continuePlanning)
        case .specKitSetUp(let space): try await setUpSpecKit(id: id, revision: current, space: space)
        case .acceptConvergence(let attempt): try await acceptConvergence(id: id, revision: current, attemptID: attempt)
        case .save(let draft): try await saveDraft(id: id, revision: current, draft: draft)
        case .launch: try await launch(id: id, revision: current)
        case .pause: try await pause(id: id, revision: current)
        case .stop: try await stop(id: id, revision: current)
        case .changes(let text): try await requestChanges(id: id, revision: current, text: text)
        case .publish(let fingerprint): try await publish(id: id, revision: current, fingerprint: fingerprint)
        case .revalidate: try await revalidate(id: id, revision: current)
        case .runAgain: return try await keepingSelection { try await self.runAgain(id: id) }
        case .steer(let attempt, let text): try await steer(id: id, revision: revision, attemptID: attempt, text: text)
        }
        return nil
    }

    /// A device's New mission or Run again never changes what the host's own page shows.
    private func keepingSelection(_ body: () async throws -> MissionID) async throws -> MissionID {
        let shown = selectedID
        defer { selectedID = shown }
        return try await body()
    }
}

enum RemoteMissionRefusal {
    static let off = "Missions are off on this host. Turn on Settings ▸ Experiments ▸ Missions there."
}
