import Foundation
import ShepherdProtocol

/// Import… and Paste JSON: servers from a JSON file or pasted text. It reads `mcpServers`
/// (Claude Desktop, Cursor, Claude Code), VS Code's `servers`, a bare `{name: entry}` map, or
/// a fragment without its outer braces (`"linear": {…}`).
enum MCPImport {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case invalid(line: Int)
        case noServers

        var description: String {
            switch self {
            case .invalid(let line): "That isn’t valid JSON (line \(line))."
            case .noServers: "No MCP servers in that JSON: it needs \"mcpServers\", \"servers\", or entries with a command or url."
            }
        }
    }

    static func parse(_ text: String) -> Result<[MCPServerEntry], Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed = MCPJSON.parse(trimmed)
        if case .failure = parsed, !trimmed.hasPrefix("{") {
            // A fragment copied out of a bigger file.
            let wrapped = MCPJSON.parse("{" + trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ",")) + "}")
            if case .success = wrapped { parsed = wrapped }
        }
        switch parsed {
        case .failure(let error): return .failure(.invalid(line: error.line))
        case .success(let value):
            guard case .object(let root) = value else { return .failure(.noServers) }
            let entries = servers(in: root)
            return entries.isEmpty ? .failure(.noServers) : .success(entries)
        }
    }

    private static func servers(in root: [String: JSONValue]) -> [MCPServerEntry] {
        for key in [MCPConfigDocument.serversKey, MCPConfigDocument.vscodeServersKey] {
            if case .object = root[key] {
                return MCPConfigDocument(root: [MCPConfigDocument.serversKey: root[key]!]).servers
            }
        }
        // A bare map: every value an entry with a command or a url.
        let entries = root.compactMap { name, value -> MCPServerEntry? in
            guard case .object(let json) = value, json["command"] != nil || json["url"] != nil else { return nil }
            return MCPServerEntry(name: name, json: json)
        }
        guard entries.count == root.count else { return [] }
        return entries.sorted { $0.name < $1.name }
    }

    /// Moves every secret-looking literal (env and header values whose key names a secret) to the
    /// Keychain and leaves a `${keychain:…}` reference in its place. Values that already refer to
    /// a variable stay as they are.
    static func moveSecrets(_ entry: inout MCPServerEntry, to secrets: MCPSecretStore) throws {
        var env = entry.env
        for (key, value) in env where MCPSecretReference.looksSecret(key: key) && !MCPSecretReference.isReference(value) {
            try secrets.set(value, for: MCPSecretReference.account(server: entry.name, name: key))
            env[key] = MCPSecretReference.reference(server: entry.name, name: key)
        }
        if env != entry.env { entry.env = env }
        var headers = entry.headers
        for (key, value) in headers where MCPSecretReference.looksSecret(key: key) && !MCPSecretReference.isReference(value) {
            // `Bearer abc` keeps its scheme in the file: `Bearer ${keychain:server/Authorization}`.
            let parts = value.split(separator: " ", maxSplits: 1)
            let scheme = parts.count == 2 && ["bearer", "token", "basic"].contains(parts[0].lowercased()) ? String(parts[0]) + " " : ""
            let secret = scheme.isEmpty ? value : String(parts[1])
            try secrets.set(secret, for: MCPSecretReference.account(server: entry.name, name: key))
            headers[key] = scheme + MCPSecretReference.reference(server: entry.name, name: key)
        }
        if headers != entry.headers { entry.headers = headers }
    }
}
