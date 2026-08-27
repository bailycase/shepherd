import Foundation
import ShepherdCore

/// A remote client's create-agent request, handed to the GUI (which owns the
/// pi spawn flow) via `SessionServer.onRemoteCreateAgent`.
public struct RemoteCreateAgentRequest: Sendable {
    public var spaceID: SpaceID
    public var cwd: String?
    public var model: String?
    public var thinking: ThinkingLevel?
    public var initialPrompt: String?

    public init(
        spaceID: SpaceID,
        cwd: String?,
        model: String?,
        thinking: ThinkingLevel?,
        initialPrompt: String?
    ) {
        self.spaceID = spaceID
        self.cwd = cwd
        self.model = model
        self.thinking = thinking
        self.initialPrompt = initialPrompt
    }
}

/// String-backed failure for remote agent creation — the message crosses the
/// wire verbatim.
public struct RemoteCreateAgentError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
import ShepherdCore
import ShepherdProtocol

/// A pane-control request from an agent's panes extension, decoded from the
/// wire and handed to the GUI.
///
/// The server owns PTYs but not layouts: which panes exist, how they are split,
/// and which is focused all live in the view model. So pane requests are
/// forwarded rather than handled here, and the server only correlates the
/// request id with the reply.
public enum PaneRequest: Hashable, Sendable {
    case list(agentID: AgentID)
    case open(agentID: AgentID, axis: SplitAxis, cwd: String?, relativeTo: PaneID?, command: String?)
    case close(agentID: AgentID, paneID: PaneID)
    case resizeSplit(agentID: AgentID, split: PaneNode, ratio: Double)
    case focus(agentID: AgentID, paneID: PaneID)
    case sendInput(agentID: AgentID, paneID: PaneID, text: String, submit: Bool)
    case read(agentID: AgentID, paneID: PaneID)

    public var agentID: AgentID {
        switch self {
        case .list(let agentID),
             .open(let agentID, _, _, _, _),
             .close(let agentID, _),
             .resizeSplit(let agentID, _, _),
             .focus(let agentID, _),
             .sendInput(let agentID, _, _, _),
             .read(let agentID, _):
            return agentID
        }
    }
}

/// A handler's answer, before the server stamps it with the request id.
public enum PaneOutcome: Hashable, Sendable {
    case ok
    case failed(code: String, message: String)
    case panes([PaneInfo])
    case opened(PaneInfo)
    case content(paneID: PaneID, lines: [String])

    /// Pair the outcome with the request it answers.
    public func withID(_ id: Int) -> ExtensionReply {
        switch self {
        case .ok:
            return .ok(id: id)
        case .failed(let code, let message):
            return .error(id: id, code: code, message: message)
        case .panes(let panes):
            return .panes(id: id, panes: panes)
        case .opened(let pane):
            return .paneOpened(id: id, pane: pane)
        case .content(let paneID, let lines):
            return .paneContent(id: id, paneID: paneID, lines: lines)
        }
    }
}

/// An automation-management request from any pi session (the automation
/// skill), forwarded to the GUI like pane requests — the GUI owns the run
/// lifecycle (space resolution, agent spawn/kill).
public enum AutomationRequest: Hashable, Sendable {
    case create(automation: Automation, start: Bool)
    case list
    case update(automationID: AutomationID, name: String?, prompt: String?, cwd: String?, enabled: Bool?)
    case delete(automationID: AutomationID)
    case start(automationID: AutomationID)
    case stop(automationID: AutomationID)
}

/// A handler's answer, before the server stamps it with the request id.
public enum AutomationOutcome: Hashable, Sendable {
    case ok
    case failed(code: String, message: String)
    case automations([AutomationInfo])

    public func withID(_ id: Int) -> ExtensionReply {
        switch self {
        case .ok:
            return .ok(id: id)
        case .failed(let code, let message):
            return .error(id: id, code: code, message: message)
        case .automations(let automations):
            return .automations(id: id, automations: automations)
        }
    }
}

/// A peer-thread request from a Shepherd agent: see the fleet, message
/// another thread, or spawn a new one. Forwarded to the GUI like pane
/// requests — it owns agent lifecycle and pi input.
public enum AgentPeerRequest: Hashable, Sendable {
    case list(agentID: AgentID)
    case send(agentID: AgentID, targetAgentID: AgentID, text: String)
    case spawn(agentID: AgentID, cwd: String, prompt: String)

    public var agentID: AgentID {
        switch self {
        case .list(let agentID), .send(let agentID, _, _), .spawn(let agentID, _, _):
            return agentID
        }
    }
}

/// A handler's answer, before the server stamps it with the request id.
public enum AgentPeerOutcome: Hashable, Sendable {
    case ok
    case failed(code: String, message: String)
    case agents([AgentPeerInfo])

    public func withID(_ id: Int) -> ExtensionReply {
        switch self {
        case .ok:
            return .ok(id: id)
        case .failed(let code, let message):
            return .error(id: id, code: code, message: message)
        case .agents(let agents):
            return .agents(id: id, agents: agents)
        }
    }
}
