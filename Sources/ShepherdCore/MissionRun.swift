import Foundation

/// Host-owned execution receipts. Model text is a proposal or evidence to inspect, never authority.
public struct MissionRun: Codable, Hashable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable, CaseIterable {
        case planning, map, running, paused, review, publishing, done, stopped
        public var active: Bool { self == .planning || self == .running || self == .publishing }
    }
    public var id: UUID
    public var model: String
    public var phase: Phase
    public var messages: [MissionChatMessage]
    public var checkouts: [MissionCheckout]
    public var attempts: [MissionAttempt]
    public var elapsedSeconds: Double
    public var activeSince: Double?
    public var notice: String?
    public var pendingQuestion: String?
    /// The planner's suggested answers to `pendingQuestion`. Picking one only sends it as a reply.
    public var pendingChoices: [String]?
    public var reviewFingerprint: String?
    public var publicationApproval: String?
    /// Actual worktree versions the owner explicitly accepted as a launch/revalidation checkpoint.
    public var inputApprovals: [String: String]?
    /// Present only for a mission driven by each repository's stock Spec Kit project. Nil keeps the map runner.
    public var specKit: MissionSpecKitRun?

    public init(id: UUID = UUID(), model: String, phase: Phase = .map, messages: [MissionChatMessage] = [],
                checkouts: [MissionCheckout] = [], attempts: [MissionAttempt] = [], elapsedSeconds: Double = 0,
                activeSince: Double? = nil, notice: String? = nil, reviewFingerprint: String? = nil) {
        self.id = id; self.model = model; self.phase = phase; self.messages = messages
        self.checkouts = checkouts; self.attempts = attempts; self.elapsedSeconds = elapsedSeconds
        self.activeSince = activeSince; self.notice = notice; self.reviewFingerprint = reviewFingerprint
    }

    public var tokens: Int { attempts.reduce(0) { $0 + $1.tokens } }
    public var cost: Double { attempts.reduce(0) { $0 + $1.cost } }
    public var plannerID: AgentID? { attempts.last(where: { $0.stationID == nil })?.agentID }
    public func elapsed(at now: Double) -> Double { elapsedSeconds + (activeSince.map { max(0, now - $0) } ?? 0) }

    public func latest(_ station: MissionStationID) -> MissionAttempt? { attempts.last { $0.stationID == station } }

    public func exhausted(_ limits: MissionLimits, at now: Double) -> String? {
        if tokens >= limits.tokens { return "Token limit reached. Review the work and raise the limit before resuming." }
        if cost >= limits.dollars { return "Spending limit reached. Review the work and raise the limit before resuming." }
        if elapsed(at: now) >= limits.seconds { return "Time limit reached. Review the work and raise the limit before resuming." }
        return nil
    }

    public mutating func transition(to phase: Phase, at now: Double, notice: String? = nil) {
        elapsedSeconds = elapsed(at: now)
        activeSince = phase.active ? now : nil
        self.phase = phase
        self.notice = notice
    }

    public func validate() throws {
        guard !model.isEmpty, model.utf8.count <= 512, messages.count <= 40, attempts.count <= 160,
              Set(attempts.map(\.id)).count == attempts.count, checkouts.count <= 32,
              Set(checkouts.map(\.spaceID)).count == checkouts.count,
              elapsedSeconds.isFinite, elapsedSeconds >= 0,
              activeSince.map({ $0.isFinite && $0 >= 0 }) ?? true,
              notice.map({ $0.utf8.count <= 4_096 }) ?? true,
              pendingQuestion.map({ !$0.isEmpty && $0.utf8.count <= 4_096 }) ?? true,
              pendingChoices.map({ $0.count <= 6 && $0.allSatisfy { !$0.isEmpty && $0.utf8.count <= 400 } }) ?? true,
              reviewFingerprint.map({ $0.utf8.count <= 128 }) ?? true else {
            throw MissionError("invalid_mission_run", "Invalid or oversized mission execution record.")
        }
        try specKit?.validate()
        for fingerprints in [inputApprovals] + attempts.map(\.inputFingerprints) {
            guard fingerprints.map({ $0.count <= 32 && $0.allSatisfy { UUID(uuidString: $0.key) != nil && $0.value.utf8.count <= 128 } }) ?? true else {
                throw MissionError("invalid_mission_run", "Invalid input version receipts.")
            }
        }
        for attempt in attempts where (attempt.operationIDs?.count ?? 0) > 64 || (attempt.undeliveredOperationIDs?.count ?? 0) > 64 || (attempt.deliveredOperationIDs?.count ?? 0) > 64 {
            throw MissionError("mission_limit", "Too many follow-up turns in one mission attempt (\(attempt.operationIDs?.count ?? 0)).")
        }
        for message in messages {
            guard message.text.utf8.count <= 16_000, ([message.question, message.choice].compactMap { $0 } + (message.choices ?? [])).allSatisfy({ $0.utf8.count <= 4_096 }),
                  (message.choices?.count ?? 0) <= 6 else { throw MissionError("mission_limit", "Mission conversation is too large.") }
        }
        for attempt in attempts {
            guard attempt.tokens >= 0, attempt.startedAt.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  attempt.endedAt.map({ $0.isFinite && $0 >= 0 }) ?? true, attempt.tokens <= 100_000_000, attempt.cost.isFinite, (0...1_000_000).contains(attempt.cost),
                  attempt.output.utf8.count <= 4_096, attempt.task.map({ $0.utf8.count <= 64 }) ?? true,
                  attempt.gitBefore.map({ ($0.branches?.count ?? 0) <= 2_000 && $0.head.utf8.count <= 128 }) ?? true else {
                throw MissionError("invalid_mission_run", "Invalid station receipt.")
            }
        }
        for checkout in checkouts {
            guard checkout.path.hasPrefix("/"), !checkout.branch.isEmpty, !checkout.base.isEmpty,
                  !checkout.head.isEmpty, [checkout.path, checkout.repo, checkout.branch, checkout.base, checkout.head, checkout.observedHead ?? ""].allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4_096 }),
                  checkout.prURL.map({ $0.hasPrefix("https://") && $0.utf8.count <= 2_048 }) ?? true else {
                throw MissionError("invalid_mission_run", "Invalid mission worktree receipt.")
            }
        }
    }
}

public struct MissionChatMessage: Codable, Hashable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: UUID
    public var role: Role
    public var text: String
    /// On an assistant message: the question it asked and the planner's suggested answers.
    public var question: String?
    public var choices: [String]?
    /// On a user message: the assistant message it answers, and the suggested answer picked, if one was.
    /// Older records carry neither; nothing infers them.
    public var replyTo: UUID?
    public var choice: String?
    /// The repository whose Spec Kit planning thread this message belongs to; nil for a whole-mission message.
    public var spaceID: SpaceID?
    public init(id: UUID = UUID(), role: Role, text: String, question: String? = nil, choices: [String]? = nil,
                replyTo: UUID? = nil, choice: String? = nil, spaceID: SpaceID? = nil) {
        self.id = id; self.role = role; self.text = text
        self.question = question; self.choices = choices; self.replyTo = replyTo; self.choice = choice; self.spaceID = spaceID
    }
}

public struct MissionCheckout: Codable, Hashable, Sendable, Identifiable {
    public var spaceID: SpaceID
    public var repo: String
    public var path: String
    public var branch: String
    public var base: String
    public var head: String
    public var fingerprint: String?
    public var prURL: String?
    public var publishedHead: String?
    public var originFingerprint: String?
    /// HEAD after the mission's own last turn, when a stock Spec Kit step committed (the git extension's
    /// commit hooks, or the model): review diffs from `head` and accepts commits up to here. Nil: none.
    public var observedHead: String?
    public var id: SpaceID { spaceID }
    public init(spaceID: SpaceID, repo: String, path: String, branch: String, base: String, head: String,
                fingerprint: String? = nil, prURL: String? = nil, publishedHead: String? = nil, originFingerprint: String? = nil) {
        self.spaceID = spaceID; self.repo = repo; self.path = path; self.branch = branch
        self.base = base; self.head = head; self.fingerprint = fingerprint; self.prURL = prURL; self.publishedHead = publishedHead
        self.originFingerprint = originFingerprint
    }
}

public struct MissionAttempt: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case running, succeeded, failed, interrupted, superseded }
    public var id: UUID
    /// Nil identifies a planning turn, never a worker or validator.
    public var stationID: MissionStationID?
    public var agentID: AgentID?
    public var status: Status
    public var output: String
    public var tokens: Int
    public var cost: Double
    /// Set only by the host's command runner. Agent prose cannot supply a check's exit status.
    public var exitCode: Int32?
    public var planRevision: UInt64?
    public var fingerprint: String?
    /// Host-observed input versions, never supplied by model prose.
    public var inputFingerprints: [String: String]?
    public var sessionID: String?
    public var generation: String?
    /// Host clock when the attempt started and settled, for elapsed times and the decision log.
    public var startedAt: Double?
    public var endedAt: Double?
    /// The stock Spec Kit command this turn sent, when it sent one.
    public var command: SpecKitCommand?
    /// Later owner turns (follow-ups and steers) in the session this attempt owns, oldest first.
    /// The first prompt's operation is the agent ID. Settlement waits for the last one.
    public var operationIDs: [UUID]?
    /// Of those, the steers pi acknowledged but never read before the run ended or stopped. Never sent again.
    public var undeliveredOperationIDs: [UUID]?
    /// Of those, the ones pi actually read: recorded by the host when the steered user message arrived.
    public var deliveredOperationIDs: [UUID]?
    /// A Spec Kit turn's repository Git state as the host read it before the turn, so a branch or commit the turn
    /// made (stock git extension hooks) is told from one that existed or was made outside it, even after a restart.
    public var gitBefore: MissionGitSnapshot?
    /// The tasks.md task ("T005") this implement turn was given alone, when Spec Kit's implement runs one agent per
    /// task. Nil for every other turn, including a whole /speckit.implement turn and an implement round's receipt.
    public var task: String?
    public init(id: UUID = UUID(), stationID: MissionStationID? = nil, agentID: AgentID? = nil,
                status: Status = .running, output: String = "", tokens: Int = 0, cost: Double = 0, exitCode: Int32? = nil,
                planRevision: UInt64? = nil, fingerprint: String? = nil, sessionID: String? = nil, generation: String? = nil) {
        self.id = id; self.stationID = stationID; self.agentID = agentID; self.status = status
        self.output = output; self.tokens = tokens; self.cost = cost; self.exitCode = exitCode
        self.planRevision = planRevision; self.fingerprint = fingerprint
        self.sessionID = sessionID; self.generation = generation
    }
}

public struct MissionGitSnapshot: Codable, Hashable, Sendable {
    public var spaceID: SpaceID
    public var head: String
    /// Local branch names (refs/heads/…) before the turn. Nil when there were too many to keep (over 2,000): then no
    /// branch the turn moved to can be shown to be new, and adopting one fails closed.
    public var branches: [String]?
    public init(spaceID: SpaceID, head: String, branches: [String]?) { self.spaceID = spaceID; self.head = head; self.branches = branches }
}

public extension ShepherdState {
    func isMissionAgent(_ id: AgentID) -> Bool { missions.contains { $0.run?.attempts.contains { $0.agentID == id } == true } }
}

public extension MissionRun {
    /// One of this run's agents: a turn's, or a Spec Kit repository's planning thread.
    static func owns(_ run: MissionRun, agent: AgentID) -> Bool {
        run.attempts.contains { $0.agentID == agent } || run.specKit?.lanes.contains { $0.plannerAgentID == agent } == true
    }

    /// The planner's thread: a planning turn's (map runner) or a repository's Spec Kit planning thread.
    func isPlanner(_ agent: AgentID) -> Bool {
        specKit?.lanes.contains { $0.plannerAgentID == agent } == true || attempts.contains { $0.agentID == agent && $0.stationID == nil }
    }
}
