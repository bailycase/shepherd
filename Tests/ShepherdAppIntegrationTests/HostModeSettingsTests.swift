import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Settings as the background host's client: what the app's Settings pages change reaches the
/// host's own `AppSettings` and server (they share one preferences domain; each follows the
/// other's writes), and Instructions, Suggested instructions, Skills, Hooks and Slash commands
/// read and change the host's stores, following each change made there.
@Suite("Settings as the background host's client", .mainActorExclusive)
@MainActor
struct HostModeSettingsTests {
    /// A Darwin notification of this test's own, so no other test's settings follow it.
    private static func notice() -> String { "com.acme.shepherd-tests.settings.\(UUID().uuidString)" }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(tool) \(arguments)")
    }

    /// The host's local listener, its token, and a second client of it (an iPhone's stand-in).
    private static func listen(_ host: ScratchServer) async throws -> (socket: String, token: String, phone: RemoteHostClient) {
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = RemoteHostClient(localSocket: socket)
        _ = try await phone.connect(host: "", port: 0, token: token, clientName: "iPhone")
        return (socket, token, phone)
    }

    /// Another process (`defaults`, `notifyutil`) writes the shared preferences: the host takes them.
    @Test func anotherProcessesWriteReachesTheHostsSettings() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        let notice = Self.notice()
        settings.followOtherProcesses(notice: notice)
        ShepherdHost.serveSettings(settings, on: host.server)
        var goals: [Bool] = []
        settings.onGoalsChange = { goals.append($0) }

        try Self.run("/usr/bin/defaults", ["write", defaults.name, AppSettings.Key.goalsEnabled, "-bool", "true"])
        try Self.run("/usr/bin/defaults", ["write", defaults.name, AppSettings.Key.defaultModel, "-string", "acme/model-b"])
        try Self.run("/usr/bin/notifyutil", ["-p", notice])
        try await eventuallyOnMain("the host to take the other process's settings") {
            settings.goalsEnabled && settings.defaultModel == "acme/model-b" && goals == [true]
        }
    }

    /// The app's Settings change the host's settings, each `on…Change` firing on the host, and a
    /// paired device's change on the host reaches the app's Settings.
    @Test func theAppsSettingsReachTheHostAndTheHostsReachTheApp() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let defaults = ScratchDefaults()
        let notice = Self.notice()
        let hostSettings = AppSettings(store: defaults)
        hostSettings.followOtherProcesses(notice: notice)
        HostSettingsMapping.serve(on: host.server, settings: hostSettings)
        ShepherdHost.serveSettings(hostSettings, on: host.server)
        var fired: Set<String> = []
        func record<T>(_ name: String, _ callback: ((T) -> Void)?) -> (T) -> Void { { fired.insert(name); callback?($0) } }
        hostSettings.onGoalsChange = record("goals", hostSettings.onGoalsChange)
        hostSettings.onProjectsChange = record("projects", hostSettings.onProjectsChange)
        hostSettings.onQueueDeliveryChange = record("queue", hostSettings.onQueueDeliveryChange)
        hostSettings.onHiddenSlashCommandsChange = record("slash", hostSettings.onHiddenSlashCommandsChange)
        hostSettings.onDesignToolChange = record("designs", hostSettings.onDesignToolChange)
        hostSettings.onCompactAtChange = record("compact", hostSettings.onCompactAtChange)

        let (socket, token, phone) = try await Self.listen(host)
        defer { phone.disconnect() }
        // The app's own settings object on the same domain, as the app process has.
        let appSettings = AppSettings(store: try #require(UserDefaults(suiteName: defaults.name)))
        appSettings.followOtherProcesses(notice: notice)
        let (vm, hosts, _, _, clientDir, _) = try await LocalClientTests.app(socket: socket, token: token, host: host, settings: appSettings)
        defer {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
        }

        vm.settings.goalsEnabled = true
        vm.settings.projectsEnabled = true
        vm.settings.queueDelivery = .oneAtATime
        vm.settings.setSlashCommand("acme-deploy", on: false)
        vm.settings.designToolEnabled = true
        vm.settings.compactAtPercent = 70
        vm.settings.defaultModel = "acme/model-b"
        vm.settings.notifyOnTurnFinished = false
        vm.settings.piPanesExtension = false
        vm.settings.worktreeCloseOnMerge = true
        try await eventuallyOnMain("every on…Change to fire on the host") {
            fired == ["goals", "projects", "queue", "slash", "designs", "compact"]
        }
        #expect(hostSettings.goalsEnabled && hostSettings.projectsEnabled && hostSettings.queueDelivery == .oneAtATime)
        #expect(hostSettings.hiddenSlashCommands == ["acme-deploy"] && hostSettings.compactAtPercent == 70)
        #expect(hostSettings.defaultModel == "acme/model-b" && !hostSettings.notifyOnTurnFinished)
        #expect(!hostSettings.agentLaunch.panes && hostSettings.worktreeCloseOnMerge)
        try await eventuallyOnMain("the host's server to serve designs") { phone.capabilities.contains(RemoteProtocol.designsCapability) }

        // A paired device changes the host's settings: the app's Settings show it.
        _ = try await phone.hostSettings(.change(.goalsEnabled(false)))
        try await eventuallyOnMain("the app to follow the host") { !vm.settings.goalsEnabled }
    }

    /// Instructions and Suggested instructions are the host's: the app's saves land there, and a
    /// paired device's save or an agent's suggestion on the host reaches the app's pages.
    @Test func instructionsAndSuggestionsAreTheHosts() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let space = Fixture.space(path: host.dir.path)
        let thread = Fixture.agent("acme-web", in: space)
        try await host.server.putState(Fixture.state(spaces: [space], agents: [thread]))
        let (socket, token, phone) = try await Self.listen(host)
        defer { phone.disconnect() }
        let (vm, hosts, idle, _, clientDir, _) = try await LocalClientTests.app(socket: socket, token: token, host: host)
        defer {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
        }

        // Settings ▸ Instructions saves the host's file, as This Mac's own.
        await vm.instructions.refresh()
        vm.instructions.setText("- Run acme-web's tests first.\n", file: .agents, on: .local)
        await vm.instructions.save()
        #expect(host.server.instructions.snapshot().agents == "- Run acme-web's tests first.\n")
        #expect(host.server.instructions.snapshot().history.first?.origin == nil, "This Mac's own save")
        #expect(idle.instructions.snapshot().agents.isEmpty)
        // A paired device's save on the host: the page follows.
        _ = try await phone.instructions(.save(file: .agents, content: "- Ask first.\n", origin: "iPhone", sync: false))
        try await eventuallyOnMain("the page to follow the host") { vm.instructions.saved(.agents, on: .local) == "- Ask first.\n" }

        // Suggested instructions: the switch is the host's.
        await vm.suggestions.setEnabled(true)
        #expect(host.server.suggestions.snapshot().settings.enabled)
        #expect(!idle.suggestions.snapshot().settings.enabled)
        // The host's agent suggests a line: the page shows it without reopening.
        let agent = try ExtensionClient(path: host.socketPath)
        try agent.send(.suggestInstruction(id: 1, agentID: thread.agent.id, line: "Use the staging database.", reason: "It failed twice.", file: nil))
        let reply = try await Task.detached { try agent.readReply(timeout: .seconds(10)) }.value
        #expect(reply == .suggestion(id: 1, outcome: .waiting))
        try await eventuallyOnMain("the suggestion on the page") { vm.suggestions.snapshot.waiting.count == 1 }
        // Adding it writes the host's file, and the Instructions page follows.
        await vm.suggestions.add(try #require(vm.suggestions.snapshot.waiting.first))
        #expect(vm.suggestions.problem == nil)
        #expect(host.server.instructions.snapshot().agents.contains("Use the staging database."))
        try await eventuallyOnMain("the Instructions page to follow") {
            vm.instructions.saved(.agents, on: .local)?.contains("Use the staging database.") == true
        }
    }

    /// Skills on/off, Hooks and Slash commands are the host's, and follow its changes.
    @Test func skillsHooksAndSlashCommandsAreTheHosts() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let skill = host.dir.appendingPathComponent("agent-skills/acme-lint/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: acme-lint\ndescription: Lints acme-web.\n---\n# Lint\n".write(to: skill, atomically: true, encoding: .utf8)
        let home = host.dir.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        host.server.hooks = HookCatalog(home: home, support: host.dir.appendingPathComponent("hooks-support"))
        HostSettingsMapping.serve(on: host.server, settings: AppSettings(store: ScratchDefaults()))
        host.server.queue.async { host.server.mergeSlashCommands([NativeCommand(name: "acme-deploy", source: "prompt")]) }
        let (socket, token, phone) = try await Self.listen(host)
        defer { phone.disconnect() }
        let (vm, hosts, idle, _, clientDir, _) = try await LocalClientTests.app(
            socket: socket, token: token, host: host, hooks: HooksModel(catalog: host.server.hooks))
        defer {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
        }

        // Slash commands: the host's catalog, and each command it lists after.
        try await eventuallyOnMain("the host's slash commands") { vm.slashCommands.catalog.map(\.name) == ["acme-deploy"] }
        host.server.queue.async { host.server.mergeSlashCommands([NativeCommand(name: "acme-release", source: "prompt")]) }
        try await eventuallyOnMain("a command the host listed after") { vm.slashCommands.catalog.map(\.name) == ["acme-deploy", "acme-release"] }

        // Skills: This Mac is the host; turning one off is the host's.
        let thisMac = try #require(vm.skillsHosts.first)
        await vm.skills.refresh([thisMac])
        #expect(vm.skills.state(of: thisMac).snapshot?.skills.map(\.name).contains("acme-lint") == true)
        await vm.skills.setOn("acme-lint", false, in: vm.skillsHosts).value
        guard case .skills(let onHost) = try host.server.skills.perform(.fetch) else { Issue.record("no skills"); return }
        #expect(onHost.skills.first { $0.name == "acme-lint" }?.isOn == false)
        #expect(idle.skills.stateDirectory.path != host.server.skills.stateDirectory.path)
        // A paired device turns it back on: the page follows.
        _ = try await phone.skills(.setOn(name: "acme-lint", on: true))
        try await eventuallyOnMain("the Skills page to follow the host") {
            vm.skills.state(of: thisMac).snapshot?.skills.first { $0.name == "acme-lint" }?.isOn == true
        }

        // Hooks: a paired device's change on the host reaches the page.
        try await eventuallyOnMain("the Hooks page loaded") { vm.hooks.snapshot != nil }
        #expect(vm.hooks.snapshot?.settings.readers.codex == true)
        _ = try await phone.hooks(.setReader(format: .codex, on: false))
        try await eventuallyOnMain("the Hooks page to follow the host") { vm.hooks.snapshot?.settings.readers.codex == false }
    }
}
