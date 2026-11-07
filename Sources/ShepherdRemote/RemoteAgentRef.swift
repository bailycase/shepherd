import Foundation
import ShepherdCore

/// An agent on a remote host: a sidebar selection, or what a banner is about.
public struct RemoteAgentRef: Hashable, Sendable {
    public var hostID: UUID
    public var agentID: AgentID

    public init(hostID: UUID, agentID: AgentID) {
        self.hostID = hostID
        self.agentID = agentID
    }
}
