import Foundation
import ShepherdCore
import ShepherdProtocol
import Testing

/// Helpers for pushing values through the real NDJSON framing.
enum Wire {
    static let projectKey = ProjectExecutionKey(ownerID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                                projectID: ProjectID(rawValue: "project"),
                                                operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

    static func project(named name: String) -> Project {
        var project = Project(id: projectKey.projectID, name: name)
        project.ownerID = projectKey.ownerID
        return project
    }

    /// Encode as one NDJSON line and decode the payload back.
    static func roundTrip<T: Codable>(_ value: T, source: SourceLocation = #_sourceLocation) throws -> T {
        // Check the value, not the spelling of the call: parameterized arrays and local
        // variables must be pinned too. The golden test checks the exact bytes separately.
        if let request = value as? RemoteRequest {
            let pinned = RemoteRequestTests.wireSamples.contains(request) || RemoteRequestTests.roundTripOnly.contains(request)
            try #require(pinned, "c-wire: add RemoteRequest.\(caseName(request)) to the shared wireSamples", sourceLocation: source)
        } else if let reply = value as? RemoteReply {
            let pinned = RemoteReplyTests.wireSamples.contains(reply) || RemoteReplyTests.roundTripOnly.contains(reply)
            try #require(pinned, "c-wire: add RemoteReply.\(caseName(reply)) to the shared wireSamples", sourceLocation: source)
        }
        let line = try NDJSON.encode(value)
        guard line.last == 0x0A else { throw CocoaError(.coderInvalidValue) }
        return try NDJSON.decode(T.self, from: line.dropLast())
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try NDJSON.decode(type, from: Data(json.utf8))
    }

    /// The encoded line as a JSON object, for asserting on keys.
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: NDJSON.encode(value)) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return object
    }

    /// The enum case name of `value` (its first Mirror child label, or its description for
    /// payload-less cases).
    static func caseName(_ value: Any) -> String {
        Mirror(reflecting: value).children.first?.label ?? String(describing: value)
    }
}
