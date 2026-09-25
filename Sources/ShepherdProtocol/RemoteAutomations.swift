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

    public init(id: UUID = UUID(), startedAt: Double, settledAt: Double? = nil, endedAt: Double? = nil,
                result: AutomationRunResult, agentID: AgentID? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.settledAt = settledAt
        self.endedAt = endedAt
        self.result = result
        self.agentID = agentID
    }

    /// How long it took: to its first finished turn, else to its end; nil while it runs.
    public var duration: Double? {
        (settledAt ?? endedAt).map { max(0, $0 - startedAt) }
    }
}

/// What a remote client may set on an automation: the fields the host's model has.
public struct RemoteAutomationDraft: Codable, Hashable, Sendable {
    public var name: String
    /// The opening prompt its run's agent gets.
    public var prompt: String
    /// The host directory its runs work in.
    public var cwd: String
    /// On: the host starts a run when Shepherd launches.
    public var enabled: Bool

    public init(name: String, prompt: String, cwd: String, enabled: Bool) {
        self.name = name
        self.prompt = prompt
        self.cwd = cwd
        self.enabled = enabled
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
}

public enum RemoteAutomationResult: Codable, Hashable, Sendable {
    case ok
    case runs([AutomationRun])
}
