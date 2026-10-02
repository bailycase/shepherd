import Foundation
import ShepherdCore
import ShepherdProtocol

/// What an agent asked to do to another thread, which the user may be asked to approve
/// (Settings ▸ Pi ▸ Agent-to-agent messages). Reading a thread, messaging it, steering it,
/// interrupting it and starting a new one are gated; listing the threads, waiting on one and
/// deleting one are not (deleting has its own dialog).
public enum AgentGatedAction: Hashable, Sendable {
    case send(targetAgentID: AgentID, text: String, delivery: AgentMessageDelivery)
    case steer(targetAgentID: AgentID, text: String)
    case interrupt(targetAgentID: AgentID)
    case read(targetAgentID: AgentID)
    case spawn(cwd: String, prompt: String)

    /// The thread it acts on; nil for starting a new one.
    public var targetAgentID: AgentID? {
        switch self {
        case .send(let target, _, _), .steer(let target, _), .interrupt(let target), .read(let target):
            return target
        case .spawn:
            return nil
        }
    }
}

/// A gated call waiting for the user: the server's token for it (the only thing an answer needs),
/// who asked, and what.
public struct AgentApprovalPrompt: Hashable, Sendable, Identifiable {
    public let requestID: String
    public let senderID: AgentID
    public let action: AgentGatedAction

    public var id: String { requestID }

    public init(requestID: String, senderID: AgentID, action: AgentGatedAction) {
        self.requestID = requestID
        self.senderID = senderID
        self.action = action
    }
}

/// The user's answer to an `AgentApprovalPrompt`.
public enum AgentApprovalDecision: String, Hashable, Sendable {
    /// This call only.
    case allowOnce
    /// This call, and every later one from the same agent until the app quits or its pi restarts.
    case allowForThread
    case deny
}

/// What the policy says about one gated call, and the words the agent hears when it is refused.
public enum AgentMessageGate {
    public enum Verdict: Equatable, Sendable {
        case perform
        case ask
        case refuse(code: String, message: String)
    }

    /// How long a dialog waits before the call is refused.
    public static let approvalTimeout: TimeInterval = 120
    /// The most calls one agent may have waiting at once, and every agent together: the user's
    /// dialogs, one after another, are the cost of each.
    public static let pendingLimitPerAgent = 8
    public static let pendingLimit = 24

    public static let deniedMessage = "The user did not approve. Don't message other agents unless the user asks you to."
    public static let timedOutMessage = "The user did not approve in time. Don't message other agents unless the user asks you to."
    public static let offMessage = "The user has turned agent-to-agent messages off. Don't message, steer, interrupt, read or start other agents; tell the user if you need something from another thread."
    public static let unattendedMessage = "An automation run can't ask the user, so it can't message other agents unless the user set Agent-to-agent messages to Always allow. Use notify instead."
    public static let busyMessage = "Too many agent messages are waiting for the user. Don't message other agents unless the user asks you to."

    /// `policy` applied to a call from an agent that is (or is not) an automation run, which has no
    /// one to ask, and that the user has (or has not) allowed for its thread.
    public static func verdict(policy: AgentMessagePolicy, senderIsAutomation: Bool, hasThreadGrant: Bool) -> Verdict {
        switch policy {
        case .never:
            return .refuse(code: "not_allowed", message: offMessage)
        case .always:
            return .perform
        case .ask:
            if senderIsAutomation { return .refuse(code: "not_allowed", message: unattendedMessage) }
            return hasThreadGrant ? .perform : .ask
        }
    }

    /// Deleting another agent: its own dialog asks every time, whatever the policy, so only the
    /// two cases that never reach it are decided here.
    public static func deleteVerdict(policy: AgentMessagePolicy, senderIsAutomation: Bool) -> Verdict {
        switch policy {
        case .never:
            return .refuse(code: "not_allowed", message: offMessage)
        case .always:
            return .perform
        case .ask:
            return senderIsAutomation ? .refuse(code: "not_allowed", message: unattendedMessage) : .perform
        }
    }
}

/// The threads the user allowed with "Allow for this thread": by agent, for as long as the pi that
/// was running when they said so is the one running. A restarted pi is a new session, so it asks
/// again; nothing here is written to disk, so a relaunch forgets all of it.
struct AgentThreadGrants {
    private var granted: [AgentID: SessionID?] = [:]

    /// Whether `agent` is allowed now, given the session its pi runs in (nil when none is bound).
    /// A grant from another session is dropped.
    mutating func allows(_ agent: AgentID, session: SessionID?) -> Bool {
        guard let at = granted[agent] else { return false }
        if at == session { return true }
        granted[agent] = nil
        return false
    }

    mutating func grant(_ agent: AgentID, session: SessionID?) {
        granted[agent] = .some(session)
    }

    mutating func removeAll() {
        granted.removeAll()
    }

    mutating func forget(_ agent: AgentID) {
        granted[agent] = nil
    }

    var agents: Set<AgentID> { Set(granted.keys) }
}
