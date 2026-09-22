import Foundation
import ShepherdCore

/// Small builders for core model values. Every call gets fresh ids unless told otherwise.
enum Fixture {
    /// One space with one agent tab whose single leaf is owned by the agent — the smallest
    /// state that passes validation with every ownership field set.
    static func state() -> ShepherdState {
        let space = Space(name: "alpha", path: "/tmp/alpha")
        let agentID = AgentID()
        let pane = LeafPane(cwd: space.path, agentID: agentID)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: agentID, name: "worker", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        return ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
    }

    static func leaf(_ cwd: String = "/tmp") -> LeafPane { LeafPane(cwd: cwd) }

    static func encodeObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return object
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}
