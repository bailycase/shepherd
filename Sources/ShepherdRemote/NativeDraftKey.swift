import Foundation
import ShepherdCore

/// Device-local drafts never cross host or agent boundaries.
public enum NativeDraftKey {
    public static func prefix(host: UUID) -> String { "shepherd.ios.draft.\(host.uuidString)/" }
    public static func text(host: UUID, agent: AgentID) -> String { prefix(host: host) + agent.rawValue + "/text" }
    public static func images(host: UUID, agent: AgentID) -> String { prefix(host: host) + agent.rawValue + "/images" }
}
