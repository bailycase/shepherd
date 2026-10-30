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
        server.onMissionThreadSend = { [weak self] agent, text, operation, delivery, reply in
            MainActor.assumeIsolated {
                guard let self else { reply(.failure(code: "mission_unavailable", message: "Host is shutting down.")); return }
                Task { @MainActor in
                    do {
                        try await self.threadMessage(agent: agent, text: text, operation: operation, delivery: delivery)
                        reply(.accepted(operationID: operation))
                    } catch let error as MissionError { reply(.failure(code: error.code, message: error.description)) }
                    catch { reply(.failure(code: "mission_failed", message: Self.safeText(String(describing: error)))) }
                }
            }
        }
        serveRemoteWhileEnabled()
        publishLiveOutput()
    }

    /// Words typed in a mission's own thread, on this Mac or a client. While its turn works they go as the composer
    /// chose: queued (`.followUp`) for after the turn, in the attempt's own session, which settles only after it; or
    /// steered in now (`.steer`, `.interrupt`), answered once pi queued it, whether it was read recorded on the
    /// attempt. While the mission waits on you, a planner's thread takes them as the planner's answer, a Spec Kit
    /// planning thread for its own repository only. Else a refusal that says what to do instead. The same checks
    /// as the Missions page's controls.
    func threadMessage(agent: AgentID, text: String, operation: UUID, delivery: NativeThreadDelivery = .steer) async throws {
        guard vm?.settings.missionsEnabled == true else { throw MissionError("missions_off", RemoteMissionRefusal.off) }
        guard let mission = records.first(where: { $0.run.map { MissionRun.owns($0, agent: agent) } == true }), let run = mission.run else {
            throw MissionError("mission_missing", "This thread's mission no longer exists.")
        }
        guard run.publicationApproval == nil else {
            throw MissionError("mission_published", "This mission's publication is authorized, so its threads take no more messages.")
        }
        if run.phase.active {
            guard let attempt = run.attempts.last(where: { $0.agentID == agent && $0.status == .running }) else {
                throw MissionError("mission_step_idle", "This step isn't working right now (the mission is \(run.phase.rawValue)). Steer a working step, or pause the mission and message the planner.")
            }
            if delivery == .followUp {
                return try await sendQueued(id: mission.id, attemptID: attempt.id, text: text, operation: operation)
            }
            let sent = try await sendSteer(id: mission.id, revision: mission.revision, attemptID: attempt.id, text: text, operation: operation)
            Task { try? await self.awaitSteer(id: mission.id, runID: sent.runID, attemptID: attempt.id, agent: sent.agent, operation: operation) }
            return
        }
        guard run.isPlanner(agent) else {
            throw MissionError("mission_step_finished", "This step has finished; its thread is a record. Message the planner from the mission, or request changes in its review.")
        }
        // A Spec Kit planning thread speaks for its own repository; the map runner's planner for the whole mission.
        let lane = run.specKit?.lanes.first { $0.plannerAgentID == agent }?.spaceID
        if run.pendingQuestion != nil, let asked = run.messages.last(where: { $0.role == .assistant && $0.question != nil }) {
            guard lane == nil || asked.spaceID == lane else {
                let name = mission.lane(asked.spaceID)?.name ?? "another repository"
                throw MissionError("mission_question_elsewhere", "The planner is waiting on your answer about \(name). Answer that first, in the mission or in \(name)'s planning thread.")
            }
            return try await answer(id: mission.id, revision: mission.revision, text: text, replyTo: asked.id)
        }
        let latest = run.messages.last { $0.role == .assistant && (lane == nil || $0.spaceID == lane) }
        guard let lane else { return try await answer(id: mission.id, revision: mission.revision, text: text, replyTo: latest?.id) }
        // That repository's planning conversation only, even before its planner has said anything.
        let words = Self.safeText(text.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 16_000)
        guard !words.isEmpty else { throw MissionError("mission_answer", "Type a message for the planner.") }
        try await continueSpecKitPlanning(mission.id, revision: mission.revision,
                                          reply: (lane, MissionChatMessage(role: .user, text: words, replyTo: latest?.id, spaceID: lane)))
    }

    /// The owner's words queued behind a working turn, in the attempt's own session: pi reads them as its next
    /// turn, and the attempt settles only after that turn (its receipts record whether pi read them).
    func sendQueued(id: MissionID, attemptID: UUID, text: String, operation: UUID) async throws {
        let mission = try record(id)
        let text = Self.safeText(text.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 16_000)
        guard let run = mission.run, run.phase.active, let attempt = run.attempts.first(where: { $0.id == attemptID }),
              attempt.status == .running, let agent = attempt.agentID, !text.isEmpty else {
            throw MissionError("mission_queue", "Only a working mission turn takes a message for after it.")
        }
        try await server.sendMissionQueued(id: id, runID: run.id, agentID: agent, operationID: operation, text: text)
    }

    /// How often paired devices hear what running missions' agents say, at most.
    static let livePublishInterval: Duration = .milliseconds(500)

    /// Publishes `liveOutput` and `attemptOutput` to the server for paired devices: on change, at most every
    /// `livePublishInterval`, only the missions whose words changed (an empty value once a job ends).
    func publishLiveOutput() {
        withObservationTracking { _ = liveOutput; _ = attemptOutput } onChange: {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.livePublishInterval)
                guard let self else { return }
                let changes = self.liveChanges()
                if !changes.isEmpty { self.server.setMissionLive(changes) }
                self.publishLiveOutput()
            }
        }
    }

    /// Each mission's words now, against what was last published.
    func liveChanges() -> [MissionID: RemoteMissionLive] {
        var changes: [MissionID: RemoteMissionLive] = [:]
        for mission in records {
            let attempts = Set(mission.run?.attempts.map(\.id) ?? [])
            let now = RemoteMissionLive(output: liveOutput[mission.id] ?? "", attempts: attemptOutput.filter { attempts.contains($0.key) })
            if now != (publishedLive[mission.id] ?? RemoteMissionLive()) { changes[mission.id] = now }
        }
        for (id, live) in changes { publishedLive[id] = live.isEmpty ? nil : live }
        publishedLive = publishedLive.filter { id, _ in records.contains { $0.id == id } }
        return changes
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
