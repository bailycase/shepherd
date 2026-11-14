import Foundation
import ShepherdCore
import ShepherdProtocol

/// Fleet ▸ Check, the host's half: this Mac looks at itself for what the fleet's work needs and says what it found
/// (`FleetCheckReport`). Everything here only reads: the markers at the top of each space's checkout, `--version` of a program on the login
/// shell's PATH, `git ls-remote` of each origin, a provider's own cheap sign-in check, free disk and `pmset -g`. Nothing is installed,
/// written or changed, and every command is bounded and killed at its limit (docs/rules.md, Features that act on their own).
enum FleetCheck {
    /// What a provider's check found.
    struct ProviderAnswer: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case works
            /// The provider refused the stored sign-in or key, or the key's variable isn't set.
            case refused(String)
            /// A provider that runs a program (an API key that is a command) whose program isn't there.
            case cantStart(String)
            /// Couldn't be reached from here: nothing is claimed.
            case unknown
        }

        var id: String
        var name: String
        var outcome: Outcome
    }

    /// Where each fact comes from. The defaults are the system's; tests give their own (a stub on a PATH of their own, a remote that answers).
    struct Sources: Sendable {
        /// Runs a script on the login shell, bounded. A shell that didn't answer has a non-zero status.
        var shell: @Sendable (_ script: String) async -> LoginShell.Output
        /// Whether `git ls-remote` of the origin of the checkout at a folder answers: nil when it couldn't be asked.
        var remote: @Sendable (_ folder: String) async -> Bool?
        /// The providers in this Mac's synced sign-ins and whether each answers.
        var providers: @Sendable () async -> [ProviderAnswer]
        /// Bytes free on the volume holding `path`.
        var freeBytes: @Sendable (_ path: String) -> UInt64?

        static func system(providers: @escaping @Sendable () async -> [ProviderAnswer] = { [] }) -> Sources {
            Sources(shell: { await LoginShell.run($0, timeout: shellTimeout) },
                    remote: { folder in await Task.detached { remoteAnswers(folder) }.value },
                    providers: providers,
                    freeBytes: systemFreeBytes)
        }
    }

    /// The login shell's whole answer, and one `git ls-remote`.
    static let shellTimeout: TimeInterval = 30
    static let remoteTimeout: TimeInterval = 20
    /// Under this much free the disk is a warning: a first dispatch can clone a whole repository.
    static let lowDisk: UInt64 = 50_000_000_000
    /// At most this many remotes are asked about.
    static let maxRemotes = 12

    // MARK: The report

    /// The report for `facts`.
    static func report(facts: FleetLocalFacts, sources: Sources) async -> FleetCheckReport {
        // Repo needs: read from each space's checkout, off the queue.
        let spaces = facts.spaces
        let needs = await Task.detached { spaces.flatMap { FleetRepoNeeds.read(folder: $0.path, repo: $0.name) } }.value
        let rows = FleetRepoNeeds.rows(needs)
        let servers = facts.mcpConfig.flatMap { try? Data(contentsOf: $0) }.map(FleetReadiness.mcpServers(in:)) ?? []

        // One login shell run answers every program, the package manager, power and sleep.
        var commands: [(command: String, servers: [String])] = []
        var inPath: [String: Bool] = [:]
        for entry in servers {
            if entry.command.contains("/") {
                inPath[entry.command] = FileManager.default.isExecutableFile(atPath: (entry.command as NSString).expandingTildeInPath)
                commands.append(entry)
            } else if FleetReadiness.isSafeCommand(entry.command) {
                commands.append(entry)
            }
        }
        let wanted = Set(rows.map(\.need.tool))
        let script = script(tools: wanted.sorted { $0.rawValue < $1.rawValue }, commands: commands.map(\.command).filter { !$0.contains("/") })
        // The remotes and the providers are asked while the shell runs: each is bounded, and together they are no slower than the slowest.
        async let remotes = remoteItems(spaces: spaces, sources: sources)
        async let models = modelsItem(sources: sources)
        let answer = await sources.shell(script)
        let found = answer.status == 0 ? parse(answer.stdout) : nil

        var items: [FleetCheckItem] = []
        for row in rows { items.append(item(for: row, found: found)) }
        for entry in commands.sorted(by: { $0.command < $1.command }) {
            let present = inPath[entry.command] ?? found?.commands[entry.command]
            let name = (entry.command as NSString).lastPathComponent
            items.append(FleetCheckItem(
                id: "tool:\(name)", group: .tools, name: name,
                why: "\(entry.servers.sorted().joined(separator: ", ")) MCP server",
                state: present == nil ? .unknown : present == true ? .ok : .warn,
                value: present == nil ? "Couldn’t check" : present == true ? "Installed" : "Missing", kind: .command, tool: name,
                subjects: entry.servers.sorted()))
        }

        // Access: each origin, and each provider.
        items += await remotes
        items += await models

        // Shepherd and the Mac.
        if let build = facts.build, !build.isEmpty {
            items.append(FleetCheckItem(id: "build", group: .system, name: "Shepherd", why: "Same build on every Mac", state: .ok,
                                        value: "Build \(build)", kind: .build))
        }
        let volume = spaces.first?.path ?? NSHomeDirectory()
        items.append(diskItem(free: sources.freeBytes((volume as NSString).expandingTildeInPath)))
        if let found { items.append(sleepItem(minutes: found.sleepMinutes, onBattery: found.onBattery)) }
        return FleetCheckReport(items: items, packageManager: found?.packageManager ?? "")
    }

    // MARK: The shell's words

    /// How each program says its version, and what it is called on the PATH.
    static func versionCommand(_ tool: FleetRepoNeed.Tool) -> (program: String, command: String) {
        switch tool {
        case .node: ("node", "node --version")
        case .pnpm: ("pnpm", "pnpm --version")
        case .npm: ("npm", "npm --version")
        case .yarn: ("yarn", "yarn --version")
        case .xcode: ("xcodebuild", "xcodebuild -version")
        case .nix: ("nix", "nix --version")
        case .cargo: ("cargo", "cargo --version")
        case .go: ("go", "go version")
        case .python: ("python3", "python3 --version")
        }
    }

    /// The one script: a `@name` line, then `=text` (what it printed) or `#none` (it isn't there). Names come from a fixed list or pass
    /// `FleetReadiness.isSafeCommand`, so nothing is quoted or expanded.
    static func script(tools: [FleetRepoNeed.Tool], commands: [String]) -> String {
        var lines: [String] = []
        for tool in tools {
            let (program, command) = versionCommand(tool)
            lines.append("echo '@need:\(tool.rawValue)'; if command -v \(program) >/dev/null 2>&1; then o=$(\(command) 2>/dev/null) && printf '=%s\\n' \"$(printf '%s' \"$o\" | head -n 1)\" || echo '#none'; else echo '#none'; fi")
        }
        for command in commands {
            lines.append("echo '@tool:\(command)'; if command -v \(command) >/dev/null 2>&1; then echo '=yes'; else echo '#none'; fi")
        }
        lines.append("echo '@pm'; if command -v nix >/dev/null 2>&1; then echo '=nix'; elif command -v brew >/dev/null 2>&1; then echo '=brew'; else echo '#none'; fi")
        lines.append("echo '@sleep'; pmset -g 2>/dev/null | awk '/^ *sleep[ \\t]/ { print \"=\" $2; exit }'")
        lines.append("echo '@power'; pmset -g batt 2>/dev/null | head -n 1")
        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }

    struct Found: Equatable {
        /// A needed program's first line of output; nil is not there.
        var needs: [FleetRepoNeed.Tool: String?] = [:]
        var commands: [String: Bool] = [:]
        var packageManager = ""
        var sleepMinutes: Int?
        var onBattery = false
    }

    /// Reads what `script` printed.
    static func parse(_ output: String) -> Found {
        var found = Found()
        var section = ""
        var lines: [String] = []
        func close() {
            defer { lines = [] }
            let text = lines.first ?? ""
            if section.hasPrefix("need:"), let tool = FleetRepoNeed.Tool(rawValue: String(section.dropFirst(5))) {
                let printed: String? = text.hasPrefix("=") ? String(text.dropFirst()) : nil
                found.needs[tool] = .some(printed)
            } else if section.hasPrefix("tool:") {
                found.commands[String(section.dropFirst(5))] = text == "=yes"
            } else if section == "pm" {
                found.packageManager = text.hasPrefix("=") ? String(text.dropFirst()) : ""
            } else if section == "sleep" {
                found.sleepMinutes = text.hasPrefix("=") ? Int(text.dropFirst()) : nil
            } else if section == "power" {
                found.onBattery = text.contains("Battery Power")
            }
        }
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("@") {
                close()
                section = String(line.dropFirst())
            } else {
                lines.append(line)
            }
        }
        close()
        return found
    }

    // MARK: Items

    private static func item(for row: FleetRepoNeeds.Row, found: Found?) -> FleetCheckItem {
        let need = row.need
        let why = "\(row.sources.joined(separator: ", ")) in \(row.repos.joined(separator: ", "))"
        var item = FleetCheckItem(id: need.rowID, group: .needs, name: need.title, why: why, state: .unknown, value: "Couldn’t check",
                                  kind: .tool, tool: need.tool.rawValue, want: need.version, atLeast: need.match == .atLeast,
                                  subjects: row.repos, sources: row.sources)
        guard let found, let answer = found.needs[need.tool] else { return item }
        guard let output = answer else {
            item.state = .warn
            item.value = "Missing"
            return item
        }
        let have = FleetVersion.first(in: output).map { $0.prefix(2).map(String.init).joined(separator: ".") }
        if let want = need.version, let have {
            let fine = FleetVersion.satisfies(have: have, need: want, match: need.match)
            item.state = fine ? .ok : .warn
            item.value = fine ? have : "Has \(have)"
        } else {
            item.state = .ok
            item.value = have ?? "Installed"
        }
        return item
    }

    /// "312 GB", "1.2 TB": decimal, as the Finder says it.
    static func size(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 1000 { return String(format: "%.1f TB", gigabytes / 1000) }
        return gigabytes >= 10 ? "\(Int(gigabytes.rounded())) GB" : String(format: "%.1f GB", gigabytes)
    }

    static func diskItem(free: UInt64?) -> FleetCheckItem {
        var item = FleetCheckItem(id: "disk", group: .system, name: "Free disk", why: "Worktrees and clones need room", state: .unknown,
                                  value: "Couldn’t check", kind: .disk)
        guard let free else { return item }
        item.value = size(free)
        item.state = free < lowDisk ? .warn : .ok
        return item
    }

    static func sleepItem(minutes: Int?, onBattery: Bool) -> FleetCheckItem {
        var item = FleetCheckItem(id: "sleep", group: .system, name: "Stays awake", why: "Auto skips a Mac while it sleeps", state: .unknown,
                                  value: "Couldn’t check", kind: .sleep)
        // On battery sleeping is what a laptop should do: nothing to fix.
        if onBattery {
            item.state = .ok
            item.value = "On battery"
        } else if let minutes {
            item.state = minutes == 0 ? .ok : .warn
            item.value = minutes == 0 ? "Never sleeps" : "Sleeps after \(minutes) min"
        }
        return item
    }

    // MARK: Access

    /// One item per `host/owner` the spaces' origins are on: whether `git ls-remote` of the first of them answers.
    private static func remoteItems(spaces: [(name: String, path: String)], sources: Sources) async -> [FleetCheckItem] {
        let groups = await Task.detached { () -> [(label: String, folder: String, count: Int)] in
            var order: [String] = []
            var byLabel: [String: (folder: String, count: Int)] = [:]
            for space in spaces {
                let folder = (space.path as NSString).expandingTildeInPath
                guard let origin = FleetDispatchGit.origin(cwd: folder), let key = CanonicalRepoKey(remote: origin) else { continue }
                let label = key.value.split(separator: "/").prefix(2).joined(separator: "/")
                if byLabel[label] == nil { order.append(label) }
                byLabel[label] = (byLabel[label]?.folder ?? folder, (byLabel[label]?.count ?? 0) + 1)
            }
            return order.prefix(maxRemotes).compactMap { label in byLabel[label].map { (label, $0.folder, $0.count) } }
        }.value
        return await withTaskGroup(of: (Int, FleetCheckItem).self) { tasks in
            for (index, group) in groups.enumerated() {
                tasks.addTask {
                    let answered = await sources.remote(group.folder)
                    return (index, FleetCheckItem(
                        id: "git:\(group.label)", group: .access, name: "Reach \(group.label)",
                        why: "origin of \(group.count) \(group.count == 1 ? "space" : "spaces")",
                        state: answered == nil ? .unknown : answered == true ? .ok : .warn,
                        value: answered == nil ? "Couldn’t check" : answered == true ? "Works" : "Doesn’t answer", kind: .remote, tool: group.label))
                }
            }
            var items: [(Int, FleetCheckItem)] = []
            for await item in tasks { items.append(item) }
            return items.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// `git ls-remote origin HEAD` in the checkout: read only, no prompt (a password or a passphrase is never asked for), killed at its limit.
    static func remoteAnswers(_ folder: String) -> Bool? {
        let ssh = ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] ?? "ssh"
        guard let result = FleetDispatchGit.run(["ls-remote", "--exit-code", "origin", "HEAD"], in: folder, timeout: remoteTimeout,
                                                environment: ["GIT_SSH_COMMAND": ssh + " -o BatchMode=yes -o ConnectTimeout=10",
                                                              "GIT_ASKPASS": "/usr/bin/true", "GCM_INTERACTIVE": "never"]) else { return nil }
        return result.status == 0
    }

    /// One "Model sign-ins" item for every provider this Mac has: "All answer", or the first that doesn't and what is wrong with it.
    private static func modelsItem(sources: Sources) async -> [FleetCheckItem] {
        let answers = await sources.providers()
        guard !answers.isEmpty else { return [] }
        let names = answers.map(\.name).joined(separator: ", ")
        let broken = answers.filter { if case .refused = $0.outcome { true } else if case .cantStart = $0.outcome { true } else { false } }
        var item = FleetCheckItem(id: "models", group: .access, name: "Model sign-ins", why: names, state: .ok, value: "All answer", kind: .provider)
        if let first = broken.first {
            item.state = .warn
            item.tool = first.id
            item.subjects = broken.map(\.id)
            switch first.outcome {
            case .cantStart: item.value = "\(first.name) can’t start"
            default: item.value = "\(first.name) was refused"
            }
            if broken.count > 1 { item.value += " and \(broken.count - 1) more" }
        } else if answers.allSatisfy({ $0.outcome == .unknown }) {
            item.state = .unknown
            item.value = "Couldn’t check"
        }
        return [item]
    }

    // MARK: The system's facts

    static let systemFreeBytes: @Sendable (String) -> UInt64? = { path in
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    }
}
