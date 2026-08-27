import Foundation

/// Defensive readers for pi's local configuration. Lives in ShepherdSessions
/// so the host side can answer a remote client's model listing with the same
/// logic the local New Agent sheet uses.
public enum PiConfig {
    private static var agentDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
    }

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
        guard let data = try? Data(contentsOf: agentDirectory.appendingPathComponent("settings.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = object["defaultModel"] as? String,
              !model.isEmpty else { return nil }
        return model
    }
}
