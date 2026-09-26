import Foundation

/// Defensive readers for pi's local configuration. Lives in ShepherdSessions
/// so the host side can answer a remote client's model listing with the same
/// logic the local New Agent sheet uses.
public enum PiConfig {
    /// pi's own override for its agent directory (config and sessions).
    public static let agentDirectoryEnvKey = "PI_CODING_AGENT_DIR"

    /// `~/.pi/agent`, or wherever `PI_CODING_AGENT_DIR` moves it, the same way pi resolves it.
    /// A blank value is ignored and `~` is expanded.
    public static func agentDirectory(environment: [String: String]) -> URL {
        agentDirectory(environment: environment,
                       otherwise: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent", isDirectory: true))
    }

    /// The directory `environment`'s `PI_CODING_AGENT_DIR` names, else `fallback`.
    public static func agentDirectory(environment: [String: String], otherwise fallback: URL) -> URL {
        if let override = environment[agentDirectoryEnvKey],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        return fallback
    }

    /// Where pi keeps its session files: `<agent directory>/sessions`.
    public static func sessionsDirectory(environment: [String: String]) -> URL {
        agentDirectory(environment: environment).appendingPathComponent("sessions", isDirectory: true)
    }

    /// The thinking levels models.json configures, per "provider/id": a model's own
    /// `thinkingLevelMap` (`providers.<name>.models[]`), with a `modelOverrides.<id>` map laid
    /// over it, as pi composes them. A level mapped to null is present with a nil value (pi
    /// drops it); a level absent from the map is absent. Empty when unreadable.
    public static func thinkingLevelMaps(in directory: URL) -> [String: [String: String?]] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("models.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [String: Any] else { return [:] }
        func map(_ value: Any?) -> [String: String?]? {
            guard let object = value as? [String: Any] else { return nil }
            var result: [String: String?] = [:]
            for (level, mapped) in object {
                if mapped is NSNull { result[level] = .some(nil) } else if let mapped = mapped as? String { result[level] = mapped }
            }
            return result
        }
        var maps: [String: [String: String?]] = [:]
        for (name, value) in providers {
            guard let provider = value as? [String: Any] else { continue }
            for case let model as [String: Any] in provider["models"] as? [Any] ?? [] {
                guard let id = (model["id"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
                      let levels = map(model["thinkingLevelMap"]) else { continue }
                maps["\(name)/\(id)"] = levels
            }
            for (id, override) in provider["modelOverrides"] as? [String: Any] ?? [:] {
                guard let levels = map((override as? [String: Any])?["thinkingLevelMap"]) else { continue }
                maps["\(name)/\(id)", default: [:]].merge(levels) { $1 }
            }
        }
        return maps
    }

    /// Models from models.json as "provider/id", the form `--model` and `setModel` take; empty
    /// when unreadable. pi's own shape (`providers.<name>.models[].id`) names each model's
    /// provider and whether it reasons (pi's default is no). Other shapes are read leniently:
    /// arrays of strings or of objects with an "id"/"name", at the top level or under wrapper
    /// keys, taken as they are and assumed to reason.
    public static func modelEntries(in directory: URL) -> [PiModelCatalog.Entry] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("models.json")),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var entries: [PiModelCatalog.Entry] = []
        var seen = Set<String>()

        func add(_ id: String, reasoning: Bool) {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            entries.append(PiModelCatalog.Entry(id: trimmed, reasoning: reasoning))
        }

        if let providers = (root as? [String: Any])?["providers"] as? [String: Any] {
            for name in providers.keys.sorted() {
                guard let models = (providers[name] as? [String: Any])?["models"] as? [Any] else { continue }
                for case let model as [String: Any] in models {
                    guard let id = model["id"] as? String, !id.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    add("\(name)/\(id.trimmingCharacters(in: .whitespaces))", reasoning: model["reasoning"] as? Bool ?? false)
                }
            }
            return entries
        }

        func harvest(_ value: Any, depth: Int) {
            guard depth < 4 else { return }
            if let array = value as? [Any] {
                for element in array {
                    if let id = element as? String {
                        add(id, reasoning: true)
                    } else if let object = element as? [String: Any],
                              let id = (object["id"] ?? object["name"] ?? object["model"]) as? String {
                        add(id, reasoning: true)
                    }
                }
            } else if let object = value as? [String: Any] {
                // Unknown wrapper shape: descend through values looking for
                // arrays of model ids (sorted keys for stable order).
                for key in object.keys.sorted() {
                    harvest(object[key] as Any, depth: depth + 1)
                }
            }
        }

        harvest(root, depth: 0)
        return entries
    }

    /// `modelEntries`' ids.
    public static func modelIDs(in directory: URL) -> [String] {
        modelEntries(in: directory).map(\.id)
    }

    /// The model pi starts a new session with when none is passed, as "provider/id" (settings.json's
    /// defaultProvider and defaultModel), if both are set. Never the bare id: several providers can
    /// serve one id, and `--model` with a bare id may pick another.
    public static func defaultModel(in directory: URL) -> String? {
        guard let object = settings(in: directory),
              let provider = object["defaultProvider"] as? String, !provider.isEmpty,
              let model = object["defaultModel"] as? String, !model.isEmpty else { return nil }
        return "\(provider)/\(model)"
    }

    /// The pi packages and extensions pi loads from its own settings.json, as declared there: each
    /// package's source ("npm:@example/pi-tools@1.0.0", in the string or the object form), then
    /// each extension path. Shepherd's own come by `-e` and are not among them.
    public static func installedExtensions(in directory: URL) -> [String] {
        guard let object = settings(in: directory) else { return [] }
        let packages = (object["packages"] as? [Any] ?? []).compactMap { entry -> String? in
            if let source = entry as? String { return source }
            return (entry as? [String: Any])?["source"] as? String
        }
        let extensions = object["extensions"] as? [Any] ?? []
        return (packages + extensions.compactMap { $0 as? String })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// pi's compaction settings for `model` ("provider/id"), as pi resolves them: the project's
    /// `.pi/settings.json` over the agent directory's, a `compaction.modelOverrides` entry for the
    /// model over the ordinary values, each field falling back on its own to pi's default. Read
    /// only; a value pi would reject reads as the default.
    public static func compactionSettings(model: String?, cwd: String?, in directory: URL) -> PiCompactionSettings {
        var merged: [String: Any] = [:]
        var overrides: [String: Any] = [:]
        for object in [settings(in: directory), cwd.flatMap { settings(in: URL(fileURLWithPath: $0).appendingPathComponent(".pi")) }] {
            guard let compaction = object?["compaction"] as? [String: Any] else { continue }
            for (key, value) in compaction where key != "modelOverrides" { merged[key] = value }
            if let model, let table = compaction["modelOverrides"] as? [String: Any], let entry = table[model] as? [String: Any] {
                overrides.merge(entry) { $1 }
            }
        }
        func count(_ key: String, _ fallback: Int) -> Int {
            for source in [overrides, merged] {
                if let number = source[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.intValue >= 0,
                   Double(number.intValue) == number.doubleValue {
                    return number.intValue
                }
            }
            return fallback
        }
        let defaults = PiCompactionSettings()
        return PiCompactionSettings(enabled: (merged["enabled"] as? Bool) ?? defaults.enabled,
                                    reserveTokens: count("reserveTokens", defaults.reserveTokens),
                                    keepRecentTokens: count("keepRecentTokens", defaults.keepRecentTokens))
    }

    private static func settings(in directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// pi's `compaction` settings (docs/settings.md): whether it compacts on its own, what it
/// reserves below the window (it compacts once the context passes `window - reserveTokens`),
/// and what it keeps as it is.
public struct PiCompactionSettings: Equatable, Sendable {
    public var enabled: Bool
    public var reserveTokens: Int
    public var keepRecentTokens: Int

    public init(enabled: Bool = true, reserveTokens: Int = 16_384, keepRecentTokens: Int = 20_000) {
        self.enabled = enabled
        self.reserveTokens = reserveTokens
        self.keepRecentTokens = keepRecentTokens
    }
}
