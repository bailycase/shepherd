import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// Which planner a new Mission uses. Records keep theirs: a run without `specKit` is the map runner.
enum MissionBackend: Sendable { case specKit, legacyMap }

/// A station's own native thread for the Missions page: the agent's existing store (no session host is
/// mounted, the deck is untouched), reads only, and a send that goes through the mission when the turn
/// can take one.
struct MissionThreadSource {
    var agentID: AgentID
    var store: NativeThreadStore
    var request: NativeThreadStore.Request
    /// The step's transcript from its pi session file on disk: what a finished (stopped) step shows.
    var preview: NativeThreadStore.Preview?
    /// Steers a working turn; nil when the attempt has settled or is not the mission's to steer.
    var send: ((String) async throws -> Void)?
}

/// Stock GitHub Spec Kit, run through each repository's own `.pi/prompts/speckit.*.md`. Shepherd sends
/// the same invocation upstream's pi integration builds, in native threads, and reads the artifacts the
/// project's commands wrote. Owner consent, approval, limits and publication stay the host's.
extension MissionController {
    static let specKitFileLimit = 4_000, specKitFileBytes = 2 << 20, specKitTotalBytes = 32 << 20

    func isSpecKit(_ id: MissionID) -> Bool { (try? record(id))?.run?.specKit != nil }

    // MARK: Owner actions

    /// Re-reads each repository's stock files from its mission worktree. Reads only.
    @discardableResult
    func specKitPreflight(id: MissionID) async throws -> [SpaceID: SpecKitPreflight] {
        let mission = try record(id)
        guard let run = mission.run, run.specKit != nil else { throw MissionError("mission_mode", "This mission does not use Spec Kit.") }
        var reports: [SpaceID: SpecKitPreflight] = [:]
        for checkout in run.checkouts { reports[checkout.spaceID] = try await Self.preflight(checkout.path) }
        specKitReports[id] = reports
        return reports
    }

    /// Explicit owner consent for one repository to load its own stock prompts (`--prompt-template`, which
    /// bypasses pi's project-trust decision), bound to the files as they are now. Any later change voids it.
    /// `continuePlanning`: the owner's explicit "and continue planning". Only then, and only once every repository is
    /// allowed, does planning start; consent on its own sends nothing.
    func grantSpecKitConsent(id: MissionID, revision: UInt64, space: SpaceID, fingerprint: String, continuePlanning: Bool = false) async throws {
        let mission = try record(id)
        guard mission.revision == revision, var run = mission.run, !run.phase.active, jobs[id] == nil,
              let lane = run.specKit?.lanes.firstIndex(where: { $0.spaceID == space }),
              let checkout = run.checkouts.first(where: { $0.spaceID == space }) else {
            throw MissionError("stale_mission", "The mission changed. Review the current Spec Kit files before consenting.")
        }
        let report = try await Self.preflight(checkout.path)
        specKitReports[id, default: [:]][space] = report
        guard report.status == .ready else { throw MissionError("speckit_not_ready", Self.describe(report)) }
        guard report.consentFingerprint == fingerprint else {
            throw MissionError("speckit_changed", "The repository's Spec Kit files changed since you reviewed them. Review them again.")
        }
        run.specKit?.lanes[lane].consentFingerprint = fingerprint
        let saved = try await server.setMissionRun(id: id, expectedRevision: revision, run: run)
        if continuePlanning, saved.run?.specKit?.lanes.allSatisfy({ $0.consentFingerprint != nil }) == true {
            try await continueSpecKitPlanning(id, revision: saved.revision)
        }
    }

    /// Sends one stock planning command to every repository in turn, each in its own persistent planning thread.
    func runSpecKit(id: MissionID, revision: UInt64, command: SpecKitCommand, arguments: String = "") async throws {
        guard ![.implement, .converge].contains(command) else {
            throw MissionError("speckit_command", "Implement and converge run after Launch approves the artifacts.")
        }
        let mission = try record(id)
        guard mission.revision == revision else { throw MissionError("stale_mission", "The mission changed. Review it before sending a command.") }
        let goal = arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && command == .specify ? mission.draft.goal : arguments
        try await startSpecKitPlanning(id, turns: (mission.run?.checkouts ?? []).map { ($0.spaceID, command, command.invocation(Self.safeText(goal, bytes: 16_000)), nil) })
    }

    /// The owner's answer to a planner question. Persists which message it answers and the suggestion picked.
    /// A Spec Kit answer goes only to the repository thread that asked.
    func answer(id: MissionID, revision: UInt64, text: String, choice: String? = nil, replyTo: UUID? = nil) async throws {
        let mission = try record(id)
        let text = Self.safeText(text.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 16_000)
        guard mission.revision == revision, var run = mission.run, !run.phase.active, jobs[id] == nil, !text.isEmpty else {
            throw MissionError("stale_mission", "The mission changed. Answer the current question.")
        }
        let latest = replyTo.flatMap({ reply in run.messages.first { $0.id == reply } }) ?? run.messages.last(where: { $0.role == .assistant })
        // Spec Kit feedback needs no earlier planner message; it starts the conversation if there is none.
        guard let target = latest ?? (run.specKit != nil ? MissionChatMessage(role: .assistant, text: "") : nil),
              target.role == .assistant else { throw MissionError("mission_answer", "There is no planner message to answer.") }
        let picked = choice.flatMap { value in target.choices?.contains(value) == true ? value : nil }
        let message = MissionChatMessage(role: .user, text: text, replyTo: target.id, choice: picked, spaceID: target.spaceID)
        if run.specKit != nil {
            // An outstanding question binds the reply to exactly that question and repository.
            if run.pendingQuestion != nil {
                guard let asked = run.messages.last(where: { $0.role == .assistant && $0.question != nil }),
                      replyTo == nil || replyTo == asked.id else {
                    throw MissionError("stale_mission", "That question was already answered or replaced. Answer the current one.")
                }
                let bound = MissionChatMessage(role: .user, text: text, replyTo: asked.id, choice: picked, spaceID: asked.spaceID)
                try await continueSpecKitPlanning(id, revision: revision, reply: (asked.spaceID, bound))
            } else {
                // General feedback: the planning conversation of the repository it answers, else every repository.
                try await continueSpecKitPlanning(id, revision: revision, reply: (replyTo == nil ? nil : target.spaceID, message))
            }
            return
        }
        run.messages.append(message)
        run.messages = Array(run.messages.suffix(40))
        let saved = try await server.setMissionRun(id: id, expectedRevision: revision, run: run)
        _ = saved
        try await plan(id: id)
    }

    /// The owner read the real /speckit.converge report and accepts it. An acknowledgement, never test evidence.
    func acceptConvergence(id: MissionID, revision: UInt64, attemptID: UUID) async throws {
        let mission = try record(id)
        guard mission.revision == revision, var run = mission.run, !run.phase.active, jobs[id] == nil,
              let lane = run.specKit?.lanes.firstIndex(where: { $0.convergence?.attemptID == attemptID }),
              let convergence = run.specKit?.lanes[lane].convergence, !convergence.accepted,
              convergence.outcome != .tasksAppended, convergence.outcome != .missing,
              run.attempts.first(where: { $0.id == attemptID })?.status == .succeeded else {
            throw MissionError("speckit_converge", "Only a finished converge report that added no tasks can be accepted. Rerun or request changes.")
        }
        run.specKit?.lanes[lane].convergence?.accepted = true
        // Repositories finish side by side: while another report or appended task list still waits, accepting this one
        // approves nothing else and starts no work. The last acceptance continues.
        let waiting = run.specKit?.lanes.filter { $0.convergence.map { !$0.accepted } ?? false } ?? []
        if !waiting.isEmpty { run.notice = Self.specKitWaitingNotice(mission, waiting: waiting) }
        _ = try await server.setMissionRun(id: id, expectedRevision: revision, run: run)
        guard waiting.isEmpty else { return }
        try await launch(id: id, revision: try record(id).revision)
    }

    /// Steers a working mission turn in its own session. The server owns the session identity and limits.
    func steer(id: MissionID, revision: UInt64, attemptID: UUID, text: String) async throws {
        let mission = try record(id)
        let text = Self.safeText(text.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 16_000)
        guard mission.revision == revision || mission.run?.phase.active == true, let run = mission.run, run.phase.active,
              let attempt = run.attempts.first(where: { $0.id == attemptID }), attempt.status == .running,
              let agent = attempt.agentID, !text.isEmpty else {
            throw MissionError("mission_steer", "Only a working mission turn can be steered.")
        }
        let operation = UUID()
        try await server.sendMissionSteer(id: id, runID: run.id, agentID: agent, operationID: operation, text: text)
        // pi's acknowledgement only means queued. Wait (bounded) for it to be read, or for the run to end without it.
        let undelivered = MissionError("mission_steer_undelivered", "The turn ended before the agent read your message, so it was not delivered. Your words were kept.")
        let deadline = Self.now + Self.steerOutcomeSeconds
        while Self.now < deadline {
            switch await server.missionSteerOutcome(agentID: agent, operationID: operation) {
            case .consumed: return
            case .undelivered:
                try? await recordUndelivered(id, runID: run.id, attemptID: attemptID, operations: [operation])
                throw undelivered
            case .queued: try await Task.sleep(for: .milliseconds(250))
            case .threadClosed:
                // Only receipts decide: read (written as pi's user message arrived) or unread (written at the
                // turn's end). With neither, Shepherd does not know, and says so.
                let receipt = server.state.missions.first { $0.id == id }?.run?.attempts.first { $0.id == attemptID }
                if receipt?.deliveredOperationIDs?.contains(operation) == true { return }
                if receipt?.undeliveredOperationIDs?.contains(operation) == true { throw undelivered }
                if receipt?.status == .running { try await Task.sleep(for: .milliseconds(250)); continue }
                throw MissionError("mission_steer_unknown", "Shepherd could not confirm whether the agent read your message. Your words were kept; check its thread before sending them again.")
            }
        }
        // Still queued with pi at the bound: not read yet. The words stay with the person; a second steer is
        // refused while this one waits, and the turn's end records whether it was read.
        throw MissionError("mission_steer_pending", "The agent has not read your message yet. It is still queued for this turn, so your words were kept; nothing more was sent.")
    }

    /// How long a steer call waits for pi to read the message. Tests shorten it.
    static var steerOutcomeSeconds: Double = 300

    nonisolated static func undeliveredNote(_ count: Int) -> String {
        "\(count == 1 ? "A steer was" : "\(count) steers were") not delivered: the turn ended before the agent read it."
    }

    func recordUndelivered(_ id: MissionID, runID: UUID, attemptID: UUID, operations: [UUID]) async throws {
        guard !operations.isEmpty else { return }
        _ = try await server.updateMissionRun(id: id, runID: runID) { value in
            guard let index = value.attempts.firstIndex(where: { $0.id == attemptID }) else { return }
            let known = value.attempts[index].undeliveredOperationIDs ?? []
            let added = operations.filter { !known.contains($0) }
            guard !added.isEmpty else { return }
            value.attempts[index].undeliveredOperationIDs = known + added
            value.attempts[index].output = MissionController.safeText(value.attempts[index].output + "\n\n" + MissionController.undeliveredNote(added.count))
        }
    }

    func thread(for attemptID: UUID) -> MissionThreadSource? {
        // Nil until the reserved agent is in the app's own state: a store made before then is orphaned
        // (pruned with no agent) and never polls. The Run inspector re-reads when the agent appears.
        guard let vm, let (mission, attempt) = server.state.missions.lazy.compactMap({ mission in
            mission.run?.attempts.first { $0.id == attemptID }.map { (mission, $0) }
        }).first, let agentID = attempt.agentID, let agent = vm.state.agents.first(where: { $0.id == agentID }) else { return nil }
        let cwd = agent.worktreePath ?? mission.run?.checkouts.first?.path
        let preview = cwd.map { PiSessionFile.previewLoader(sessionID: agent.effectivePiSessionID, cwd: $0, sessionsRoot: vm.server.pi.sessionsRoot) }
        let server = server, missionID = mission.id
        let request: NativeThreadStore.Request = { value in
            switch value {
            case .snapshot, .image, .subagentTranscript:
                let result = try await server.nativeThread(agentID: agentID, request: value)
                // The server offers a mission thread no actions of its own. While the mission can steer this turn,
                // the composer may send; its send is the source's `send` (the server-owned steer), never this request.
                let run = server.state.missions.first { $0.id == missionID }?.run
                guard case .snapshot(var snapshot) = result, run?.phase.active == true,
                      run?.attempts.first(where: { $0.id == attemptID })?.status == .running else { return result }
                snapshot.supportedActions.append("send")
                return .snapshot(value: snapshot)
            default: throw MissionError("mission_thread", "Mission threads take messages through the mission.")
            }
        }
        let steerable = attempt.status == .running && mission.run?.phase.active == true
        return MissionThreadSource(agentID: agentID, store: vm.threadStores.store(for: agentID), request: request, preview: preview,
                                   send: steerable ? { [weak self] text in
                                       guard let self else { return }
                                       try await self.steer(id: mission.id, revision: try self.record(mission.id).revision, attemptID: attemptID, text: text)
                                   } : nil)
    }

    // MARK: Planning

    // MARK: Conversational planning

    /// Planning bounds. Turns per owner action and per mission count stock commands and replies; clarify rounds are
    /// per repository across the whole mission (from its receipts), so asking again never resets them.
    /// Per repository: the whole stock flow is constitution, specify, plan, tasks and analyze plus clarify rounds.
    static var planningTurnsPerCall = 12, planningTurnsPerMission = 60, planningTurnsCap = 96, clarifyRounds = 5

    /// The owner talks; the planner picks the stock steps. `reply` (repository or nil for all, the owner's message)
    /// goes first into that planning conversation; then each repository advances through specify → clarify while its
    /// spec marks questions → plan → tasks, re-reading its own files before every step. Stops at a question, a step that
    /// produced nothing, missing trust, a bound, or the ready map. Never resumes on its own.
    func continueSpecKitPlanning(_ id: MissionID, revision: UInt64, reply: (SpaceID?, MissionChatMessage)? = nil) async throws {
        var mission = try record(id)
        guard mission.revision == revision, var run = mission.run, let lanes = run.specKit?.lanes, !run.phase.active, jobs[id] == nil else {
            throw MissionError("stale_mission", "The mission changed. Review it before continuing.")
        }
        if let reason = run.exhausted(mission.draft.limits, at: Self.now) { throw MissionError("mission_limit", reason) }
        guard run.publicationApproval == nil else { throw MissionError("mission_published", "This mission has authorized publication.") }
        guard lanes.allSatisfy({ $0.consentFingerprint != nil }) else {
            throw MissionError("speckit_consent", "Allow every repository's Spec Kit files first. Nothing was sent.")
        }
        if let message = reply?.1 { run.messages.append(message); run.messages = Array(run.messages.suffix(40)) }
        run.pendingQuestion = nil; run.pendingChoices = nil
        run.id = UUID(); run.reviewFingerprint = nil
        // Planning clears map approval (server): implementation needs Launch again after any change.
        run.transition(to: .planning, at: Self.now)
        mission = try await server.setMissionRun(id: id, expectedRevision: mission.revision, run: run)
        let runID = run.id, spaces = lanes.map(\.spaceID)
        schedule(id: id, runID: runID) { try await self.planSpecKit(id, runID: runID, spaces: spaces, reply: reply.map { ($0.0, $0.1.text) }) }
    }

    enum PlanningStop { case question(SpaceID, String), blocked(SpaceID, String), ready }

    func planSpecKit(_ id: MissionID, runID: UUID, spaces: [SpaceID], reply: (SpaceID?, String)?) async throws {
        var turns = 0
        // Steps this owner action already ran. A step that ran and wrote nothing stops planning; the owner's next reply
        // or Continue runs it again (bounded by the turn limits), so "continue" always makes progress.
        var ran: Set<String> = []
        func turn(_ space: SpaceID, _ command: SpecKitCommand?, _ text: String) async throws -> String {
            let mission = try record(id, runID: runID)
            let used = mission.run?.attempts.filter { $0.command != nil && $0.command != .implement && $0.command != .converge }.count ?? 0
            // Per repository, capped below the run's 160-receipt record limit so execution keeps room for its receipts.
            let perCall = Self.planningTurnsPerCall * spaces.count
            let perMission = min(Self.planningTurnsPerMission * spaces.count, Self.planningTurnsCap)
            guard turns < perCall else {
                throw MissionError("speckit_turn_limit", "Planning reached \(perCall) steps for this request. Reply or continue to go on.")
            }
            guard used < perMission else {
                throw MissionError("speckit_turn_limit", "Planning reached this mission's \(perMission)-step limit. Start a new mission or narrow the request.")
            }
            turns += 1
            if let command { ran.insert("\(space.rawValue)/\(command.rawValue)") }
            let lane = mission.run?.specKit?[space]
            var reuse = lane?.plannerAgentID
            if let agent = reuse, !(await server.missionAgentIsLive(id: id, agentID: agent)) { reuse = nil }
            // A reply belongs to the step it answers (a clarify answer is a clarify round).
            let answering = mission.run?.attempts.last { $0.agentID != nil && $0.agentID == lane?.plannerAgentID }?.command
            var text = text
            if command == nil, reuse == nil, let asked = mission.run?.messages.last(where: { $0.role == .assistant && $0.spaceID == space }) {
                // The planning session ended (the app quit): a new one gets what it is answering, not a bare reply.
                text = Self.safeText("You are continuing this repository's Spec Kit planning in a new session. Your last message to the owner was:\n\n"
                                     + asked.text + "\n\nThe owner replies:\n\n" + text, bytes: 64_000)
            }
            let result = try await specKitTurn(id, runID: runID, space: space, command: command, text: text, reuse: reuse, keepAlive: true,
                                               replyCommand: command == nil ? answering : nil)
            _ = try await server.updateMissionRun(id: id, runID: runID) { value in
                value.messages.append(.init(role: .assistant, text: Self.safeText(result.text, bytes: 16_000), spaceID: space))
                value.messages = Array(value.messages.suffix(40))
                if let index = value.specKit?.lanes.firstIndex(where: { $0.spaceID == space }) { value.specKit?.lanes[index].plannerAgentID = result.agentID }
            }
            return result.text
        }
        func files(_ space: SpaceID) throws -> (feature: String?, spec: String?, plan: String?, tasks: String?, constitution: String?) {
            let mission = try record(id, runID: runID)
            guard let checkout = mission.run?.checkouts.first(where: { $0.spaceID == space }) else { throw MissionError("mission_worktree", "The repository's worktree is missing.") }
            let feature = mission.run?.specKit?[space]?.featureDirectory ?? Self.featureDirectory(checkout.path)
            func read(_ name: String) -> String? {
                feature.flatMap { try? Data(contentsOf: Self.resolved(checkout.path, "\($0)/\(name)")) }.map { String(decoding: $0, as: UTF8.self) }
            }
            let constitution = (try? Data(contentsOf: Self.resolved(checkout.path, ".specify/memory/constitution.md"))).map { String(decoding: $0, as: UTF8.self) }
            return (feature, read("spec.md"), read("plan.md"), read("tasks.md"), constitution)
        }
        func ranNow(_ space: SpaceID, _ command: SpecKitCommand) -> Bool { ran.contains("\(space.rawValue)/\(command.rawValue)") }
        func receipt(_ space: SpaceID, _ command: SpecKitCommand) throws -> Bool {
            let station = SpecKit.stationID(id, space, command.planningStation)
            return try record(id, runID: runID).run?.attempts.contains { $0.stationID == station && $0.command == command && $0.status == .succeeded } == true
        }
        /// /speckit.analyze ran on the current task list: its receipt is newer than the latest tasks receipt.
        func analyzed(_ space: SpaceID) throws -> Bool {
            let station = SpecKit.stationID(id, space, SpecKitCommand.tasks.planningStation)
            let attempts = try record(id, runID: runID).run?.attempts ?? []
            func last(_ command: SpecKitCommand) -> Int? { attempts.lastIndex { $0.stationID == station && $0.command == command && $0.status == .succeeded } }
            guard let tasks = last(.tasks), let analysis = last(.analyze) else { return false }
            return analysis > tasks
        }
        func supersede(_ space: SpaceID, _ commands: [SpecKitCommand]) async throws {
            _ = try await server.updateMissionRun(id: id, runID: runID) { value in
                for index in value.attempts.indices where value.attempts[index].status == .succeeded {
                    guard let command = value.attempts[index].command, commands.contains(command),
                          value.attempts[index].stationID == SpecKit.stationID(id, space, command.planningStation) else { continue }
                    value.attempts[index].status = .superseded
                }
            }
        }
        func stop(_ outcome: PlanningStop) async throws {
            let saved = try await server.updateMissionRun(id: id, runID: runID) { value in
                switch outcome {
                case .question(let space, let text):
                    let question = Self.safeText(text.isEmpty ? "The planner is waiting for your answer." : text)
                    if let index = value.messages.lastIndex(where: { $0.role == .assistant && $0.spaceID == space }) { value.messages[index].question = question }
                    value.pendingQuestion = question
                    value.transition(to: .map, at: Self.now, notice: question)
                case .blocked(let space, let notice):
                    value.pendingQuestion = Self.safeText(notice)
                    // On that repository's own last message, so the answer goes to its planning thread.
                    if let index = value.messages.lastIndex(where: { $0.role == .assistant && $0.spaceID == space }) {
                        value.messages[index].question = Self.safeText(notice)
                    } else {
                        value.messages.append(.init(role: .assistant, text: Self.safeText(notice), question: Self.safeText(notice), spaceID: space))
                    }
                    value.transition(to: .map, at: Self.now, notice: Self.safeText(notice))
                case .ready:
                    value.transition(to: .map, at: Self.now, notice: "The map is ready. Review it, then Launch to approve implementation. No implementation has started.")
                }
            }
            try await refreshSpecKitProjection(id, revision: saved.revision)
        }

        // 1. The owner's words go into the planning conversation first. What they changed decides what is rebuilt.
        if let (target, text) = reply {
            for space in target.map({ [$0] }) ?? spaces {
                let before = try files(space)
                let answer = try await turn(space, nil, text)
                let after = try files(space)
                // By content: a rewritten plan.md or tasks.md (not just one that appeared) makes what follows stale.
                if before.spec != after.spec { try await supersede(space, [.plan, .tasks, .analyze]) }
                else if before.plan != after.plan { try await supersede(space, [.tasks, .analyze]) }
                else if before.tasks != after.tasks || before.constitution != after.constitution { try await supersede(space, [.analyze]) }
                // Inside clarify, a reply that leaves questions marked gets clarify's next question back.
                let clarifying = try record(id, runID: runID).run?.attempts.last { $0.stationID == SpecKit.stationID(id, space, "specify") }?.command == .clarify
                if clarifying, let spec = after.spec, SpecKit.parseSpec(spec).clarificationsNeeded > 0 {
                    let rounds = try record(id, runID: runID).run?.attempts.filter { $0.command == .clarify && $0.stationID == SpecKit.stationID(id, space, "specify") }.count ?? 0
                    if rounds < Self.clarifyRounds { return try await stop(.question(space, answer)) }
                }
            }
        }
        // 2. Each repository through the stock steps, in order. Markers in its files are data, never instructions.
        for space in spaces {
            while true {
                let state = try files(space)
                let name = try record(id, runID: runID).draft.plan?.lanes.first { $0.spaceID == space }?.name ?? "this repository"
                let step: SpecKitCommand
                if SpecKit.constitutionNeedsWriting(state.constitution) {
                    // A fresh project's constitution is upstream's template: write it first, since plan and analyze
                    // check everything against it. It asks only what the repository can't answer.
                    guard !ranNow(space, .constitution) else {
                        return try await stop(.blocked(space, "\(name)'s constitution still has template placeholders. Reply with the principles the project should follow, or with what to infer them from."))
                    }
                    step = .constitution
                } else if state.spec == nil {
                    guard !ranNow(space, .specify) else {
                        return try await stop(.blocked(space, "The planner finished writing the spec for \(name) without a spec.md. Reply with what to change, or Continue planning to try again."))
                    }
                    step = .specify
                } else if SpecKit.parseSpec(state.spec!).clarificationsNeeded > 0 {
                    let rounds = try record(id, runID: runID).run?.attempts.filter { $0.command == .clarify && $0.stationID == SpecKit.stationID(id, space, "specify") }.count ?? 0
                    guard rounds < Self.clarifyRounds else {
                        return try await stop(.blocked(space, "\(name)'s spec still needs clarification after \(Self.clarifyRounds) rounds. Reply with the decisions, or start a narrower mission."))
                    }
                    step = .clarify
                } else if try state.plan == nil || !receipt(space, .plan) {
                    if state.plan == nil && ranNow(space, .plan) {
                        return try await stop(.blocked(space, "The planner finished planning \(name) without writing plan.md. Reply with what to change, or Continue planning to try again."))
                    }
                    step = .plan
                } else if try (state.tasks.map(SpecKit.parseTasks) ?? []).isEmpty || !receipt(space, .tasks) {
                    if (state.tasks.map(SpecKit.parseTasks) ?? []).isEmpty && ranNow(space, .tasks) {
                        return try await stop(.blocked(space, "The planner finished \(name)'s task breakdown without a task list. Reply with what to change, or Continue planning to try again."))
                    }
                    step = .tasks
                } else if try !analyzed(space) {
                    // Upstream's consistency pass across spec, plan, tasks and the constitution. Read-only.
                    step = .analyze
                } else { break }
                let goal = try record(id, runID: runID).draft.goal
                let arguments: String = switch step {
                case .specify: Self.safeText(goal, bytes: 16_000)
                case .constitution: Self.safeText("Infer the principles from this repository's existing code, docs and conventions; ask only what it can't answer. The first feature: " + goal, bytes: 16_000)
                default: ""
                }
                let reply = try await turn(space, step, step.invocation(arguments))
                if step == .analyze, SpecKit.analysisFoundCritical(reply) {
                    // Upstream recommends resolving CRITICAL findings before implement. You decide: reply with changes
                    // (a changed spec, plan or task list runs analyze again), or reply to go ahead (this analysis stays
                    // current, so it isn't rerun and doesn't stop again).
                    return try await stop(.question(space, reply))
                }
                if step == .clarify, let spec = try files(space).spec, SpecKit.parseSpec(spec).clarificationsNeeded > 0 {
                    // clarify asks one question per turn and waits: its own reply is the question.
                    return try await stop(.question(space, reply))
                }
                if step == .specify, try files(space).spec == nil {
                    return try await stop(.blocked(space, "The planner finished writing the spec for \(name) without a spec.md. Reply with what to change, or Continue planning to try again."))
                }
            }
        }
        try await stop(.ready)
    }

    /// Each turn: repository, the stock command it sends (nil for a reply), the text, the owner message to persist.
    func startSpecKitPlanning(_ id: MissionID, turns: [(SpaceID, SpecKitCommand?, String, MissionChatMessage?)]) async throws {
        var mission = try record(id)
        guard var run = mission.run, run.specKit != nil, !run.phase.active, jobs[id] == nil else {
            throw MissionError("mission_busy", "Wait for the current operation or pause it first.")
        }
        if let reason = run.exhausted(mission.draft.limits, at: Self.now) { throw MissionError("mission_limit", reason) }
        guard run.publicationApproval == nil else { throw MissionError("mission_published", "This mission has authorized publication.") }
        for (space, _, _, _) in turns {
            guard run.specKit?[space]?.consentFingerprint != nil else {
                throw MissionError("speckit_consent", "Review and consent to each repository's Spec Kit files first. Nothing was sent.")
            }
        }
        for (space, _, text, message) in turns {
            run.messages.append(message ?? .init(role: .user, text: Self.safeText(text, bytes: 16_000), spaceID: space))
        }
        run.messages = Array(run.messages.suffix(40))
        run.id = UUID(); run.reviewFingerprint = nil
        run.transition(to: .planning, at: Self.now)
        mission = try await server.setMissionRun(id: id, expectedRevision: mission.revision, run: run)
        let runID = run.id
        schedule(id: id, runID: runID) {
            for (space, command, text, _) in turns {
                let lane = try self.record(id, runID: runID).run?.specKit?[space]
                let reuse = lane?.plannerAgentID
                let live: Bool
                if let reuse { live = await self.server.missionAgentIsLive(id: id, agentID: reuse) } else { live = false }
                let result = try await self.specKitTurn(id, runID: runID, space: space, command: command, text: text,
                                                        reuse: live ? reuse : nil, keepAlive: true)
                _ = try await self.server.updateMissionRun(id: id, runID: runID) { value in
                    value.messages.append(.init(role: .assistant, text: Self.safeText(result.text, bytes: 16_000), spaceID: space))
                    value.messages = Array(value.messages.suffix(40))
                    if let index = value.specKit?.lanes.firstIndex(where: { $0.spaceID == space }) { value.specKit?.lanes[index].plannerAgentID = result.agentID }
                }
            }
            let saved = try await self.server.updateMissionRun(id: id, runID: runID) {
                $0.transition(to: .map, at: Self.now, notice: "Read each repository's reply and artifacts. Reply, send the next Spec Kit command, or Launch. No implementation has started.")
            }
            try await self.refreshSpecKitProjection(id, revision: saved.revision)
        }
    }

    /// Redraws the map from each repository's artifacts. Display only; an unchanged projection is a no-op.
    func refreshSpecKitProjection(_ id: MissionID, revision: UInt64) async throws {
        let mission = try record(id)
        guard let run = mission.run, let lanes = mission.draft.plan?.lanes else { return }
        var stations: [MissionStation] = [], wires: [MissionDependency] = [], requirements: [String] = []
        var phases: [SpaceID: [SpecKitPhase]] = [:]
        for lane in lanes {
            guard let checkout = run.checkouts.first(where: { $0.spaceID == lane.spaceID }) else { continue }
            let feature = run.specKit?[lane.spaceID]?.featureDirectory
            let files = try feature.map { try Self.snapshot(root: checkout.path, prefixes: [$0 + "/"]) } ?? [:]
            func text(_ name: String) -> String? { feature.flatMap { files["\($0)/\(name)"] }.map { String(decoding: $0, as: UTF8.self) } }
            let spec = text("spec.md").map(SpecKit.parseSpec)
            let parsed = text("tasks.md").map(SpecKit.parseTasks) ?? []
            phases[lane.spaceID] = parsed
            let checks = (mission.draft.plan?.stations ?? []).filter { $0.kind == .check && $0.laneID == lane.spaceID }
            let projected = SpecKit.projection(mission: id, lane: lane.spaceID,
                                               artifacts: [.specify: spec != nil, .plan: text("plan.md") != nil, .tasks: !parsed.isEmpty],
                                               spec: spec, phases: parsed, keeping: checks)
            stations += projected.stations; wires += projected.dependencies
            let label = lanes.count > 1 ? "\(lane.name): " : ""
            requirements += ((spec?.requirements ?? []) + (spec?.successCriteria ?? [])).map { Self.safeText(label + $0, bytes: 4_000) }
        }
        specKitPhases[id] = phases
        var draft = mission.draft
        let fitted = try SpecKit.fitted(stations: stations, dependencies: wires, mission: id, lanes: lanes.map(\.spaceID))
        draft.plan?.stations = fitted.stations
        draft.plan?.dependencies = fitted.dependencies
        if !requirements.isEmpty { draft.requirements = Array(requirements.prefix(64)) }
        guard draft != mission.draft else { return }
        _ = try await server.projectSpecKitMap(id: id, expectedRevision: revision, draft: draft)
    }

    // MARK: Execution

    func launchSpecKit(_ id: MissionID, revision: UInt64) async throws {
        guard try record(id).revision == revision, jobs[id] == nil else {
            throw MissionError("stale_mission", "The mission changed. Review the current artifacts before launching.")
        }
        if try record(id).approvedPlanRevision == nil { try await refreshSpecKitProjection(id, revision: revision) }
        var mission = try record(id)
        guard var run = mission.run, !run.phase.active, let lanes = run.specKit?.lanes else {
            throw MissionError("stale_mission", "The mission changed. Review the current artifacts before launching.")
        }
        if let reason = run.exhausted(mission.draft.limits, at: Self.now) { throw MissionError("mission_limit", reason) }
        guard run.publicationApproval == nil else { throw MissionError("mission_published", "This mission has published work.") }
        // Converge appended tasks: Launch is your approval of them, and implement runs again for that repository.
        let appended = Set(lanes.filter { $0.convergence?.outcome == .tasksAppended && $0.convergence?.accepted == false }.map(\.spaceID))
        let replanned = mission.approvedPlanRevision == nil
        let approving = replanned || !appended.isEmpty
        if replanned, let unfinished = lanes.lazy.compactMap({ self.unfinishedPlanning(mission, space: $0.spaceID) }).first {
            throw MissionError("speckit_unfinished", unfinished)
        }
        for (index, lane) in lanes.enumerated() {
            guard let checkout = run.checkouts.first(where: { $0.spaceID == lane.spaceID }), let feature = lane.featureDirectory else {
                throw MissionError("speckit_feature", "Run /speckit.specify, plan and tasks in every repository before Launch.")
            }
            try await verifyConsent(lane, checkout: checkout)
            let artifacts = SpecKit.artifactFingerprints(try Self.snapshot(root: checkout.path, prefixes: [feature + "/", ".specify/memory/"]), featureDirectory: feature)
            guard artifacts[feature + "/tasks.md"] != nil else { throw MissionError("speckit_tasks", "\(feature)/tasks.md is missing. Run /speckit.tasks first.") }
            if approving {
                // Repositories finish side by side: when only another repository's appended tasks changed the map, a
                // report you accepted about these exact files stays accepted. Any other replan assesses everything again.
                let kept = !appended.isEmpty && !appended.contains(lane.spaceID) && lane.convergence?.accepted == true
                    && (lane.observedArtifacts ?? lane.approvedArtifacts) == artifacts
                run.specKit?.lanes[index].approvedArtifacts = artifacts
                run.specKit?.lanes[index].observedArtifacts = artifacts
                // A new approval assesses the work again; a report you accepted earlier was about other files.
                if appended.contains(lane.spaceID) || (replanned && !kept) {
                    run.specKit?.lanes[index].convergence = nil
                }
                if appended.contains(lane.spaceID), let latest = run.attempts.lastIndex(where: {
                    $0.stationID == SpecKit.stationID(id, lane.spaceID, "phase-0") && $0.task == nil && $0.status == .succeeded }) {
                    run.attempts[latest].status = .superseded
                }
            } else if (lane.observedArtifacts ?? lane.approvedArtifacts) != artifacts,
                      !interruptedImplementOnly(run, lane: lane, current: artifacts) {
                throw MissionError("speckit_changed", "Spec Kit artifacts changed outside the mission since its last recorded turn. Review them and approve again.")
            }
        }
        if approving {
            let inputs = try await collectReviews(id)
            run.inputApprovals = Dictionary(uniqueKeysWithValues: inputs.map { ($0.spaceID.rawValue, $0.fingerprint) })
            mission = try await server.setMissionRun(id: id, expectedRevision: mission.revision, run: run)
            mission = try await server.approveMissionPlan(id: id, expectedRevision: mission.revision)
            run = mission.run ?? run
        }
        run.id = UUID(); run.reviewFingerprint = nil
        run.transition(to: .running, at: Self.now)
        _ = try await server.setMissionRun(id: id, expectedRevision: mission.revision, run: run)
        schedule(id: id, runID: run.id) { try await self.executeSpecKit(id, runID: run.id) }
    }

    /// Why planning isn't finished for a repository (Launch would approve a spec with open questions or tasks nobody
    /// analyzed), or nil.
    func unfinishedPlanning(_ mission: Mission, space: SpaceID) -> String? {
        guard let run = mission.run, let lane = run.specKit?[space] else { return nil }
        let name = mission.lane(space)?.name ?? "a repository"
        let station = SpecKit.stationID(mission.id, space, SpecKitCommand.tasks.planningStation)
        func last(_ command: SpecKitCommand) -> Int? { run.attempts.lastIndex { $0.stationID == station && $0.command == command && $0.status == .succeeded } }
        guard let tasks = last(.tasks), let analysis = last(.analyze), analysis > tasks else {
            return "Planning isn't finished in \(name): its tasks haven't been checked against the spec, plan and constitution. Continue planning first."
        }
        if let checkout = run.checkouts.first(where: { $0.spaceID == space }), let feature = lane.featureDirectory,
           let spec = try? Data(contentsOf: Self.resolved(checkout.path, feature + "/spec.md")),
           SpecKit.parseSpec(String(decoding: spec, as: UTF8.self)).clarificationsNeeded > 0 {
            return "\(name)'s spec still has open questions. Answer them in the planner first."
        }
        return nil
    }

    /// The only difference from the last observation is implement's own output, from an implement turn the app lost
    /// before recording it (it recovers when the run starts). Approved files never qualify.
    func interruptedImplementOnly(_ run: MissionRun, lane: MissionSpecKitLane, current: [String: String]) -> Bool {
        guard let feature = lane.featureDirectory, let expected = lane.observedArtifacts ?? lane.approvedArtifacts,
              let last = run.attempts.last(where: { $0.gitBefore?.spaceID == lane.spaceID }),
              last.command == .implement, last.status == .running || last.status == .interrupted else { return false }
        let approved = Set([feature + "/spec.md", feature + "/plan.md", feature + "/tasks.md", ".specify/memory/constitution.md"])
        return Set(expected.keys).union(current.keys).allSatisfy { expected[$0] == current[$0] || !approved.contains($0) }
    }

    /// Worktrees, then each repository's stock files read for the owner's review. Sends nothing.
    func prepareSpecKit(_ id: MissionID) async throws {
        var mission = try record(id)
        guard var run = mission.run, run.specKit != nil, !run.phase.active, jobs[id] == nil else {
            throw MissionError("mission_busy", "Wait for the current operation or pause it first.")
        }
        run.id = UUID(); run.reviewFingerprint = nil
        run.transition(to: .planning, at: Self.now)
        mission = try await server.setMissionRun(id: id, expectedRevision: mission.revision, run: run)
        let runID = run.id
        schedule(id: id, runID: runID) {
            try await self.ensureCheckouts(id, runID: runID)
            let reports = try await self.specKitPreflight(id: id)
            let blocked = reports.values.filter { $0.status != .ready }.map(Self.describe)
            let saved = try await self.server.updateMissionRun(id: id, runID: runID) {
                $0.transition(to: .map, at: Self.now, notice: blocked.first ?? "Review each repository's Spec Kit files and consent before the first command. Nothing has been sent.")
            }
            try await self.refreshSpecKitProjection(id, revision: saved.revision)
        }
    }

    /// Every repository still owed work runs implement → your checks → converge in its own worktree, side by side, at
    /// most the map's concurrent-station limit at once. A report you accepted stays done; one still waiting for you is
    /// kept, never rerun under you. A failure admits nothing new but lets running repositories finish, so their reports
    /// are kept; then it pauses the run. Every report and appended task list waits for you before review.
    func executeSpecKit(_ id: MissionID, runID: UUID) async throws {
        try await ensureCheckouts(id, runID: runID)
        let mission = try record(id, runID: runID)
        guard let run = mission.run, let lanes = run.specKit?.lanes else { throw MissionError("speckit_feature", "A repository has no Spec Kit feature.") }
        var queue = lanes.filter { lane in
            let converged = run.latest(SpecKit.stationID(id, lane.spaceID, SpecKitCommand.converge.rawValue))
            guard let convergence = lane.convergence, converged?.status == .succeeded, converged?.id == convergence.attemptID else { return true }
            return !convergence.accepted && [.tasksAppended, .missing].contains(convergence.outcome)
        }.map(\.spaceID)[...]
        var failure: Error?
        agentSlots[id] = MissionSlots(mission.draft.limits.concurrentStations)
        defer { agentSlots[id] = nil }
        await withTaskGroup(of: Error?.self) { group in
            func admit() {
                guard failure == nil, let space = queue.popFirst() else { return }
                group.addTask {
                    do { _ = try await self.runSpecKitLane(id, runID: runID, space: space); return nil } catch { return error }
                }
            }
            for _ in 0..<max(1, mission.draft.limits.concurrentStations) { admit() }
            while let result = await group.next() {
                if let result, failure == nil || failure is CancellationError { failure = result }
                admit()
            }
        }
        if let failure { throw failure }
        let current = try record(id, runID: runID)
        let waiting = current.run?.specKit?.lanes.filter { $0.convergence.map { !$0.accepted } ?? false } ?? []
        guard !waiting.isEmpty else { try await prepareReview(id, runID: runID); return }
        let notice = Self.specKitWaitingNotice(current, waiting: waiting)
        let saved = try await server.updateMissionRun(id: id, runID: runID) { $0.transition(to: .map, at: Self.now, notice: notice) }
        if waiting.contains(where: { $0.convergence?.outcome == .tasksAppended }) { try await refreshSpecKitProjection(id, revision: saved.revision) }
    }

    /// What waits for you once repositories finish: appended tasks to approve, reports to accept.
    nonisolated static func specKitWaitingNotice(_ mission: Mission, waiting: [MissionSpecKitLane]) -> String {
        let name = { (lane: MissionSpecKitLane) in mission.draft.plan?.lanes.first { $0.spaceID == lane.spaceID }?.name ?? "this repository" }
        let appended = waiting.filter { $0.convergence?.outcome == .tasksAppended }.map(name)
        let reports = waiting.filter { $0.convergence?.outcome != .tasksAppended }.map(name)
        var notes: [String] = []
        if !appended.isEmpty { notes.append("Converge appended tasks in \(appended.formatted(.list(type: .and))). Review them and approve again before implementing.") }
        if reports.count == 1 { notes.append("Read the /speckit.converge report for \(reports[0]). Accept it, reply or request changes. It is an assessment, not test evidence.") }
        if reports.count > 1 { notes.append("Read the /speckit.converge reports for \(reports.formatted(.list(type: .and))). Accept each, reply or request changes. They are assessments, not test evidence.") }
        return notes.joined(separator: " ")
    }

    /// This run's agent turns, shared by every repository (`agentSlots`); one at a time outside a run.
    func slots(_ id: MissionID) -> MissionSlots { agentSlots[id] ?? MissionSlots(1) }

    /// Batches for one agent per task (`SpecKit.implementBatches`), or nil when the repository implements in one stock
    /// turn: no [P] tasks in tasks.md, nothing left unchecked, a mandatory implement hook (it runs once around the whole implementation), an
    /// unfinished checklist (stock implement stops to ask about it), or too few receipts left for every task's own.
    func taskBatches(_ id: MissionID, runID: UUID, checkout: MissionCheckout, feature: String) async throws -> [[SpecKitTaskSlot]]? {
        guard let data = try? Data(contentsOf: Self.resolved(checkout.path, feature + "/tasks.md")) else { return nil }
        // A task list with [P] tasks keeps one agent per task to the end, so a relaunch runs only what's unchecked.
        let phases = SpecKit.parseTasks(String(decoding: data, as: UTF8.self)), batches = SpecKit.implementBatches(phases)
        guard phases.contains(where: { $0.tasks.contains(where: \.parallel) }), !batches.isEmpty,
              let used = try record(id, runID: runID).run?.attempts.count, used + batches.joined().count + 8 <= Self.taskReceiptLimit else { return nil }
        guard !SpecKit.hasMandatoryImplementHooks(try await Self.preflight(checkout.path).hooks) else { return nil }
        let checklists = try Self.snapshot(root: checkout.path, prefixes: [feature + "/checklists/"])
        let unfinished = checklists.values.contains { data in
            String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ]") }
        }
        return unfinished ? nil : batches
    }

    /// A run keeps at most 160 receipts (MissionRun.validate); per-task agents leave room for the rest of the run.
    static let taskReceiptLimit = 150

    /// One agent per task, a batch at a time, each in its own thread in the repository's worktree, all bounded by the
    /// run's agent slots. Shepherd checks a task off when its agent's reply says it's done; a task that isn't stops the
    /// round once its batch has finished (the others in it keep their work). Launch's retry limit counts the round's
    /// receipt (phase-0, no task), and a relaunch implements only the tasks still unchecked.
    func implementByTask(_ id: MissionID, runID: UUID, space: SpaceID, checkout: MissionCheckout, feature: String, batches: [[SpecKitTaskSlot]]) async throws {
        var round = MissionAttempt(stationID: SpecKit.stationID(id, space, "phase-0"), planRevision: try record(id, runID: runID).approvedPlanRevision)
        round.command = .implement; round.startedAt = Self.now
        let receipt = round
        _ = try await server.updateMissionRun(id: id, runID: runID) { $0.attempts.append(receipt) }
        var done: [String] = [], failure: Error?
        for (index, batch) in batches.enumerated() where failure == nil {
            await withTaskGroup(of: (String, Error?).self) { group in
                for slot in batch {
                    group.addTask {
                        do { try await self.implementTask(id, runID: runID, space: space, checkout: checkout, feature: feature, slot: slot, first: index == 0) }
                        catch { return (slot.task.id, error) }
                        return (slot.task.id, nil)
                    }
                }
                for await (task, error) in group {
                    if let error { if failure == nil || failure is CancellationError { failure = error } } else { done.append(task) }
                }
            }
        }
        let agents = batches.joined().count, widest = batches.map(\.count).max() ?? 1
        let summary = "Implemented \(done.isEmpty ? "no tasks" : done.joined(separator: ", ")), one agent per task (\(agents) planned, up to \(widest) at once)."
            + (failure.map { $0 is CancellationError ? " Stopped." : " " + String(describing: $0) } ?? "")
        let output = Self.safeText(summary), passed = failure == nil
        _ = try? await server.updateMissionRun(id: id, runID: runID) { value in
            guard let index = value.attempts.firstIndex(where: { $0.id == receipt.id && $0.status == .running }) else { return }
            value.attempts[index].status = passed ? .succeeded : .failed
            value.attempts[index].output = output; value.attempts[index].endedAt = Self.now
        }
        if let failure { throw failure }
    }

    /// One task's own stock /speckit.implement turn, scoped by its arguments (`SpecKit.taskScope`). Its checkbox is
    /// checked only from its own `Done:` line; anything else fails the task with the agent's last words.
    func implementTask(_ id: MissionID, runID: UUID, space: SpaceID, checkout: MissionCheckout, feature: String, slot: SpecKitTaskSlot, first: Bool) async throws {
        let task = slot.task
        let result = try await slots(id).run {
            guard let used = try self.record(id, runID: runID).run?.attempts.count, used < Self.taskReceiptLimit else {
                throw MissionError("mission_limit", "This mission has kept too many turns to give \(task.id) its own. Relaunch: the rest implements in one stock turn.")
            }
            return try await self.specKitTurn(id, runID: runID, space: space, command: .implement,
                                              text: SpecKitCommand.implement.invocation(SpecKit.taskScope(task, first: first)),
                                              station: SpecKit.stationID(id, space, "phase-\(slot.phase)"), reuse: nil, keepAlive: false, task: task.id)
        }
        guard SpecKit.taskReported(result.text, task: task.id) else {
            let attempt = result.attemptID
            _ = try await server.updateMissionRun(id: id, runID: runID) { value in
                if let index = value.attempts.firstIndex(where: { $0.id == attempt }) { value.attempts[index].status = .failed }
            }
            let last = result.text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "no reply"
            throw MissionError("speckit_task", "\(task.id) didn't report it was done: \(Self.safeText(last, bytes: 600)) Open its thread, then relaunch to retry the unchecked tasks.")
        }
        let url = try Self.resolved(checkout.path, feature + "/tasks.md")
        if let marked = SpecKit.markingDone(String(decoding: try Data(contentsOf: url), as: UTF8.self), task: task.id) {
            try Data(marked.utf8).write(to: url, options: .atomic)
        }
    }

    /// One repository's implement → your checks → converge, in its own worktree. Records the report and returns its outcome.
    @discardableResult
    func runSpecKitLane(_ id: MissionID, runID: UUID, space: SpaceID) async throws -> SpecKitConvergeOutcome {
        var mission = try record(id, runID: runID)
        guard let run = mission.run, let lane = run.specKit?[space], let feature = lane.featureDirectory,
              let checkout = run.checkouts.first(where: { $0.spaceID == space }) else { throw MissionError("speckit_feature", "A repository has no Spec Kit feature.") }
        let implementStation = SpecKit.stationID(id, space, "phase-0"), convergeStation = SpecKit.stationID(id, space, SpecKitCommand.converge.rawValue)
        try await recoverInterruptedTurn(id, runID: runID, space: space)
        guard let recovered = try record(id, runID: runID).run?.specKit?[space] else { throw CancellationError() }
        try await verifyObserved(recovered, checkout: checkout)
        // An implement round's receipt: one whole stock turn, or the round of one agent per task (`implementByTask`).
        let implemented = run.attempts.last { $0.stationID == implementStation && $0.task == nil }
        if implemented?.status != .succeeded || implemented?.planRevision != mission.approvedPlanRevision {
            let used = run.attempts.filter { $0.stationID == implementStation && $0.command == .implement && $0.task == nil }.count
            guard used <= mission.draft.limits.retries else {
                throw MissionError("mission_retry_limit", "Implement reached the approved attempt limit across this mission. Raise the retry limit or revise the tasks.")
            }
            if let batches = try await taskBatches(id, runID: runID, checkout: checkout, feature: feature) {
                try await implementByTask(id, runID: runID, space: space, checkout: checkout, feature: feature, batches: batches)
            } else {
                let result = try await slots(id).run {
                    try await self.specKitTurn(id, runID: runID, space: space, command: .implement, text: SpecKitCommand.implement.invocation(""),
                                               station: implementStation, reuse: nil, keepAlive: false)
                }
                guard try record(id, runID: runID).run?.attempts.first(where: { $0.id == result.attemptID })?.status == .succeeded else {
                    throw MissionError("speckit_implement", "/speckit.implement did not finish. Open its thread, then request changes or relaunch.")
                }
            }
            // Implement builds what you approved; it doesn't get to change it. A rewritten spec, plan, constitution or
            // task list goes back to you (converge would otherwise check the code against the weakened version).
            let rewritten = try await observeImplementOutputs(id, runID: runID, space: space, checkout: checkout)
            guard rewritten.isEmpty else {
                throw MissionError("speckit_scope", "/speckit.implement changed what you approved in \(mission.lane(space)?.name ?? "a repository"): \(rewritten.joined(separator: ", ")). Reply to the planner to review the change; Launch then approves the files as they are.")
            }
        }
        mission = try record(id, runID: runID)
        for check in (mission.draft.plan?.stations ?? []).filter({ $0.kind == .check && $0.laneID == space }) {
            guard try await runCheck(id, runID: runID, station: check, checkout: checkout) else {
                throw MissionError("mission_validation", "\(check.title) failed. Open its output, then request changes or relaunch.")
            }
        }
        // Your own checks may write (a formatter); what they leave is part of the work converge assesses.
        if (mission.draft.plan?.stations ?? []).contains(where: { $0.kind == .check && $0.laneID == space }) {
            _ = try await observeImplementOutputs(id, runID: runID, space: space, checkout: checkout)
        }
        guard let observed = try record(id, runID: runID).run?.specKit?[space] else { throw CancellationError() }
        try await verifyObserved(observed, checkout: checkout)
        let before = try? Data(contentsOf: Self.resolved(checkout.path, feature + "/tasks.md"))
        let result = try await slots(id).run {
            try await self.specKitTurn(id, runID: runID, space: space, command: .converge, text: SpecKitCommand.converge.invocation(""),
                                       station: convergeStation, reuse: nil, keepAlive: false, tasksBefore: before)
        }
        let after = try? Data(contentsOf: Self.resolved(checkout.path, feature + "/tasks.md"))
        let outcome = SpecKit.convergeOutcome(before: before, after: after)
        // Appended tasks clear approval below. Otherwise converge is held to implement's gate: a report that rewrote the
        // spec, plan, constitution or tasks would otherwise make the weakened files the accepted baseline.
        if outcome != .tasksAppended {
            let rewritten = try await observeImplementOutputs(id, runID: runID, space: space, checkout: checkout)
            guard rewritten.isEmpty else {
                throw MissionError("speckit_scope", "/speckit.converge changed what you approved in \(mission.lane(space)?.name ?? "a repository"): \(rewritten.joined(separator: ", ")). Reply to the planner to review the change; Launch then approves the files as they are.")
            }
        }
        let reviews = try await collectReviews(id)
        _ = try await server.updateMissionRun(id: id, runID: runID) { value in
            if let index = value.attempts.firstIndex(where: { $0.id == result.attemptID }) {
                // Per-project scope: another repository's later work never makes this report stale.
                value.attempts[index].inputFingerprints = Dictionary(uniqueKeysWithValues: reviews.filter { $0.spaceID == space }.map { ($0.spaceID.rawValue, $0.fingerprint) })
            }
            if let index = value.specKit?.lanes.firstIndex(where: { $0.spaceID == space }) {
                value.specKit?.lanes[index].convergence = .init(attemptID: result.attemptID, outcome: outcome)
            }
        }
        return outcome
    }

    /// An owner-entered command check, run by the host. The only test evidence a Spec Kit mission records.
    func runCheck(_ id: MissionID, runID: UUID, station: MissionStation, checkout: MissionCheckout) async throws -> Bool {
        let mission = try record(id, runID: runID)
        guard let run = mission.run else { throw CancellationError() }
        var attempt = MissionAttempt(stationID: station.id, planRevision: mission.approvedPlanRevision)
        attempt.startedAt = Self.now
        _ = try await server.updateMissionRun(id: id, runID: runID) { $0.attempts.append(attempt) }
        let result = await Self.command(station.command ?? "", cwd: checkout.path, timeout: max(0.01, mission.draft.limits.seconds - run.elapsed(at: Self.now)))
        _ = try record(id, runID: runID)
        let reviews = try await collectReviews(id)
        let output = Self.safeText("Command: \(station.command ?? "")\nExit: \(result.status)\n\(result.stdout)\n\(result.stderr)")
        _ = try await server.updateMissionRun(id: id, runID: runID) { value in
            guard let index = value.attempts.firstIndex(where: { $0.id == attempt.id && $0.status == .running }) else { throw CancellationError() }
            value.attempts[index].status = result.status == 0 ? .succeeded : .failed
            value.attempts[index].exitCode = result.status; value.attempts[index].output = output; value.attempts[index].endedAt = Self.now
            value.attempts[index].fingerprint = reviews.first { $0.spaceID == checkout.spaceID }?.fingerprint
            value.attempts[index].inputFingerprints = Dictionary(uniqueKeysWithValues: reviews.filter { $0.spaceID == checkout.spaceID }.map { ($0.spaceID.rawValue, $0.fingerprint) })
        }
        return result.status == 0
    }

    /// Spec Kit publication readiness: every repository's converge report accepted, every owner check passed.
    func specKitReadyToPublish(_ mission: Mission) -> Bool {
        guard let run = mission.run, let lanes = run.specKit?.lanes else { return false }
        let checks = (mission.draft.plan?.stations ?? []).filter { $0.kind == .check }
        return lanes.allSatisfy { lane in
            lane.convergence?.accepted == true && run.latest(SpecKit.stationID(mission.id, lane.spaceID, SpecKitCommand.converge.rawValue))?.id == lane.convergence?.attemptID
        } && checks.allSatisfy { run.latest($0.id)?.status == .succeeded }
    }

    // MARK: One turn

    /// One stock command or reply in a repository's worktree: consent and the loaded template verified
    /// first, the turn bounded by mission limits, changed paths and stock-contract notes kept as evidence.
    @discardableResult
    func specKitTurn(_ id: MissionID, runID: UUID, space: SpaceID, command: SpecKitCommand?, text: String, station: MissionStationID? = nil,
                     reuse: AgentID?, keepAlive: Bool, tasksBefore: Data? = nil, replyCommand: SpecKitCommand? = nil,
                     task: String? = nil) async throws -> (attemptID: UUID, agentID: AgentID, text: String) {
        let mission = try record(id, runID: runID)
        guard let vm, let run = mission.run, let lane = run.specKit?[space],
              let checkout = run.checkouts.first(where: { $0.spaceID == space }) else { throw MissionError("mission_worktree", "The repository's worktree is missing.") }
        try await verifyConsent(lane, checkout: checkout)
        let feature = lane.featureDirectory
        let tasksPath = feature.map { $0 + "/tasks.md" }
        let tasksText = { (data: Data?) in data.map { String(decoding: $0, as: UTF8.self) } }
        let tasksBefore = tasksBefore ?? tasksPath.flatMap { try? Data(contentsOf: Self.resolved(checkout.path, $0)) }
        // Nothing moved the worktree's Git state since the mission's own last turn; a commit, rebase or branch switch
        // made in between is not the mission's work, so nothing is sent until the owner looks.
        let git = try await Self.gitState(checkout.path, space: space)
        guard git.branch == checkout.branch, git.snapshot.head == (checkout.observedHead ?? checkout.head) else {
            throw MissionError("mission_unexpected_commit", "\(checkout.path) moved outside the mission's turns (now \(git.branch.isEmpty ? "detached" : git.branch) at \(git.snapshot.head.prefix(8))). Inspect it; nothing was sent.")
        }
        let before = await Self.worktreeTree(checkout.path)
        let agentID = reuse ?? AgentID()
        let stationID = station ?? SpecKit.stationID(id, space, command?.planningStation ?? "specify")
        var attempt = MissionAttempt(stationID: stationID, agentID: agentID, planRevision: mission.approvedPlanRevision)
        attempt.gitBefore = git.snapshot
        attempt.startedAt = Self.now
        attempt.command = command ?? replyCommand ?? run.attempts.last(where: { $0.agentID == agentID })?.command ?? .clarify
        attempt.task = task
        _ = try await server.updateMissionRun(id: id, runID: runID) { $0.attempts.append(attempt) }
        do {
            if reuse == nil {
                let config = NewAgentConfig(spaceID: checkout.spaceID, workingDirectory: checkout.path, reservedAgentID: agentID,
                                            model: run.model, thinking: .off, initialPrompt: nil,
                                            initialName: "Spec Kit: \(task ?? command.map { "/speckit.\($0.rawValue)" } ?? "reply")",
                                            worktreeBranch: checkout.branch, worktreeBase: checkout.base, worktreePath: checkout.path)
                _ = try await vm.startAgent(config, selectAfter: false, focusWindow: false)
            }
            let started = Self.now
            var submitted = false, baseline: (Int, Double)?
            while true {
                let current = try record(id, runID: runID)
                let snapshot = try await server.missionAgentSnapshot(id: id, runID: runID, agentID: agentID)
                if !submitted, snapshot.ready, try Self.loadedStockTemplates(snapshot.promptTemplates, checkout: checkout, command: command) {
                    try await verifyConsent(lane, checkout: checkout)
                    let prompt = Self.safeText(text, bytes: 128 * 1024)
                    baseline = (snapshot.tokens ?? 0, snapshot.cost ?? 0)
                    if reuse == nil {
                        baseline = (0, 0)
                        try await server.sendMissionPrompt(id: id, runID: runID, agentID: agentID, prompt: prompt)
                    } else {
                        try await server.sendMissionFollowUp(id: id, runID: runID, agentID: agentID, operationID: UUID(), text: prompt)
                    }
                    submitted = true
                    continue
                }
                if let baseline {
                    let previous = current.run?.attempts.first { $0.id == attempt.id }
                    let tokens = max(previous?.tokens ?? 0, (snapshot.tokens ?? 0) - baseline.0)
                    let cost = max(previous?.cost ?? 0, (snapshot.cost ?? 0) - baseline.1)
                    if tokens != previous?.tokens || cost != previous?.cost {
                        _ = try await server.updateMissionRun(id: id, runID: runID) { value in
                            guard let index = value.attempts.firstIndex(where: { $0.id == attempt.id && $0.status == .running }) else { throw CancellationError() }
                            value.attempts[index].tokens = tokens; value.attempts[index].cost = cost
                        }
                    }
                    if !snapshot.text.isEmpty { attemptOutput[attempt.id] = Self.safeText(snapshot.text); liveOutput[id] = attemptOutput[attempt.id] }
                }
                if let error = snapshot.error { throw MissionError("mission_agent", error) }
                if submitted, snapshot.settled, snapshot.tokens != nil { break }
                if !submitted, Self.now - started > 60 {
                    throw MissionError("speckit_template", "pi did not load this repository's stock \(command.map { "speckit.\($0.rawValue)" } ?? "Spec Kit") prompt from its worktree within 60 seconds. Nothing was sent.")
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            let final = try await server.missionAgentSnapshot(id: id, runID: runID, agentID: agentID)
            // Analyze's findings come before its closing hook note; the whole turn is the report.
            let reply = command == .analyze && !final.turnText.isEmpty ? final.turnText : final.text
            // Unread steers are on the record before the thread can close (a steer call reads it then).
            try await recordUndelivered(id, runID: runID, attemptID: attempt.id, operations: final.undelivered)
            if !keepAlive { await stopAgent(agentID) }
            attemptOutput[attempt.id] = nil
            try await observeCheckout(id, runID: runID, space: space, before: git.snapshot)
            // What the turn changed, committed or not (stock git extension hooks commit before and after steps).
            let after = await Self.worktreeTree(checkout.path)
            let changed = await Self.changedPaths(checkout.path, from: before, to: after)
            let discovered = feature ?? Self.featureDirectory(checkout.path)
            let tasksAfter = discovered.flatMap { try? Data(contentsOf: Self.resolved(checkout.path, $0 + "/tasks.md")) }
            let notes = command.map { SpecKit.advisories(command: $0, featureDirectory: discovered, changedPaths: changed,
                                                         tasksBefore: tasksText(tasksBefore), tasksAfter: tasksText(tasksAfter)) } ?? []
            let evidence = (changed.isEmpty ? "Changed: nothing" : "Changed: " + changed.prefix(30).joined(separator: ", "))
                + (notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n"))
                + (final.undelivered.isEmpty ? "" : "\n" + Self.undeliveredNote(final.undelivered.count))
            let reviews = try await collectReviews(id)
            _ = try await server.updateMissionRun(id: id, runID: runID) { value in
                guard let index = value.attempts.firstIndex(where: { $0.id == attempt.id && $0.status == .running }) else { throw CancellationError() }
                value.attempts[index].status = .succeeded
                value.attempts[index].endedAt = Self.now
                value.attempts[index].output = Self.safeText(evidence + "\n\n" + reply)
                value.attempts[index].fingerprint = reviews.first { $0.spaceID == space }?.fingerprint
                if let discovered, let lane = value.specKit?.lanes.firstIndex(where: { $0.spaceID == space }) {
                    value.specKit?.lanes[lane].featureDirectory = discovered
                }
            }
            return (attempt.id, agentID, reply)
        } catch {
            if !keepAlive || reuse == nil || error is CancellationError { await stopAgent(agentID) }
            attemptOutput[attempt.id] = nil
            try? await observeCheckout(id, runID: runID, space: space, before: git.snapshot)
            // A failed or interrupted implement still did owned work: its outputs are what the next launch continues from.
            // Only its own outputs, though: a rewrite of what you approved is never recorded as the baseline.
            if command == .implement { _ = try? await observeImplementOutputs(id, runID: runID, space: space, checkout: checkout) }
            if !(error is CancellationError) {
                let message = Self.safeText(String(describing: error))
                _ = try? await server.updateMissionRun(id: id, runID: runID) { value in
                    if let index = value.attempts.firstIndex(where: { $0.id == attempt.id && $0.status == .running }) {
                        value.attempts[index].status = .failed; value.attempts[index].output = message; value.attempts[index].endedAt = Self.now
                    }
                }
            }
            throw error
        }
    }

    // MARK: Stock setup and the git extension's feature branch

    /// The owner's one click for a repository that isn't a Spec Kit project with the pi integration yet: stock
    /// `specify init` (no project) or `specify integration install pi` (another integration, kept as the default),
    /// run in this mission's worktree so the setup ships in the PR and the primary checkout is untouched. Sends
    /// nothing to a model; the files it writes still need the owner's consent like any other project's.
    func setUpSpecKit(id: MissionID, revision: UInt64, space: SpaceID) async throws {
        let mission = try record(id)
        guard mission.revision == revision, let run = mission.run, !run.phase.active, jobs[id] == nil,
              run.specKit?[space] != nil, let checkout = run.checkouts.first(where: { $0.spaceID == space }) else {
            throw MissionError("stale_mission", "The mission changed. Review it before setting up Spec Kit.")
        }
        // One setup per mission at a time: two `specify init --force` in one worktree would race.
        guard !specKitSettingUp.contains(id) else { throw MissionError("mission_busy", "Spec Kit is already being set up.") }
        specKitSettingUp.insert(id)
        defer { specKitSettingUp.remove(id) }
        let script: String
        let report = try await Self.preflight(checkout.path)
        switch report.status {
        case .notInitialized:
            // A project whose .specify/ is ignored by Git exists only in the owner's checkout; initializing the worktree
            // would replace it with a blank template (its constitution included).
            let ignored = await Self.command("git check-ignore -q .specify || git check-ignore -q .specify/init-options.json", cwd: checkout.repo)
            if ignored.status == 0 || FileManager.default.fileExists(atPath: (checkout.repo as NSString).appendingPathComponent(".specify/init-options.json")) {
                throw MissionError("speckit_ignored", "This repository has a Spec Kit project, but it isn't committed (or Git ignores it), so the mission's worktree can't see it. Commit .specify/ and .pi/ to \(checkout.base), then start a new mission.")
            }
            script = "specify init --here --force --non-interactive --ignore-agent-tools --integration pi --script sh"
        case .piIntegrationMissing:
            // Installed but missing prompts: stock `install` refuses ("already installed"); `upgrade` restores them.
            script = report.integrations.contains("pi") ? "specify integration upgrade pi --script sh" : "specify integration install pi --script sh"
        case .ready, .blocked:
            specKitReports[id, default: [:]][space] = report
            return
        }
        // uv installs specify-cli into ~/.local/bin, which a login shell started from the Dock may not list.
        let result = await Self.command("PATH=\"$PATH:$HOME/.local/bin\"\n" + script, cwd: checkout.path, timeout: 180)
        let after = try await Self.preflight(checkout.path)
        specKitReports[id, default: [:]][space] = after
        guard result.status == 0, after.status == .ready else {
            if result.status == 127 {
                throw MissionError("speckit_cli", "Spec Kit's specify CLI isn't installed. Install it with `uv tool install specify-cli --from git+https://github.com/github/spec-kit.git@v1.2.3`, then set up again.")
            }
            let output = Self.safeText((result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines), bytes: 2_000)
            throw MissionError("speckit_setup", "`\(script)` didn't finish setting up Spec Kit (exit \(result.status)). \(output)")
        }
    }

    /// What a stock step did to the worktree's Git state, recorded as the mission's own: the git extension's
    /// mandatory `speckit.git.feature` hook switches to a feature branch of its own in `/speckit.specify`, and its
    /// commit hooks (or the model) may commit. Measured against the state read just before that turn (`before`), the
    /// mission adopts only a branch that did not exist then, with no upstream, built on that turn's starting commit,
    /// and commits on top of it. Anything else (the owner's own branch, a rewritten history) fails closed.
    func observeCheckout(_ id: MissionID, runID: UUID, space: SpaceID, before: MissionGitSnapshot) async throws {
        guard let known = try record(id).run?.checkouts.first(where: { $0.spaceID == space }) else { return }
        let now = try await Self.gitState(known.path, space: space)
        let branch = now.branch, commit = now.snapshot.head
        guard branch != known.branch || commit != (known.observedHead ?? known.head) else { return }
        let descends = await Self.command("git merge-base --is-ancestor \(shellQuoted(before.head)) HEAD", cwd: known.path)
        let upstream = await Self.command("git rev-parse --abbrev-ref --symbolic-full-name @{u}", cwd: known.path)
        let newBranch = branch == known.branch || (before.branches.map { !$0.contains(branch) } ?? false)
        guard !branch.isEmpty, branch != known.base, newBranch, descends.status == 0, upstream.status != 0 else {
            throw MissionError("mission_checkout", "The worktree moved to \(branch.isEmpty ? "a detached HEAD" : branch), which isn't a new branch the mission made on its own work. Nothing was reviewed or pushed.")
        }
        _ = try await server.updateMissionRun(id: id, runID: runID) { value in
            guard let index = value.checkouts.firstIndex(where: { $0.spaceID == space }) else { return }
            value.checkouts[index].branch = branch
            value.checkouts[index].observedHead = commit == value.checkouts[index].head ? nil : commit
        }
    }

    /// A Spec Kit turn the app lost (quit, crash, pause mid-turn) never recorded what it did to Git or, for implement,
    /// to the feature's files. Before anything else reads the worktree, record it against the turn's own snapshot.
    func recoverInterruptedTurn(_ id: MissionID, runID: UUID, space: SpaceID) async throws {
        guard let run = try record(id, runID: runID).run, run.specKit != nil,
              let last = run.attempts.last(where: { $0.gitBefore?.spaceID == space }), let before = last.gitBefore,
              last.status == .running || last.status == .interrupted else { return }
        try await observeCheckout(id, runID: runID, space: space, before: before)
        if last.command == .implement, let checkout = try record(id, runID: runID).run?.checkouts.first(where: { $0.spaceID == space }) {
            _ = try await observeImplementOutputs(id, runID: runID, space: space, checkout: checkout)
        }
    }

    /// Records what implement left in the feature as its own output, unless it rewrote what you approved (spec.md,
    /// plan.md, the constitution, or tasks beyond checking them off). Returns the approved files it changed, if any.
    @discardableResult
    func observeImplementOutputs(_ id: MissionID, runID: UUID, space: SpaceID, checkout: MissionCheckout) async throws -> [String] {
        guard let lane = try record(id, runID: runID).run?.specKit?[space], let feature = lane.featureDirectory,
              let expected = lane.observedArtifacts ?? lane.approvedArtifacts, let current = try artifacts(lane, checkout: checkout) else { return [] }
        let approved = Set([feature + "/spec.md", feature + "/plan.md", feature + "/tasks.md", ".specify/memory/constitution.md"])
        let rewritten = Set(expected.keys).union(current.keys).filter { approved.contains($0) && expected[$0] != current[$0] }.sorted()
        if rewritten.isEmpty { try await observeArtifacts(id, runID: runID, space: space, checkout: checkout) }
        return rewritten
    }

    nonisolated static func gitState(_ root: String, space: SpaceID) async throws -> (branch: String, snapshot: MissionGitSnapshot) {
        let branch = await command("git branch --show-current", cwd: root)
        let head = await command("git rev-parse HEAD", cwd: root)
        let refs = await command("git for-each-ref --format='%(refname:short)' refs/heads", cwd: root)
        guard branch.status == 0, head.status == 0, refs.status == 0 else {
            throw MissionError("mission_checkout", "Couldn't read \(root)'s Git state. Nothing was sent.")
        }
        let names = refs.stdout.split(separator: "\n").map(String.init)
        return (branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                MissionGitSnapshot(spaceID: space, head: head.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                                   branches: names.count <= 2_000 ? names : nil))
    }

    /// The whole worktree (tracked, modified and untracked, not ignored) as a Git tree id, through a private copy of the
    /// index: the repository's index, refs and files are untouched. Nil when Git can't say.
    nonisolated static func worktreeTree(_ root: String) async -> String? {
        let script = """
            index=$(mktemp "${TMPDIR:-/tmp}/shepherd-index.XXXXXX") || exit 1
            trap 'rm -f "$index"' EXIT
            cp "$(git rev-parse --path-format=absolute --git-path index)" "$index" 2>/dev/null || :
            GIT_INDEX_FILE="$index" git add -A . >/dev/null 2>&1 && GIT_INDEX_FILE="$index" git write-tree
            """
        let result = await command(script, cwd: root, timeout: 120)
        let tree = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !tree.isEmpty ? tree : nil
    }

    /// Paths whose content differs between two worktree trees, whether committed in between or not.
    nonisolated static func changedPaths(_ root: String, from before: String?, to after: String?) async -> [String] {
        guard let before, let after else { return [] }
        guard before != after else { return [] }
        let diff = await command("git diff --name-only -z \(shellQuoted(before)) \(shellQuoted(after))", cwd: root)
        return diff.status == 0 ? diff.stdout.split(separator: "\0").map(String.init).prefix(20_000).sorted() : []
    }

    // MARK: Checks on the repository's own files

    /// Consent still matches the files as they are now; a change clears it and nothing runs.
    func verifyConsent(_ lane: MissionSpecKitLane, checkout: MissionCheckout) async throws {
        let report = try await Self.preflight(checkout.path)
        guard report.status == .ready, let consent = lane.consentFingerprint, consent == report.consentFingerprint else {
            if let mission = records.first(where: { $0.run?.checkouts.contains(checkout) == true }), let run = mission.run, run.phase.active {
                _ = try? await server.updateMissionRun(id: mission.id, runID: run.id) { value in
                    if let index = value.specKit?.lanes.firstIndex(where: { $0.spaceID == lane.spaceID }) { value.specKit?.lanes[index].consentFingerprint = nil }
                }
            }
            throw MissionError("speckit_consent", "This repository's Spec Kit files changed since you consented (or were never consented). Review them again; nothing was sent.")
        }
    }

    func artifacts(_ lane: MissionSpecKitLane, checkout: MissionCheckout) throws -> [String: String]? {
        guard let feature = lane.featureDirectory else { return nil }
        return SpecKit.artifactFingerprints(try Self.snapshot(root: checkout.path, prefixes: [feature + "/", ".specify/memory/"]), featureDirectory: feature)
    }

    /// Before every owned turn after approval: the files are as approved, or as the host last observed them
    /// after its own turn. Anything else was changed outside the mission and needs the owner again.
    func verifyObserved(_ lane: MissionSpecKitLane, checkout: MissionCheckout) async throws {
        try await verifyConsent(lane, checkout: checkout)
        guard let expected = lane.observedArtifacts ?? lane.approvedArtifacts, lane.approvedArtifacts != nil,
              try artifacts(lane, checkout: checkout) == expected else {
            throw MissionError("speckit_changed", "Spec Kit artifacts changed outside the mission since its last recorded turn. Review them and approve again.")
        }
    }

    /// Records the artifacts as an owned turn left them: implementation output and review evidence, not approval.
    func observeArtifacts(_ id: MissionID, runID: UUID, space: SpaceID, checkout: MissionCheckout) async throws {
        guard let lane = try record(id, runID: runID).run?.specKit?[space], let observed = try artifacts(lane, checkout: checkout) else { return }
        _ = try await server.updateMissionRun(id: id, runID: runID) { value in
            if let index = value.specKit?.lanes.firstIndex(where: { $0.spaceID == space }) { value.specKit?.lanes[index].observedArtifacts = observed }
        }
    }

    /// The command must have loaded from this worktree's `.pi/prompts`, resolved, or the stock text never ran.
    nonisolated static func loadedStockTemplates(_ templates: [String: String], checkout: MissionCheckout, command: SpecKitCommand?) throws -> Bool {
        guard let command else { return true }
        guard let path = templates["speckit.\(command.rawValue)"] else { return false }
        let expected = try resolved(checkout.path, command.promptPath).path
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expected else {
            throw MissionError("speckit_template", "pi loaded speckit.\(command.rawValue) from \(path), not this repository's stock prompt. Nothing was sent.")
        }
        return true
    }

    nonisolated static func preflight(_ root: String) async throws -> SpecKitPreflight {
        let task = Task.detached { SpecKit.preflight(try snapshot(root: root, prefixes: SpecKit.snapshotPrefixes)) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    nonisolated static func describe(_ report: SpecKitPreflight) -> String {
        switch report.status {
        case .ready: return "Ready."
        case .notInitialized: return "This repository has no Spec Kit project yet. Set it up to continue: Shepherd runs stock `specify init` in the mission's worktree, so the setup is part of the PR."
        case .piIntegrationMissing: return "This Spec Kit project lacks the pi integration. Set it up to continue: Shepherd runs stock `specify integration install pi` in the mission's worktree. Your default integration stays as it is."
        case .blocked: return report.ownershipConflicts.joined(separator: "\n")
        }
    }

    /// A path inside the worktree, symlinks resolved; anything resolving outside it is refused.
    nonisolated static func resolved(_ root: String, _ relative: String) throws -> URL {
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard SpecKit.isSafeRelativePath(relative), url.path == base.path || url.path.hasPrefix(base.path + "/") else {
            throw MissionError("speckit_path", "\(relative) resolves outside the repository's worktree. Nothing was read.")
        }
        return url
    }

    /// Bytes of every regular file under `prefixes`, by repository-relative path. Bounded; any link out of the worktree refuses.
    nonisolated static func snapshot(root: String, prefixes: [String]) throws -> [String: Data] {
        var files: [String: Data] = [:], total = 0
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        for prefix in prefixes {
            let start = try resolved(root, String(prefix.hasSuffix("/") ? prefix.dropLast() : Substring(prefix)))
            guard let items = FileManager.default.enumerator(at: start, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            for case let url as URL in items {
                let real = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard real.hasPrefix(base + "/") else { throw MissionError("speckit_path", "\(url.path) links outside the repository's worktree. Nothing was read.") }
                guard (try? URL(fileURLWithPath: real).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let relative = String(url.standardizedFileURL.path.dropFirst(start.path.count + 1))
                let key = (prefix.hasSuffix("/") ? prefix : prefix + "/") + relative
                guard files.count < specKitFileLimit else { throw MissionError("speckit_limit", "Too many Spec Kit files to review (over \(specKitFileLimit)).") }
                let data = try Data(contentsOf: URL(fileURLWithPath: real))
                total += data.count
                guard data.count <= specKitFileBytes, total <= specKitTotalBytes else { throw MissionError("speckit_limit", "Spec Kit files exceed the review size limit.") }
                files[key] = data
            }
        }
        return files
    }

    /// `.specify/feature.json` as upstream writes it, when it names a safe directory inside the worktree.
    nonisolated static func featureDirectory(_ root: String) -> String? {
        guard let data = try? Data(contentsOf: resolved(root, ".specify/feature.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var value = object["feature_directory"] as? String else { return nil }
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        if value.hasPrefix(base + "/") { value = String(value.dropFirst(base.count + 1)) }
        while value.hasSuffix("/") { value.removeLast() }
        guard SpecKit.isSafeRelativePath(value), (try? resolved(root, value)) != nil else { return nil }
        return value
    }

}
