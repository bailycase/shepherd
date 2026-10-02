import Foundation
import ShepherdCore
import ShepherdProtocol

/// The live model catalog, asked of Shepherd's pi itself (`get_available_models` over RPC through
/// the launcher in its home, `PiLaunch.listModels`): models are dynamic (engine updates, sign-ins),
/// so no config file is the truth. One per `PiSetup`: an answer is kept until the home's
/// `auth.json`, `models.json` or `settings.json` changes (a sign-in, a re-import), or
/// `invalidate()` forgets it.
public final class PiModelCatalog: @unchecked Sendable {
    /// One catalog row: `provider/model`, its context window as pi prints it ("200K", "1M"),
    /// and whether it takes a thinking level.
    public struct Entry: Equatable, Sendable {
        public var id: String
        public var context: String?
        /// The window in tokens, when pi reported one.
        public var contextWindow: Int?
        public var reasoning: Bool
        public var api: String?
        /// The composed model's levels, including built-in and extension-supplied maps.
        public var thinkingLevels: [String]?

        public init(id: String, context: String? = nil, contextWindow: Int? = nil, reasoning: Bool = true, api: String? = nil, thinkingLevels: [String]? = nil) {
            self.id = id
            self.context = context
            self.contextWindow = contextWindow
            self.reasoning = reasoning
            self.api = api
            self.thinkingLevels = thinkingLevels
        }

        public var provider: String { id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? id }
    }

    /// Shepherd's pi home, whose launcher answers and whose models.json answers when pi can't.
    public let files: PiHome
    /// Readies the home before pi is asked; false when no pi may start there.
    private let ready: @Sendable () -> Bool
    private let timeout: TimeInterval
    private let environment: [String: String]
    private let lock = NSLock()
    private var cached: (fingerprint: [Double], entries: [Entry], defaultModel: String?)?

    public convenience init(home: PiHome, ready: @escaping @Sendable () -> Bool) {
        self.init(home: home, timeout: 20, ready: ready)
    }

    init(home: PiHome, timeout: TimeInterval, environment: [String: String] = ProcessInfo.processInfo.environment,
         ready: @escaping @Sendable () -> Bool) {
        files = home
        self.timeout = timeout
        self.environment = environment
        self.ready = ready
    }

    /// The home's folder.
    public var home: URL { files.directory }

    /// `provider/model` ids in catalog order; empty when pi is missing or
    /// errors. Blocking — call off the main thread and off the server queue.
    public func modelIDs() -> [String] { entries().map(\.id) }

    /// The shared pre-creation listing, with the same speed support rules as a running thread.
    public func listing() -> ModelListing {
        let entries = entriesOrConfigured()
        var listing = ModelListing(entries: entries, defaultModel: PiConfig.defaultModel(in: home) ?? lock.withLock { cached?.defaultModel },
                                   levelMaps: PiConfig.thinkingLevelMaps(in: home))
        let offers = ServiceTierOffers(home: files)
        let tiers = entries.compactMap { entry -> (String, [String])? in
            let parts = entry.id.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let tiers = offers.tiers(for: ServiceTierModel(provider: parts[0], id: parts[1], api: entry.api))
            return tiers.isEmpty ? nil : (entry.id, tiers.map(\.rawValue))
        }
        listing.serviceTiers = tiers.isEmpty ? nil : Dictionary(tiers, uniquingKeysWith: { first, _ in first })
        return listing
    }

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
        let fingerprint = self.fingerprint()
        if let cached = lock.withLock({ cached }), cached.fingerprint == fingerprint { return cached.entries }

        guard ready() else { return [] }
        let line = PiLaunch.listModels(home: files)
        // Both commands are synchronous in the pinned engine and flush before EOF shuts pi down.
        // The state identifies pi's automatic default when settings don't pin one. No prompt runs.
        let input = Data("{\"id\":\"shepherd-models\",\"type\":\"get_available_models\"}\n{\"id\":\"shepherd-model-state\",\"type\":\"get_state\"}\n".utf8)
        guard let result = try? BoundedCommand.run(line.argv, environment: environment, input: input, timeout: timeout, outputLimit: 8 << 20),
              result.status == 0 else { return [] }

        let output = String(decoding: result.output, as: UTF8.self)
        let entries = Self.parseEntries(output)
        lock.withLock { cached = (fingerprint, entries, Self.parseDefaultModel(output)) }
        return entries
    }

    /// The modification dates of what the catalog depends on in the home (-1 while missing).
    private func fingerprint() -> [Double] {
        ["auth.json", "models.json", "settings.json", CLIProxyAPIStore.fileName].map { name in
            var info = stat()
            guard stat(files.directory.appendingPathComponent(name).path, &info) == 0 else { return -1 }
            return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        }
    }

    static func parse(_ output: String) -> [String] { parseEntries(output).map(\.id) }

    // Decode only capability fields, never endpoints, headers or other provider configuration.
    private struct Model: Decodable {
        var provider: String
        var id: String
        var contextWindow: Int?
        var reasoning: Bool
        var api: String?
        var thinkingLevelMap: [String: String?]?
    }
    private struct Response: Decodable {
        struct Payload: Decodable { var models: [Model]?; var model: Model? }
        var type: String
        var id: String?
        var command: String?
        var success: Bool
        var data: Payload?
    }

    static func parseDefaultModel(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard let reply = try? JSONDecoder().decode(Response.self, from: Data(line.utf8)),
                  reply.type == "response", reply.id == "shepherd-model-state", reply.command == "get_state",
                  reply.success, let model = reply.data?.model else { continue }
            return "\(model.provider)/\(model.id)"
        }
        return nil
    }

    /// Decode the matching RPC response, or an older aligned table from an alternate engine.
    static func parseEntries(_ output: String) -> [Entry] {
        for line in output.split(separator: "\n") {
            guard let reply = try? JSONDecoder().decode(Response.self, from: Data(line.utf8)),
                  reply.type == "response", reply.id == "shepherd-models", reply.command == "get_available_models" else { continue }
            guard reply.success, let models = reply.data?.models else { return [] }
            var seen = Set<String>()
            return models.compactMap { model in
                let id = "\(model.provider)/\(model.id)"
                guard seen.insert(id).inserted else { return nil }
                let context = model.contextWindow.map { count in
                    count >= 1_000_000 ? String(format: "%.3gM", Double(count) / 1_000_000)
                        : count >= 1_000 ? String(format: "%.3gK", Double(count) / 1_000) : String(count)
                }
                return Entry(id: id, context: context, contextWindow: model.contextWindow, reasoning: model.reasoning, api: model.api,
                             thinkingLevels: ThinkingLevel.supported(reasoning: model.reasoning, levelMap: model.thinkingLevelMap).map(\.rawValue))
            }
        }
        // Keep accepting the older table format from alternate/debug engines.
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
            if let offered = entry.thinkingLevels {
                levels[entry.id] = offered
            } else if let map = levelMaps[entry.id] {
                levels[entry.id] = ThinkingLevel.supported(reasoning: true, levelMap: map).map(\.rawValue)
            }
        }
        self.init(models: entries.map(\.id), defaultModel: defaultModel,
                  withoutThinking: entries.filter { !$0.reasoning }.map(\.id), thinkingLevels: levels.isEmpty ? nil : levels)
        let contexts = entries.compactMap { entry in entry.context.map { (entry.id, $0) } }
        self.contexts = contexts.isEmpty ? nil : Dictionary(contexts, uniquingKeysWith: { first, _ in first })
    }

    /// The listing as catalog rows, for a picker and the thinking chip. A model the listing does
    /// not say takes no thinking level reasons (`takesThinking`).
    public var entries: [PiModelCatalog.Entry] {
        let plain = Set(withoutThinking ?? [])
        return models.map { PiModelCatalog.Entry(id: $0, context: contexts?[$0], reasoning: !plain.contains($0)) }
    }
}
