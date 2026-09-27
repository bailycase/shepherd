import Darwin
import Foundation

/// How a stored API key gets its value (auth.json's `key`), never the value itself: Shepherd shows
/// and logs only this.
public enum PiKeySource: Equatable, Sendable {
    /// The key itself.
    case literal
    /// `$NAME` or `${NAME}`: pi reads these variables when it needs the key.
    case environment([String])
    /// `!command`: pi runs it, in a shell, when it needs the key.
    case command
}

/// One provider's credential in a pi's `auth.json`, as its kind only.
public struct PiLogin: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// `type: "api_key"`.
        case apiKey(PiKeySource)
        /// `type: "oauth"`: a subscription sign-in (Claude Pro/Max, ChatGPT, Copilot, …).
        case subscription
        /// Another `type` pi may add; copied as it is.
        case other(String)
    }

    public var provider: String
    public var kind: Kind
    public var id: String { provider }

    public init(provider: String, kind: Kind) {
        self.provider = provider
        self.kind = kind
    }
}

/// Why a file of the user's pi couldn't be imported. It never quotes the file.
public struct YourPiFileError: Error, Equatable, CustomStringConvertible {
    public let description: String
    /// Where the parser stopped ("Unexpected character around line 31, column 5."), without the
    /// character itself: never the file's contents.
    public let detail: String?
    public init(_ description: String, detail: String? = nil) {
        self.description = description
        self.detail = detail
    }
}

/// The user's own pi's files, read as plain JSON and plain folders: never through pi's
/// `AuthStorage`, `SettingsManager` or `ProjectTrustStore` (which take lock folders even to read),
/// and never by running pi. Pure parsers, so each has a unit table (`YourPiFilesTests`).
public enum YourPiFiles {
    /// Files larger than this are not read.
    public static let maxBytes = 4 << 20

    /// pi's global context files in one folder, in the order it takes the first that exists.
    public static let contextFileNames = ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]

    /// A file's bytes, when it is a file of at most `maxBytes`; nil when it is missing. A link is
    /// followed, as pi follows it. The file is opened without blocking and checked on the open
    /// descriptor, so a FIFO or device (or a file swapped for one) fails at once instead of
    /// hanging the first launch, and no more than `maxBytes` is ever read.
    public static func read(_ url: URL) throws -> Data? {
        let name = url.lastPathComponent
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw YourPiFileError("\(name) couldn't be read")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw YourPiFileError("\(name) couldn't be read") }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw YourPiFileError("\(name) isn't a file") }
        guard info.st_size <= Int64(maxBytes) else { throw YourPiFileError("\(name) is too large to import") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw YourPiFileError("\(name) couldn't be read")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            // It grew after the check.
            guard data.count <= maxBytes else { throw YourPiFileError("\(name) is too large to import") }
        }
        return data
    }

    /// A JSON object, as pi reads its config (a leading BOM and comments allowed).
    public static func object(_ data: Data, file: String) throws -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else { throw YourPiFileError("\(file) isn't UTF-8 text") }
        let cleaned = strippingComments(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(cleaned.utf8))
        } catch {
            throw YourPiFileError("\(file) isn't a valid JSON object", detail: parserDetail(error))
        }
        guard let object = parsed as? [String: Any] else { throw YourPiFileError("\(file) isn't a valid JSON object") }
        return object
    }

    /// Where Foundation's parser stopped, with any quoted character taken out.
    static func parserDetail(_ error: Error) -> String? {
        guard let text = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String else { return nil }
        let unquoted = text.replacingOccurrences(of: #"\s*'.{1,4}'"#, with: "", options: .regularExpression)
        return unquoted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `//` and `/* */` comments removed outside strings, as pi's `stripJsonComments` does.
    static func strippingComments(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var inString = false
        while index < scalars.count {
            let c = scalars[index]
            if inString {
                out.append(c)
                if c == "\\", index + 1 < scalars.count { out.append(scalars[index + 1]); index += 2; continue }
                if c == "\"" { inString = false }
                index += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); index += 1; continue }
            if c == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
                continue
            }
            if c == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                index += 2
                while index + 1 < scalars.count, !(scalars[index] == "*" && scalars[index + 1] == "/") { index += 1 }
                index += 2
                continue
            }
            out.append(c)
            index += 1
        }
        return String(out)
    }

    // MARK: auth.json

    /// auth.json's credentials, by provider, as the objects pi stores. Throws when it isn't a JSON
    /// object; an entry that isn't an object is left out.
    public static func credentials(_ data: Data) throws -> [String: [String: Any]] {
        var credentials: [String: [String: Any]] = [:]
        for (provider, value) in try object(data, file: "auth.json") {
            guard let credential = value as? [String: Any], !provider.isEmpty else { continue }
            credentials[provider] = credential
        }
        return credentials
    }

    /// What each credential is, sorted by provider.
    public static func logins(_ data: Data) throws -> [PiLogin] {
        try credentials(data).map { login(provider: $0.key, credential: $0.value) }.sorted { $0.provider < $1.provider }
    }

    /// One credential's kind.
    public static func login(provider: String, credential: [String: Any]) -> PiLogin {
        switch credential["type"] as? String {
        case "api_key": PiLogin(provider: provider, kind: .apiKey(keySource(credential["key"] as? String ?? "")))
        case "oauth": PiLogin(provider: provider, kind: .subscription)
        case let other: PiLogin(provider: provider, kind: .other(other ?? "unknown"))
        }
    }

    /// Where an api_key credential's `key` comes from, by pi's own rules: `!` starts a command;
    /// otherwise `$NAME` and `${NAME}` name variables (`$$` and `$!` are a literal `$` and `!`).
    public static func keySource(_ key: String) -> PiKeySource {
        if key.hasPrefix("!") { return .command }
        var names: [String] = []
        let chars = Array(key)
        var index = 0
        func isNameStart(_ c: Character) -> Bool { c == "_" || (c.isASCII && c.isLetter) }
        func isName(_ c: Character) -> Bool { isNameStart(c) || (c.isASCII && c.isNumber) }
        while index < chars.count {
            guard chars[index] == "$", index + 1 < chars.count else { index += 1; continue }
            let next = chars[index + 1]
            if next == "$" || next == "!" { index += 2; continue }
            if next == "{", let end = chars[(index + 2)...].firstIndex(of: "}") {
                let name = String(chars[(index + 2)..<end])
                if let first = name.first, isNameStart(first), name.allSatisfy(isName), !names.contains(name) { names.append(name) }
                index = end + 1
                continue
            }
            var end = index + 1
            if end < chars.count, isNameStart(chars[end]) {
                while end < chars.count, isName(chars[end]) { end += 1 }
                let name = String(chars[(index + 1)..<end])
                if !names.contains(name) { names.append(name) }
                index = end
                continue
            }
            index += 1
        }
        return names.isEmpty ? .literal : .environment(names)
    }

    // MARK: models.json

    /// The custom providers models.json configures, sorted; throws when it isn't a JSON object.
    public static func customProviders(_ data: Data) throws -> [String] {
        let root = try object(data, file: "models.json")
        guard let providers = root["providers"] else { return [] }
        guard let table = providers as? [String: Any] else { throw YourPiFileError("models.json's providers isn't an object") }
        return table.keys.sorted()
    }

    // MARK: settings.json

    /// `defaultProvider/defaultModel`, when both are set.
    public static func defaultModel(_ settings: [String: Any]?) -> String? {
        guard let provider = (settings?["defaultProvider"] as? String)?.trimmingCharacters(in: .whitespaces), !provider.isEmpty,
              let model = (settings?["defaultModel"] as? String)?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
        return "\(provider)/\(model)"
    }

    static func absolute(_ path: String, agentDirectory: URL, home: String) -> String {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
        let full = expanded.hasPrefix("/") ? expanded : agentDirectory.path + "/" + expanded
        return (full as NSString).standardizingPath
    }

    // MARK: Instructions

    /// The global context file pi would load from `directory`: the first of `contextFileNames` that
    /// is a file (a link to a file counts, as it does for pi).
    public static func contextFile(in directory: URL) -> URL? {
        for name in contextFileNames {
            var info = stat()
            let url = directory.appendingPathComponent(name)
            if stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG { return url }
        }
        return nil
    }

    // MARK: trust.json

    /// trust.json's decisions (`path: true|false`; null means none), without any that would trust
    /// `home` as a project: a `true` for `home` or a folder above it. Those come back as `dropped`.
    public static func trust(_ data: Data, home: String) throws -> (decisions: [String: Bool], dropped: [String]) {
        let root = try object(data, file: "trust.json")
        let canonicalHome = PiHome.canonical(home)
        var decisions: [String: Bool] = [:]
        var dropped: [String] = []
        for (path, value) in root {
            if value is NSNull { continue }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw YourPiFileError("trust.json's decision for a folder isn't true, false or null")
            }
            let trusted = number.boolValue
            if trusted, PiHome.isInside(canonicalHome, PiHome.canonical(path)) {
                dropped.append(path)
                continue
            }
            decisions[path] = trusted
        }
        return (decisions, dropped.sorted())
    }

    // MARK: Sources

    /// `source` with a URL's user and password removed (`https://user:token@host/…` becomes
    /// `https://host/…`): a private package's source may carry a token, and Settings shows it.
    public static func withoutCredentials(_ source: String) -> String {
        source.replacingOccurrences(of: #"://[^/@\s]*@"#, with: "://", options: .regularExpression)
    }
}

/// pi's built-in providers Shepherd names in Settings ▸ Pi, and the variables pi-ai reads each
/// one's key from (pi: `getApiKeyEnvVars`). Only names: Shepherd never reads a value.
public enum PiProviders {
    public static let names: [String: String] = [
        "amazon-bedrock": "Amazon Bedrock", "ant-ling": "Ant Ling", "anthropic": "Anthropic",
        "azure-openai-responses": "Azure OpenAI", "baseten": "Baseten", "cerebras": "Cerebras",
        "cloudflare-ai-gateway": "Cloudflare AI Gateway", "cloudflare-workers-ai": "Cloudflare Workers AI",
        "deepseek": "DeepSeek", "fireworks": "Fireworks", "github-copilot": "GitHub Copilot", "google": "Google",
        "google-vertex": "Google Vertex AI", "groq": "Groq", "huggingface": "Hugging Face", "kimi-coding": "Kimi For Coding",
        "meta": "Meta", "minimax": "MiniMax", "minimax-cn": "MiniMax CN", "mistral": "Mistral", "moonshotai": "Moonshot AI",
        "moonshotai-cn": "Moonshot AI CN", "nvidia": "NVIDIA", "openai": "OpenAI", "openai-codex": "OpenAI Codex",
        "opencode": "OpenCode Zen", "opencode-go": "OpenCode Go", "openrouter": "OpenRouter", "radius": "Radius",
        "together": "Together", "vercel-ai-gateway": "Vercel AI Gateway", "xai": "xAI", "xiaomi": "Xiaomi", "zai": "Z.AI",
        "zai-coding-cn": "Z.AI Coding CN",
    ]

    public static let environmentKeys: [String: [String]] = [
        "anthropic": ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"],
        "github-copilot": ["COPILOT_GITHUB_TOKEN"],
        "ant-ling": ["ANT_LING_API_KEY"], "openai": ["OPENAI_API_KEY"], "azure-openai-responses": ["AZURE_OPENAI_API_KEY"],
        "nvidia": ["NVIDIA_API_KEY"], "deepseek": ["DEEPSEEK_API_KEY"], "google": ["GEMINI_API_KEY"],
        "google-vertex": ["GOOGLE_CLOUD_API_KEY"], "groq": ["GROQ_API_KEY"], "cerebras": ["CEREBRAS_API_KEY"],
        "xai": ["XAI_API_KEY"], "radius": ["RADIUS_API_KEY"], "openrouter": ["OPENROUTER_API_KEY"],
        "vercel-ai-gateway": ["AI_GATEWAY_API_KEY"], "zai": ["ZAI_API_KEY"], "zai-coding-cn": ["ZAI_CODING_CN_API_KEY"],
        "mistral": ["MISTRAL_API_KEY"], "minimax": ["MINIMAX_API_KEY"], "minimax-cn": ["MINIMAX_CN_API_KEY"],
        "moonshotai": ["MOONSHOT_API_KEY"], "moonshotai-cn": ["MOONSHOT_API_KEY"], "huggingface": ["HF_TOKEN"],
        "fireworks": ["FIREWORKS_API_KEY"], "together": ["TOGETHER_API_KEY"], "baseten": ["BASETEN_API_KEY"],
        "opencode": ["OPENCODE_API_KEY"], "opencode-go": ["OPENCODE_API_KEY"], "kimi-coding": ["KIMI_API_KEY"],
        "meta": ["META_API_KEY"], "cloudflare-workers-ai": ["CLOUDFLARE_API_KEY"], "cloudflare-ai-gateway": ["CLOUDFLARE_API_KEY"],
        "xiaomi": ["XIAOMI_API_KEY"],
    ]

    /// Providers that can sign in with cloud credentials pi doesn't store (an AWS profile, Google
    /// application default credentials), so Shepherd can't tell they're missing.
    public static let ambient: Set<String> = ["amazon-bedrock", "google-vertex"]

    /// Every variable name above, sorted.
    public static var allEnvironmentKeys: [String] { Array(Set(environmentKeys.values.joined())).sorted() }

    /// The provider's name as people know it, else its id.
    public static func name(_ id: String) -> String { names[id] ?? id }

    /// The providers whose key one of `found` (variable names) supplies.
    public static func providers(withKeys found: Set<String>) -> [String: [String]] {
        var providers: [String: [String]] = [:]
        for (provider, keys) in environmentKeys {
            let present = keys.filter(found.contains)
            if !present.isEmpty { providers[provider] = present }
        }
        return providers
    }
}
