import Foundation
import ShepherdCore

/// One agent on one host: agent ids are only unique within the host that made them.
struct AgentRef: Hashable, Codable, Sendable {
    var host: UUID
    var agent: AgentID
}
