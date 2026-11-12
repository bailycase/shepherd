import CryptoKit
import Foundation

/// What a fleet's content index leaves out of a checkout (slice 4b): only caches that are bound to the path
/// they were made at and break when moved. Everything else is indexed and travels, `node_modules` and
/// `.env` included. A name alone decides where a name is unambiguous; where it is not (`target`, a
/// virtualenv, a CMake tree) a marker beside or inside the directory does.
///
/// A space can change the answer for its own checkout (`Overrides`): list more paths to keep home, or
/// list a path or name a default rule would leave out that should travel after all.
struct FleetExclusions: Equatable, Sendable {
    /// Why a directory is left out.
    enum Reason: String, Equatable, Sendable {
        case swiftBuild
        case derivedData
        case pythonVirtualenv
        case cmakeBuild
        case cargoTarget
        /// The space says so.
        case space
    }

    /// A space's changes to the defaults (`fleet.snapshotExcludes.<spaceID>`): each entry is a path relative to the checkout
    /// ("packages/web/dist") or, with no "/", a name that matches at any depth ("dist").
    struct Overrides: Codable, Equatable, Sendable {
        /// Kept home as well. Files and directories.
        var excluded: [String] = []
        /// Sent although a default rule would keep the directory home.
        var included: [String] = []

        var isEmpty: Bool { excluded.isEmpty && included.isEmpty }

        init(excluded: [String] = [], included: [String] = []) {
            self.excluded = excluded
            self.included = included
        }

        private enum CodingKeys: String, CodingKey { case excluded, included }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
            included = try c.decodeIfPresent([String].self, forKey: .included) ?? []
        }
    }

    /// What a probe of the filesystem answers while a directory is judged: whether `name` is inside it, and
    /// whether `name` is beside it.
    struct Probe {
        var inside: (String) -> Bool
        var beside: (String) -> Bool
    }

    var overrides: Overrides

    init(overrides: Overrides = Overrides()) { self.overrides = overrides }

    /// Why the directory at `path` (relative to the checkout, "/" separated, never empty) is left out; nil when it travels.
    func reason(forDirectory path: String, probe: Probe) -> Reason? {
        let name = Self.name(of: path)
        if overrides.included.contains(where: { Self.matches($0, path: path, name: name) }) { return nil }
        if overrides.excluded.contains(where: { Self.matches($0, path: path, name: name) }) { return .space }
        switch name {
        case ".build": return .swiftBuild
        case "DerivedData": return .derivedData
        case "target" where probe.beside("Cargo.toml"): return .cargoTarget
        default: break
        }
        if probe.inside("pyvenv.cfg") { return .pythonVirtualenv }
        if probe.inside("CMakeCache.txt") { return .cmakeBuild }
        return nil
    }

    /// Whether a file the space listed stays home. Defaults only ever name directories.
    func excludes(file path: String) -> Bool {
        let name = Self.name(of: path)
        if overrides.included.contains(where: { Self.matches($0, path: path, name: name) }) { return false }
        return overrides.excluded.contains { Self.matches($0, path: path, name: name) }
    }

    /// The marker files whose appearance or removal can change a directory's answer, so an event for one asks for another look.
    static let markers: Set<String> = ["pyvenv.cfg", "CMakeCache.txt", "Cargo.toml"]

    /// A short string that differs whenever the rules do, kept with an index so a rule change is a rescan.
    var key: String {
        let text = ["v1"] + overrides.excluded.sorted().map { "x:" + $0 } + overrides.included.sorted().map { "i:" + $0 }
        return SHA256.hash(data: Data(text.joined(separator: "\n").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func name(of path: String) -> String {
        path.lastIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? path
    }

    private static func matches(_ entry: String, path: String, name: String) -> Bool {
        let trimmed = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
        return trimmed.contains("/") ? trimmed == path : trimmed == name
    }
}
