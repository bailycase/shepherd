import Foundation
import ShepherdProtocol

/// Sign-ins in a fleet (slice 2c): `credential:<provider>`, one provider's entry in pi's `auth.json`
/// (a subscription's tokens or an API key), and `mcpAuth:<key>`, one MCP server's sign-in in
/// `mcp-auth.json` (pi's key, `mcp__<name>|<url>`). The value is the entry as pi stores it, sorted
/// keys, inline: there is no sealing and no Keychain (Q4), and a login that lives only in a Mac's
/// Keychain is not in either file and does not travel.
///
/// pi writes both files itself (a sign-in, a token refresh), so a unit is one top level key applied
/// under pi's own lock with every other key left as it is, and pi's rewrites are read back as ops by
/// the watcher. An OAuth refresh token rotates, so each rewrite is a new generation of its unit: it
/// becomes an op at once, and a Mac about to start pi reads its peers' first
/// (`FleetSync.catchUpCredentials`).
///
/// Only a Mac of the fleet ever holds these units: `FleetService` refuses sync to everything else.
final class FleetCredentialsSource: FleetUnitSource {
    enum Kind {
        /// `auth.json`: provider name to its credential.
        case providers
        /// `mcp-auth.json`: pi's key for a server to its sign-in.
        case mcpServers

        var prefix: String { self == .providers ? FleetUnit.credentialKind : FleetUnit.mcpAuthKind }
    }

    private let file: PiSettingsFile
    private let kind: Kind
    private let exclusions: URL
    private var present: [String] = []

    /// `exclusions`: a JSON array of provider names (or MCP server names) this Mac keeps out of the sync, the
    /// switch to pull one out if a real provider misbehaves with a token that is shared (R1).
    init(file: URL, kind: Kind, exclusions: URL) {
        // A write waits briefly for pi's lock; one that can't try again at the next change.
        self.file = PiSettingsFile(url: file, patience: 1)
        self.kind = kind
        self.exclusions = exclusions
    }

    var isCredential: Bool { true }
    var units: [String] { present }
    func owns(_ unit: String) -> Bool { unit.hasPrefix(kind.prefix) }
    func storesBlob(_ unit: String) -> Bool { false }
    var watchedFiles: [URL] { [file.url] }

    /// A file that exists and doesn't parse (pi is mid write) reads as no sign-ins, which would sign
    /// every Mac out: wait until it does. No file at all is no sign-ins.
    var isReady: Bool { Self.load(file.url) != nil }

    static func load(_ url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func read() -> [String: Data] {
        guard let object = Self.load(file.url) else { return [:] }
        let excluded = excludedNames()
        var values: [String: Data] = [:]
        for (key, value) in object {
            let unit = kind.prefix + key
            // A server's entry with no tokens is a sign-in under way (a verifier, a state): not a sign-in yet.
            guard let entry = value as? [String: Any], !entry.isEmpty, FleetUnit.isValid(unit), !excluded.contains(name(of: key)),
                  kind == .providers || entry["tokens"] is [String: Any],
                  let json = FleetPiSettingsSource.canonical(entry) else { continue }
            values[unit] = json
        }
        present = Array(values.keys)
        return values
    }

    func isSeedable(_ unit: String, _ value: Data) -> Bool { true }

    func write(_ unit: String, _ value: Data?, origin: String) throws {
        guard unit.hasPrefix(kind.prefix) else { return }
        let key = String(unit.dropFirst(kind.prefix.count))
        if excludedNames().contains(name(of: key)) {
            throw FleetUnitRefused(description: "\(key) is kept out of the sync on this Mac", quiet: true)
        }
        var entry: [String: Any]?
        if let value {
            guard let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any], !object.isEmpty else {
                throw FleetUnitRefused(description: "\(unit) isn't a sign-in")
            }
            entry = object
        } else if !FileManager.default.fileExists(atPath: file.url.path) {
            return
        }
        let notes = try file.update { object in
            if let entry { object[key] = entry } else { object.removeValue(forKey: key) }
            return []
        }
        // pi's file isn't a JSON object: left as it is (`isReady` is false for that, so this is a race).
        if !notes.isEmpty { throw PiHomeError(notes.joined(separator: " ")) }
    }

    /// The name a person kept out is spelled by: a provider, or the server's name in pi's key
    /// (`mcp__<name>|<url>`, or `mcp__<name>@<space>|<url>` for a space's own sign-in).
    private func name(of key: String) -> String {
        guard kind == .mcpServers, key.hasPrefix("mcp__") else { return key }
        let rest = key.dropFirst("mcp__".count)
        return String(rest.prefix { $0 != "|" && $0 != "@" })
    }

    private func excludedNames() -> Set<String> {
        guard let data = try? Data(contentsOf: exclusions), let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names.map { kind == .mcpServers ? $0.replacingOccurrences(of: "-", with: "_") : $0 })
    }
}
