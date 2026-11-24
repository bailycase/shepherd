import Foundation
import ShepherdProtocol
import ShepherdRemote

// Settings ▸ Pi ▸ Sign-in's bridge to pi's own login: `Extensions/shepherd-sign-in.mjs` runs `ModelRuntime.login` against Shepherd's pi
// home on the engine's node, and speaks JSON lines. These are its two halves, and the process.
// Nothing of a credential ever crosses: the app sends what the user typed (a key, a pasted code)
// as a prompt's answer, and hears back only that it worked.

/// How a provider signs in: with an account (OAuth), or with a key.
public typealias PiSignInMethod = HostProviderSignInMethod

/// Which of a provider's account sign-ins to take when pi asks (OpenAI Codex and Radius offer both).
public enum PiSignInFlow: String, Codable, Sendable {
    case browser
    case device
    /// The browser's page, but the code is pasted: no check of the callback port, which another
    /// sign-in holds.
    case paste
}

/// A key to check: its value, or the variable the login shell sets.
public enum PiKeyInput: Equatable, Sendable {
    case literal(String)
    case variable(String)

    /// What auth.json stores for it, as pi reads it (pi: core/resolve-config-value.js): `$NAME`
    /// for a variable; a literal with every `$` doubled and a leading `!` escaped, so a key that
    /// happens to hold either is never read as a variable or run as a command.
    public var stored: String {
        switch self {
        case .variable(let name): "$" + name
        case .literal(let key):
            key.hasPrefix("!") ? "$!" + key.dropFirst().replacingOccurrences(of: "$", with: "$$")
                : key.replacingOccurrences(of: "$", with: "$$")
        }
    }
}

/// Interactive authentication exposed by a loaded Pi provider. Never a credential or endpoint.
public typealias PiSignInProvider = HostProviderSignIn

/// What the app tells the bridge.
public enum PiSignInCommand: Equatable, Sendable {
    case providers
    case login(provider: String, method: PiSignInMethod, flow: PiSignInFlow)
    /// A prompt's answer.
    case answer(id: String, value: String)
    /// Ends the login under way.
    case cancel
    /// Removes Shepherd's credential for the provider (pi's own logout).
    case logout(provider: String)
    /// Whether a key works, with the smallest request pi can make; with no `key`, whether the
    /// provider's stored login does (a stale OAuth token is refreshed on the way).
    case check(id: String, provider: String, key: PiKeyInput?)
    /// Each provider extension's usage and balance (`usage(auth)` or the "shepherd:usage" event):
    /// the signed-in account's, and each saved account's in `accounts` with its stored credential.
    case usage(accounts: [PiSavedCredential] = [])

    /// One JSON line, newline included.
    public var line: Data {
        var object: [String: String]
        switch self {
        case .providers: object = ["type": "providers"]
        case .usage(let accounts) where !accounts.isEmpty:
            let list = accounts.map { ["provider": $0.provider, "id": $0.id, "credential": $0.credential] as [String: Any] }
            var data = (try? JSONSerialization.data(withJSONObject: ["type": "usage", "accounts": list] as [String: Any], options: [.sortedKeys])) ?? Data()
            data.append(0x0A)
            return data
        case .usage: object = ["type": "usage"]
        case .login(let provider, let method, let flow):
            object = ["type": "login", "provider": provider, "method": method.rawValue, "flow": flow.rawValue]
        case .answer(let id, let value): object = ["type": "answer", "id": id, "value": value]
        case .cancel: object = ["type": "cancel"]
        case .logout(let provider): object = ["type": "logout", "provider": provider]
        case .check(let id, let provider, let key):
            object = ["type": "check", "id": id, "provider": provider]
            switch key {
            case .literal(let value): object["key"] = value
            case .variable(let name): object["variable"] = name
            case nil: break
            }
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// A question pi asks while it signs in, shared with clients of the host.
public typealias PiSignInPrompt = HostSignInPrompt

/// Why a sign-in ended without one, in words fit for the sheet: never a credential.
public struct PiSignInFailure: Equatable, Sendable, Error {
    public enum Code: String, Sendable {
        case cancelled
        /// The provider's fixed callback port is taken (Codex CLI, or the terminal pi's /login).
        case portBusy
        case unknownProvider
        /// The bridge couldn't run, or stopped without an answer.
        case bridge
        case other
    }

    public var code: Code
    public var reason: String
    public var port: Int?

    public init(_ code: Code, reason: String, port: Int? = nil) {
        self.code = code
        self.reason = reason
        self.port = port
    }
}

/// What checking a key found.
public enum PiKeyCheck: Equatable, Sendable {
    /// The provider answered; these are some of its models.
    case works(models: [String])
    /// The provider refused it, in its words.
    case rejected(String)
    /// The provider couldn't be reached, so the key wasn't checked.
    case unreachable(String)
    /// The variable isn't set in the login shell.
    case unset(String)
}

/// What one loaded extension registered, as pi's loader recorded it: the providers it added (by
/// id, the last registration of an id winning) and the rest of what it gave pi. Names only.
public struct PiExtensionInventory: Codable, Equatable, Sendable {
    /// The file pi loaded, as Shepherd's settings name it.
    public var path: String
    public var providers: [String]
    public var tools: [String]
    public var commands: [String]
    /// The events it listens to (`session_start`, `tool_call`, …).
    public var events: [String]
    public var shortcuts: [String]
    public var flags: [String]
    /// Message, entry and tool renderers and markdown transformers: all drawn by pi's terminal UI.
    public var renderers: Int

    public init(path: String, providers: [String] = [], tools: [String] = [], commands: [String] = [], events: [String] = [],
                shortcuts: [String] = [], flags: [String] = [], renderers: Int = 0) {
        self.path = path
        self.providers = providers
        self.tools = tools
        self.commands = commands
        self.events = events
        self.shortcuts = shortcuts
        self.flags = flags
        self.renderers = renderers
    }

    private enum CodingKeys: String, CodingKey { case path, providers, tools, commands, events, shortcuts, flags, renderers }

    // A field an older bridge leaves out reads as none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        providers = try c.decodeIfPresent([String].self, forKey: .providers) ?? []
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        commands = try c.decodeIfPresent([String].self, forKey: .commands) ?? []
        events = try c.decodeIfPresent([String].self, forKey: .events) ?? []
        shortcuts = try c.decodeIfPresent([String].self, forKey: .shortcuts) ?? []
        flags = try c.decodeIfPresent([String].self, forKey: .flags) ?? []
        renderers = try c.decodeIfPresent(Int.self, forKey: .renderers) ?? 0
    }
}

/// A provider's prepaid balance as its extension reports it ("Credit", 18.40, "USD").
public struct PiBalance: Codable, Equatable, Sendable {
    public var amount: Double
    /// An ISO 4217 code ("USD", "CNY") or the provider's own unit ("credits").
    public var currency: String
    public var label: String?

    public init(amount: Double, currency: String, label: String? = nil) {
        self.amount = amount
        self.currency = currency
        self.label = label
    }
}

/// A saved account that isn't active, sent to the bridge so a usage hook can ask about it.
public struct PiSavedCredential: @unchecked Sendable, Equatable {
    public var provider: String
    public var id: String
    /// As `PiAccounts` stores it: pi's credential object.
    public var credential: [String: Any]

    public init(provider: String, id: String, credential: [String: Any]) {
        self.provider = provider
        self.id = id
        self.credential = credential
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.provider == b.provider && a.id == b.id && NSDictionary(dictionary: a.credential).isEqual(to: b.credential)
    }
}

/// One provider's usage from its extension: limit windows and a balance, for the signed-in account
/// (`account` nil) or a saved one, and the account's email when the provider said it.
public struct PiProviderUsage: Decodable, Equatable, Sendable {
    public var provider: String
    public var account: String?
    public var windows: [PiUsageWindow]
    public var balance: PiBalance?
    public var email: String?

    public init(provider: String, account: String? = nil, windows: [PiUsageWindow] = [], balance: PiBalance? = nil, email: String? = nil) {
        self.provider = provider
        self.account = account
        self.windows = windows
        self.balance = balance
        self.email = email
    }

    private struct Window: Decodable { var name: String; var usedPercent: Double; var resetsAt: Double? }
    private enum CodingKeys: String, CodingKey { case provider, account, windows, balance, email }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        account = try c.decodeIfPresent(String.self, forKey: .account)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        windows = (try c.decodeIfPresent([Window].self, forKey: .windows) ?? []).map {
            PiUsageWindow(name: $0.name, usedPercent: min(100, max(0, $0.usedPercent)),
                          resetsAt: $0.resetsAt.map { Date(timeIntervalSince1970: $0 / 1000) })
        }
        balance = try? c.decodeIfPresent(PiBalance.self, forKey: .balance)
    }
}

/// What the bridge says.
public enum PiSignInReply: Equatable, Sendable {
    case ready
    case providers([PiSignInProvider])
    /// An installed extension at this path didn't load while listing providers: it is skipped.
    case extensionFailed(path: String)
    /// What each loaded extension registered, just before `providers`.
    case extensions([PiExtensionInventory])
    /// Usage and balance from the providers' extensions that report them.
    case usage([PiProviderUsage])
    /// The browser sign-in's page: open it.
    case authURL(URL, instructions: String?)
    /// A device-code sign-in's code and where to enter it.
    case deviceCode(code: String, verificationURI: String, expiresIn: Int?)
    case info(String)
    case progress(String)
    case prompt(PiSignInPrompt)
    /// pi no longer needs that answer (the browser's callback won).
    case promptClosed(String)
    /// Signed in: the credential is in the home's auth.json.
    case done(provider: String, subscription: Bool)
    case failed(PiSignInFailure)
    case checked(id: String, PiKeyCheck)
    case loggedOut(provider: String)

    private struct Wire: Decodable {
        struct Event: Decodable {
            var type: String
            var url: String?
            var instructions: String?
            var userCode: String?
            var verificationUri: String?
            var expiresInSeconds: Double?
            var message: String?
        }
        struct Option: Decodable { var id: String; var label: String? }
        var type: String
        var event: Event?
        var id: String?
        var kind: String?
        var keyForm: Bool?
        var message: String?
        var placeholder: String?
        var options: [Option]?
        var provider: String?
        var credential: String?
        var code: String?
        var reason: String?
        var port: Int?
        var result: String?
        var models: [String]?
        var providers: [PiSignInProvider]?
        var path: String?
        var extensions: [PiExtensionInventory]?
        var usage: [PiProviderUsage]?
    }

    /// One line of the bridge's stdout; nil for anything it doesn't say.
    public static func parse(_ line: Data) -> PiSignInReply? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: line) else { return nil }
        switch wire.type {
        case "ready": return .ready
        case "providers":
            guard let providers = wire.providers,
                  providers.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }),
                  Set(providers.map(\.id)).count == providers.count else { return nil }
            return .providers(providers)
        case "extensionFailed":
            return wire.path.flatMap { $0.isEmpty ? nil : .extensionFailed(path: $0) }
        case "extensions":
            return wire.extensions.map { .extensions($0) }
        case "usage":
            return .usage(wire.usage ?? [])
        case "event":
            guard let event = wire.event else { return nil }
            switch event.type {
            case "auth_url":
                guard let url = event.url.flatMap(URL.init(string:)), ["https", "http"].contains(url.scheme ?? "") else { return nil }
                return .authURL(url, instructions: event.instructions)
            case "device_code":
                guard let code = event.userCode, let uri = event.verificationUri,
                      let url = URL(string: uri), ["https", "http"].contains(url.scheme ?? "") else { return nil }
                return .deviceCode(code: code, verificationURI: uri, expiresIn: event.expiresInSeconds.map { Int($0) })
            case "info": return .info(event.message ?? "")
            case "progress": return .progress(event.message ?? "")
            default: return nil
            }
        case "prompt":
            guard let id = wire.id, let kind = wire.kind.flatMap(PiSignInPrompt.Kind.init(rawValue:)) else { return nil }
            return .prompt(PiSignInPrompt(id: id, kind: kind, message: wire.message ?? "", placeholder: wire.placeholder,
                                          options: (wire.options ?? []).map { .init(id: $0.id, label: $0.label ?? $0.id) }, keyForm: wire.keyForm))
        case "promptClosed":
            return wire.id.map { .promptClosed($0) }
        case "done":
            guard let provider = wire.provider else { return nil }
            return .done(provider: provider, subscription: wire.credential == "oauth")
        case "failed":
            let code = wire.code.flatMap(PiSignInFailure.Code.init(rawValue:)) ?? .other
            return .failed(PiSignInFailure(code, reason: wire.reason ?? "The sign-in stopped.", port: wire.port))
        case "checked":
            guard let id = wire.id else { return nil }
            let reason = wire.reason ?? ""
            switch wire.result {
            case "works": return .checked(id: id, .works(models: wire.models ?? []))
            case "rejected": return .checked(id: id, .rejected(reason))
            case "unset": return .checked(id: id, .unset(reason))
            default: return .checked(id: id, .unreachable(reason))
            }
        case "loggedOut":
            return wire.provider.map { .loggedOut(provider: $0) }
        default:
            return nil
        }
    }
}

extension PiLaunch {
    /// The sign-in bridge: `shepherd-sign-in.mjs` on the engine's node, in a login shell (so a
    /// key's variable and the user's proxy settings are there), with the shell's pi, jiti and
    /// Node settings dropped and Shepherd's pi home pinned, in the home: `$0` is the script, `$1`
    /// pi's SDK (the engine's `dist/bundle/index.js`), `$2` the home.
    /// `extensions`: Shepherd's own extensions the bridge loads beside the home's (`PiSignInScript.usageExtension`).
    public static func signInBridge(node: PiEngine.Program, script: String, sdk: String, home: PiHome, extensions: [String] = []) -> Line {
        Line(script: clearedEnvironment(home: home)
                + "export PI_CODING_AGENT_DIR=\(quoted(home.directory.path)) PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0"
                + (extensions.isEmpty ? "" : " SHEPHERD_USAGE_EXTENSION=1") + "; "
                + "cd -- \(quoted(home.directory.path)) && exec \(word(node)) \"$0\" \"$@\"",
             positional: [script, sdk, home.directory.path] + extensions)
    }
}

/// One run of the sign-in bridge: its replies as they come, and the commands the sheet sends. It
/// ends when the sheet closes (`close`), or on its own when it can't run; either way `replies`
/// finishes, and a bridge that never said `ready` or stopped mid-login is a `.bridge` failure.
public final class PiSignInBridge: @unchecked Sendable {
    public let replies: AsyncStream<PiSignInReply>
    private let continuation: AsyncStream<PiSignInReply>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let lock = NSLock()
    private var buffer = LineBuffer()
    private var closed = false

    /// Starts `line` (`PiLaunch.signInBridge`). The environment is the app's, without Shepherd's
    /// own variables but the support folder's.
    public init(line: PiLaunch.Line, environment: [String: String] = ProcessInfo.processInfo.environment) {
        (replies, continuation) = AsyncStream.makeStream(of: PiSignInReply.self)
        process.executableURL = URL(fileURLWithPath: line.argv[0])
        process.arguments = Array(line.argv.dropFirst())
        var env = environment
        for key in env.keys where key.hasPrefix("SHEPHERD_") && key != ShepherdPaths.supportDirectoryEnvKey { env[key] = nil }
        process.environment = env
        let output = Pipe(), stderr = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = stderr
        // Pipe handlers outlive a weak owner. Remove them even if close released the bridge.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            let lines = self.lock.withLock { (try? self.buffer.append(chunk)) ?? [] }
            for line in lines {
                if let reply = PiSignInReply.parse(line) { self.continuation.yield(reply) }
            }
        }
        // Extensions can write credentials to stderr. Drain it, never retain or display it.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] process in
            output.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            // What was still in the pipe.
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            let lines = self.lock.withLock { (try? self.buffer.append(rest + (rest.last == 0x0A || rest.isEmpty ? Data() : Data([0x0A])))) ?? [] }
            for line in lines { if let reply = PiSignInReply.parse(line) { self.continuation.yield(reply) } }
            let wasClosed = self.lock.withLock { self.closed }
            if !wasClosed, process.terminationStatus != 0 {
                let reason = process.terminationStatus == 127 ? "Shepherd can’t find its pi’s runtime."
                    : "The sign-in helper stopped (status \(process.terminationStatus))."
                self.continuation.yield(.failed(PiSignInFailure(.bridge, reason: reason)))
            }
            self.continuation.finish()
        }
        do {
            try process.run()
        } catch {
            continuation.yield(.failed(PiSignInFailure(.bridge, reason: "Couldn’t start the sign-in: \(error.localizedDescription)")))
            continuation.finish()
        }
    }

    public func send(_ command: PiSignInCommand) {
        let open = lock.withLock { !closed }
        guard open, process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: command.line)
    }

    /// Ends the bridge: a login under way is cancelled, and the process exits by itself.
    public func close() {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        try? input.fileHandleForWriting.close()
        // It exits within a beat of stdin closing; one that doesn't is stopped.
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
    }

    deinit {
        if process.isRunning { process.terminate() }
    }
}

/// The installed bridge script.
public enum PiSignInScript {
    public static let fileName = "shepherd-sign-in.mjs"
    /// Anthropic's and OpenAI Codex's usage, a provider extension shipped with Shepherd (Settings ▸ Tools ▸ Built in).
    public static let usageExtension = "shepherd-usage.mjs"

    /// Writes the script (or another of Shepherd's, `name`) into `directory` when it differs, and returns its path.
    public static func install(in directory: URL, name: String = fileName) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let data = Data(EmbeddedExtensions.source(name).utf8)
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        return url
    }
    static var source: String { EmbeddedExtensions.source("shepherd-sign-in.mjs") }
}
