import Foundation

/// A helper command a test relies on (mkdtemp, git, a setup script) failed.
public struct CommandFailure: Error, CustomStringConvertible {
    public let command: String
    public let detail: String

    public init(_ command: String, _ detail: String) {
        self.command = command
        self.detail = detail
    }

    public var description: String { "\(command) failed: \(detail)" }
}

/// A new, uniquely named scratch directory inside the process's isolation root, removed by the
/// caller (and with the root when the process exits). `mkdtemp` guarantees no two parallel tests
/// share one, and the root is short enough for socket paths (`sun_path` caps them at 104 bytes).
public func makeScratchDirectory(_ label: String = "shepherd") throws -> URL {
    var template = Array(TestProcess.root.appendingPathComponent("\(label)-XXXXXX").path.utf8CString)
    let created = template.withUnsafeMutableBufferPointer { buffer -> String? in
        guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
        return String(cString: base)
    }
    guard let created else {
        throw CommandFailure("mkdtemp \(label)-XXXXXX", String(cString: strerror(errno)))
    }
    return URL(fileURLWithPath: created, isDirectory: true)
}
