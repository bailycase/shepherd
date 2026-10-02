import Foundation

/// A node on this machine's PATH that can run the sign-in bridge's script (22.6 or later), for
/// the tests that run a script of Shepherd's on node with a stand-in for pi's SDK. Nil when there
/// is none, and those tests skip.
public enum TestNode {
    public static let url: URL? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let places = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let node = places.map({ URL(fileURLWithPath: $0).appendingPathComponent("node") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
        let process = Process()
        process.executableURL = node
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let version = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().split(separator: ".").compactMap { Int($0) }
        guard version.count >= 2, version[0] > 22 || (version[0] == 22 && version[1] >= 6) else { return nil }
        return node
    }()
}
