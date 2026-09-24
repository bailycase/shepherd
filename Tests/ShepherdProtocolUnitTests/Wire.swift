import Foundation
import ShepherdProtocol

/// Helpers for pushing values through the real NDJSON framing.
enum Wire {
    /// Encode as one NDJSON line and decode the payload back.
    static func roundTrip<T: Codable>(_ value: T) throws -> T {
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
