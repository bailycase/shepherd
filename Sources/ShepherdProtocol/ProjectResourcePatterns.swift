import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// pi's resource arrays in `settings.json` (`skills`, `prompts`, `extensions`): `!glob` excludes,
/// `+path` force-includes and `-path` force-excludes an exact path, relative to the settings
/// file's folder or absolute. This is how `pi config` turns one resource on or off, so a space's
/// toggle stays pi's own format.
public enum ProjectResourcePatterns {
    /// Whether pi loads the resource at absolute `path` under `entries` (pi's `isEnabledByOverrides`):
    /// excludes, then force-includes, then force-excludes, each later rule winning. A skill also
    /// matches by its folder.
    public static func isEnabled(_ path: String, entries: [String], base: String, otherwise: Bool = true) -> Bool {
        let names = candidates(path, base: base), globbed = candidates(path, base: base, names: true)
        var enabled = otherwise
        // ponytail: `!` uses fnmatch, close to pi's minimatch; `**` and brace globs differ.
        if entries.contains(where: { entry in entry.hasPrefix("!") && globbed.contains { glob(String(entry.dropFirst()), $0) } }) { enabled = false }
        if entries.contains(where: { $0.hasPrefix("+") && names.contains(exact($0)) }) { enabled = true }
        if entries.contains(where: { $0.hasPrefix("-") && names.contains(exact($0)) }) { enabled = false }
        return enabled
    }

    /// `entries` with the resource at `path` turned on or off. A space resource is on unless an
    /// entry turns it off, so on removes its overrides and off adds `-<relative path>`. A global
    /// one is named in full and overridden only where the space differs from `inherited` (what the
    /// host's own settings say), as `pi config` does for an inherited item.
    public static func setting(_ enabled: Bool, path: String, global: Bool, inherited: Bool = true, base: String, in entries: [String]) -> [String] {
        let names = candidates(path, base: base)
        var result = entries.filter { entry in
            guard let first = entry.first, "!+-".contains(first) else { return !(global && entry == path) }
            return !names.contains(exact(entry))
        }
        if global {
            if enabled != inherited { result += [path, (enabled ? "+" : "-") + path] }
        } else if !enabled {
            result.append("-" + relative(path, from: base))
        }
        return result
    }

    /// `path` from `base`, both absolute: `skills/a/SKILL.md`, or `../.pi/skills/a/SKILL.md`.
    public static func relative(_ path: String, from base: String) -> String {
        let to = path.split(separator: "/"), from = base.split(separator: "/")
        var common = 0
        while common < min(to.count, from.count), to[common] == from[common] { common += 1 }
        return (Array(repeating: "..", count: from.count - common) + to[common...].map(String.init)).joined(separator: "/")
    }

    private static func exact(_ entry: String) -> String {
        let target = String(entry.dropFirst())
        return target.hasPrefix("./") ? String(target.dropFirst(2)) : target
    }

    /// The names an exact entry can match: the path relative to `base` and the absolute path, and
    /// for a SKILL.md the same for its folder. A glob also matches the last component (`names`).
    private static func candidates(_ path: String, base: String, names: Bool = false) -> [String] {
        var result = [relative(path, from: base), path] + (names ? [(path as NSString).lastPathComponent] : [])
        if (path as NSString).lastPathComponent == "SKILL.md" {
            let folder = (path as NSString).deletingLastPathComponent
            result += [relative(folder, from: base), folder] + (names ? [(folder as NSString).lastPathComponent] : [])
        }
        return result
    }

    private static func glob(_ pattern: String, _ name: String) -> Bool {
        let pattern = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
        return fnmatch(pattern, name, 0) == 0
    }
}
