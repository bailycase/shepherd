import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

public struct MissionAgentSnapshot: Sendable {
    public var settled = false
    public var ready = false
    public var text = ""
    /// Every assistant message since the turn's prompt, in order: a stock report can come before a closing note
    /// (/speckit.analyze's findings table, then its hook check), and `text` is only the last message.
    public var turnText = ""
    public var error: String?
    public var tokens: Int?
    public var cost: Double?
    /// The prompt templates pi actually loaded, by command name, with the file each came from.
    public var promptTemplates: [String: String] = [:]
    /// This attempt's steers that its run ended without pi reading.
    public var undelivered: [UUID] = []
    public init() {}
}

extension SessionServer {
    /// The owner's API, driven only by the app's `MissionController` (on this Mac or for a paired
    /// device's `missions.v1` request). No extension message can approve a map or publish a PR.
    public func missions() async throws -> [Mission] {
        try await enqueue {
            try self.requireStarted()
            return self.store.state.missions
        }
    }

    public func createMission(id: MissionID = MissionID(), draft: MissionDraft) async throws -> Mission {
        try await enqueue {
            try self.requireStarted()
            if let existing = self.store.state.missions.first(where: { $0.id == id }) {
                guard existing.draft == draft else {
                    throw MissionError("mission_conflict", "This mission ID already belongs to a different draft.")
                }
                return existing
            }
            let mission = Mission(id: id, draft: draft)
            try mission.validate()
            try self.validateMissionSpaces(draft)
            try self.mutateState { $0.missions.append(mission) }
            return mission
        }
    }

    public func editMission(id: MissionID, expectedRevision: UInt64, draft: MissionDraft) async throws -> Mission {
        try await enqueue {
            var mission = try self.missionForMutation(id, expectedRevision: expectedRevision)
            guard mission.run?.phase.active != true else { throw MissionError("mission_busy", "Pause the mission before editing its map.") }
            guard mission.draft != draft else { return mission }
            for checkout in mission.run?.checkouts ?? [] {
                guard draft.plan?.lanes.first(where: { $0.spaceID == checkout.spaceID })?.baseBranch
                    == mission.draft.plan?.lanes.first(where: { $0.spaceID == checkout.spaceID })?.baseBranch else {
                    throw MissionError("mission_base", "A mission worktree's selected base cannot change. Start a new mission from another branch.")
                }
            }
            guard mission.run?.publicationApproval == nil else { throw MissionError("mission_published", "Publication has been authorized. Finish or reconcile its PRs before starting a different mission.") }
            if let plan = draft.plan, var run = mission.run {
                guard Set(run.checkouts.map(\.spaceID)).isSubset(of: Set(draft.spaceIDs)) else {
                    throw MissionError("mission_scope", "A repository with retained work cannot be removed from the mission.")
                }
                let oldPlan = mission.draft.plan
                let oldStations = Dictionary(uniqueKeysWithValues: (oldPlan?.stations ?? []).map { ($0.id, $0) })
                var changed = Set(plan.stations.filter { oldStations[$0.id] != $0 }.map(\.id))
                for station in plan.stations where Set(plan.dependencies.filter { $0.target == station.id }) != Set((oldPlan?.dependencies ?? []).filter { $0.target == station.id }) {
                    changed.insert(station.id)
                }
                if mission.draft.goal != draft.goal || mission.draft.requirements != draft.requirements || mission.draft.context != draft.context {
                    changed.formUnion(plan.stations.map(\.id))
                }
                changed.formUnion(try plan.dataConsumers(of: changed))
                if !changed.isEmpty { changed.formUnion(plan.stations.filter { $0.kind == .check || $0.kind == .validator }.map(\.id)) }
                for index in run.attempts.indices where run.attempts[index].stationID.map(changed.contains) == true {
                    run.attempts[index].status = .superseded
                }
                run.reviewFingerprint = nil
                run.transition(to: .map, at: Date().timeIntervalSince1970)
                mission.run = run
            }
            mission.draft = draft
            mission.revision += 1
            mission.approvedPlanRevision = nil
            try mission.validate()
            try self.validateMissionSpaces(draft)
            try self.mutateState { state in
                state.missions = state.missions.map { $0.id == id ? mission : $0 }
            }
            return mission
        }
    }

    /// A Spec Kit mission's map redrawn from its repositories' own artifacts. The map is a display of
    /// those files, so receipts stay as they are (an owner edit through `editMission` supersedes them);
    /// approval is cleared whenever the drawing changes, and repositories and bases cannot change here.
    public func projectSpecKitMap(id: MissionID, expectedRevision: UInt64, draft: MissionDraft) async throws -> Mission {
        try await enqueue {
            var mission = try self.missionForMutation(id, expectedRevision: expectedRevision)
            guard let run = mission.run, run.specKit != nil else { throw MissionError("mission_mode", "Only a Spec Kit mission's map is drawn from its artifacts.") }
            guard !run.phase.active else { throw MissionError("mission_busy", "Pause the mission before redrawing its map.") }
            guard run.publicationApproval == nil else { throw MissionError("mission_published", "Publication has been authorized.") }
            guard mission.draft != draft else { return mission }
            guard draft.goal == mission.draft.goal, draft.context == mission.draft.context,
                  draft.plan?.lanes == mission.draft.plan?.lanes, draft.plan?.limits == mission.draft.plan?.limits else {
                throw MissionError("mission_scope", "A drawn map cannot change the destination, repositories, bases or limits.")
            }
            mission.draft = draft
            mission.revision += 1
            mission.approvedPlanRevision = nil
            try mission.validate()
            try self.validateMissionSpaces(draft)
            try self.storeMission(mission)
            return mission
        }
    }

    /// Accepts the map only. Publication will require a separate approval of the validated commit set.
    public func approveMissionPlan(id: MissionID, expectedRevision: UInt64) async throws -> Mission {
        try await enqueue {
            var mission = try self.missionForMutation(id, expectedRevision: expectedRevision)
            guard mission.run?.phase.active != true else { throw MissionError("mission_busy", "The mission is already working.") }
            guard mission.run?.pendingQuestion == nil else { throw MissionError("mission_question", "Answer the planner's question before approving the map.") }
            if mission.approvedPlanRevision != nil { return mission }
            try mission.draft.validateForApproval()
            try self.validateMissionSpaces(mission.draft)
            mission.revision += 1
            mission.approvedPlanRevision = mission.revision
            try mission.validate()
            try self.mutateState { state in
                state.missions = state.missions.map { $0.id == id ? mission : $0 }
            }
            return mission
        }
    }

    /// Removes planning metadata only; it never deletes a repository, checkout or thread.
    public func deleteMission(id: MissionID, expectedRevision: UInt64) async throws {
        try await enqueue {
            let mission = try self.missionForMutation(id, expectedRevision: expectedRevision)
            guard mission.run?.phase.active != true else { throw MissionError("mission_busy", "Stop the mission before removing it.") }
            // Ownership also prevents ordinary thread restoration from relaunching mission workers.
            guard mission.run?.attempts.isEmpty ?? true else { throw MissionError("mission_has_history", "Retain this mission's execution history. Removing it would orphan its worker threads.") }
            try self.mutateState { $0.missions.removeAll { $0.id == id } }
        }
    }

    /// Human controls carry the displayed revision. A new run ID fences all late completions.
    public func setMissionRun(id: MissionID, expectedRevision: UInt64, run: MissionRun) async throws -> Mission {
        try await enqueue {
            var mission = try self.missionForMutation(id, expectedRevision: expectedRevision)
            if run.phase == .running {
                guard mission.approvedPlanRevision != nil, mission.run?.pendingQuestion == nil, run.pendingQuestion == nil else { throw MissionError("mission_unapproved", "Answer open questions and approve the current map before launching.") }
                try mission.draft.validateForApproval()
                try self.validateMissionSpaces(mission.draft)
            }
            if run.phase == .publishing {
                guard let previous = mission.run,
                      [.review, .paused, .publishing].contains(previous.phase) || (previous.phase == .stopped && previous.publicationApproval != nil),
                      run.reviewFingerprint != nil, run.reviewFingerprint == previous.reviewFingerprint,
                      previous.phase != .publishing || (run.id == previous.id && previous.publicationApproval != nil) else {
                    throw MissionError("stale_mission", "Review and validate the current changes before publishing.")
                }
            }
            // Attempts are the mission's ownership receipts (its threads stay out of ordinary lists and never
            // restart as ordinary work): a new run keeps every recorded attempt and the agent it reserved.
            if let previous = mission.run {
                let next = Dictionary(run.attempts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for attempt in previous.attempts {
                    guard let kept = next[attempt.id] else {
                        throw MissionError("mission_history", "A mission run cannot drop a recorded attempt; its thread would lose its owner.")
                    }
                    guard attempt.agentID == nil || kept.agentID == attempt.agentID else {
                        throw MissionError("mission_history", "A recorded attempt's agent cannot change.")
                    }
                }
            }
            mission.run = run
            if run.phase == .planning { mission.approvedPlanRevision = nil }
            mission.revision += 1
            try self.storeMission(mission)
            return mission
        }
    }

    /// Progress is serialized against the current run, rather than overwriting another lane's receipt.
    public func updateMissionRun(id: MissionID, runID: UUID,
                                 update: @escaping @Sendable (inout MissionRun) throws -> Void) async throws -> Mission {
        try await enqueue {
            try self.requireStarted()
            guard var mission = self.store.state.missions.first(where: { $0.id == id }),
                  var run = mission.run, run.id == runID, run.phase.active else {
                throw MissionError("mission_stopped", "This mission run is no longer active.")
            }
            try update(&run)
            guard run.id == runID else { throw MissionError("stale_mission", "A progress update cannot replace its run identity.") }
            mission.run = run
            mission.revision += 1
            try self.storeMission(mission)
            return mission
        }
    }

    /// Sends only after the selected model and a fresh, idle session are confirmed. The reservation is durable first.
    public func sendMissionPrompt(id: MissionID, runID: UUID, agentID: AgentID, prompt: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.requireStarted()
                    guard var mission = self.store.state.missions.first(where: { $0.id == id }), var run = mission.run,
                          run.id == runID, run.phase.active,
                          let index = run.attempts.firstIndex(where: { $0.agentID == agentID && $0.status == .running }),
                          let agent = self.store.state.agents.first(where: { $0.id == agentID }),
                          let thread = self.rpcThread(forAgent: agentID), thread.isServable, thread.canMoveSpace,
                          let session = thread.piSessionID, let operation = UUID(uuidString: agentID.rawValue),
                          thread.model == agent.model, run.attempts[index].sessionID == nil,
                          thread.history.isEmpty, thread.live.isEmpty else {
                        throw MissionError("mission_send", "The worker is not a fresh, idle session on the selected model. No mission prompt was sent.")
                    }
                    if let reason = run.exhausted(mission.draft.limits, at: Date().timeIntervalSince1970) { throw MissionError("mission_limit", reason) }
                    run.attempts[index].sessionID = session; run.attempts[index].generation = thread.generation
                    mission.run = run; mission.revision += 1
                    try self.storeMission(mission)
                    thread.handle(.send(expectedSessionID: session, generation: thread.generation, operationID: operation,
                                        text: prompt, delivery: .followUp), isolateSend: true) { result in
                        switch result {
                        case .accepted: continuation.resume()
                        case .failure(let code, let message): continuation.resume(throwing: MissionError(code, message))
                        default: continuation.resume(throwing: MissionError("mission_send", "The worker did not accept its mission prompt."))
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// A further turn in a session a running attempt owns: a stock Spec Kit reply or next command
    /// once the turn settled (`.followUp`), or an owner steer while it works (`.steer`). The session
    /// is the attempt's own, or the same agent's earlier attempt's (a persistent planning thread);
    /// the server, not the caller, carries that identity. The new operation is durable first.
    public func sendMissionFollowUp(id: MissionID, runID: UUID, agentID: AgentID, operationID: UUID, text: String) async throws {
        try await sendMissionTurn(id: id, runID: runID, agentID: agentID, operationID: operationID, text: text, steer: false)
    }

    public func sendMissionSteer(id: MissionID, runID: UUID, agentID: AgentID, operationID: UUID, text: String) async throws {
        try await sendMissionTurn(id: id, runID: runID, agentID: agentID, operationID: operationID, text: text, steer: true)
    }

    private func sendMissionTurn(id: MissionID, runID: UUID, agentID: AgentID, operationID: UUID, text: String, steer: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.requireStarted()
                    guard var mission = self.store.state.missions.first(where: { $0.id == id }), var run = mission.run,
                          run.id == runID, run.phase.active,
                          let index = run.attempts.firstIndex(where: { $0.agentID == agentID && $0.status == .running }),
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 128 * 1024,
                          operationID.uuidString.lowercased() != agentID.rawValue,
                          !run.attempts.contains(where: { $0.operationIDs?.contains(operationID) == true }),
                          // A follow-up needs the idle session; a steer needs it working (canMoveSpace is false mid-turn).
                          let thread = self.rpcThread(forAgent: agentID), thread.isServable, steer || thread.canMoveSpace,
                          thread.dialogs.isEmpty, thread.session.isAlive,
                          let session = thread.piSessionID else {
                        throw MissionError("mission_send", "The mission thread is not a live session this attempt owns. Nothing was sent.")
                    }
                    let owned = run.attempts[index].sessionID.map { ($0, run.attempts[index].generation) }
                        ?? run.attempts[..<index].last(where: { $0.agentID == agentID && $0.sessionID != nil }).map { ($0.sessionID!, $0.generation) }
                    // A steer goes only into a run pi can still read it in; a message Shepherd would have to hold
                    // for a later turn is refused, so the person keeps it.
                    guard let owned, owned.0 == session, owned.1 == thread.generation,
                          steer ? (run.attempts[index].sessionID != nil && !thread.actualTurnSettled && thread.canSteerNow) : thread.actualTurnSettled else {
                        throw MissionError("mission_send", steer ? "Only a working mission turn in its own session can be steered."
                                                                 : "The mission thread is not its own settled session. No follow-up was sent.")
                    }
                    if let reason = run.exhausted(mission.draft.limits, at: Date().timeIntervalSince1970) { throw MissionError("mission_limit", reason) }
                    // One unread steer at a time: a second would duplicate words the person may resend after a timeout.
                    if steer, !thread.oneShotSteers.isEmpty {
                        throw MissionError("mission_steer_waiting", "Your previous message to this turn is still waiting to be read. Nothing was sent.")
                    }
                    run.attempts[index].sessionID = session; run.attempts[index].generation = thread.generation
                    run.attempts[index].operationIDs = (run.attempts[index].operationIDs ?? []) + [operationID]
                    mission.run = run; mission.revision += 1
                    try mission.validate()
                    try self.storeMission(mission)
                    if steer { thread.oneShotSteers[operationID] = text }
                    thread.handle(.send(expectedSessionID: session, generation: thread.generation, operationID: operationID,
                                        text: text, delivery: steer ? .steer : .followUp), isolateSend: true) { result in
                        switch result {
                        case .accepted: continuation.resume()
                        case .failure(let code, let message): continuation.resume(throwing: MissionError(code, message))
                        default: continuation.resume(throwing: MissionError("mission_send", "The mission thread did not accept the message."))
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// `threadClosed`: the thread is gone (its turn settled and the mission stopped it, or Stop); the
    /// attempt's own record then says what happened.
    public enum MissionSteerOutcome: Sendable, Equatable { case queued, consumed, undelivered, threadClosed }

    /// What became of a steer pi acknowledged: still queued, read (its user message is in the thread), or
    /// left unread when the run ended or stopped. An acknowledgement alone is never "consumed".
    public func missionSteerOutcome(agentID: AgentID, operationID: UUID) async -> MissionSteerOutcome {
        (try? await enqueue {
            guard let thread = self.rpcThread(forAgent: agentID) else { return .threadClosed }
            let receipt = self.store.state.missions.lazy.compactMap { $0.run?.attempts.first { $0.agentID == agentID && $0.operationIDs?.contains(operationID) == true } }.first
            if thread.operationsByEntry.values.contains(operationID) || receipt?.deliveredOperationIDs?.contains(operationID) == true { return .consumed }
            if thread.undeliveredSteers.contains(operationID) || !thread.session.isAlive { return .undelivered }
            return .queued
        }) ?? .undelivered
    }

    /// pi read a mission's owned follow-up or steer: a durable receipt, written as the user message arrives,
    /// so the outcome survives the thread closing or an immediate Stop.
    func missionSteerConsumed(agentID: AgentID, operation: UUID) {
        guard var mission = store.state.missions.first(where: { $0.run?.attempts.contains { $0.agentID == agentID && $0.operationIDs?.contains(operation) == true } == true }),
              var run = mission.run,
              let index = run.attempts.firstIndex(where: { $0.agentID == agentID && $0.operationIDs?.contains(operation) == true }),
              run.attempts[index].deliveredOperationIDs?.contains(operation) != true else { return }
        run.attempts[index].deliveredOperationIDs = (run.attempts[index].deliveredOperationIDs ?? []) + [operation]
        mission.run = run; mission.revision += 1
        do { try storeMission(mission) } catch { ShepherdLog.warning("Mission steer receipt not saved: \(error)") }
    }

    /// Whether a mission's earlier planning thread is still a live, servable session it could continue.
    public func missionAgentIsLive(id: MissionID, agentID: AgentID) async -> Bool {
        (try? await enqueue {
            guard self.store.state.missions.first(where: { $0.id == id })?.run?.attempts.contains(where: { $0.agentID == agentID }) == true,
                  let thread = self.rpcThread(forAgent: agentID) else { return false }
            return thread.session.isAlive && thread.isServable && thread.canMoveSpace && thread.dialogs.isEmpty
        }) ?? false
    }

    /// Consults actual RPC settlement after Changes capture, never the display status or startup idle.
    public func missionAgentSnapshot(id: MissionID, runID: UUID, agentID: AgentID) async throws -> MissionAgentSnapshot {
        try await enqueue {
            guard let run = self.store.state.missions.first(where: { $0.id == id })?.run,
                  run.id == runID, run.phase.active, run.attempts.contains(where: { $0.agentID == agentID && $0.status == .running }) else {
                throw MissionError("mission_stopped", "The worker no longer belongs to an active mission attempt.")
            }
            guard let thread = self.rpcThread(forAgent: agentID) else { return MissionAgentSnapshot() }
            var result = MissionAgentSnapshot()
            result.ready = thread.isServable && thread.canMoveSpace
            let attempt = run.attempts.first { $0.agentID == agentID && $0.status == .running }
            if let session = attempt?.sessionID, session != thread.piSessionID || attempt?.generation != thread.generation {
                result.error = "The worker process changed. Its old prompt will not be replayed automatically."
            }
            result.promptTemplates = thread.promptTemplatePaths
            result.tokens = thread.stats?.totalTokens
            result.cost = thread.stats?.cost
            result.text = thread.lastTurnAssistant?.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n") ?? ""
            // Settled messages move from `live` into `history`; the turn is everything after its prompt in either.
            let messages = thread.history + thread.live.map(\.value)
            if let prompt = messages.lastIndex(where: { $0.role == "user" }) {
                result.turnText = messages[(prompt + 1)...].filter { $0.role == "assistant" }
                    .map { $0.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n") }
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            let user = thread.live.last(where: { $0.value.role == "user" })?.value.entryID
                ?? thread.history.last(where: { $0.role == "user" })?.entryID
            let operation = user.flatMap { thread.operationsByEntry[$0] }
            let first = UUID(uuidString: agentID.rawValue)
            // A steer the run ended without reading is not the turn to wait for.
            result.undelivered = (attempt?.operationIDs ?? []).filter { thread.undeliveredSteers.contains($0) }
            let expected = attempt?.operationIDs?.last { !thread.undeliveredSteers.contains($0) } ?? first
            // An earlier owned turn may still be the last user entry while a newer send is in flight.
            let owned = Set([first].compactMap { $0 } + run.attempts.filter { $0.agentID == agentID }.flatMap { $0.operationIDs ?? [] })
            if let operation, !owned.contains(operation) { result.error = "The worker conversation changed outside this mission. Inspect it before continuing." }
            if !thread.session.isAlive { result.error = "The worker exited before its result could be collected. Open its thread for details." }
            if !thread.dialogs.isEmpty { result.error = "The worker needs an answer. Inspect its thread, then add the answer to the mission and revise the map." }
            result.settled = thread.actualTurnSettled && thread.canMoveSpace && operation == expected
            if result.settled && thread.runFailed { result.error = "The model turn failed. Open the worker thread for the provider's error." }
            if result.settled && thread.lastTurnAssistant?.truncated == true { result.error = "The worker result was truncated. Ask for a smaller plan or result." }
            return result
        }
    }

    /// Stops only processes reserved for this run. Worktrees, branches, evidence and threads stay intact.
    public func stopMissionAgents(id: MissionID, runID: UUID) async {
        _ = try? await enqueue {
            guard let run = self.store.state.missions.first(where: { $0.id == id })?.run, run.id == runID else { return }
            for attempt in run.attempts where attempt.status == .running || attempt.status == .interrupted {
                guard let agent = attempt.agentID, let thread = self.rpcThread(forAgent: agent) else { continue }
                thread.cancelPreparingPrompts()
                self.killSession(thread.session.id)
            }
        }
    }

    private func storeMission(_ mission: Mission) throws {
        try mission.validate()
        try mutateState { state in state.missions = state.missions.map { $0.id == mission.id ? mission : $0 } }
    }

    private func missionForMutation(_ id: MissionID, expectedRevision: UInt64) throws -> Mission {
        try requireStarted()
        guard let mission = store.state.missions.first(where: { $0.id == id }) else {
            throw MissionError("no_such_mission", "Mission no longer exists on this host.")
        }
        guard mission.revision == expectedRevision else {
            throw MissionError("stale_mission", "Mission changed. Refresh before trying again.")
        }
        return mission
    }

    private func validateMissionSpaces(_ draft: MissionDraft) throws {
        let available = Set(store.state.spaces.filter { !$0.hidden && !$0.holdsDesigns && !$0.holdsProjects }.map(\.id))
        guard draft.plan?.lanes.allSatisfy({ available.contains($0.spaceID) }) ?? true else {
            throw MissionError("no_such_space", "Choose existing visible Spaces on the Mission owner.")
        }
    }
}
