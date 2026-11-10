import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Anthropic's usage limit mid-turn on the background host, with the app as its client over
/// `host.sock`: the host's turn errors and banners are wired as `Shepherd --host` wires them
/// (`HostStores.serveTurnErrors`, `ThreadBanners.observeServer`). The stub pi's "limit" turn fails
/// with the 429 and, continued from its checkpoint, answers "Recovered: …".
@Suite("A usage limit on the background host", .mainActorExclusive)
@MainActor
struct UsageLimitHostTests {
    @MainActor struct Setup {
        let host: ScratchServer
        let vm: ShepherdViewModel
        let hosts: RemoteHostStore
        let connection: RemoteHostStore.Connection
        let ref: RemoteAgentRef
        let banners: Locked<[AgentBanner]>
        let observer: ThreadBanners
        let clientDir: URL

        func stop() {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
            host.stop()
        }

        func snapshot() async throws -> NativeThreadSnapshot? {
            if case .snapshot(let value)? = try? await hosts.nativeThread(ref, request: .snapshot()) { return value }
            return nil
        }
    }

    /// `accounts`: two saved Anthropic accounts with rotation on (the second one active), else none.
    func start(accounts: Bool) async throws -> Setup {
        try StubPi.installAsEngine()
        _ = NSApplication.shared
        let host = try ScratchServer()
        host.server.serveThreads(ThreadHosting(defaults: {
            ThreadHosting.Defaults(model: "anthropic/claude-fixture-4", thinking: .medium, serviceTier: .standard,
                                   worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
        }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        let pi = host.server.pi
        if accounts {
            try FileManager.default.createDirectory(at: pi.files.directory, withIntermediateDirectories: true)
            let auth = PiSettingsFile(url: pi.files.directory.appendingPathComponent("auth.json"))
            let saved = PiAccounts(home: pi.files)
            _ = try auth.update { $0["anthropic"] = ["type": "oauth", "refresh": "A1"]; return [] }
            try saved.beginAdding("anthropic")
            _ = try auth.update { $0["anthropic"] = ["type": "oauth", "refresh": "B1"]; return [] }
            _ = try saved.landed("anthropic", adding: true)
            try saved.setRotate("anthropic", true)
        }
        // As `Shepherd --host` does: its turn errors, then its banners.
        HostStores(mcp: MCPStore(dependencies: .app(pi: pi, openURL: { _ in }, copy: { _ in })),
                   subagents: { SubagentDefinitionsModel(pi: pi) }, piAuth: PiAuthStore(pi: pi),
                   yourPi: YourPiModel(pi: pi), remoteSignIns: RemoteSignIns()).serveTurnErrors(on: host.server)
        let banners = Locked<[AgentBanner]>([])
        let observer = ThreadBanners(server: host.server, state: { host.server.state }, sink: .init(
            post: { banner in banners.withValue { $0.append(banner) } }, remove: { _ in },
            isWatching: { _ in false }, notifyOnTurnFinished: { true }))
        observer.observeServer()

        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let space = Space(name: "acme-web", path: host.dir.path)
        try await host.server.addSpace(space)
        let (vm, hosts, _, connection, clientDir, _) = try await LocalClientTests.app(socket: socket, token: token, host: host)

        vm.openNewThread(in: space.id)
        vm.newThread.prompt = "limit now"
        try await eventuallyOnMain("the host's defaults") { vm.newThread.blocker(vm) == nil }
        vm.newThread.send(vm)
        try await eventuallyOnMain("the host's new thread", timeout: .seconds(20)) {
            vm.selectedAgentID.map { id in host.server.state.agents.contains { $0.id == id } } == true
        }
        let ref = RemoteAgentRef(hostID: connection.id, agentID: try #require(vm.selectedAgentID))
        return Setup(host: host, vm: vm, hosts: hosts, connection: connection, ref: ref, banners: banners, observer: observer,
                     clientDir: clientDir)
    }

    /// The status extension's reports, which the stub pi doesn't send itself.
    func report(_ status: AgentStatus, for s: Setup) throws {
        s.host.server.extensionPeerCheck = { _, _ in true }
        try ExtensionClient(path: s.host.socketPath).send(.setAgentStatus(agentID: s.ref.agentID, status: status))
    }

    @Test func withNoOtherAccountTheTurnFailsVisiblyWithRetry() async throws {
        let s = try await start(accounts: false)
        defer { s.stop() }
        try report(.working, for: s)
        try await eventuallyAsync("the failed turn in the app's thread", timeout: .seconds(10)) {
            guard let thread = try await s.snapshot() else { return false }
            return !thread.running && thread.messages.last?.status == "error"
                && thread.messages.last?.blocks.contains { $0.text.contains("rate_limit_error") } == true
        }
        try report(.done, for: s)
        try await eventuallyOnMain("the app's row to read failed") {
            s.connection.state.agents.first { $0.id == s.ref.agentID }?.lastFailure?.contains("rate_limit_error") == true
        }
        try await eventuallyOnMain("the host's Turn failed banner") {
            s.banners.current.contains { $0.subtitle == "Turn failed" && $0.actions.contains(.retry) && $0.recovery != nil }
        }
        #expect(s.vm.threadStores.existing(for: s.ref.agentID)?.notice == nil, "no account switched")
    }

    @Test func withAnotherAccountItSwitchesAndTheTurnGoesOn() async throws {
        let s = try await start(accounts: true)
        defer { s.stop() }
        let line = PiAuthText.switched("anthropic", (from: "Account 2", to: "Account 1"))
        try await eventuallyOnMain("the thread to say it switched", timeout: .seconds(10)) {
            s.vm.threadStores.existing(for: s.ref.agentID)?.notice == line
        }
        try await eventuallyAsync("the turn to go on and finish on the new account", timeout: .seconds(10)) {
            guard let thread = try await s.snapshot() else { return false }
            return !thread.running && thread.messages.last?.blocks.first?.text == "Recovered: limit now"
        }
        let auth = try Data(contentsOf: s.host.server.pi.files.directory.appendingPathComponent("auth.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: auth) as? [String: Any])
        #expect((json["anthropic"] as? [String: Any])?["refresh"] as? String == "A1")
    }
}
