import Foundation
import ShepherdProtocol

/// pi's `mcp.json` for Shepherd's pi home, derived from Settings ▸ MCP servers' file
/// (docs/mcp.md › How Shepherd maps onto it). pi's MCP is the runtime: it connects the servers,
/// lists and calls their tools, and signs in. This only says which servers, how their tools reach
/// the model, and where each secret comes from. The user's file is read, never written; no secret
/// value is in the result: a `${keychain:…}` reference becomes `${SHEPHERD_MCP_SECRET_…}`, a
/// variable of pi's own environment, which the app fills from the Keychain at each launch.
enum MCPPiConfig {
    /// The prefix of the variables Keychain values travel in. `restore-env.sh` unsets them for an
    /// agent's shell commands, and a stdio server's wrapper unsets them before it runs.
    static let secretPrefix = "SHEPHERD_MCP_SECRET_"

    /// A Keychain item a server's entry refers to, and the variable it reaches pi in.
    struct Secret: Equatable, Sendable {
        var variable: String
        var server: String
        var name: String

        var account: String { MCPSecretReference.account(server: server, name: name) }
    }

    struct Derived: Equatable, Sendable {
        /// The file's text.
        var json: Data
        /// The Keychain values the file refers to, each in its own variable.
        var secrets: [Secret]
        /// Why a server is not in the file, by name.
        var problems: [String: String]
        /// The servers in the file, in the user's order.
        var servers: [String]
    }

    /// The file for `document`. `home` is the user's home folder, which `~/` in a command or an
    /// argument means when a shell has to start the server.
    static func derive(_ document: MCPConfigDocument, home: String) -> Derived {
        var table = SecretTable()
        var written: [(name: String, entry: [String: JSONValue])] = []
        var problems: [String: String] = [:]
        var taken: [String: String] = [:]
        // The first pass finds the secrets (they decide whether stdio servers need the wrapper),
        // the second builds the entries.
        var parsed: [(MCPServerEntry, Result<Translation, Problem>)] = []
        for entry in document.servers {
            let key = normalized(entry.name)
            if !isPiName(entry.name) {
                problems[entry.name] = "pi’s MCP names a server with letters, digits, - and _ only."
                continue
            }
            if let other = taken[key] {
                problems[entry.name] = "pi’s MCP treats \(entry.name) and \(other) as one server (- and _ are the same). Rename one."
                continue
            }
            taken[key] = entry.name
            parsed.append((entry, translate(entry, table: &table)))
        }
        let wrap = !table.secrets.isEmpty
        for (entry, result) in parsed {
            switch result {
            case .failure(let problem):
                problems[entry.name] = problem.message
            case .success(let translation):
                written.append((entry.name, translation.build(wrap: wrap, home: home)))
            }
        }
        let servers = written.map(\.name)
        let root: JSONValue = .object([MCPConfigDocument.serversKey: .object(Dictionary(uniqueKeysWithValues: written.map { ($0.name, JSONValue.object($0.entry)) }))])
        let text = MCPJSON.write(root, order: [MCPConfigDocument.serversKey: servers]) + "\n"
        return Derived(json: Data(text.utf8), secrets: table.secrets, problems: problems, servers: servers)
    }

    /// pi's rule for a server name.
    static func isPiName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    /// Names that differ only by `-` and `_` are one server to pi.
    private static func normalized(_ name: String) -> String { name.replacingOccurrences(of: "-", with: "_") }

    // MARK: Secrets

    /// The variables, unique and stable for one document: `SHEPHERD_MCP_SECRET_GITHUB_TOKEN`, and
    /// a number after it when two items would otherwise share one.
    private struct SecretTable {
        var secrets: [Secret] = []

        mutating func variable(server: String, name: String) -> String {
            if let known = secrets.first(where: { $0.server == server && $0.name == name }) { return known.variable }
            let base = MCPPiConfig.secretPrefix + sanitize(server) + "_" + sanitize(name)
            var variable = base
            var n = 1
            while secrets.contains(where: { $0.variable == variable }) {
                n += 1
                variable = "\(base)_\(n)"
            }
            secrets.append(Secret(variable: variable, server: server, name: name))
            return variable
        }

        private func sanitize(_ text: String) -> String {
            String(text.uppercased().unicodeScalars.map { ($0.isASCII && (CharacterSet.alphanumerics.contains($0))) ? Character($0) : "_" })
        }
    }

    // MARK: One value

    /// A value of `env` or `headers`, as pi will read it.
    private struct MappedValue {
        var text: String
        /// Whether it needs a shell: it holds a `${NAME:-default}`, which pi does not expand.
        var usesShell: Bool
    }

    /// One `${…}` in a value.
    private enum Reference {
        /// `${NAME}`: pi's own form.
        case variable(String)
        /// `${keychain:server/NAME}`.
        case keychain(server: String, name: String)
        /// `${NAME:-default}` and its kin: a shell's.
        case shell(String)
    }

    private enum Part {
        case literal(String)
        case reference(Reference)
    }

    private static func parts(of value: String) -> [Part] {
        var out: [Part] = []
        var literal = ""
        var rest = Substring(value)
        while let open = rest.range(of: "${") {
            literal += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.firstIndex(of: "}") else {
                literal += rest[open.lowerBound...]
                rest = ""
                break
            }
            let body = String(after[..<close])
            if let reference = reference(body) {
                if !literal.isEmpty { out.append(.literal(literal)); literal = "" }
                out.append(.reference(reference))
            } else {
                literal += "${\(body)}"
            }
            rest = after[after.index(after: close)...]
        }
        literal += rest
        if !literal.isEmpty { out.append(.literal(literal)) }
        return out
    }

    private static func reference(_ body: String) -> Reference? {
        if body.hasPrefix("keychain:") {
            let item = body.dropFirst("keychain:".count)
            guard let slash = item.firstIndex(of: "/"), slash != item.startIndex, item.index(after: slash) != item.endIndex else { return nil }
            return .keychain(server: String(item[..<slash]), name: String(item[item.index(after: slash)...]))
        }
        let name = body.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        guard let first = name.first, !first.isNumber else { return nil }
        if name.count == body.count { return .variable(body) }
        let tail = body.dropFirst(name.count)
        // `:-`, `-`, `:=`, `=`, `:+`, `+`, `:?`, `?`: the shell's expansions.
        guard let operatorStart = tail.first, ":-=+?".contains(operatorStart) else { return nil }
        return .shell(body)
    }

    /// `value` for an `env` or `header` entry: Keychain references become pi variables; a shell
    /// default makes the whole value a command, `!printf '%s' "…"`, which pi runs with `/bin/sh`.
    private static func mapValue(_ value: String, table: inout SecretTable) -> MappedValue {
        var usesShell = false
        var pieces: [(literal: String?, raw: String?)] = []
        for part in parts(of: value) {
            switch part {
            case .literal(let text): pieces.append((text, nil))
            case .reference(.variable(let name)): pieces.append((nil, "${\(name)}"))
            case .reference(.keychain(let server, let name)): pieces.append((nil, "${\(table.variable(server: server, name: name))}"))
            case .reference(.shell(let body)):
                usesShell = true
                pieces.append((nil, "${\(body)}"))
            }
        }
        guard usesShell else {
            return MappedValue(text: pieces.map { $0.literal ?? $0.raw ?? "" }.joined(), usesShell: false)
        }
        let quoted = pieces.map { piece in piece.raw ?? doubleQuoted(piece.literal ?? "") }.joined()
        return MappedValue(text: "!printf '%s' \"" + quoted + "\"", usesShell: true)
    }

    /// Text inside a shell's double quotes: only `$`, `` ` ``, `"` and `\` need a backslash.
    private static func doubleQuoted(_ text: String) -> String {
        var out = ""
        for c in text {
            if "$`\"\\".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    // MARK: One server

    struct Problem: Error, Equatable {
        var message: String
    }

    /// What one entry becomes, short of the stdio wrapper (which depends on the other servers).
    private struct Translation {
        var common: [String: JSONValue]
        var kind: Kind

        enum Kind {
            case http(url: String, headers: [String: String], oauth: JSONValue?)
            case stdio(command: String, args: [String], env: [String: String], cwd: String?, needsShell: Bool)
        }

        func build(wrap: Bool, home: String) -> [String: JSONValue] {
            var entry = common
            switch kind {
            case .http(let url, let headers, let oauth):
                entry["url"] = .string(url)
                if !headers.isEmpty { entry["headers"] = .object(headers.mapValues(JSONValue.string)) }
                if let oauth { entry["oauth"] = oauth }
            case .stdio(let command, let args, let env, let cwd, let needsShell):
                if wrap || needsShell {
                    let words = [command] + args
                    entry["command"] = .string("/bin/zsh")
                    entry["args"] = .array(MCPPiConfig.shellWrapper(words: words, home: home, expands: needsShell).map(JSONValue.string))
                } else {
                    entry["command"] = .string(command)
                    if !args.isEmpty { entry["args"] = .array(args.map(JSONValue.string)) }
                }
                if !env.isEmpty { entry["env"] = .object(env.mapValues(JSONValue.string)) }
                if let cwd { entry["cwd"] = .string(cwd) }
            }
            return entry
        }
    }

    private static func translate(_ entry: MCPServerEntry, table: inout SecretTable) -> Result<Translation, Problem> {
        let settings = entry.settings
        var common: [String: JSONValue] = [:]
        if !settings.enabled { common["enabled"] = .bool(false) }
        // Always written: pi's own default, `codemode`, is unreachable while its codemode is off.
        let mode: JSONValue = .string(settings.exposure == .direct ? "direct" : "deferred")
        if let chosen = settings.tools {
            common["exposure"] = .string("hidden")
            common["toolExposure"] = .object(Dictionary(chosen.map { ($0, mode) }, uniquingKeysWith: { first, _ in first }))
        } else {
            common["exposure"] = mode
        }
        if entry.json["shepherd"]?["timeoutSeconds"] != nil { common["timeout"] = .number(Double(settings.timeoutSeconds)) }

        if entry.type == "sse" {
            return .failure(Problem(message: "pi’s MCP doesn’t speak the legacy SSE transport. Use the server’s Streamable HTTP address."))
        }
        switch entry.kind {
        case .remote:
            guard let url = entry.url, URL(string: url) != nil, !url.contains("${"),
                  let scheme = URL(string: url)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                let holdsReference = entry.url?.contains("${") == true
                return .failure(Problem(message: holdsReference
                    ? "pi’s MCP doesn’t expand variables in a URL. Put the value in a header, or write the URL out."
                    : "The URL must be an http or https address."))
            }
            var headers: [String: String] = [:]
            for (key, value) in entry.headers { headers[key] = mapValue(value, table: &table).text }
            let signsInByHeader = entry.headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
            return .success(Translation(common: common, kind: .http(url: url, headers: headers,
                                                                    oauth: signsInByHeader ? nil : oauth(settings.oauth, table: &table))))
        case .local:
            guard let command = entry.command, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .failure(Problem(message: "It needs a command or a URL."))
            }
            if let cwd = entry.json["cwd"]?.stringValue, cwd.contains("${") {
                return .failure(Problem(message: "pi’s MCP doesn’t expand variables in a working folder."))
            }
            var env: [String: String] = [:]
            for (key, value) in entry.env { env[key] = mapValue(value, table: &table).text }
            // `${…}` in the command line is expanded by the shell that starts the server.
            var needsShell = false
            func word(_ text: String) -> String {
                guard text.contains("${") else { return text }
                var out = ""
                for part in parts(of: text) {
                    switch part {
                    case .literal(let literal): out += literal
                    case .reference(.variable(let name)): out += "${\(name)}"; needsShell = true
                    case .reference(.keychain(let server, let name)): out += "${\(table.variable(server: server, name: name))}"; needsShell = true
                    case .reference(.shell(let body)): out += "${\(body)}"; needsShell = true
                    }
                }
                return out
            }
            let mappedCommand = word(command)
            let mappedArgs = entry.args.map(word)
            return .success(Translation(common: common, kind: .stdio(command: mappedCommand, args: mappedArgs, env: env,
                                                                    cwd: entry.json["cwd"]?.stringValue, needsShell: needsShell)))
        }
    }

    /// `oauth` for a server that signs in: the name pi registers under, and what Add's Advanced set.
    private static func oauth(_ settings: MCPOAuthSettings, table: inout SecretTable) -> JSONValue {
        var oauth: [String: JSONValue] = ["clientName": .string("Shepherd")]
        if let id = settings.clientID, !id.isEmpty { oauth["clientId"] = .string(id) }
        if let secret = settings.clientSecret, !secret.isEmpty { oauth["clientSecret"] = .string(mapValue(secret, table: &table).text) }
        if !settings.scopes.isEmpty { oauth["scope"] = .string(settings.scopes.joined(separator: " ")) }
        return .object(oauth)
    }

    // MARK: The stdio wrapper

    /// The `zsh` arguments that start a server without the other servers' secrets in its
    /// environment: pi gives every stdio server its whole environment, secrets included, so the
    /// shell removes them all before it executes the server. `-f` skips the startup files.
    ///
    /// Without a reference in the words they are `zsh`'s own arguments (`exec "$@"`); with one
    /// they are zsh words that expand it first (`a=('uvx' 'tool' '--token='"${X}")`), and only
    /// then are the variables unset. What the server's own `env` asked for was expanded by pi into
    /// other variables, so it keeps those.
    static func shellWrapper(words: [String], home: String, expands: Bool) -> [String] {
        let unset = "unset -m '\(secretPrefix)*'"
        guard expands else {
            return ["-f", "-c", unset + "; exec \"$@\"", "shepherd-mcp"] + words.map { expandingHome($0, home: home) }
        }
        let list = words.map(shellWord).joined(separator: " ")
        return ["-f", "-c", "a=(\(list)); \(unset); exec \"${a[@]}\""]
    }

    private static func expandingHome(_ word: String, home: String) -> String {
        if word == "~" { return home }
        return word.hasPrefix("~/") ? home + word.dropFirst() : word
    }

    /// One zsh word: literals single-quoted, each reference double-quoted so it stays one word.
    private static func shellWord(_ text: String) -> String {
        var pieces: [String] = []
        for part in parts(of: text) {
            switch part {
            case .literal(let literal):
                if pieces.isEmpty, literal == "~" || literal.hasPrefix("~/") {
                    pieces.append("\"${HOME}\"")
                    let rest = literal.dropFirst()
                    if !rest.isEmpty { pieces.append(singleQuoted(String(rest))) }
                } else {
                    pieces.append(singleQuoted(literal))
                }
            case .reference(.variable(let name)): pieces.append("\"${\(name)}\"")
            case .reference(.keychain): pieces.append("''")
            case .reference(.shell(let body)): pieces.append("\"${\(body)}\"")
            }
        }
        return pieces.isEmpty ? "''" : pieces.joined()
    }

    private static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
