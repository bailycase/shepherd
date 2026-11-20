import Foundation

/// Step records consumed by scripts/validate.py. Direct Swift test runs need no artifact directory.
public enum ValidationEvidence {
    public static var directory: URL? {
        ProcessInfo.processInfo.environment["SHEPHERD_VALIDATION_DIR"].map { URL(fileURLWithPath: $0) }
    }

    public static func record(in directory: URL?, step: String, appearance: String? = nil, status: String,
                       expected: String, actual: String, evidence: [String] = []) throws {
        guard let directory else { return }
        let steps = directory.appendingPathComponent("steps", isDirectory: true)
        try FileManager.default.createDirectory(at: steps, withIntermediateDirectories: true)
        var record: [String: Any] = ["step": step, "status": status, "expected": expected, "actual": actual, "evidence": evidence]
        if let appearance { record["appearance"] = appearance }
        let name = appearance.map { "\(step)-\($0)" } ?? step
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(
            to: steps.appendingPathComponent("\(name).json"), options: .atomic)
    }
}
