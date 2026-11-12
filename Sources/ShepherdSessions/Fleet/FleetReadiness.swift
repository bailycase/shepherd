import Foundation
import ShepherdProtocol

/// What this host knows of itself that a readiness report is made from.
struct FleetLocalFacts: Sendable {
    /// Threads working now.
    var activeAgents: Int
    /// Each project (space) this Mac has a folder for.
    var spaces: [(name: String, path: String)]
    /// pi's MCP file on this Mac: the commands of the local servers in it are what a thread may run.
    var mcpConfig: URL?

    init(activeAgents: Int = 0, spaces: [(name: String, path: String)] = [], mcpConfig: URL? = nil) {
        self.activeAgents = activeAgents
        self.spaces = spaces
        self.mcpConfig = mcpConfig
    }
}

/// What a probe of the login shell found missing.
struct FleetProbeResult: Equatable, Sendable {
    var missingCommands: Set<String> = []
    var noGit = false
    var noXcode = false
}

/// Readiness (`FleetReadinessReport`): the facts sync can't carry. Each local MCP server's command
/// resolved the way a thread would run it (the login shell's PATH), git, Xcode where a project
/// needs it, the projects this Mac has a folder for, and its hardware. Never sign-in, which
/// syncs, and never an action: a Mac that lacks a program says so and that is all.
enum FleetReadiness {
    /// Asks the login shell which of `commands` don't resolve, and whether git and Xcode are there.
    typealias Probe = @Sendable (_ commands: [String]) async -> FleetProbeResult

    /// The model name and chip of this Mac.
    typealias Hardware = @Sendable () -> (model: String, chip: String)

    /// Names the shell may be asked about: no quoting, no expansion.
    private static let safeCommand = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._+@-]+$"#)

    /// What a recheck of the facts would compare: the same key means the same report.
    static func key(commands: [String], needsXcode: Bool, repos: [String]) -> String {
        (commands + [needsXcode ? "xcode" : "-"] + repos).joined(separator: "\u{1}")
    }

    /// The commands of the local (stdio) servers in `config`, each once, sorted: `npx`, `uvx`,
    /// `muse`. A path to a program names that program. A server switched off isn't asked about.
    static func mcpCommands(in config: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: config)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return [] }
        var names = Set<String>()
        for case let entry as [String: Any] in servers.values {
            guard let command = (entry["command"] as? String)?.trimmingCharacters(in: .whitespaces), !command.isEmpty,
                  (entry["shepherd"] as? [String: Any])?["enabled"] as? Bool != false else { continue }
            names.insert(command)
        }
        return names.sorted()
    }

    /// Whether any project folder holds an Xcode project at its top level.
    static func needsXcode(spaces: [(name: String, path: String)], fileManager: FileManager = .default) -> Bool {
        spaces.contains { space in
            let path = (space.path as NSString).expandingTildeInPath
            let names = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
            return names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        }
    }

    /// The report for `facts`. `commands` are the ones to resolve (`mcpCommands`).
    static func report(commands: [String], needsXcode: Bool, spaces: [(name: String, path: String)],
                       probe: Probe, hardware: Hardware) async -> FleetReadinessReport {
        // A command that is a path is checked on disk; a name goes to the shell.
        var missing: [FleetMissingTool] = []
        var names: [String] = []
        for command in commands {
            if command.contains("/") {
                let path = (command as NSString).expandingTildeInPath
                if !FileManager.default.isExecutableFile(atPath: path) {
                    missing.append(FleetMissingTool(kind: .binary, name: (command as NSString).lastPathComponent))
                }
            } else if safeCommand.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil {
                names.append(command)
            }
        }
        let found = await probe(names)
        missing += names.filter { found.missingCommands.contains($0) }.map { FleetMissingTool(kind: .binary, name: $0) }
        if found.noGit { missing.append(FleetMissingTool(kind: .git)) }
        if needsXcode, found.noXcode { missing.append(FleetMissingTool(kind: .xcode)) }
        let machine = hardware()
        return FleetReadinessReport(model: machine.model, chip: machine.chip, missing: missing,
                                    repos: Array(Set(spaces.map(\.name).filter { !$0.isEmpty })).sorted())
    }

    // MARK: The system's facts

    /// One login shell run: `command -v` for each name, git (the stub in /usr/bin counts only
    /// with developer tools behind it) and Xcode (`xcode-select` pointing into an app).
    static let systemProbe: Probe = { commands in
        let loop = commands.isEmpty ? "" : "for c in \(commands.joined(separator: " ")); do command -v \"$c\" >/dev/null 2>&1 || echo \"bin:$c\"; done\n"
        let script = loop + """
        p=$(command -v git 2>/dev/null)
        if [ -z "$p" ] || { [ "$p" = /usr/bin/git ] && ! xcode-select -p >/dev/null 2>&1; }; then echo git; fi
        case "$(xcode-select -p 2>/dev/null)" in *.app/Contents/Developer) ;; *) echo xcode ;; esac
        """
        let output = await LoginShell.run(script, timeout: 30)
        // A shell that didn't answer says nothing is missing: a guess either way would be a claim.
        guard output.status == 0 else { return FleetProbeResult() }
        var result = FleetProbeResult()
        for line in output.stdout.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line == "git" { result.noGit = true } else if line == "xcode" { result.noXcode = true }
            else if line.hasPrefix("bin:") { result.missingCommands.insert(String(line.dropFirst(4))) }
        }
        return result
    }

    static let systemHardware: Hardware = {
        func sysctl(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
            return String(cString: buffer)
        }
        return (modelName(identifier: sysctl("hw.model")), chipName(brand: sysctl("machdep.cpu.brand_string")))
    }

    /// "MacBookPro18,3" is a MacBook Pro. An Apple silicon identifier ("Mac16,5") names no family.
    static func modelName(identifier: String) -> String {
        let families = [("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"),
                        ("Macmini", "Mac mini"), ("iMac", "iMac"), ("MacPro", "Mac Pro")]
        return families.first { identifier.hasPrefix($0.0) }?.1 ?? "Mac"
    }

    /// "Apple M4 Pro" is "M4 Pro"; an Intel brand string is left as it is.
    static func chipName(brand: String) -> String {
        let text = brand.trimmingCharacters(in: .whitespaces)
        return text.hasPrefix("Apple ") ? String(text.dropFirst("Apple ".count)) : text
    }
}
