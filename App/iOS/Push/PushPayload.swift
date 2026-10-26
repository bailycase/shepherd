import Foundation
import ShepherdCore

/// The `shepherd` key inside an APNs push payload:
/// `{ "aps": { ... }, "shepherd": { "hostID": "...", "agentID": "...", "eventID": "...", "kind": "..." } }`
struct PushPayload: Codable, Hashable, Sendable {
    let hostID: String
    let agentID: String
    let eventID: String
    let kind: String

    /// Parses from the raw userInfo dictionary APNs delivers.
    static func from(_ userInfo: [AnyHashable: Any]) -> PushPayload? {
        guard let shepherd = userInfo["shepherd"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: shepherd) else { return nil }
        guard let payload = try? JSONDecoder().decode(PushPayload.self, from: data),
              payload.agentRef != nil, UUID(uuidString: payload.eventID) != nil else { return nil }
        return payload
    }

    /// The agent reference to navigate to, if the host is known.
    var agentRef: AgentRef? {
        guard let uuid = UUID(uuidString: hostID), let agent = UUID(uuidString: agentID) else { return nil }
        return AgentRef(host: uuid, agent: AgentID(rawValue: agent.uuidString.lowercased()))
    }
}
