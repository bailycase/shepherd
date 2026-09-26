import Foundation
import ShepherdProtocol

// Settings ▸ MCP servers' file: ~/.config/mcp/mcp.json (or $SHEPHERD_MCP_CONFIG), in the common
// `{"mcpServers": {name: entry}}` shape. Only the app writes it: atomically, keeping every key
// it doesn't know, other tools' entries and their plaintext values, and never over a file that
// doesn't parse. Shepherd's own fields sit under each entry's `shepherd` key.

/// How a server starts (`shepherd.start`).
enum MCPStartMode: String, CaseIterable, Sendable {
    case whenUsed, withSession, alwaysOn

    var title: String {
        switch self {
        case .whenUsed: "When used"
        case .withSession: "With each session"
        case .alwaysOn: "Always on"
        }
    }
}

/// How the agent reaches a server's tools (`shepherd.exposure`).
enum MCPExposure: String, Sendable {
    /// Through the one `mcp` tool.
    case proxy
    /// Each tool on its own, named `<server>_<tool>`.
    case direct
}

/// `shepherd.oauth`: set from the Add sheet's Advanced section.
struct MCPOAuthSettings: Equatable, Sendable {
    var clientID: String?
    var clientSecret: String?
    var scopes: [String] = []

    var isEmpty: Bool { clientID == nil && clientSecret == nil && scopes.isEmpty }
}

/// Shepherd's own fields for one server. Each default applies when its key is missing.
struct MCPShepherdSettings: Equatable, Sendable {
    static let defaultIdleMinutes = 10
    static let defaultTimeoutSeconds = 30

    var enabled = true
    var start: MCPStartMode = .whenUsed
    var idleMinutes = defaultIdleMinutes
    var exposure: MCPExposure = .proxy
    /// "Choose which tools…": nil means all.
    var tools: [String]?
    var timeoutSeconds = defaultTimeoutSeconds
    var oauth = MCPOAuthSettings()
}

/// One server's entry, kept whole so unknown keys survive an edit.
struct MCPServerEntry: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable { case local, remote }

    var name: String
    var json: [String: JSONValue]

    var id: String { name }

    init(name: String, json: [String: JSONValue]) {
        self.name = name
        self.json = json
    }

    /// A new local server: `command`, `args`, `env`, and no `type`.
    static func local(_ name: String, command: String, args: [String] = [], env: [String: String] = [:]) -> MCPServerEntry {
        var entry = MCPServerEntry(name: name, json: [:])
        entry.command = command
        entry.args = args
        entry.env = env
        return entry
    }

    /// A new remote server: `"type": "http"` and its URL.
    static func remote(_ name: String, url: String, headers: [String: String] = [:]) -> MCPServerEntry {
        var entry = MCPServerEntry(name: name, json: ["type": .string("http")])
        entry.url = url
        entry.headers = headers
        return entry
    }

    var type: String? { json["type"]?.stringValue }

    var kind: Kind {
        if command != nil || type == "stdio" { return .local }
        return url != nil ? .remote : .local
    }

    /// The transport the entry asks for: `sse` alone means legacy HTTP+SSE only; any other URL
    /// is Streamable HTTP, falling back to SSE.
    var transport: MCPTransportKind {
        if kind == .local { return .stdio }
        return type == "sse" ? .sse : .streamableHTTP
    }

    var command: String? {
        get { json["command"]?.stringValue }
        set { json["command"] = newValue.map(JSONValue.string) }
    }

    var args: [String] {
        get { json["args"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
        set { json["args"] = newValue.isEmpty && json["args"] == nil ? nil : .array(newValue.map(JSONValue.string)) }
    }

    var env: [String: String] {
        get { Self.strings(json["env"]) }
        set { json["env"] = newValue.isEmpty && json["env"] == nil ? nil : .object(newValue.mapValues(JSONValue.string)) }
    }

    var url: String? {
        get { json["url"]?.stringValue }
        set { json["url"] = newValue.map(JSONValue.string) }
    }

    var headers: [String: String] {
        get { Self.strings(json["headers"]) }
        set { json["headers"] = newValue.isEmpty && json["headers"] == nil ? nil : .object(newValue.mapValues(JSONValue.string)) }
    }

    /// The command line as the row shows it: `uvx postgres-mcp --access-mode=restricted`.
    var commandLine: String {
        ([command ?? ""] + args).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The row's second line: the URL, or the command line.
    var endpoint: String { kind == .remote ? (url ?? "") : commandLine }

    /// The entry as other tools see it: without `shepherd`. The tools cache keys on it.
    var withoutShepherd: [String: JSONValue] {
        var copy = json
        copy["shepherd"] = nil
        return copy
    }

    var settings: MCPShepherdSettings {
        get {
            let s = json["shepherd"]
            var settings = MCPShepherdSettings()
            if let enabled = s?["enabled"]?.boolValue { settings.enabled = enabled }
            if let start = s?["start"]?.stringValue.flatMap(MCPStartMode.init(rawValue:)) { settings.start = start }
            if let idle = s?["idleMinutes"]?.doubleValue, idle >= 1 { settings.idleMinutes = Int(idle) }
            if let exposure = s?["exposure"]?.stringValue.flatMap(MCPExposure.init(rawValue:)) { settings.exposure = exposure }
            settings.tools = s?["tools"]?.arrayValue?.compactMap(\.stringValue)
            if let timeout = s?["timeoutSeconds"]?.doubleValue, timeout >= 1 { settings.timeoutSeconds = Int(timeout) }
            if let oauth = s?["oauth"] {
                settings.oauth.clientID = oauth["clientId"]?.stringValue
                settings.oauth.clientSecret = oauth["clientSecret"]?.stringValue
                settings.oauth.scopes = oauth["scopes"]?.arrayValue?.compactMap(\.stringValue) ?? []
            }
            return settings
        }
        set {
            let defaults = MCPShepherdSettings()
            var object: [String: JSONValue] = {
                if case .object(let o) = json["shepherd"] { return o }
                return [:]
            }()
            // A key is written when it differs from its default, or was already there.
            func put(_ key: String, _ value: JSONValue, isDefault: Bool) {
                if isDefault && object[key] == nil { return }
                object[key] = value
            }
            put("enabled", .bool(newValue.enabled), isDefault: newValue.enabled == defaults.enabled)
            put("start", .string(newValue.start.rawValue), isDefault: newValue.start == defaults.start)
            put("idleMinutes", .number(Double(newValue.idleMinutes)), isDefault: newValue.idleMinutes == defaults.idleMinutes)
            put("exposure", .string(newValue.exposure.rawValue), isDefault: newValue.exposure == defaults.exposure)
            if let tools = newValue.tools {
                object["tools"] = .array(tools.map(JSONValue.string))
            } else {
                object["tools"] = nil
            }
            put("timeoutSeconds", .number(Double(newValue.timeoutSeconds)),
                isDefault: newValue.timeoutSeconds == defaults.timeoutSeconds)
            if newValue.oauth.isEmpty {
                object["oauth"] = nil
            } else {
                var oauth: [String: JSONValue] = {
                    if case .object(let o) = object["oauth"] { return o }
                    return [:]
                }()
                oauth["clientId"] = newValue.oauth.clientID.map(JSONValue.string)
                oauth["clientSecret"] = newValue.oauth.clientSecret.map(JSONValue.string)
                oauth["scopes"] = newValue.oauth.scopes.isEmpty ? nil : .array(newValue.oauth.scopes.map(JSONValue.string))
                object["oauth"] = .object(oauth)
            }
            json["shepherd"] = object.isEmpty ? nil : .object(object)
        }
    }

    private static func strings(_ value: JSONValue?) -> [String: String] {
        guard case .object(let object) = value else { return [:] }
        return object.compactMapValues(\.stringValue)
    }
}

/// The whole file: its root kept as parsed, and the servers read from it.
struct MCPConfigDocument: Equatable, Sendable {
    static let serversKey = "mcpServers"
    /// VS Code's key, read but never written by Shepherd.
    static let vscodeServersKey = "servers"

    var root: [String: JSONValue]

    init(root: [String: JSONValue] = [:]) {
        self.root = root
    }

    /// Every server, `mcpServers` first, then VS Code's `servers` not already listed; by name.
    var servers: [MCPServerEntry] {
        var seen = Set<String>()
        var out: [MCPServerEntry] = []
        for key in [Self.serversKey, Self.vscodeServersKey] {
            guard case .object(let map) = root[key] else { continue }
            for name in map.keys.sorted() where !seen.contains(name) {
                guard case .object(let json) = map[name] else { continue }
                seen.insert(name)
                out.append(MCPServerEntry(name: name, json: json))
            }
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func server(_ name: String) -> MCPServerEntry? {
        servers.first { $0.name == name }
    }

    /// Where an entry lives: `servers` only when VS Code's key holds it and `mcpServers` doesn't.
    private func key(for name: String) -> String {
        if case .object(let map) = root[Self.serversKey], map[name] != nil { return Self.serversKey }
        if case .object(let map) = root[Self.vscodeServersKey], map[name] != nil { return Self.vscodeServersKey }
        return Self.serversKey
    }

    /// Adds or replaces an entry where it lives; a new one goes in `mcpServers`.
    mutating func upsert(_ entry: MCPServerEntry) {
        let key = key(for: entry.name)
        var map: [String: JSONValue] = {
            if case .object(let o) = root[key] { return o }
            return [:]
        }()
        map[entry.name] = .object(entry.json)
        root[key] = .object(map)
    }

    mutating func remove(_ name: String) {
        for key in [Self.serversKey, Self.vscodeServersKey] {
            guard case .object(var map) = root[key], map[name] != nil else { continue }
            map[name] = nil
            root[key] = .object(map)
        }
    }

    /// Renames an entry in place, keeping everything else about it.
    mutating func rename(_ name: String, to newName: String) {
        guard name != newName, var entry = server(name) else { return }
        remove(name)
        entry.name = newName
        upsert(entry)
    }
}

enum MCPConfigError: Error, Equatable, CustomStringConvertible {
    /// The file doesn't parse: nothing is written until it does.
    case invalid(line: Int)
    case writeFailed(String)
    /// Someone else kept changing the file while Shepherd wrote it.
    case busy

    var description: String {
        switch self {
        case .invalid(let line): "mcp.json isn’t valid JSON (line \(line))"
        case .writeFailed(let reason): "Couldn’t save mcp.json: \(reason)"
        case .busy: "mcp.json kept changing while Shepherd saved it. Try again."
        }
    }
}

/// Reads and writes one mcp.json. Takes its URL; never reads the environment itself.
struct MCPConfigFile: Sendable {
    let url: URL

    enum Contents: Equatable, Sendable {
        case document(MCPConfigDocument)
        case invalid(line: Int)
    }

    /// A missing or empty file is an empty document.
    func read() -> Contents {
        let data = (try? Data(contentsOf: url)) ?? Data()
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> Contents {
        guard !data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) else { return .document(MCPConfigDocument()) }
        switch MCPJSON.parse(data) {
        case .success(.object(let root)): return .document(MCPConfigDocument(root: root))
        case .success: return .invalid(line: 1)
        case .failure(let error): return .invalid(line: error.line)
        }
    }

    /// Reads the file, applies `edit`, and writes it back in one step. When the file changes on
    /// disk meanwhile, it is read again and the edit applied again.
    @discardableResult
    func update(_ edit: (inout MCPConfigDocument) throws -> Void) throws -> MCPConfigDocument {
        for _ in 0..<5 {
            let before = try? Data(contentsOf: url)
            var document: MCPConfigDocument
            switch Self.parse(before ?? Data()) {
            case .invalid(let line): throw MCPConfigError.invalid(line: line)
            case .document(let parsed): document = parsed
            }
            try edit(&document)
            let text = MCPJSON.write(.object(document.root)) + "\n"
            if try write(Data(text.utf8), ifStill: before) { return document }
        }
        throw MCPConfigError.busy
    }

    /// Writes to a temp file beside the target and renames it over, unless the target no longer
    /// holds `expected`. A new file is 0600; an existing one keeps its mode.
    private func write(_ data: Data, ifStill expected: Data?) throws -> Bool {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw MCPConfigError.writeFailed(error.localizedDescription)
        }
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o600
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).shepherd-\(UUID().uuidString.prefix(8))")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: NSNumber(value: mode)]) else {
            throw MCPConfigError.writeFailed("can’t write in \(directory.path)")
        }
        guard (try? Data(contentsOf: url)) == expected else {
            try? fm.removeItem(at: temp)
            return false
        }
        guard rename(temp.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: temp)
            throw MCPConfigError.writeFailed(reason)
        }
        return true
    }
}

/// JSON as mcp.json holds it: parsed tolerantly with the failing line, and written with sorted
/// keys, 2-space indents and unescaped slashes, so a hand-edited file stays readable.
enum MCPJSON {
    struct ParseError: Error, Equatable {
        let line: Int
    }

    static func parse(_ data: Data) -> Result<JSONValue, ParseError> {
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return .success(value(object))
        } catch let error as NSError {
            let index = error.userInfo["NSJSONSerializationErrorIndex"] as? Int ?? data.count
            let prefix = data.prefix(max(0, min(index, data.count)))
            return .failure(ParseError(line: prefix.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }))
        }
    }

    static func parse(_ text: String) -> Result<JSONValue, ParseError> {
        parse(Data(text.utf8))
    }

    private static func value(_ object: Any) -> JSONValue {
        switch object {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        case let string as String: return .string(string)
        case let array as [Any]: return .array(array.map(value))
        case let dictionary as [String: Any]: return .object(dictionary.mapValues(value))
        default: return .null
        }
    }

    static func write(_ value: JSONValue, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n.isFinite, n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
            return n.isFinite ? String(n) : "null"
        case .string(let s): return quote(s)
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { inner + write($0, indent: indent + 1) }.joined(separator: ",\n") + "\n" + pad + "]"
        case .object(let object):
            guard !object.isEmpty else { return "{}" }
            return "{\n" + object.keys.sorted().map { key in
                inner + quote(key) + ": " + write(object[key]!, indent: indent + 1)
            }.joined(separator: ",\n") + "\n" + pad + "}"
        }
    }

    static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

/// `${keychain:<server>/<NAME>}`: a value that lives in Shepherd's Keychain, never in the file.
enum MCPSecretReference {
    static func reference(server: String, name: String) -> String { "${keychain:\(server)/\(name)}" }
    static func account(server: String, name: String) -> String { "secret/\(server)/\(name)" }
    static func oauthAccount(server: String) -> String { "oauth/\(server)" }

    /// Every `(server, name)` a value refers to.
    static func references(in value: String) -> [(server: String, name: String)] {
        var out: [(String, String)] = []
        var rest = Substring(value)
        while let open = rest.range(of: "${keychain:") {
            let after = rest[open.upperBound...]
            guard let close = after.firstIndex(of: "}") else { break }
            let body = after[..<close]
            if let slash = body.firstIndex(of: "/") {
                out.append((String(body[..<slash]), String(body[body.index(after: slash)...])))
            }
            rest = after[after.index(after: close)...]
        }
        return out
    }

    /// The first `${VAR}` a value names (not a keychain one): the Sign-in column's `$GITHUB_TOKEN`.
    static func variable(in value: String) -> String? {
        guard let open = value.range(of: "${"), !value[open.upperBound...].hasPrefix("keychain:"),
              let close = value[open.upperBound...].firstIndex(of: "}") else { return nil }
        let body = value[open.upperBound..<close]
        return String(body.split(separator: ":", maxSplits: 1).first ?? body)
    }

    /// Whether a key names a secret, so a typed or imported value goes to the Keychain.
    /// `PAT` counts only as its own word, so `PATH` stays plaintext.
    static func looksSecret(key: String) -> Bool {
        let upper = key.uppercased()
        if upper == "AUTHORIZATION" { return true }
        if ["TOKEN", "KEY", "SECRET", "PASSWORD", "DATABASE_URI", "DSN"].contains(where: upper.contains) { return true }
        return upper.split(separator: "_").contains("PAT") || upper.split(separator: "-").contains("PAT")
    }

    /// Whether a value is only references and plain text other tools expand (`Bearer ${TOKEN}`).
    static func isReference(_ value: String) -> Bool {
        value.contains("${")
    }
}
