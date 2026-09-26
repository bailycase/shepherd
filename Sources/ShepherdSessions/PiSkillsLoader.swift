import Darwin
import Foundation
import ShepherdProtocol

/// The skills this host's pi loads from outside Shepherd's skills folder (Settings ▸ Skills'
/// read-only groups; docs/skills.md › Outside skills), from two places:
///
/// - Shepherd's own pi home, asked of pi's own loader, so the page lists exactly what an agent
///   gets: `shepherd-pi-skills.mjs` runs on the engine's node, imports the engine's pi, and prints
///   what it resolves for the home (its `skills/`, the `skills` paths in its settings; it loads
///   no packages).
/// - "Your pi" (the user's own), read as plain files, never through pi's code: its `skills/`
///   and the `skills` paths in its settings.json, for From your pi setup.
///
/// It only reads; nothing under either folder is written.
///
/// Running node takes about half a second, so a result is kept until one of the folders it came
/// from changes (their modification dates), and reads wait for one another rather than run twice.
/// Blocking: call it off the main thread and the server queue.
public final class PiSkillsLoader: @unchecked Sendable {
    /// How node starts.
    public enum Launch: Sendable {
        /// The engine's node, importing the engine's pi (`PiLaunch.skillsReader`).
        case engine
        /// This node, importing pi from this package (tests).
        case node(URL, package: URL)
    }

    /// A read that takes longer is stopped, and the page says pi took too long.
    public static let timeout: TimeInterval = 20

    private let agentDirectory: URL
    private let engine: PiEngine
    private let yourPi: @Sendable () -> YourPi?
    private let ready: @Sendable () -> Bool
    private let launch: Launch
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let home: String
    private let lock = NSLock()
    private var cached: (installed: String, fingerprint: [String: Double], skills: PiSkills)?

    /// `environment` is the child's (tests move `HOME` with it); `agentDirectory` is Shepherd's
    /// pi home, `engine` the pi an `.engine` launch imports, and `yourPi` the user's own pi.
    /// `ready` readies the home before pi's loader reads it (`PiSetup.prepare`, which strips a
    /// `packages` key: resolving one pi can't find in the home runs the user's npm); false when
    /// no pi may read it.
    public init(agentDirectory: URL, engine: PiEngine, yourPi: @escaping @Sendable () -> YourPi? = { nil },
                ready: @escaping @Sendable () -> Bool = { true }, launch: Launch = .engine,
                environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = PiSkillsLoader.timeout) {
        self.agentDirectory = agentDirectory.standardizedFileURL
        self.engine = engine
        self.yourPi = yourPi
        self.ready = ready
        self.launch = launch
        self.environment = environment
        self.timeout = timeout
        home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
    }

    /// The outside skills, with `installedDirectory` (Shepherd's skills folder) left out: its
    /// skills are the page's Installed ones. Kept until a folder involved changes.
    public func read(installedDirectory: URL) -> PiSkills {
        lock.withLock {
            let installed = installedDirectory.standardizedFileURL.path
            if let cached, cached.installed == installed, Self.fingerprint(Array(cached.fingerprint.keys)) == cached.fingerprint {
                return cached.skills
            }
            let yours = yourPi()
            let (output, problem) = ready() ? run() : (nil, PiSkills.Problem.failed.rawValue)
            let skills: PiSkills
            var watched = baseWatched(installed: installed, yourPi: yours)
            let shown = yours?.agentDirectory.path ?? agentDirectory.path
            if var output {
                if let yours { output = Self.merging(Self.plainSkills(of: yours), into: output) }
                output.agentDir = shown
                skills = Self.report(output, installedDirectories: [installed, home + "/.agents/skills"], home: home,
                                     agentDirectory: shown)
                watched += Self.watched(output)
            } else {
                skills = PiSkills(agentDirectory: Self.abbreviate(shown, home: home),
                                  problem: problem ?? PiSkills.Problem.failed.rawValue)
            }
            // A failure isn't kept: the next read tries again.
            if output?.problem == nil, problem == nil {
                cached = (installed, Self.fingerprint(watched), skills)
            } else {
                cached = nil
            }
            return skills
        }
    }

    // MARK: Running

    private func run() -> (Output?, problem: String?) {
        let process = Process()
        var env = environment
        // The engine's node, as the launcher starts it: none of the environment's pi, jiti or
        // Node settings.
        for key in env.keys where key.hasPrefix("PI_") || key.hasPrefix("JITI_") || key.hasPrefix("NODE_") || key == "OPENSSL_CONF" {
            if key != "NODE_EXTRA_CA_CERTS" { env[key] = nil }
        }
        env["SHEPHERD_PI_SKILLS_AGENT_DIR"] = agentDirectory.path
        env["PI_CODING_AGENT_DIR"] = agentDirectory.path
        env["PI_OFFLINE"] = "1"
        switch launch {
        case .engine:
            guard let package = engine.packageDirectory else { return (nil, PiSkills.Problem.piNotFound.rawValue) }
            let argv = PiLaunch.skillsReader(engine: engine)
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            env["SHEPHERD_PI_SKILLS_PACKAGE"] = package
        case .node(let node, let package):
            process.executableURL = node
            process.arguments = ["--input-type=module", "-"]
            env["SHEPHERD_PI_SKILLS_PACKAGE"] = package.path
        }
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: home, isDirectory: true)
        let input = Pipe(), output = Pipe()
        // The script fits the pipe's buffer, so it is written before node starts, while this
        // process still holds the read end: no write can meet a closed pipe.
        input.fileHandleForWriting.write(Data(Self.scriptSource.utf8))
        try? input.fileHandleForWriting.close()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (nil, PiSkills.Problem.nodeNotFound.rawValue)
        }
        let data = ReadBuffer(Data())
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            data.set(output.fileHandleForReading.readDataToEndOfFile())
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return (nil, PiSkills.Problem.timedOut.rawValue)
        }
        process.waitUntilExit()
        if let decoded = Output.decode(data.value) { return (decoded, nil) }
        return (nil, process.terminationStatus == 127 ? PiSkills.Problem.nodeNotFound.rawValue : PiSkills.Problem.failed.rawValue)
    }

    // MARK: Your pi, as plain files

    /// The skills in "your pi", read as files, in pi's order: its `skills/` folder, then each
    /// `skills` path in its settings.json (absolute, `~`, or relative to the folder; a `!` or `-`
    /// filter is skipped and a `+` dropped). A folder's skills are its `.md` files and every
    /// `SKILL.md` below it; a file is one skill.
    static func plainSkills(of yourPi: YourPi) -> [Output.Entry] {
        let agent = yourPi.agentDirectory.path
        var roots: [(path: String, source: String)] = [(agent + "/skills", "auto")]
        if let data = try? Data(contentsOf: yourPi.agentDirectory.appendingPathComponent("settings.json")), data.count < 1 << 20,
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for case var entry as String in settings["skills"] as? [Any] ?? [] {
                entry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                if entry.hasPrefix("!") || entry.hasPrefix("-") || entry.isEmpty { continue }
                if entry.hasPrefix("+") { entry.removeFirst() }
                let expanded = (entry as NSString).expandingTildeInPath
                let absolute = expanded.hasPrefix("/") ? expanded : agent + "/" + expanded
                roots.append(((absolute as NSString).standardizingPath, "local"))
            }
        }
        var entries: [Output.Entry] = []
        var seen: Set<String> = []
        for root in roots {
            for file in skillFiles(at: root.path) where seen.insert(canonical(file)).inserted {
                guard let entry = entry(file: file, source: root.source) else { continue }
                entries.append(entry)
            }
        }
        return entries
    }

    /// The skill files under `path`: the file itself, or a folder's top-level `.md` files and each
    /// `SKILL.md` below it (a folder holding one is that skill, and isn't searched further).
    static func skillFiles(at path: String) -> [String] {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return path.hasSuffix(".md") ? [path] : [] }
        var found: [String] = []
        let names = ((try? files.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for name in names where name.hasSuffix(".md") && name != "SKILL.md" {
            var directory: ObjCBool = false
            if files.fileExists(atPath: path + "/" + name, isDirectory: &directory), !directory.boolValue { found.append(path + "/" + name) }
        }
        func search(_ folder: String, depth: Int) {
            if files.fileExists(atPath: folder + "/SKILL.md") { found.append(folder + "/SKILL.md"); return }
            guard depth < 4 else { return }
            let children = ((try? files.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") && $0 != "node_modules" }.sorted()
            for child in children {
                var directory: ObjCBool = false
                if files.fileExists(atPath: folder + "/" + child, isDirectory: &directory), directory.boolValue {
                    search(folder + "/" + child, depth: depth + 1)
                }
            }
        }
        if files.fileExists(atPath: path + "/SKILL.md") { return [path + "/SKILL.md"] }
        for name in names {
            var directory: ObjCBool = false
            if files.fileExists(atPath: path + "/" + name, isDirectory: &directory), directory.boolValue { search(path + "/" + name, depth: 1) }
        }
        return found
    }

    /// A skill file's name, description and invocation, from its front matter (the folder's or
    /// file's name when it names none).
    static func entry(file: String, source: String) -> Output.Entry? {
        guard let handle = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? handle.close() }
        let text = String(decoding: (try? handle.read(upToCount: 64 * 1024)) ?? Data(), as: UTF8.self)
        var fields: [String: String] = [:]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.first == "---" {
            for line in lines.dropFirst() {
                if line == "---" { break }
                guard let colon = line.firstIndex(of: ":") else { continue }
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                    value = String(value.dropFirst().dropLast())
                }
                fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = value
            }
        }
        let url = URL(fileURLWithPath: file)
        let fallback = url.lastPathComponent == "SKILL.md" ? url.deletingLastPathComponent().lastPathComponent
            : url.deletingPathExtension().lastPathComponent
        let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        return Output.Entry(name: name, description: fields["description"] ?? "", path: file, source: source, origin: "top-level",
                            scope: "user", slashOnly: fields["disable-model-invocation"] == "true")
    }

    /// `output` with `yours` added after what Shepherd's pi loads: a file already listed once, and
    /// a name already taken (which the later one loses to, as in pi), become a shadowed entry.
    static func merging(_ yours: [Output.Entry], into output: Output) -> Output {
        var merged = output
        var paths = Set((output.skills + output.shadowed).map { canonical($0.path) })
        var winners = Dictionary(output.skills.map { ($0.name, $0.path) }, uniquingKeysWith: { first, _ in first })
        for entry in yours where paths.insert(canonical(entry.path)).inserted {
            if let winner = winners[entry.name] {
                var loser = entry
                loser.winner = winner
                merged.shadowed.append(loser)
            } else {
                winners[entry.name] = entry.path
                merged.skills.append(entry)
            }
        }
        return merged
    }

    // MARK: What pi reported

    /// The script's answer.
    struct Output: Decodable, Equatable {
        struct Entry: Decodable, Equatable {
            var name: String
            var description: String?
            var path: String
            var source: String?
            var origin: String?
            var scope: String?
            var baseDir: String?
            var packageName: String?
            var slashOnly: Bool?
            /// A shadowed skill's: the SKILL.md pi uses instead.
            var winner: String?
        }

        var agentDir: String?
        var skills: [Entry]
        var shadowed: [Entry]
        var problem: String?

        private enum CodingKeys: String, CodingKey { case agentDir, skills, shadowed, problem }

        init(agentDir: String? = nil, skills: [Entry] = [], shadowed: [Entry] = [], problem: String? = nil) {
            self.agentDir = agentDir
            self.skills = skills
            self.shadowed = shadowed
            self.problem = problem
        }

        /// The script's answer from its stdout: the last line that decodes, since a login shell's
        /// startup files may print before node runs.
        static func decode(_ data: Data) -> Output? {
            let decoder = JSONDecoder()
            for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
                if let output = try? decoder.decode(Output.self, from: Data(line)) { return output }
            }
            return nil
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentDir = try c.decodeIfPresent(String.self, forKey: .agentDir)
            skills = try c.decodeIfPresent([Entry].self, forKey: .skills) ?? []
            shadowed = try c.decodeIfPresent([Entry].self, forKey: .shadowed) ?? []
            problem = try c.decodeIfPresent(String.self, forKey: .problem)
        }
    }

    /// pi's skills as the page lists them: every skill outside `installedDirectories` (Shepherd's
    /// folder, which the Installed group shows), by origin, package and name, each shadowed one
    /// after the one pi uses; and the installed skills pi doesn't use because an outside one of
    /// the same name comes first. Paths read with `home` as `~`.
    static func report(_ output: Output, installedDirectories: [String], home: String, agentDirectory: String) -> PiSkills {
        let installedRoots = installedDirectories.map(canonical)
        func isInstalled(_ entry: Output.Entry) -> Bool {
            let path = canonical(entry.path)
            return installedRoots.contains { isUnder(path, $0) }
        }
        func origin(_ entry: Output.Entry) -> PiSkill.Origin {
            if entry.origin == "package" { return .package }
            return entry.source == "auto" ? .agentDirectory : .settingsPath
        }
        // A repository's or a command line's own skills never reach a global list.
        func belongs(_ entry: Output.Entry) -> Bool { (entry.scope ?? "user") == "user" }
        func skill(_ entry: Output.Entry, shadowedBy winner: String?) -> PiSkill {
            let kind = origin(entry)
            return PiSkill(name: entry.name, summary: entry.description ?? "", path: abbreviate(entry.path, home: home), origin: kind,
                           package: kind == .package ? packageLabel(entry) : nil,
                           invocation: entry.slashOnly == true ? .slashOnly : .automatic,
                           shadowedBy: winner.map { abbreviate($0, home: home) })
        }

        var skills: [PiSkill] = []
        var shadowedInstalled: [String: String] = [:]
        for entry in output.skills where belongs(entry) && !isInstalled(entry) {
            skills.append(skill(entry, shadowedBy: nil))
        }
        for entry in output.shadowed where belongs(entry) {
            guard let winner = entry.winner else { continue }
            if isInstalled(entry) {
                shadowedInstalled[entry.name] = abbreviate(winner, home: home)
            } else {
                skills.append(skill(entry, shadowedBy: winner))
            }
        }
        let order: [PiSkill.Origin: Int] = [.agentDirectory: 0, .settingsPath: 1, .package: 2]
        skills.sort { a, b in
            if a.origin != b.origin { return order[a.origin, default: 3] < order[b.origin, default: 3] }
            if (a.package ?? "") != (b.package ?? "") { return (a.package ?? "") < (b.package ?? "") }
            if a.name != b.name { return a.name < b.name }
            return a.isUsed && !b.isUsed
        }
        return PiSkills(agentDirectory: abbreviate(output.agentDir ?? agentDirectory, home: home), skills: skills,
                        shadowedInstalled: shadowedInstalled, problem: output.problem)
    }

    /// A package as the page names it: its package.json's name, else its source in pi's settings
    /// without the kind or version ("npm:@acme/skills@1.2" → "@acme/skills", "git:github.com/o/r@v1"
    /// → "o/r", "./vendor/skills" → "skills").
    static func packageLabel(_ entry: Output.Entry) -> String {
        if let name = entry.packageName, !name.isEmpty { return name }
        var source = entry.source ?? entry.baseDir ?? ""
        if source.hasPrefix("npm:") {
            source.removeFirst(4)
            if let at = source.dropFirst().lastIndex(of: "@") { source = String(source[..<at]) }
            return source
        }
        if source.hasPrefix("git:") || source.hasPrefix("git@") || source.contains("://") {
            if source.hasPrefix("git:") { source.removeFirst(4) }
            if let at = source.lastIndex(of: "@"), let slash = source.lastIndex(of: "/"), at > slash { source = String(source[..<at]) }
            if source.hasSuffix(".git") { source.removeLast(4) }
            return source.split(whereSeparator: { $0 == "/" || $0 == ":" }).suffix(2).joined(separator: "/")
        }
        return (source as NSString).lastPathComponent
    }

    // MARK: Paths

    /// `path` with `home` as `~`.
    static func abbreviate(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The real path when the file exists (so /tmp and /private/tmp agree), else the path tidied.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isUnder(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: When to read again

    /// The folders every read depends on: pi's settings and skills, and the skills folders.
    private func baseWatched(installed: String, yourPi: YourPi?) -> [String] {
        var folders = [agentDirectory.path, installed, home + "/.agents/skills"]
        if let yourPi { folders.append(yourPi.agentDirectory.path) }
        return folders.flatMap { [$0, $0 + "/settings.json", $0 + "/skills"] }
    }

    /// The folders a result came from: each skill's file, its folder and the one holding that (a
    /// new skill beside it), and each package.
    static func watched(_ output: Output) -> [String] {
        var paths: [String] = []
        for entry in output.skills + output.shadowed {
            let folder = (entry.path as NSString).deletingLastPathComponent
            paths += [entry.path, folder, (folder as NSString).deletingLastPathComponent]
            if let base = entry.baseDir { paths.append(base) }
        }
        return paths
    }

    /// Each path's modification date, or -1 while it doesn't exist.
    static func fingerprint(_ paths: [String]) -> [String: Double] {
        var dates: [String: Double] = [:]
        for path in paths where dates[path] == nil {
            var info = stat()
            dates[path] = stat(path, &info) == 0
                ? Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
                : -1
        }
        return dates
    }
}

/// A value one thread writes and another reads after a semaphore.
private final class ReadBuffer<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}

extension PiSkillsLoader {
    /// Extensions/shepherd-pi-skills.mjs is canonical; keep this literal byte-identical
    /// (scripts/sync-embedded-extension.py).
    static let scriptSource = #"""
        // Settings ▸ Skills' outside skills: every skill Shepherd's own pi loads for a session outside any
        // repository, read with pi's own loader, so the page lists exactly what the agent gets
        // (docs/skills.md). Shepherd runs it on the engine's node, source on stdin:
        //
        //   node --input-type=module -
        //
        // SHEPHERD_PI_SKILLS_AGENT_DIR names the pi home (Shepherd's own), and SHEPHERD_PI_SKILLS_PACKAGE
        // the pi package to import (the engine's); the user's own pi is never imported or looked for. It
        // prints one JSON object and exits 0, even when it can't read pi's skills ("problem" says why).
        // It only reads: pi's settings go through a storage that never writes, nothing missing is
        // installed (PI_OFFLINE), and no extension runs, so skills an extension adds while it runs are
        // not here.
        import { existsSync, readFileSync, statSync } from "node:fs";
        import { homedir } from "node:os";
        import { join, resolve, sep } from "node:path";
        import { pathToFileURL } from "node:url";

        const print = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);

        function readJSON(file) {
          try { return JSON.parse(readFileSync(file, "utf8")); } catch { return undefined; }
        }

        function findPackage() {
          const named = process.env.SHEPHERD_PI_SKILLS_PACKAGE;
          return named && existsSync(join(named, "package.json")) ? resolve(named) : undefined;
        }

        // The engine ships pi's bundle alone, so its library entry is the bundle's; a full package's is
        // what its exports name.
        function entryOf(packageDir) {
          const manifest = readJSON(join(packageDir, "package.json")) ?? {};
          const root = manifest.exports?.["."];
          const bundled = join("dist", "bundle", "index.js");
          const entry = existsSync(join(packageDir, bundled)) ? bundled
            : (typeof root === "string" ? root : root?.import ?? root?.default) ?? manifest.main ?? "dist/index.js";
          return { file: join(packageDir, entry), version: typeof manifest.version === "string" ? manifest.version : undefined };
        }

        // pi's settings, read and never written back: a lock or a migration would write.
        function readOnlyStorage(agentDir, cwd) {
          const files = { global: join(agentDir, "settings.json"), project: join(cwd, ".pi", "settings.json") };
          return {
            withLock(scope, fn) {
              let current;
              try { current = readFileSync(files[scope], "utf8"); } catch {}
              fn(current);
            },
          };
        }

        function under(path, root) {
          const r = resolve(root);
          const p = resolve(path);
          return p === r || p.startsWith(r.endsWith(sep) ? r : r + sep);
        }

        async function main() {
          const agentDir = resolve(process.env.SHEPHERD_PI_SKILLS_AGENT_DIR || join(homedir(), ".pi", "agent"));
          const packageDir = findPackage();
          if (!packageDir) return print({ agentDir, skills: [], shadowed: [], problem: "pi_not_found" });
          const { file, version } = entryOf(packageDir);
          let pi;
          try { pi = await import(pathToFileURL(file).href); } catch (error) {
            return print({ agentDir, version, skills: [], shadowed: [], problem: "pi_unreadable", detail: String(error?.message ?? error) });
          }
          const { DefaultPackageManager, SettingsManager, loadSkills } = pi;
          if (typeof DefaultPackageManager !== "function" || typeof SettingsManager?.fromStorage !== "function" || typeof loadSkills !== "function") {
            return print({ agentDir, version, skills: [], shadowed: [], problem: "pi_unsupported" });
          }
          process.env.PI_OFFLINE = "1";
          // Outside any repository: a repository's own skills show in its threads, never here.
          const cwd = homedir();
          const settingsManager = SettingsManager.fromStorage(readOnlyStorage(agentDir, cwd), { projectTrusted: false });
          const manager = new DefaultPackageManager({ cwd, agentDir, settingsManager });
          const resolved = await manager.resolve(async () => "skip");

          // As pi's resource loader does: a folder from auto-discovery or a package that holds a
          // SKILL.md is that skill; the resolved list is already in pi's order of precedence.
          const metadataByPath = new Map();
          const paths = [];
          for (const resource of resolved.skills) {
            if (!metadataByPath.has(resource.path)) metadataByPath.set(resource.path, resource.metadata);
            if (!resource.enabled) continue;
            let path = resource.path;
            const { source, origin } = resource.metadata;
            if (source === "auto" || origin === "package") {
              try {
                if (statSync(path).isDirectory() && existsSync(join(path, "SKILL.md"))) {
                  path = join(path, "SKILL.md");
                  if (!metadataByPath.has(path)) metadataByPath.set(path, resource.metadata);
                }
              } catch {}
            }
            if (!paths.includes(path)) paths.push(path);
          }
          const metadataFor = (filePath) => {
            const exact = metadataByPath.get(resolve(filePath)) ?? metadataByPath.get(filePath);
            if (exact) return exact;
            for (const [path, metadata] of metadataByPath) if (under(filePath, path)) return metadata;
            return undefined;
          };
          const packageNames = new Map();
          const packageName = (baseDir) => {
            if (!baseDir) return undefined;
            if (!packageNames.has(baseDir)) packageNames.set(baseDir, readJSON(join(baseDir, "package.json"))?.name);
            return packageNames.get(baseDir);
          };
          const describe = (skill) => {
            const metadata = metadataFor(skill.filePath) ?? {};
            return {
              name: skill.name,
              description: skill.description ?? "",
              path: skill.filePath,
              source: metadata.source ?? "local",
              origin: metadata.origin ?? "top-level",
              scope: metadata.scope ?? "user",
              baseDir: metadata.baseDir,
              packageName: metadata.origin === "package" ? packageName(metadata.baseDir) : undefined,
              slashOnly: skill.disableModelInvocation === true,
            };
          };

          const loaded = loadSkills({ cwd, agentDir, skillPaths: paths, includeDefaults: false });
          const skills = loaded.skills.map(describe);
          // A name pi found twice: the first wins, and the agent never sees the other.
          const shadowed = [];
          for (const diagnostic of loaded.diagnostics ?? []) {
            const collision = diagnostic.collision;
            if (diagnostic.type !== "collision" || collision?.resourceType !== "skill") continue;
            const loser = loadSkills({ cwd, agentDir, skillPaths: [collision.loserPath], includeDefaults: false }).skills[0];
            const entry = loser ? describe(loser) : describe({ name: collision.name, description: "", filePath: collision.loserPath });
            shadowed.push({ ...entry, winner: collision.winnerPath });
          }
          print({ agentDir, version, skills, shadowed });
        }

        main().catch((error) => print({ skills: [], shadowed: [], problem: "failed", detail: String(error?.message ?? error) }));

        """#
}
