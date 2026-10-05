import CoreFoundation
import Foundation

/// Settings for Shepherd's bounded use of Pi's native codemode factory.
public enum PiCodemode {
    public static func projectOverride(in settings: [String: Any]) -> Bool? {
        (settings["codemode"] as? [String: Any])?["enabled"] as? Bool
    }

    /// nil removes the project override. Other Pi settings and literal tool allowlists survive.
    public static func setting(_ enabled: Bool?, in settings: [String: Any]) throws -> [String: Any] {
        if let value = settings["extensions"], !(value is [Any]) { throw PiHomeError("extensions must be an array.") }
        if let value = settings["codemode"], !(value is [String: Any]) { throw PiHomeError("codemode must be a JSON object.") }
        var codemode = settings["codemode"] as? [String: Any] ?? [:]
        if let value = codemode["enabled"], (value as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) != true {
            throw PiHomeError("codemode.enabled must be true or false.")
        }
        var result = settings
        codemode["enabled"] = enabled
        result["codemode"] = codemode.isEmpty ? nil : codemode

        // The unconfigured built-in would register the same tool without Shepherd's bounds.
        var extensions = (settings["extensions"] as? [Any] ?? []).filter {
            guard let entry = $0 as? String else { return true }
            return !["builtin:codemode", "+builtin:codemode", "-builtin:codemode"].contains(entry)
        }
        if enabled != nil { extensions.append("-builtin:codemode") }
        result["extensions"] = extensions.isEmpty ? nil : extensions
        return result
    }
}

extension PiHome {
    /// Written under Pi's settings lock before an agent starts, never into a project's files.
    /// Pi's trusted-project merge resolves codemode.enabled before the extension registers it.
    public func configureCodemode(_ enabled: Bool) throws {
        let notes = try PiSettingsFile(url: settings).update { settings in
            settings = try PiCodemode.setting(enabled, in: settings)
            return []
        }
        if let note = notes.first { throw PiHomeError(note) }
    }
}
