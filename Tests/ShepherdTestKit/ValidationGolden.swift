import Foundation

/// Ordered observations from an unchanged reference implementation, compared as canonical JSON.
public final class ValidationGolden {
    public let seed: Any
    private let observations: [[String: Any]]
    private var index = 0

    /// Pass `#filePath` from a Swift file directly inside a test target directory under `Tests/`.
    public static func check(_ filename: String, from source: StaticString, completion: String,
                             isolation: isolated (any Actor)? = #isolation,
                             _ scenario: (ValidationGolden) async throws -> Void) async throws {
        let directory = ValidationEvidence.directory
        do {
            let url = URL(fileURLWithPath: String(describing: source)).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(filename)")
            let golden = try ValidationGolden(Data(contentsOf: url))
            try await scenario(golden)
            if golden.index < golden.observations.count {
                throw Difference(expected: try display(golden.observations[golden.index]), actual: "<no observation>")
            }
            for step in ["compare-golden", "complete"] {
                try ValidationEvidence.record(in: directory, step: step, status: "passed", expected: completion, actual: completion)
            }
        } catch {
            let diff = error as? Difference ?? Difference(expected: completion, actual: "Scenario threw: \(error)")
            try? ValidationEvidence.record(in: directory, step: "compare-golden", status: "failed",
                                           expected: diff.expected, actual: diff.actual)
            throw diff
        }
    }

    private init(_ data: Data) throws {
        let json = try Self.object(data)
        guard let seed = json["seed"], let observations = json["observations"] as? [[String: Any]] else {
            throw Difference(expected: "golden seed and observations", actual: try Self.display(json))
        }
        self.seed = seed
        self.observations = observations
    }

    public func observe(_ step: String, _ actual: [String: Any]) throws {
        let row = observations.indices.contains(index) ? observations[index] : nil
        guard let row, row["step"] as? String == step, let expected = row["fields"] as? [String: Any] else {
            throw Difference(expected: try Self.display(row), actual: try Self.display(["step": step, "fields": actual]))
        }
        index += 1
        var before: [String] = [], after: [String] = []
        func compare(_ path: String, _ old: Any?, _ new: Any?) throws {
            if let old = old as? [String: Any], let new = new as? [String: Any] {
                for key in Set(old.keys).union(new.keys).sorted() {
                    try compare("\(path).\(key)", old[key], new[key])
                }
            } else if let old = old as? [Any], let new = new as? [Any] {
                for i in 0..<max(old.count, new.count) {
                    try compare("\(path)[\(i)]", old.indices.contains(i) ? old[i] : nil, new.indices.contains(i) ? new[i] : nil)
                }
            } else {
                let old = try Self.display(old), new = try Self.display(new)
                if old != new {
                    before.append("\(path) = \(old)")
                    after.append("\(path) = \(new)")
                }
            }
        }
        try compare(step, expected, actual)
        if !before.isEmpty {
            throw Difference(expected: before.joined(separator: "\n"), actual: after.joined(separator: "\n"))
        }
    }

    public static func object(_ data: Data) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any] else {
            throw Difference(expected: "JSON object", actual: try display(json))
        }
        return object
    }

    /// Replace known IDs and scratch path roots without masking unexpected values or reordering arrays.
    public static func normalize(_ value: Any, ids: [String: String] = [:], root: String? = nil) -> Any {
        if let object = value as? [String: Any] { return object.mapValues { normalize($0, ids: ids, root: root) } }
        if let array = value as? [Any] { return array.map { normalize($0, ids: ids, root: root) } }
        guard let text = value as? String else { return value }
        if let id = ids[text] { return id }
        if let root, text == root || text.hasPrefix(root + "/") { return "<root>" + text.dropFirst(root.count) }
        return text
    }

    private static func display(_ value: Any?) throws -> String {
        guard let value else { return "<missing>" }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
                      as: UTF8.self)
    }

    private struct Difference: Error, CustomStringConvertible {
        let expected: String
        let actual: String
        var description: String { "Expected: \(expected)\nActual:   \(actual)" }
    }
}
