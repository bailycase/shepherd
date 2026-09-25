import Foundation

/// Defensive readers for pi's local configuration. Lives in ShepherdSessions
/// so the host side can answer a remote client's model listing with the same
/// logic the local New Agent sheet uses.
public enum PiConfig {
    /// pi's own override for its agent directory (config and sessions).
    public static let agentDirectoryEnvKey = "PI_CODING_AGENT_DIR"

    /// `~/.pi/agent`, or wherever `PI_CODING_AGENT_DIR` moves it, the same way pi resolves it.
    /// A blank value is ignored and `~` is expanded.
    public static func agentDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[agentDirectoryEnvKey],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent", isDirectory: true)
    }

    /// Where pi keeps its session files: `<agent directory>/sessions`.
    public static func sessionsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        agentDirectory(environment: environment).appendingPathComponent("sessions", isDirectory: true)
    }

    /// Models from models.json as "provider/id", the form `--model` and `setModel` take; empty
    /// when unreadable. pi's own shape (`providers.<name>.models[].id`) names each model's
    /// provider and whether it reasons (pi's default is no). Other shapes are read leniently:
    /// arrays of strings or of objects with an "id"/"name", at the top level or under wrapper
    /// keys, taken as they are and assumed to reason.
    public static func modelEntries(in directory: URL = agentDirectory()) -> [PiModelCatalog.Entry] {
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
    public static func modelIDs(in directory: URL = agentDirectory()) -> [String] {
        modelEntries(in: directory).map(\.id)
    }

    /// The model pi starts a new session with when none is passed, as "provider/id" (settings.json's
    /// defaultProvider and defaultModel), if both are set. Never the bare id: several providers can
    /// serve one id, and `--model` with a bare id may pick another.
    public static func defaultModel(in directory: URL = agentDirectory()) -> String? {
        guard let object = settings(in: directory),
              let provider = object["defaultProvider"] as? String, !provider.isEmpty,
              let model = object["defaultModel"] as? String, !model.isEmpty else { return nil }
        return "\(provider)/\(model)"
    }

    /// The pi packages and extensions pi loads from its own settings.json, as declared there: each
    /// package's source ("npm:@example/pi-tools@1.0.0", in the string or the object form), then
    /// each extension path. Shepherd's own come by `-e` and are not among them.
    public static func installedExtensions(in directory: URL = agentDirectory()) -> [String] {
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

    private static func settings(in directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
