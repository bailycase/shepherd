import Foundation
import ShepherdProtocol
import ShepherdRemote

/// "Your pi": the folder the user's own terminal pi uses, which Shepherd only ever reads, as
/// plain files (adoption of an agent's conversation, Settings ▸ Skills' From your pi setup).
/// Shepherd never writes it, never runs pi's code against it, and never starts a pi in it.
public struct YourPi: Equatable, Sendable {
    /// Its `PI_CODING_AGENT_DIR`: `~/.pi/agent`, or wherever their startup files move it.
    public var agentDirectory: URL
    /// A session folder their pi uses for every project (`PI_CODING_AGENT_SESSION_DIR`, or
    /// `sessionDir` in its settings), when one is set: pi keeps sessions in it directly.
    public var sessionDirectory: URL?
    /// `~/.pi/agent` when their startup files moved the agent directory elsewhere: an older
    /// conversation may still be there.
    public var fallbackAgentDirectory: URL?

    public init(agentDirectory: URL, sessionDirectory: URL? = nil, fallbackAgentDirectory: URL? = nil) {
        self.agentDirectory = agentDirectory.standardizedFileURL
        self.sessionDirectory = sessionDirectory?.standardizedFileURL
        self.fallbackAgentDirectory = fallbackAgentDirectory?.standardizedFileURL
    }

    /// The folders a conversation for `cwd` may be in, most likely first: the session folder
    /// their pi is set to, then `<agent dir>/sessions/--<cwd>--`, then the same under
    /// `~/.pi/agent`. A project's own `sessionDir` comes from `cwd`'s `.pi/settings.json`.
    public func sessionFolders(forCwd cwd: String) -> [URL] {
        var folders: [URL] = []
        if let sessionDirectory { folders.append(sessionDirectory) }
        let project = URL(fileURLWithPath: cwd).appendingPathComponent(".pi/settings.json")
        if let data = try? YourPiFiles.read(project), data.count < 1 << 20,
           let settings = try? YourPiFiles.object(data, file: "settings.json"),
           let dir = settings["sessionDir"] as? String, !dir.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (dir as NSString).expandingTildeInPath
            folders.append(expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded, isDirectory: true)
                           : URL(fileURLWithPath: cwd).appendingPathComponent(expanded, isDirectory: true))
        }
        let name = PiSessionFolder.name(forCwd: cwd)
        folders.append(agentDirectory.appendingPathComponent("sessions/\(name)", isDirectory: true))
        if let fallbackAgentDirectory {
            folders.append(fallbackAgentDirectory.appendingPathComponent("sessions/\(name)", isDirectory: true))
        }
        var seen: Set<String> = []
        return folders.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }
}

/// How pi names a project's session folder: `--<cwd>--`, the real path with one leading
/// separator dropped and every `/`, `\` and `:` replaced with `-` (pi: core/session-manager.js).
public enum PiSessionFolder {
    public static func name(forCwd cwd: String) -> String {
        "--\(mangled(cwd))--"
    }

    public static func mangled(_ cwd: String) -> String {
        var path = Substring(realPath(cwd))
        if let first = path.first, first == "/" || first == "\\" { path = path.dropFirst() }
        return String(path.map { "/\\:".contains($0) ? "-" : $0 })
    }

    /// The path as pi sees it: `realpath(3)`, like Node's `fs.realpathSync`. Foundation's
    /// `resolvingSymlinksInPath` is not a substitute: it maps /private/tmp back to /tmp.
    public static func realPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard let resolved = realpath(expanded, nil) else { return (expanded as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Finds "your pi" the way the user's terminal does, once per process, and keeps the answer.
///
/// A login shell, with the app's own `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR`
/// removed so only the user's startup files can set them, prints both; with neither it is
/// `~/.pi/agent`. A folder that resolves inside any edition's support folder is refused: that
/// would make Shepherd read (and adopt from) its own home. Debug builds honour
/// `SHEPHERD_YOUR_PI`, which the test isolation sets once as a test process loads; under the
/// engine override without it, there is no "your pi" at all, so a test never reads the real one.
public final class YourPiLocator: @unchecked Sendable {
    public enum Source: Sendable {
        /// This folder, or none, and the provider key variables to report as set (names only).
        case fixed(URL?, environmentKeys: Set<String> = [])
        /// A login shell with `environment`, refusing folders inside `supportFolders`.
        case loginShell(environment: [String: String], supportFolders: [URL])
    }

    public static let overrideEnvKey = "SHEPHERD_YOUR_PI"

    private let source: Source
    private let lock = NSLock()
    private var resolved: Answer?

    /// What a login shell's answer comes to: "your pi" to read, if any, and a folder refused for
    /// being inside a support folder, which Shepherd never reads but still guards its home against.
    struct Answer: Equatable {
        var yourPi: YourPi?
        var refused: URL?
        /// The provider key variables (`PiProviders.environmentKeys`) the user's login shell sets,
        /// by name: never a value.
        var environmentKeys: Set<String> = []
    }

    public init(_ source: Source) {
        self.source = source
    }

    /// The locator for an environment: the override where honoured, none under the engine
    /// override without it, else the login shell.
    public static func forEnvironment(_ environment: [String: String], supportDirectory: URL,
                                      honoursOverride: Bool = PiEngine.honoursOverride) -> YourPiLocator {
        func set(_ key: String) -> String? {
            environment[key].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        if honoursOverride, let value = set(overrideEnvKey) {
            return YourPiLocator(.fixed(URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)))
        }
        if honoursOverride, set(PiEngine.overrideEnvKey) != nil { return YourPiLocator(.fixed(nil)) }
        return YourPiLocator(.loginShell(environment: environment, supportFolders: supportFolders(including: supportDirectory)))
    }

    /// Every edition's support folder, and `current`.
    public static func supportFolders(including current: URL) -> [URL] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [current] + ["Shepherd", "Shepherd Nightly", "Shepherd-dev"].map { base.appendingPathComponent($0, isDirectory: true) }
    }

    /// "Your pi", or nil when it can't be found or was refused. Blocking the first time (a
    /// login shell): call it off the main thread and the server queue.
    public func resolve() -> YourPi? {
        answer().yourPi
    }

    /// The folder the user's startup files name as their pi, when it was refused for being inside
    /// a support folder (so `resolve()` is nil): Shepherd reads nothing of it, but its home must
    /// not overlap it (`PiSetup.check`). Blocking the first time, like `resolve()`.
    public func refusedDirectory() -> URL? {
        answer().refused
    }

    /// The provider key variables the user's login shell sets, by name only (pi reads them from an
    /// agent's login shell). Blocking the first time, like `resolve()`.
    public func environmentKeys() -> Set<String> {
        answer().environmentKeys
    }

    private func answer() -> Answer {
        lock.withLock {
            if let resolved { return resolved }
            let found: Answer
            switch source {
            case .fixed(let url, let keys): found = Answer(yourPi: url.map { YourPi(agentDirectory: $0) }, environmentKeys: keys)
            case .loginShell(let environment, let supportFolders): found = Self.fromLoginShell(environment: environment, supportFolders: supportFolders)
            }
            resolved = found
            return found
        }
    }

    static let marker = "SHEPHERD-YOUR-PI"

    private static func fromLoginShell(environment: [String: String], supportFolders: [URL]) -> Answer {
        var env = environment
        for key in ["PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR"] { env[key] = nil }
        for key in env.keys where key.hasPrefix("SHEPHERD_") && key != ShepherdPaths.supportDirectoryEnvKey { env[key] = nil }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        // The key variables are printed by name, only when set: never a value.
        let keys = PiProviders.allEnvironmentKeys.joined(separator: " ")
        let script = #"print -r -- "\#(marker)-DIR=${PI_CODING_AGENT_DIR-}"; print -r -- "\#(marker)-SESSIONS=${PI_CODING_AGENT_SESSION_DIR-}"; "#
            + #"for _n in \#(keys); do [[ -n ${(P)_n-} ]] && print -r -- "\#(marker)-KEY=$_n"; done; true"#
        let output = LoginShellProbe.run(script: script, environment: env, directory: home, timeout: 10)
        var values: [String: String] = [:]
        var found: Set<String> = []
        for line in output.split(separator: "\n") {
            for key in ["DIR", "SESSIONS"] where line.hasPrefix("\(marker)-\(key)=") {
                values[key] = String(line.dropFirst(marker.count + key.count + 2))
            }
            if line.hasPrefix("\(marker)-KEY=") {
                let name = String(line.dropFirst(marker.count + 5))
                if PiProviders.allEnvironmentKeys.contains(name) { found.insert(name) }
            }
        }
        var result = Self.answer(dir: values["DIR"], sessions: values["SESSIONS"], home: home, supportFolders: supportFolders)
        result.environmentKeys = found
        return result
    }

    /// What a login shell printed, as pi would take it: the folder (`~` expanded, relative to
    /// home), the session folder from the environment or the folder's settings, and `~/.pi/agent`
    /// when the folder is elsewhere. Nil when the folder resolves inside a support folder.
    static func interpret(dir: String?, sessions: String?, home: String, supportFolders: [URL]) -> YourPi? {
        answer(dir: dir, sessions: sessions, home: home, supportFolders: supportFolders).yourPi
    }

    /// `interpret`, with the folder it refused.
    static func answer(dir: String?, sessions: String?, home: String, supportFolders: [URL]) -> Answer {
        func path(_ value: String?, relativeTo base: String) -> URL? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            let expanded = value == "~" ? home : value.hasPrefix("~/") ? home + value.dropFirst() : value
            return URL(fileURLWithPath: expanded.hasPrefix("/") ? expanded : base + "/" + expanded, isDirectory: true).standardizedFileURL
        }
        let standard = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".pi/agent", isDirectory: true)
        let agent = path(dir, relativeTo: home) ?? standard
        let canonicalAgent = PiHome.canonical(agent.path)
        for folder in supportFolders where PiHome.isInside(canonicalAgent, PiHome.canonical(folder.path)) {
            ShepherdLog.info("your pi resolves to \(agent.path), inside Shepherd's support folder \(folder.path): Shepherd won't read it")
            return Answer(refused: agent)
        }
        var sessionFolder = path(sessions, relativeTo: home)
        if sessionFolder == nil,
           let data = try? YourPiFiles.read(agent.appendingPathComponent("settings.json")), data.count < 1 << 20,
           let settings = try? YourPiFiles.object(data, file: "settings.json") {
            sessionFolder = path(settings["sessionDir"] as? String, relativeTo: agent.path)
        }
        return Answer(yourPi: YourPi(agentDirectory: agent, sessionDirectory: sessionFolder,
                                     fallbackAgentDirectory: agent.standardizedFileURL == standard.standardizedFileURL ? nil : standard))
    }
}

/// A short login-shell run for what the user's startup files set.
enum LoginShellProbe {
    static func run(script: String, environment: [String: String], directory: String, timeout: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", script]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return "" }
        let data = LockedData()
        DispatchQueue.global(qos: .userInitiated).async {
            data.set(output.fileHandleForReading.readDataToEndOfFile())
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut || done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return ""
        }
        return String(decoding: data.value, as: UTF8.self)
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        var value: Data { lock.withLock { stored } }
        func set(_ data: Data) { lock.withLock { stored = data } }
    }
}
