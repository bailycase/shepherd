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

    private static var agentDirectory: URL { agentDirectory() }

    /// Model ids from ~/.pi/agent/models.json; empty when unreadable. Accepts
    /// arrays of strings or of objects with an "id"/"name", at the top level
    /// or under common wrapper keys.
    public static func modelIDs() -> [String] {
        guard let data = try? Data(contentsOf: agentDirectory.appendingPathComponent("models.json")),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var ids: [String] = []
        var seen = Set<String>()

        func add(_ id: String) {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            ids.append(trimmed)
        }

        func harvest(_ value: Any, depth: Int) {
            guard depth < 4 else { return }
            if let array = value as? [Any] {
                for element in array {
                    if let id = element as? String {
                        add(id)
                    } else if let object = element as? [String: Any],
                              let id = (object["id"] ?? object["name"] ?? object["model"]) as? String {
                        add(id)
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
        return ids
    }

    /// defaultModel from ~/.pi/agent/settings.json, if readable.
    public static func defaultModel() -> String? {
        guard let object = settings(),
              let model = object["defaultModel"] as? String,
              !model.isEmpty else { return nil }
        return model
    }

    /// The model pi starts a new session with when none is passed, as "provider/id" (settings.json's
    /// defaultProvider and defaultModel), if both are set.
    public static func defaultModelReference(in directory: URL = agentDirectory()) -> String? {
        guard let object = settings(in: directory),
              let provider = object["defaultProvider"] as? String, !provider.isEmpty,
              let model = object["defaultModel"] as? String, !model.isEmpty else { return nil }
        return "\(provider)/\(model)"
    }

    private static func settings(in directory: URL = agentDirectory) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
