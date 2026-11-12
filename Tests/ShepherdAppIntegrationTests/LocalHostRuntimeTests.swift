import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Projects run on the background host (`RuntimeHosting.headless`, as `ShepherdHost.main`
/// serves them), and the app, as its client over its local socket, draws them as This Mac's own.
/// The rules for features that act on their own hold there: every control is fenced by the revision
/// it was shown, a restart brings them back paused, Stop and Pause reach the host, and a second
/// client acts under the same fences.
@Suite("Projects on the background host", .mainActorExclusive)
@MainActor
struct LocalHostRuntimeTests {
    @MainActor
    final class Setup {
        var host: ScratchServer
        let vm: ShepherdViewModel
        let hosts: RemoteHostStore
        let space: Space
        let clientDir: URL
        let hostSettings: AppSettings
        var runtime: (coordinator: ProjectCoordinatorController, execution: ProjectExecutionController)
        let socket: String
        let tokenURL: URL

        init(host: ScratchServer, vm: ShepherdViewModel, hosts: RemoteHostStore, space: Space, clientDir: URL, hostSettings: AppSettings,
             runtime: (coordinator: ProjectCoordinatorController, execution: ProjectExecutionController),
             socket: String, tokenURL: URL) {
            self.host = host; self.vm = vm; self.hosts = hosts; self.space = space; self.clientDir = clientDir
            self.hostSettings = hostSettings; self.runtime = runtime; self.socket = socket; self.tokenURL = tokenURL
        }

        func stop() {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
            host.stop()
        }

        /// The host stops and a new one starts on the same workspace, as after a crash, a login or a drain.
        func restartHost() async throws {
            host.stop(keepFiles: true)
            host = try ScratchServer(dir: host.dir)
            runtime = LocalHostRuntimeTests.serve(host.server, settings: hostSettings)
            try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        }

        /// A paired device, over the host's TCP listener.
        func pairedClient() async throws -> RemoteHostClient {
            let tokenURL = host.dir.appendingPathComponent("paired-token")
            let port = try host.server.startRemoteListener(port: 0, tokenURL: tokenURL)
            let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let client = RemoteHostClient()
            _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "Paired iPad")
            return client
        }
    }

    /// What `ShepherdHost.main` serves: threads, worktrees and the runtime, with the host's own settings.
    static func serve(_ server: SessionServer, settings: AppSettings)
        -> (coordinator: ProjectCoordinatorController, execution: ProjectExecutionController) {
        server.serveThreads(ThreadHosting(defaults: {
            ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                   worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
        }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        let worktrees = server.serveAgentQueries(WorktreeHosting(defaults: { .init(generateDescription: false) },
                                                                 deleteAgent: { id, _ in try await server.deleteAgent(id) }))
        server.setProjectsEnabled(settings.projectsEnabled)
        return RuntimeHosting.headless(server: server, settings: settings, worktrees: worktrees, mcp: { _, _, _, _, _ in nil },
                                       notify: { _, _ in }).serve()
    }

    static func setUp() async throws -> Setup {
        try StubPi.installAsEngine()
        let host = try ScratchServer()
        let hostDefaults = ScratchDefaults()
        let hostSettings = AppSettings(store: hostDefaults)
        hostSettings.projectsEnabled = true
        let runtime = serve(host.server, settings: hostSettings)
        let repo = try makeScratchRepo(files: ["README.md": "# acme-web\n"])
        let space = Space(name: "acme-web", path: repo.path)
        try await host.server.addSpace(space)

        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let clientDir = try makeScratchDirectory("cli")
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        settings.projectsEnabled = true
        let hosts = RemoteHostStore(defaults: defaults, childRefreshInterval: .milliseconds(200))
        let vm = ShepherdViewModel(settings: settings,
            keybindings: KeybindingsStore(store: defaults),
            themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
            remoteHosts: hosts, sidebarDefaults: defaults, themeInstaller: { _ in },
            hooks: HooksModel(home: clientDir.appendingPathComponent("hooks-home").path, support: clientDir.appendingPathComponent("hooks-support")),
            apps: AppsModel(home: clientDir.appendingPathComponent("apps-home").path))
        vm.connectLocalHost(socket: socket, token: token)
        try await eventuallyOnMain("the host's workspace as the app's", timeout: .seconds(30)) {
            vm.state.spaces == host.server.state.spaces && hosts.localHost?.phase == .connected
        }
        return Setup(host: host, vm: vm, hosts: hosts, space: space, clientDir: clientDir, hostSettings: hostSettings,
                     runtime: runtime, socket: socket, tokenURL: tokenURL)
    }

    @Test func aProjectRunsOnTheHostAndIsThisMacs() async throws {
        let s = try await Self.setUp()
        defer { s.stop() }
        let model = s.vm.logicalProjects
        let id = ProjectID()
        let made = try #require(await model.create(home: .local, id: id, name: "Checkout revamp", goal: "Ship the new checkout", spaces: [s.space.id]))
        #expect(s.host.server.state.projects.map(\.id) == [id], "the host owns it")
        let ref = LogicalProjectRef(home: .local, id: id)
        try await eventuallyOnMain("the Project as This Mac's") { s.vm.state.projects.map(\.id) == [id] }
        #expect(s.vm.sidebarLogicalProjects.map(\.ref) == [ref] && s.vm.sidebarLogicalProjects.first?.hostName == nil,
                "This Mac's, with no host section of its own")

        // The first message starts its coordinator on the host; its thread is the app's own.
        #expect(await model.sendMessage(ref, text: "Plan the checkout work"))
        let coordinator = try #require(s.host.server.state.projects.first?.coordinatorAgentID)
        try await eventuallyOnMain("the coordinator starts on the host", timeout: .seconds(30)) {
            StubPi.launches().contains { $0.argv.contains(coordinator.rawValue) }
        }
        try await eventuallyOnMain("the coordinator is the app's own thread") { s.vm.state.agents.contains { $0.id == coordinator } }
        #expect(s.vm.state.agents.first { $0.id == coordinator }?.coordinatorFor == id)
        try await eventuallyAsync("the host's coordinator conversation, read through the app") {
            guard case .snapshot(let snapshot) = try? await s.vm.nativeThread(coordinator, request: .snapshot()) else { return false }
            return !snapshot.messages.isEmpty
        }

        // Fence: an edit at the revision shown before the message is refused on the host and changes nothing.
        let shown = made.revision
        await #expect(throws: (any Error).self) {
            _ = try await s.hosts.logicalProjects(hostID: try #require(s.hosts.localHost).id,
                                                  request: .edit(projectID: id, expectedRevision: shown, name: "Stale", goal: "Stale"))
        }
        #expect(s.host.server.state.projects.first?.name == "Checkout revamp")

        // Pause from the app reaches the host.
        try await eventuallyOnMain("the app's copy is current") { s.vm.state.projects.first == s.host.server.state.projects.first }
        #expect(await model.setPaused(ref, true))
        #expect(s.host.server.state.projects.first?.pausedByPerson == true)

        // A second client sees the same Project, and its stale revision is refused too.
        let paired = try await s.pairedClient()
        defer { paired.disconnect() }
        guard case .project(let seen) = try await paired.logicalProjects(.get(projectID: id)) else { Issue.record("no Project for the paired client"); return }
        #expect(seen.paused)
        await #expect(throws: (any Error).self) {
            _ = try await paired.logicalProjects(.setPaused(projectID: id, expectedRevision: shown, paused: false))
        }
        #expect(s.host.server.state.projects.first?.paused == true)
    }

    /// A restart resumes nothing of a Project: its coordinator stays down until the person's next
    /// message, and a message being delivered is no longer in flight.
    @Test func aRestartResumesNoProjectWork() async throws {
        let s = try await Self.setUp()
        defer { s.stop() }
        let id = ProjectID()
        let ref = LogicalProjectRef(home: .local, id: id)
        _ = try #require(await s.vm.logicalProjects.create(home: .local, id: id, name: "Checkout revamp", goal: "Ship it", spaces: [s.space.id]))
        try await eventuallyOnMain("the Project as This Mac's") { s.vm.logicalProjects.project(ref) != nil }
        #expect(await s.vm.logicalProjects.sendMessage(ref, text: "Plan the checkout work"))
        let coordinator = try #require(s.host.server.state.projects.first?.coordinatorAgentID)
        try await eventuallyOnMain("the coordinator starts on the host", timeout: .seconds(30)) {
            StubPi.launches().contains { $0.argv.contains(coordinator.rawValue) }
        }
        try await eventuallyOnMain("the message reaches the coordinator", timeout: .seconds(30)) {
            s.host.server.state.projects.first?.messages.first?.phase == .delivered
        }

        try await s.restartHost()
        // As `SessionHost.run` does once it serves.
        await s.host.server.respawnAgentsNeedingRecovery { AgentSpawn(agent: $0, cwd: "", settings: AgentLaunchSettings()) }
        #expect(await s.host.server.listSessions().isEmpty, "no coordinator or worker came back on its own")
        #expect(s.host.server.state.projects.first?.coordinatorAgentID == coordinator, "its conversation stays, idle")
        try await eventuallyOnMain("the app reconnects to the restarted host", timeout: .seconds(30)) {
            s.vm.state.projects.first?.revision == s.host.server.state.projects.first?.revision
        }
    }
}
