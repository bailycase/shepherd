import Foundation
import Testing

/// R0 observes raw JSON, so a decoder default cannot hide a changed field.
public enum WireGolden {
    public static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    public static func read() throws -> [String: Any] {
        try object(Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/c-wire.json")))
    }

    public static func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    public static func check(_ expected: Any?, _ actual: Any?, at path: String, step: String) throws {
        guard let diff = try difference(expected, actual, at: path) else { return }
        try fail(step: step, expected: diff.0, actual: diff.1)
    }

    public static func fail(step: String, expected: String, actual: String) throws -> Never {
        try ValidationEvidence.record(in: ValidationEvidence.directory, step: step, status: "failed",
                                      expected: expected, actual: actual)
        throw Mismatch(description: "c-wire: expected \(expected)\nactual: \(actual)")
    }

    private struct Mismatch: Error, CustomStringConvertible {
        let description: String
    }

    private static func difference(_ expected: Any?, _ actual: Any?, at path: String) throws -> (String, String)? {
        if let expected = expected as? [String: Any], let actual = actual as? [String: Any] {
            for key in Set(expected.keys).union(actual.keys).sorted() {
                if let diff = try difference(expected[key], actual[key], at: "\(path).\(key)") { return diff }
            }
            return nil
        }
        if let expected = expected as? [Any], let actual = actual as? [Any] {
            for index in 0..<max(expected.count, actual.count) {
                if let diff = try difference(expected.indices.contains(index) ? expected[index] : nil,
                                             actual.indices.contains(index) ? actual[index] : nil,
                                             at: "\(path)[\(index)]") { return diff }
            }
            return nil
        }
        func display(_ value: Any?) throws -> String {
            guard let value else { return "<missing>" }
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        let old = try display(expected), new = try display(actual)
        return old == new ? nil : ("\(path) = \(old)", "\(path) = \(new)")
    }
}
