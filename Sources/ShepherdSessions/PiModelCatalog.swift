import Foundation

/// The live model catalog, asked from pi itself (`pi --list-models`) — models
/// are dynamic (catalog updates, auth state), so no config file is the truth.
/// Runs through a login shell exactly like agent spawns, so `pi` resolves
/// from the user's PATH. Cached per process: the catalog changes on `pi
/// update`, not mid-session.
public enum PiModelCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [String]?

    /// `provider/model` ids in catalog order; empty when pi is missing or
    /// errors. Blocking — call off the main thread and off the server queue.
    public static func modelIDs() -> [String] {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "exec pi --list-models"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }

        let ids = parse(String(decoding: data, as: UTF8.self))
        lock.lock()
        cached = ids
        lock.unlock()
        return ids
    }

    /// Parse the aligned table: header row, then `provider  model  …` — the
    /// first two whitespace-separated fields form the id.
    static func parse(_ output: String) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for (index, line) in output.split(separator: "\n").enumerated() {
            if index == 0, line.hasPrefix("provider") { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            let id = "\(fields[0])/\(fields[1])"
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }
}
