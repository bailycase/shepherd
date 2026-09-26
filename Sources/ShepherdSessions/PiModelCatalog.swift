import Foundation
import ShepherdCore
import ShepherdProtocol

/// The live model catalog, asked from pi itself (`pi --list-models`) — models
/// are dynamic (catalog updates, auth state), so no config file is the truth.
/// Runs through a login shell exactly like agent spawns (`PiLaunch.listModels`). One per
/// `PiSetup`, kept for its lifetime: the catalog changes on `pi update`, not mid-session, and
/// `invalidate()` forgets it.
public final class PiModelCatalog: @unchecked Sendable {
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

    /// What starts pi.
    public let engine: PiEngine
    /// The pi home whose models.json answers when pi can't be asked.
    public let home: URL
    private let lock = NSLock()
    private var cached: [Entry]?

    public init(engine: PiEngine, home: URL) {
        self.engine = engine
        self.home = home
    }

    /// `provider/model` ids in catalog order; empty when pi is missing or
    /// errors. Blocking — call off the main thread and off the server queue.
    public func modelIDs() -> [String] { entries().map(\.id) }

    /// pi's catalog, or models.json's models when pi cannot be asked. Blocking, like `entries()`.
    public func entriesOrConfigured() -> [Entry] {
        let asked = entries()
        return asked.isEmpty ? PiConfig.modelEntries(in: home) : asked
    }

    /// Forgets the kept catalog, so the next ask runs pi again.
    public func invalidate() {
        lock.withLock { cached = nil }
    }

    /// Blocking, like `modelIDs()`.
    public func entries() -> [Entry] {
        if let cached = lock.withLock({ cached }) { return cached }

        let process = Process()
        let line = PiLaunch.listModels(engine: engine)
        process.executableURL = URL(fileURLWithPath: line.argv[0])
        process.arguments = Array(line.argv.dropFirst())
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

        let entries = Self.parseEntries(String(decoding: data, as: UTF8.self))
        lock.withLock { cached = entries }
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
    /// `levelMaps` (models.json's `thinkingLevelMap`s) name the levels of the reasoning models
    /// they cover (`ThinkingLevel.supported`).
    public init(entries: [PiModelCatalog.Entry], defaultModel: String?, levelMaps: [String: [String: String?]] = [:]) {
        var levels: [String: [String]] = [:]
        for entry in entries where entry.reasoning {
            guard let map = levelMaps[entry.id] else { continue }
            levels[entry.id] = ThinkingLevel.supported(reasoning: true, levelMap: map).map(\.rawValue)
        }
        self.init(models: entries.map(\.id), defaultModel: defaultModel,
                  withoutThinking: entries.filter { !$0.reasoning }.map(\.id), thinkingLevels: levels.isEmpty ? nil : levels)
    }

    /// The listing as catalog rows, for a picker and the thinking chip. A model the listing does
    /// not say takes no thinking level reasons (`takesThinking`).
    public var entries: [PiModelCatalog.Entry] {
        let plain = Set(withoutThinking ?? [])
        return models.map { PiModelCatalog.Entry(id: $0, reasoning: !plain.contains($0)) }
    }
}
