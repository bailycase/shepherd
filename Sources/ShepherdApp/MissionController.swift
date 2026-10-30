import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

struct MissionRepositoryReview: Identifiable, Equatable {
    var spaceID: SpaceID
    var name: String
    var path: String
    var branch: String
    var head: String
    var fingerprint: String
    var files: [DiffFile]
    var id: SpaceID { spaceID }
}

/// A Mission composes ordinary native threads and the existing worktree/commit paths.
/// SessionServer owns every receipt; this app-owned driver never resumes itself after launch.
@MainActor @Observable
final class MissionController {
    var selectedID: MissionID?
    var error: String?
    var liveOutput: [MissionID: String] = [:]
    var reviews: [MissionID: [MissionRepositoryReview]] = [:]
    /// Files marked Viewed in review, by repository, path and content fingerprint. Session only.
    var viewed: [MissionID: Set<String>] = [:]
    var availableModels: [String] = []
    var defaultModel: String?
    var availableSpaces: [Space] = []
    var branchChoices: [SpaceID: [String]] = [:]
    /// Missions whose Spec Kit setup (`setUpSpecKit`) is running.
    var specKitSettingUp: Set<MissionID> = []
    var defaultBranches: [SpaceID: String] = [:]
    /// Last read of each repository's stock Spec Kit files, by mission. Reads only.
    var specKitReports: [MissionID: [SpaceID: SpecKitPreflight]] = [:]
    /// tasks.md phases with their checkbox progress, by mission and repository. tasks.md owns it.
    var specKitPhases: [MissionID: [SpaceID: [SpecKitPhase]]] = [:]
    /// The latest assistant text of each running attempt, so parallel stations never share one stream.
    var attemptOutput: [UUID: String] = [:]
    /// What `create` makes. Spec Kit for new Missions; tests of the map runner opt out explicitly.
    var newMissionBackend: MissionBackend = .specKit
    @ObservationIgnored weak var vm: ShepherdViewModel?
    @ObservationIgnored let server: SessionServer
    @ObservationIgnored var jobs: [MissionID: Task<Void, Never>] = [:]
    @ObservationIgnored var jobRuns: [MissionID: UUID] = [:]
    @ObservationIgnored var reviewInfo: [MissionID: [SpaceID: RemoteCommitInfo]] = [:]
    /// A running Spec Kit mission's agent turns, at most its concurrent-station limit at once across every repository.
    @ObservationIgnored var agentSlots: [MissionID: MissionSlots] = [:]
    /// What `liveOutput` and `attemptOutput` last published to paired devices, by mission (`publishLiveOutput`).
    @ObservationIgnored var publishedLive: [MissionID: RemoteMissionLive] = [:]

    init(vm: ShepherdViewModel) { self.vm = vm; server = vm.server }
    var records: [Mission] { vm?.state.missions ?? [] }

    func refreshModels() async {
        let server = server
        let listing = await Task.detached { server.modelListing() }.value
        availableModels = listing.models
        let preferred = vm?.settings.agentDefaults.model ?? listing.defaultModel
        defaultModel = preferred.flatMap { availableModels.contains($0) ? $0 : nil } ?? availableModels.first
        let spaces = (vm?.state.spaces ?? []).filter { !$0.hidden && !$0.holdsProjects && !$0.holdsDesigns }
        var repositories: [Space] = []
        for space in spaces {
            let refs = await Self.command("git for-each-ref --format='%(refname)' refs/heads/ refs/remotes/origin/", cwd: space.path)
            guard refs.status == 0 else { continue }
            repositories.append(space)
            branchChoices[space.id] = refs.stdout.split(separator: "\n").map(String.init).filter { $0 != "refs/remotes/origin/HEAD" }
            let current = await Self.command("git symbolic-ref --quiet HEAD", cwd: space.path)
            let ref = current.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            defaultBranches[space.id] = branchChoices[space.id]?.contains(ref) == true ? ref : nil
        }
        availableSpaces = repositories
    }

    func create(goal: String, spaces: [SpaceID], model: String, branches: [SpaceID: String], backend: MissionBackend? = nil) async throws -> MissionID {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !spaces.isEmpty else { throw MissionError("mission_input", "Describe the outcome and choose at least one repository.") }
        guard availableModels.contains(model) else { throw MissionError("mission_model", "Choose an available model. Mission context goes only to the provider you select.") }
        let selected = spaces.compactMap { id in availableSpaces.first { $0.id == id } }
        guard selected.count == spaces.count else { throw MissionError("mission_scope", "Choose existing local Git repositories.") }
        guard selected.allSatisfy({ space in branches[space.id].map { branchChoices[space.id]?.contains($0) == true } == true }) else {
            throw MissionError("mission_base", "Choose the starting branch for every repository. Each gets a new mission worktree.")
        }
        let draft = MissionDraft(title: String(goal.prefix(100)), goal: goal,
                                 plan: MissionPlan(lanes: selected.map { MissionLane(spaceID: $0.id, name: $0.name, baseBranch: branches[$0.id]) }))
        let mission = try await server.createMission(draft: draft)
        var run = MissionRun(model: model, messages: [.init(role: .user, text: goal)])
        if (backend ?? newMissionBackend) == .specKit { run.specKit = MissionSpecKitRun(lanes: selected.map { MissionSpecKitLane(spaceID: $0.id) }) }
        _ = try await server.setMissionRun(id: mission.id, expectedRevision: mission.revision, run: run)
        selectedID = mission.id
        try await plan(id: mission.id)
        return mission.id
    }

    /// A new mission with the same destination, repositories, starting branches and model. It plans
    /// afresh in new worktrees; nothing from the finished run's worktrees or approvals carries over.
    func runAgain(id: MissionID) async throws -> MissionID {
        let mission = try record(id)
        guard let run = mission.run, let lanes = mission.draft.plan?.lanes, !lanes.isEmpty else {
            throw MissionError("mission_input", "This mission has no repositories to run again.")
        }
        let branches = Dictionary(lanes.compactMap { lane in lane.baseBranch.map { (lane.spaceID, $0) } }, uniquingKeysWith: { first, _ in first })
        return try await create(goal: mission.draft.goal, spaces: lanes.map(\.spaceID), model: run.model, branches: branches,
                                backend: run.specKit == nil ? .legacyMap : .specKit)
    }

    func saveDraft(id: MissionID, revision: UInt64, draft: MissionDraft) async throws {
        let mission = try record(id)
        guard mission.run?.phase.active != true else { throw MissionError("mission_busy", "Pause before editing the mission.") }
        if let run = mission.run {
            guard Set(run.checkouts.map(\.spaceID)).isSubset(of: Set(draft.spaceIDs)) else {
                throw MissionError("mission_scope", "A repository with retained work cannot be removed. Start a separate mission for a different scope.")
            }
        }
        _ = try await server.editMission(id: id, expectedRevision: revision, draft: draft)
        reviews[id] = nil; reviewInfo[id] = nil
    }

    func plan(id: MissionID, feedback: String = "") async throws {
        var mission = try record(id)
        guard mission.run?.phase.active != true, jobs[id] == nil, var run = mission.run else {
            throw MissionError("mission_busy", "Wait for the current operation or pause it first.")
        }
        if let reason = run.exhausted(mission.draft.limits, at: Self.now) { throw MissionError("mission_limit", reason) }
        guard run.publicationApproval == nil, run.checkouts.allSatisfy({ $0.prURL == nil && $0.publishedHead == nil }) else {
            throw MissionError("mission_published", "This mission has authorized publication. Finish its PRs or start a new mission.")
        }
        if run.specKit != nil {
            let text = Self.safeText(feedback.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 16_000)
            let trusted = run.specKit?.lanes.allSatisfy { $0.consentFingerprint != nil } == true
            // Until every repository is allowed, planning only re-reads files; it never starts on its own.
            guard trusted, !run.checkouts.isEmpty else { return try await prepareSpecKit(id) }
            if text.isEmpty { return try await continueSpecKitPlanning(id, revision: mission.revision) }
            return try await answer(id: id, revision: mission.revision, text: text)
        }
        if !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            run.messages.append(.init(role: .user, text: Self.safeText(feedback, bytes: 16_000)))
        }
        run.id = UUID(); run.reviewFingerprint = nil; run.pendingQuestion = nil; run.pendingChoices = nil
        run.transition(to: .planning, at: Self.now)
        mission = try await server.setMissionRun(id: id, expectedRevision: mission.revision, run: run)
        schedule(id: id, runID: run.id) { try await self.makePlan(mission.id, runID: run.id) }
    }

    func launch(id: MissionID, revision: UInt64) async throws {
        if isSpecKit(id) { return try await launchSpecKit(id, revision: revision) }
        var mission = try record(id)
        guard mission.revision == revision, jobs[id] == nil, var run = mission.run, !run.phase.active else {
            throw MissionError("stale_mission", "The mission changed. Review the current map before launching.")
        }
        if let reason = run.exhausted(mission.draft.limits, at: Self.now) { throw MissionError("mission_limit", reason) }
        guard run.publicationApproval == nil, run.checkouts.allSatisfy({ $0.prURL == nil && $0.publishedHead == nil }) else {
            throw MissionError("mission_published", "This mission has published work. Reconcile its PRs before making further changes.")
        }
        let inputs = try await collectReviews(id)
        run.inputApprovals = Dictionary(uniqueKeysWithValues: inputs.map { ($0.spaceID.rawValue, $0.fingerprint) })
        mission = try await server.approveMissionPlan(id: id, expectedRevision: revision)
        run.id = UUID(); run.reviewFingerprint = nil
        run.transition(to: .running, at: Self.now)
        _ = try await server.setMissionRun(id: id, expectedRevision: mission.revision, run: run)
        schedule(id: id, runID: run.id) { try await self.execute(id, runID: run.id) }
    }

    func pause(id: MissionID, revision: UInt64) async throws { guard try record(id).revision == revision else { throw MissionError("stale_mission", "This mission changed. Pause the current run.") }; try await halt(id: id, phase: .paused, notice: "Paused. Worktrees and evidence are retained; nothing will resume on its own.") }
    func stop(id: MissionID, revision: UInt64) async throws { guard try record(id).revision == revision else { throw MissionError("stale_mission", "This mission changed. Stop the current run.") }; try await halt(id: id, phase: .stopped, notice: "Stopped. Worktrees and publication receipts are retained. Inspect any in-flight publication before trying again.") }

    func requestChanges(id: MissionID, revision: UInt64, text: String) async throws {
        guard try record(id).revision == revision, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MissionError("stale_mission", "Describe the changes against the current review.")
        }
        try await plan(id: id, feedback: text)
    }

    func revalidate(id: MissionID, revision: UInt64) async throws {
        let mission = try record(id)
        guard mission.revision == revision, var run = mission.run, !run.phase.active, jobs[id] == nil else {
            throw MissionError("stale_mission", "The mission changed. Refresh before revalidating.")
        }
        guard run.publicationApproval == nil else { throw MissionError("mission_published", "Publication is already authorized. Retry publication or inspect its existing PRs.") }
        let checks = Set((mission.draft.plan?.stations ?? []).filter { $0.kind == .check || $0.kind == .validator }.map(\.id))
        for index in run.attempts.indices where run.attempts[index].stationID.map(checks.contains) == true {
            run.attempts[index].status = .superseded
        }
        run.reviewFingerprint = nil
        run.transition(to: .map, at: Self.now)
        let saved = try await server.setMissionRun(id: id, expectedRevision: revision, run: run)
        try await launch(id: id, revision: saved.revision)
    }

    func openThread(_ id: AgentID) { vm?.selectAgent(id) }

    func record(_ id: MissionID, runID: UUID? = nil) throws -> Mission {
        guard let mission = server.state.missions.first(where: { $0.id == id }) else { throw MissionError("mission_missing", "Mission no longer exists.") }
        if let runID {
            try Task.checkCancellation()
            guard mission.run?.id == runID, mission.run?.phase.active == true else { throw CancellationError() }
            // Publishing is the person's approved step, each command bounded at 60 s; the run's limits bound unattended work,
            // and edits are locked after approval, so a limit reached here could never be raised again.
            if let run = mission.run, run.phase != .publishing, let reason = run.exhausted(mission.draft.limits, at: Self.now) { throw MissionError("mission_limit", reason) }
        }
        return mission
    }

    func schedule(id: MissionID, runID: UUID, operation: @escaping @MainActor () async throws -> Void) {
        error = nil; jobRuns[id] = runID
        jobs[id] = Task {
            let watchdog = Task {
                guard let mission = try? self.record(id), let run = mission.run, run.phase != .publishing else { return }
                let remaining = max(0, mission.draft.limits.seconds - run.elapsed(at: Self.now))
                do {
                    try await Task.sleep(for: .seconds(remaining))
                    guard self.jobRuns[id] == runID, (try? self.record(id).run?.phase.active) == true else { return }
                    try await self.halt(id: id, phase: .paused, notice: "Time limit reached. Increase the limit explicitly before resuming.")
                } catch {}
            }
            defer { watchdog.cancel() }
            do { try await operation() }
            catch {
                if let mission = try? self.record(id), mission.run?.id == runID, mission.run?.phase.active == true {
                    let message = Self.safeText(String(describing: error))
                    self.error = message
                    try? await self.halt(id: id, phase: .paused, notice: message)
                }
            }
            if self.jobRuns[id] == runID {
                self.jobs[id] = nil; self.jobRuns[id] = nil; self.liveOutput[id] = nil
                for attempt in (try? self.record(id))?.run?.attempts ?? [] { self.attemptOutput[attempt.id] = nil }
            }
        }
    }

    func halt(id: MissionID, phase: MissionRun.Phase, notice: String) async throws {
        let mission = try record(id)
        guard var run = mission.run else { return }
        jobs[id]?.cancel()
        let runID = run.id
        if run.phase.active {
            _ = try await server.updateMissionRun(id: id, runID: runID) {
                $0.transition(to: phase, at: Self.now, notice: Self.safeText(notice))
                for i in $0.attempts.indices where $0.attempts[i].status == .running { $0.attempts[i].status = .interrupted }
            }
        } else {
            run.transition(to: phase, at: Self.now, notice: Self.safeText(notice))
            _ = try await server.setMissionRun(id: id, expectedRevision: mission.revision, run: run)
        }
        await server.stopMissionAgents(id: id, runID: runID)
        for agent in (try? record(id))?.run?.specKit?.lanes.compactMap(\.plannerAgentID) ?? [] { await stopAgent(agent) }
    }

    nonisolated static var now: Double { Date().timeIntervalSince1970 }
    nonisolated static func safeText(_ value: String, bytes: Int = 4_096) -> String {
        let redacted = NativeRedaction.projectData(value)
        var data = Data(redacted.utf8.prefix(bytes))
        while !data.isEmpty && String(data: data, encoding: .utf8) == nil { data.removeLast() }
        return String(decoding: data, as: UTF8.self)
    }

    /// Same bounded process-group owner for checks and publication; Stop cancels the whole group.
    nonisolated static func command(_ script: String, cwd: String?, timeout: Double = 60) async -> LoginShell.Output {
        let task = Task.detached {
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GH_PROMPT_DISABLED"] = "1"
            // Reads (status, diff) never take index.lock from a repository's own turn running beside them.
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            let prefix = cwd.map { "cd -- \(shellQuoted($0)) || exit\n" } ?? ""
            return try BoundedCommand.run(["/bin/zsh", "-l", "-c", prefix + script], directory: cwd.map { URL(fileURLWithPath: $0) },
                                          environment: environment, timeout: min(86_400, max(0.01, timeout)), outputLimit: 2 << 20)
        }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            return .init(status: result.status, stdout: String(decoding: result.output, as: UTF8.self), stderr: String(decoding: result.errors, as: UTF8.self))
        } catch { return .init(status: error is CancellationError ? 130 : 124, stdout: "", stderr: "Command stopped: \(error)") }
    }
}

/// A fixed number of turns at once, first come first served. A waiter cancelled in line leaves it without a slot.
@MainActor final class MissionSlots {
    private var free: Int
    private var waiting: [(id: UUID, resume: CheckedContinuation<Void, Error>)] = []
    init(_ limit: Int) { free = max(1, limit) }

    func run<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async throws {
        if free > 0 { free -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { @MainActor in self.leave(id) }
        }
    }

    private func leave(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).resume.resume(throwing: CancellationError())
    }

    private func release() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume.resume() }
    }
}
