import Foundation
import ShepherdCore

// Automations over the remote protocol (`RemoteProtocol.automationsCapability`): switch one on
// or off, run it now or stop its run, read the runs the host kept, and create, edit or delete
// one. The host serves them through the same handler as an agent's `automation_*` tools, so a
// remote change follows the local rules: a run is an ordinary agent in the hidden space, and
// no run agent outlives the host's launch.

/// How one run of an automation went, as the host last saw it.
public enum AutomationRunResult: String, Codable, Hashable, Sendable, CaseIterable {
    /// Its agent is working, or pi is still starting.
    case running
    /// Its agent is waiting on an answer.
    case needsYou
    /// Its agent finished its turn (it may still be open to read or continue).
    case finished
    /// It was stopped, or its agent deleted, before it finished.
    case stopped
    /// The host quit while it was going.
    case interrupted
    /// A triggered run that never got going (its thread or worktree couldn't be made). Older
    /// clients read it as stopped.
    case failed

    /// A result a newer host names that this build does not know reads as stopped.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .stopped
    }

    /// The run is still going (its agent works or waits on you).
    public var isLive: Bool { self == .running || self == .needsYou }
}

/// One run of an automation the host kept (newest last, a bounded number per automation). Times
/// are seconds since 1970.
public struct AutomationRun: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var startedAt: Double
    /// The first time its agent finished a turn.
    public var settledAt: Double?
    /// When its agent went away (stopped, deleted, or the host quit).
    public var endedAt: Double?
    public var result: AutomationRunResult
    /// Its agent, while it still exists on the host: open this to read the run.
    public var agentID: AgentID?
    /// What fired it ("#12 Fix login crash · issue labeled shepherd"), nil for Run now.
    public var trigger: String?
    /// The event's page (the issue or PR).
    public var triggerURL: String?
    /// The pull request its thread's branch opened, once the host saw one.
    public var pullRequestURL: String?
    /// Settled or asking, and not opened since (the inbox's unread dot).
    public var unread: Bool
    /// Why a `failed` run never started.
    public var failure: String?

    public init(id: UUID = UUID(), startedAt: Double, settledAt: Double? = nil, endedAt: Double? = nil,
                result: AutomationRunResult, agentID: AgentID? = nil, trigger: String? = nil,
                triggerURL: String? = nil, pullRequestURL: String? = nil, unread: Bool = false, failure: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.settledAt = settledAt
        self.endedAt = endedAt
        self.result = result
        self.agentID = agentID
        self.trigger = trigger
        self.triggerURL = triggerURL
        self.pullRequestURL = pullRequestURL
        self.unread = unread
        self.failure = failure
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, settledAt, endedAt, result, agentID, trigger, triggerURL, pullRequestURL, unread, failure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Double.self, forKey: .startedAt)
        settledAt = try c.decodeIfPresent(Double.self, forKey: .settledAt)
        endedAt = try c.decodeIfPresent(Double.self, forKey: .endedAt)
        result = try c.decode(AutomationRunResult.self, forKey: .result)
        agentID = try c.decodeIfPresent(AgentID.self, forKey: .agentID)
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger)
        triggerURL = try c.decodeIfPresent(String.self, forKey: .triggerURL)
        pullRequestURL = try c.decodeIfPresent(String.self, forKey: .pullRequestURL)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(settledAt, forKey: .settledAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encode(result, forKey: .result)
        try c.encodeIfPresent(agentID, forKey: .agentID)
        try c.encodeIfPresent(trigger, forKey: .trigger)
        try c.encodeIfPresent(triggerURL, forKey: .triggerURL)
        try c.encodeIfPresent(pullRequestURL, forKey: .pullRequestURL)
        if unread { try c.encode(unread, forKey: .unread) }
        try c.encodeIfPresent(failure, forKey: .failure)
    }

    /// How long it took: to its first finished turn, else to its end; nil while it runs.
    public var duration: Double? {
        (settledAt ?? endedAt).map { max(0, $0 - startedAt) }
    }

    /// Whether a run whose agent still exists is going: working, waiting on you, or pi still
    /// starting (idle before any turn settled; `run` is the one the host kept for that agent, nil
    /// while unknown). A settled run only waits to be read, so running the automation again
    /// replaces it. The host decides Run now by this, and clients offer it by the same rule.
    public static func isLive(agentStatus: AgentStatus, run: AutomationRun?) -> Bool {
        switch agentStatus {
        case .working, .blocked: true
        case .idle: run?.settledAt == nil
        case .done: false
        }
    }
}

/// What a remote client may set on an automation: the fields the host's model has.
public struct RemoteAutomationDraft: Codable, Hashable, Sendable {
    public var name: String
    /// The opening prompt its run's agent gets.
    public var prompt: String
    /// The host directory its runs work in.
    public var cwd: String
    /// On: the host starts a run when Shepherd launches (manual), or its trigger fires.
    public var enabled: Bool
    /// Trigger, destination, workspace, gate, limits and pins
    /// (`RemoteProtocol.automationTriggersCapability`). Nil, and every nil field inside, keeps
    /// what the host has: an older client's edit never clears a trigger.
    public var settings: AutomationSettings?

    public init(name: String, prompt: String, cwd: String, enabled: Bool, settings: AutomationSettings? = nil) {
        self.name = name
        self.prompt = prompt
        self.cwd = cwd
        self.enabled = enabled
        self.settings = settings
    }
}

/// How a triggered automation's trigger stands on the host (`.status`).
public struct AutomationTriggerStatus: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        /// Watching (or a manual automation: nothing to watch).
        case active
        /// Switched off by the user (the automation is disabled).
        case off
        /// Paused: by the user, by Pause all triggers, or by a lasting error (`reason`).
        case paused
        /// A passing error (network, rate limit): checks resume after `retryAt`.
        case retrying

        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .paused
        }
    }

    public var state: State
    /// Why it's paused or retrying, in words the user can act on.
    public var reason: String?
    /// Events waiting for a free slot (oldest first); they expire after a week.
    public var pending: [AutomationEvent]
    /// The schedule's next run (seconds since 1970).
    public var nextRunAt: Double?
    /// The last time GitHub was checked successfully.
    public var lastCheckedAt: Double?
    public var retryAt: Double?
    /// Runs started today against `limits.maxPerDay`.
    public var runsToday: Int
    /// Every trigger on the host is paused.
    public var allPaused: Bool
    /// The host's time zone identifier: schedules run in it, so a client previews in it too.
    public var timeZone: String?

    public init(state: State, reason: String? = nil, pending: [AutomationEvent] = [], nextRunAt: Double? = nil,
                lastCheckedAt: Double? = nil, retryAt: Double? = nil, runsToday: Int = 0, allPaused: Bool = false,
                timeZone: String? = nil) {
        self.timeZone = timeZone
        self.state = state
        self.reason = reason
        self.pending = pending
        self.nextRunAt = nextRunAt
        self.lastCheckedAt = lastCheckedAt
        self.retryAt = retryAt
        self.runsToday = runsToday
        self.allPaused = allPaused
    }

    private enum CodingKeys: String, CodingKey { case state, reason, pending, nextRunAt, lastCheckedAt, retryAt, runsToday, allPaused, timeZone }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(State.self, forKey: .state)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        pending = try c.decodeIfPresent([AutomationEvent].self, forKey: .pending) ?? []
        nextRunAt = try c.decodeIfPresent(Double.self, forKey: .nextRunAt)
        lastCheckedAt = try c.decodeIfPresent(Double.self, forKey: .lastCheckedAt)
        retryAt = try c.decodeIfPresent(Double.self, forKey: .retryAt)
        runsToday = try c.decodeIfPresent(Int.self, forKey: .runsToday) ?? 0
        allPaused = try c.decodeIfPresent(Bool.self, forKey: .allPaused) ?? false
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
    }
}

public enum RemoteAutomationRequest: Codable, Hashable, Sendable {
    /// On or off: whether the host starts a run when Shepherd launches.
    case setEnabled(enabled: Bool)
    /// Start a run now. A no-op while one is going, as on the host.
    case run
    /// End the current run by deleting its agent; the automation stays.
    case stop
    /// The runs the host kept, oldest first.
    case runs
    /// Save a new automation under the request's (client-minted) id. It does not start a run.
    case create(draft: RemoteAutomationDraft)
    /// Replace its name, prompt, directory and switch.
    case update(draft: RemoteAutomationDraft)
    /// Stop its run and remove it.
    case delete
    /// Its trigger's state, pending events and schedule (`automationTriggersCapability`).
    case status
    /// Pause its trigger (it stays enabled; nothing fires until resumed).
    case pause
    /// Resume a paused trigger: clears a lasting error and checks again now.
    case resume
    /// Start a run for one pending event now, past the daily cap.
    case runEvent(eventID: String)
    /// Drop one pending event without running it.
    case dismissEvent(eventID: String)
    /// Clear one run's unread dot.
    case markRead(runID: UUID)
    /// Pause or resume every trigger on the host (the automation named is incidental).
    case setAllPaused(paused: Bool)
}

public enum RemoteAutomationResult: Codable, Hashable, Sendable {
    case ok
    case runs([AutomationRun])
    case status(AutomationTriggerStatus)
}
