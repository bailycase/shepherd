import Foundation
import ShepherdProtocol

/// The live model catalog, asked from pi itself (`pi --list-models`) — models
/// are dynamic (catalog updates, auth state), so no config file is the truth.
/// Runs through a login shell exactly like agent spawns, so `pi` resolves
/// from the user's PATH. Cached per process: the catalog changes on `pi
/// update`, not mid-session.
public enum PiModelCatalog {
    /// One catalog row: `provider/model`, its context window as pi prints it ("200K", "1M"),
    /// and whether it takes a thinking level.
    public struct Entry: Equatable, Sendable {
        public var id: String
        public var context: String?
        public var reasoning: Bool

        public init(id: String, context: String? = nil, reasoning: Bool = true) {
            self.id = id
            self.context = context
            self.reasoning = reasoning
        }

        public var provider: String { id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? id }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [Entry]?

    /// `provider/model` ids in catalog order; empty when pi is missing or
    /// errors. Blocking — call off the main thread and off the server queue.
    public static func modelIDs() -> [String] { entries().map(\.id) }

    /// pi's catalog, or models.json's models when pi cannot be asked. Blocking, like `entries()`.
    public static func entriesOrConfigured() -> [Entry] {
        let asked = entries()
        return asked.isEmpty ? PiConfig.modelEntries() : asked
    }

    /// Blocking, like `modelIDs()`.
    public static func entries() -> [Entry] {
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

        let entries = parseEntries(String(decoding: data, as: UTF8.self))
        lock.lock()
        cached = entries
        lock.unlock()
        return entries
    }

    static func parse(_ output: String) -> [String] { parseEntries(output).map(\.id) }

    /// Parse the aligned table: a header row naming the columns, then `provider  model
    /// context  max-out  thinking  images`. The id is the first two fields; the other columns
    /// are read by header position when present.
    static func parseEntries(_ output: String) -> [Entry] {
        var entries: [Entry] = []
        var seen = Set<String>()
        var header: [String] = []
        for (index, line) in output.split(separator: "\n").enumerated() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if index == 0, line.hasPrefix("provider") {
                header = fields
                continue
            }
            guard fields.count >= 2 else { continue }
            let id = "\(fields[0])/\(fields[1])"
            guard seen.insert(id).inserted else { continue }
            func column(_ name: String) -> String? {
                header.firstIndex(of: name).flatMap { fields.indices.contains($0) ? fields[$0] : nil }
            }
            entries.append(Entry(id: id, context: column("context"), reasoning: column("thinking").map { $0 != "no" } ?? true))
        }
        return entries
    }
}

extension ModelListing {
    /// A catalog as a listing: its ids, `defaultModel`, and the models that take no thinking level.
    public init(entries: [PiModelCatalog.Entry], defaultModel: String?) {
        self.init(models: entries.map(\.id), defaultModel: defaultModel,
                  withoutThinking: entries.filter { !$0.reasoning }.map(\.id))
    }
}
