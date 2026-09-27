import Darwin
import Foundation

/// Shepherd's own pi home, `<support directory>/pi`: the `PI_CODING_AGENT_DIR` of every pi
/// Shepherd starts, holding its settings, sign-ins, models, sessions, and `bin/pi`, the launcher
/// every launch goes through. Nothing in it is the user's own pi, and nothing Shepherd writes
/// goes anywhere else (docs/pi-home.md).
///
/// `install()` writes Shepherd's files whenever they differ, the way the embedded extensions are
/// installed: the launcher, `restore-env.sh` (which gives an agent's shell commands back the
/// variables the launcher set aside), the marker that names this folder as Shepherd's, and
/// Shepherd's keys in `settings.json`, which pi writes too.
public struct PiHome: Equatable, Sendable {
    /// The folder: `PI_CODING_AGENT_DIR`.
    public let directory: URL
    /// What the launcher execs.
    public let engine: PiEngine
    /// The user's home folder as pi sees it (`HOME`): pi also reads skills from its
    /// `.agents/skills`, which Shepherd's settings exclude (`userSkillsExclusions`).
    public let userHome: String

    public init(directory: URL, engine: PiEngine, userHome: String = PiHome.environmentHome) {
        self.directory = directory.standardizedFileURL
        self.engine = engine
        self.userHome = userHome
    }

    /// `HOME`, as the agents' pi inherits it, else the account's home folder.
    public static var environmentHome: String {
        ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
    }

    /// `<home>/bin/pi`, the launcher. pi puts `<home>/bin` first on its bash tool's PATH, so a
    /// bare `pi` an agent types reaches it too.
    public var launcher: URL { directory.appendingPathComponent("bin/pi") }
    /// Sourced before every command an agent's bash tool runs (`shellCommandPrefix`).
    public var restoreEnv: URL { directory.appendingPathComponent("restore-env.sh") }
    public var settings: URL { directory.appendingPathComponent("settings.json") }
    public var sessions: URL { directory.appendingPathComponent("sessions", isDirectory: true) }
    /// `<home>/sessions/--<cwd>--`, pi's own name for a project's session folder.
    public func sessionDirectory(forCwd cwd: String) -> URL {
        sessions.appendingPathComponent(PiSessionFolder.name(forCwd: cwd), isDirectory: true)
    }
    /// Names this folder as Shepherd's pi home. Found in "your pi", it means the two are one
    /// folder, and Shepherd starts no pi (`PiSetup.check`).
    public var marker: URL { directory.appendingPathComponent(Self.markerName) }
    public static let markerName = ".shepherd-pi-home"

    /// The prefix the launcher keeps each set-aside variable under, and the list of their names.
    /// Not `SHEPHERD_`: the children extension drops those from a child's environment.
    public static let stashPrefix = "_SHEPHERD_STASH_"
    public static let stashNamesKey = "_SHEPHERD_STASH_NAMES"

    /// pi's own subcommands that install, remove or update packages, or change its config: the
    /// launcher refuses them, because Shepherd's pi changes only through Shepherd.
    public static let refusedSubcommands = ["install", "remove", "uninstall", "update", "config"]

    /// The variables the launcher pins, after setting aside every `PI_*`, `JITI_*`, `NODE_*` and
    /// `OPENSSL_CONF` it was started with.
    public var pins: [(String, String)] {
        var pins = [("PI_CODING_AGENT_DIR", directory.path)]
        if let package = engine.packageDirectory { pins.append(("PI_PACKAGE_DIR", package)) }
        pins += [("PI_OFFLINE", "1"), ("PI_SKIP_VERSION_CHECK", "1"), ("PI_TELEMETRY", "0"),
                 ("PI_SUBAGENTS_TEMP_ROOT", directory.appendingPathComponent("tmp/pi-subagents").path)]
        return pins
    }

    // MARK: The launcher

    /// `bin/pi`. It runs under `zsh -f`, so no startup file runs between it and pi, and in order:
    /// sets aside and unsets the environment's `PI_*`, `JITI_*`, `NODE_*` and `OPENSSL_CONF`
    /// (putting `NODE_EXTRA_CA_CERTS` back, for corporate CAs), exports the pins, refuses
    /// `refusedSubcommands`, and execs the engine, or says it's missing and exits 127.
    public var launcherScript: String {
        let q = PiLaunch.quoted
        var script = """
            #!/bin/zsh -f
            # Shepherd's pi. Shepherd writes this file (Sources/ShepherdSessions/PiHome.swift) and rewrites it
            # whenever it differs. Every pi Shepherd starts, and every `pi` its agents type, runs through it:
            # it sets aside the pi, jiti and Node variables it was started with (restore-env.sh gives them back
            # to an agent's shell commands), pins Shepherd's own, and starts the pi that ships inside Shepherd.
            # The pi in your terminal is your own, and this changes nothing of it.
            zmodload zsh/parameter
            unset -m '\(Self.stashPrefix)*'
            typeset -a _shepherd_names
            for _shepherd_name in ${(k)parameters}; do
              [[ ${parameters[$_shepherd_name]} == *export* && $_shepherd_name == (PI_*|JITI_*|NODE_*|OPENSSL_CONF) ]] || continue
              _shepherd_names+=($_shepherd_name)
            done
            for _shepherd_name in $_shepherd_names; do
              export "\(Self.stashPrefix)$_shepherd_name=${(P)_shepherd_name}"
              unset $_shepherd_name
            done
            export \(Self.stashNamesKey)="${_shepherd_names[*]}"
            if (( ${+\(Self.stashPrefix)NODE_EXTRA_CA_CERTS} )); then export NODE_EXTRA_CA_CERTS="$\(Self.stashPrefix)NODE_EXTRA_CA_CERTS"; fi
            unset _shepherd_name _shepherd_names

            """
        for (key, value) in pins { script += "export \(key)=\(q(value))\n" }
        script += """
            case ${1-} in
              (\(Self.refusedSubcommands.joined(separator: "|")))
                print -r -u2 -- "pi $1: Shepherd's pi changes only through Shepherd (Settings ▸ Pi). The pi in your terminal is unaffected."
                exit 2 ;;
            esac

            """
        let executable = engine.command.first ?? ""
        var checks = ["! -x \(q(executable))"]
        for file in engine.command.dropFirst() { checks.append("! -f \(q(file))") }
        script += "if [[ \(checks.joined(separator: " || ")) ]]; then\n"
        script += "  print -r -u2 -- \(q("pi: Shepherd's pi engine is missing: \(engine.command.joined(separator: " ")). Reinstall Shepherd."))\n"
        script += "  exit 127\nfi\n"
        script += "exec \(engine.command.map(q).joined(separator: " ")) \"$@\"\n"
        return script
    }

    /// `restore-env.sh`, sourced by the bash tool's shell (bash, or zsh) before each command:
    /// unsets the pins and exports each variable the launcher set aside, as it was.
    public var restoreEnvScript: String {
        """
        # Shepherd's pi: gives an agent's shell commands back the pi, jiti and Node variables its
        # launcher (bin/pi) set aside. Shepherd writes this file and rewrites it whenever it differs.
        unset \(pins.map(\.0).joined(separator: " "))
        for _shepherd_name in $(printf '%s\\n' "${\(Self.stashNamesKey)-}"); do
          case $_shepherd_name in (''|*[!A-Za-z0-9_]*) continue ;; esac
          eval "export $_shepherd_name=\\"\\${\(Self.stashPrefix)$_shepherd_name}\\""
        done
        unset _shepherd_name

        """
    }

    /// What the bash tool runs before each command (pi joins it to the command with a newline).
    public var shellCommandPrefix: String { ". \(PiLaunch.quoted(restoreEnv.path))" }

    static let markerText = "This folder is Shepherd's own pi home. Shepherd writes it; the pi in your terminal never reads it.\n"

    // MARK: Installing

    /// Writes Shepherd's files into the home, each only when it differs, and Shepherd's keys into
    /// `settings.json`. Blocking (it may wait for pi's settings lock): call it off the main thread.
    /// Returns what it couldn't do that pi should know about, for the log.
    @discardableResult
    public func install() throws -> [String] {
        let files = FileManager.default
        try files.createDirectory(at: directory.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        // A link in the home would carry the launcher somewhere else, such as the user's own pi.
        let bin = launcher.deletingLastPathComponent().path
        guard Self.isInside(Self.canonical(bin), Self.canonical(directory.path)) else {
            throw PiHomeError("\(bin) leads outside Shepherd's pi home, so Shepherd won't write its launcher there")
        }
        try Self.write(Data(Self.markerText.utf8), to: marker, mode: 0o644)
        try Self.write(Data(restoreEnvScript.utf8), to: restoreEnv, mode: 0o644)
        try Self.write(Data(launcherScript.utf8), to: launcher, mode: 0o755)
        return try PiSettingsFile(url: settings).update { settings in
            var notes: [String] = []
            settings["shellCommandPrefix"] = shellCommandPrefix
            // pi reads skills from `$HOME/.agents/skills` besides its own home; Shepherd's pi reads
            // only its home, so a `!` filter in its skills list turns that folder off.
            let skills = Self.excludingUserSkills(settings["skills"], home: userHome)
            if skills.isEmpty { settings.removeValue(forKey: "skills") } else { settings["skills"] = skills }
            // A user-scope package missing from <home>/npm makes pi load the user's global npm
            // install, even offline; packages come to Shepherd's pi only as imported extensions.
            if settings.removeValue(forKey: "packages") != nil {
                notes.append("Removed `packages` from Shepherd's pi settings: Shepherd's pi loads no pi packages.")
            }
            return notes
        }
    }

    // MARK: ~/.agents/skills

    /// The `skills` filters that turn off pi's `$HOME/.agents/skills` (pi: core/package-manager.js,
    /// `addAutoDiscoveredResources`, which adds that folder's skills for every session and enables
    /// each unless a `!` pattern in the global `skills` matches its absolute path). One for `home`
    /// as pi builds the path (`HOME` as it is, never resolved), and one for its real path when that
    /// differs. Glob characters in the path are escaped for minimatch.
    public static func userSkillsExclusions(home: String) -> [String] {
        var homes = [(home as NSString).standardizingPath]
        let real = canonical(home)
        if real != homes[0] { homes.append(real) }
        return homes.map { "!" + globEscaped($0 == "/" ? "" : $0) + "/.agents/skills/**" }
    }

    /// `entries` (the `skills` list pi reads, as settings.json holds it) with Shepherd's exclusions
    /// for `home`, replacing any it wrote for another home; every other entry stays, in order.
    static func excludingUserSkills(_ entries: Any?, home: String) -> [Any] {
        let own = userSkillsExclusions(home: home)
        var kept = (entries as? [Any] ?? []).filter { entry in
            guard let text = entry as? String else { return true }
            return !(text.hasPrefix("!") && text.hasSuffix("/.agents/skills/**"))
        }
        kept += own as [Any]
        return kept
    }

    /// `path` with minimatch's special characters escaped, so it matches only itself.
    static func globEscaped(_ path: String) -> String {
        var out = ""
        for c in path {
            if "\\*?[]{}()!+@#".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Writes `data` to `url` by temp file and rename, unless it already holds exactly that with
    /// `mode`.
    static func write(_ data: Data, to url: URL, mode: mode_t) throws {
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_mode & 0o7777 == mode,
           (try? Data(contentsOf: url)) == data { return }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: temporary)
        chmod(temporary.path, mode)
        guard rename(temporary.path, url.path) == 0 else {
            let error = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw PiHomeError("Couldn't write \(url.path): \(error)")
        }
    }

    // MARK: Paths

    /// The path as it resolves on disk: `realpath` of its deepest existing ancestor, with the
    /// rest appended, so a folder that doesn't exist yet still resolves through a symlinked parent.
    public static func canonical(_ path: String) -> String {
        var existing = (path as NSString).standardizingPath
        var rest: [String] = []
        while !existing.isEmpty {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + rest.reversed()).joined(separator: "/")
            }
            rest.append((existing as NSString).lastPathComponent)
            let parent = (existing as NSString).deletingLastPathComponent
            if parent == existing { break }
            existing = parent
        }
        return (path as NSString).standardizingPath
    }

    /// Whether `path` is `root` or inside it, both already canonical.
    public static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Whether `path` resolves inside this home.
    public func contains(_ path: String) -> Bool {
        Self.isInside(Self.canonical(path), Self.canonical(directory.path))
    }
}

struct PiHomeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One of pi's JSON files in Shepherd's home that pi writes too: `settings.json` (the TUI's
/// `/settings`, a first `/login`), `auth.json` (sign-ins and refreshes), `trust.json`. Shepherd
/// changes it read-modify-write, under pi's own lock (proper-lockfile's `<file>.lock` folder,
/// stale after 10 s), by temp file and rename, and only when its keys differ.
struct PiSettingsFile {
    let url: URL
    /// How long a write waits for pi to let go of the lock.
    var patience: TimeInterval = 5
    /// The file's permissions once written (`auth.json` and `settings.json` are private to the user).
    var mode: mode_t = 0o600
    /// proper-lockfile's default: a lock this old is abandoned.
    static let stale: TimeInterval = 10

    /// Applies `change`, and writes the file only when that changed it. A file that isn't a JSON
    /// object is left as it is. Returns `change`'s notes.
    func update(_ change: (inout [String: Any]) -> [String]) throws -> [String] {
        try withLock {
            var settings: [String: Any] = [:]
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return ["Shepherd's pi's \(url.lastPathComponent) (\(url.path)) isn't a JSON object, so Shepherd left it as it is."]
                }
                settings = object
            }
            let before = NSDictionary(dictionary: settings)
            let notes = change(&settings)
            guard !before.isEqual(to: settings) || !FileManager.default.fileExists(atPath: url.path) else { return notes }
            var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(UInt8(ascii: "\n"))
            try PiHome.write(data, to: url, mode: mode)
            return notes
        }
    }

    /// Replaces the file with `data`, under the lock, by temp file and rename.
    func replace(with data: Data) throws {
        try withLock { try PiHome.write(data, to: url, mode: mode) }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let folder = PiHome.canonical(url.deletingLastPathComponent().path)
        let lock = folder + "/" + url.lastPathComponent + ".lock"
        let deadline = Date().addingTimeInterval(patience)
        while mkdir(lock, 0o777) != 0 {
            guard errno == EEXIST else { throw PiHomeError("Couldn't lock \(url.path): \(String(cString: strerror(errno)))") }
            var info = stat()
            if stat(lock, &info) == 0, Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > Self.stale {
                rmdir(lock)
                continue
            }
            guard Date() < deadline else { throw PiHomeError("pi held \(url.lastPathComponent)'s lock too long") }
            usleep(25_000)
        }
        defer { rmdir(lock) }
        return try body()
    }
}
