import Foundation
import ShepherdCore
import ShepherdProtocol

/// What an agent asked to do to another thread. Internal server policy controls access,
/// without approval dialogs or a Settings permission row. Listing and waiting are not gated.
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

/// Legacy approval payload retained for existing consumers. The server no longer emits it.
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

/// Legacy approval answer. The server ignores stale answers.
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
        /// Legacy result, no longer returned by the access policy.
        case ask
        case refuse(code: String, message: String)
    }

    public static let offMessage = "The user has turned agent-to-agent messages off. Don't message, steer, interrupt, read or start other agents; tell the user if you need something from another thread."
    public static let unattendedMessage = "An automation run can't act on other agents unless the user set Agent-to-agent messages to Always allow. Use notify instead."

    /// Apply the access policy. Thread grants no longer affect access; the argument is retained
    /// for existing consumers.
    public static func verdict(policy: AgentMessagePolicy, senderIsAutomation: Bool, hasThreadGrant: Bool) -> Verdict {
        switch policy {
        case .never:
            return .refuse(code: "not_allowed", message: offMessage)
        case .always:
            return .perform
        case .ask:
            if senderIsAutomation { return .refuse(code: "not_allowed", message: unattendedMessage) }
            return .perform
        }
    }

    /// Deleting another agent follows the same access policy, without confirmation.
    public static func deleteVerdict(policy: AgentMessagePolicy, senderIsAutomation: Bool) -> Verdict {
        verdict(policy: policy, senderIsAutomation: senderIsAutomation, hasThreadGrant: false)
    }
}
