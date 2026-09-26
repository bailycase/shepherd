import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A real server on scratch paths plus a view model wired exactly like the app's, but with
/// isolated settings, keybindings, theme, remote hosts, and sidebar defaults so no test reads
/// or writes the user's preferences. Call `stop()` when done.
@MainActor
final class AppHarness {
    let scratch: ScratchServer
    let defaults = ScratchDefaults()
    let settings: AppSettings
    let keybindings: KeybindingsStore
    let themeManager: ThemeManager
    let remoteHosts: RemoteHostStore
    private(set) var vm: ShepherdViewModel!

    var server: SessionServer { scratch.server }
    var dir: URL { scratch.dir }

    init() throws {
        scratch = try ScratchServer()
        settings = AppSettings(store: defaults)
        keybindings = KeybindingsStore(store: defaults)
        themeManager = ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark)
        // A client polls its hosts' subagents every 3 s; tests that wait on a change would sit
        // through two polls each.
        remoteHosts = RemoteHostStore(defaults: defaults, childRefreshInterval: .milliseconds(200))
    }

    /// Seeds `state` (if any), then builds the view model and waits until it has adopted the
    /// server's snapshot. `restoringAgents` starts every seeded agent's pi at once, as a launch
    /// does; otherwise an agent's pi starts when a test asks for its pane's session (most tests
    /// seed agents only to look at them, with no pi on PATH). `readingCheckouts` turns on the
    /// header's checkout reads, which would otherwise change the workspace under a test that
    /// seeded a repository.
    @discardableResult
    func start(with state: ShepherdState? = nil, restoringAgents: Bool = false,
               readingCheckouts: Bool = false) async throws -> ShepherdViewModel {
        if let state { try await server.putState(state) }
        let vm = ShepherdViewModel(
            server: server, settings: settings, keybindings: keybindings, themeManager: themeManager,
            remoteHosts: remoteHosts, sidebarDefaults: defaults, themeInstaller: { _ in },
            restoresAgentsAtLaunch: restoringAgents,
            checkoutReader: readingCheckouts ? CheckoutMonitor.git : nil
        )
        self.vm = vm
        let server = server
        try await eventuallyOnMain("the view model to adopt the server's workspace") { vm.state == server.state }
        return vm
    }

    /// Waits for every queued optimistic write to reach the server.
    func settle() async {
        await vm?.persistenceTail?.value
    }

    func stop() {
        for connection in remoteHosts.connections { remoteHosts.removeHost(id: connection.id) }
        vm = nil
        scratch.stop()
    }
}

// MARK: Fixtures

/// One agent's workspace: its space, its layout container, and its primary (pi) pane.
struct AgentFixture {
    var space: Space
    var tab: Tab
    var agent: Agent
    var piPane: LeafPane
    /// Extra shell panes split beside the pi pane, in layout order.
    var auxiliary: [LeafPane] = []
}

enum Fixture {
    static func space(_ name: String = "workspace", path: String) -> Space {
        Space(name: name, path: path)
    }

    /// An agent whose layout is its pi pane, optionally split with `auxiliary` shell panes.
    static func agent(
        _ name: String = "worker",
        in space: Space,
        order: Int = 0,
        cwd: String? = nil,
        auxiliary: Int = 0,
        piSession: SessionID? = nil,
        status: AgentStatus = .idle
    ) -> AgentFixture {
        let cwd = cwd ?? space.path
        let id = AgentID()
        let pi = LeafPane(sessionID: piSession, cwd: cwd, agentID: id)
        let extra = (0..<auxiliary).map { _ in LeafPane(cwd: cwd) }
        var layout = PaneNode.leaf(pi)
        for pane in extra {
            layout = .split(axis: .vertical, ratio: 0.5, first: layout, second: .leaf(pane))
        }
        let tab = Tab(spaceID: space.id, order: order, layout: layout)
        let agent = Agent(id: id, name: name, spaceID: space.id, tabID: tab.id, paneID: pi.id, status: status)
        return AgentFixture(space: space, tab: tab, agent: agent, piPane: pi, auxiliary: extra)
    }

    /// A state with `spaces` and the given agents' tabs and records.
    static func state(spaces: [Space], agents: [AgentFixture]) -> ShepherdState {
        ShepherdState(spaces: spaces, tabs: agents.map(\.tab), agents: agents.map(\.agent))
    }
}

// MARK: Stub pi

extension AppHarness {
    /// Spawns the scripted stub pi as an RPC session, the process an agent's thread talks to.
    /// `log` records every command the app writes to it.
    func spawnStubPi(cwd: String? = nil, log: URL? = nil) async throws -> SessionID {
        var env: [String: String] = [:]
        if let log { env["STUB_PI_LOG"] = log.path }
        let info = try await server.createSession(params: CreateSessionParams(
            cwd: cwd ?? dir.path, command: StubPi.command, env: env.isEmpty ? nil : env, runtime: .rpc
        ))
        return info.id
    }

    /// An agent whose pi pane is already bound to a running stub pi when the workspace loads.
    func liveAgent(_ name: String = "worker", in space: Space, order: Int = 0, auxiliary: Int = 0, log: URL? = nil) async throws -> AgentFixture {
        let session = try await spawnStubPi(cwd: space.path, log: log)
        return Fixture.agent(name, in: space, order: order, auxiliary: auxiliary, piSession: session)
    }

    /// Waits until the agent's pi answers a native snapshot with a session id.
    func readyThread(_ agentID: AgentID) async throws -> NativeThreadSnapshot {
        var ready: NativeThreadSnapshot?
        let server = server
        try await eventuallyAsync("the agent's pi to answer a snapshot", timeout: .seconds(20)) {
            if case .snapshot(let value)? = try? await server.nativeThread(agentID: agentID, request: .snapshot()),
               !value.piSessionID.isEmpty {
                ready = value
                return true
            }
            return false
        }
        return try #require(ready)
    }

    /// The prompts the stub pi received, in order, read from its log.
    static func prompts(in log: URL) -> [String] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "prompt" else { return nil }
            return object["message"] as? String
        }
    }
}

// MARK: Remote

extension RemoteHostClientError {
    /// The code the host rejected a request with; nil for any other failure (a dropped
    /// connection, a timeout), so a refusal test cannot pass on the wrong failure.
    var rejectionCode: String? {
        if case .rejected(let code, _) = self { return code }
        return nil
    }
}

/// A second, in-process Shepherd acting as a remote host: its own server (and optionally its
/// own view model, which answers host-side requests), serving over TCP on an ephemeral port.
@MainActor
final class RemoteHostHarness {
    let host: AppHarness
    let port: UInt16
    let token: String

    init() throws {
        host = try AppHarness()
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        port = try host.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds this host to `store` and waits for the connection to come up with `state`.
    func connect(_ store: RemoteHostStore, name: String = "host") async throws -> RemoteHostStore.Connection {
        store.addHost(name: name, host: "127.0.0.1", port: port, token: token)
        let connection = try #require(store.connections.last)
        let server = host.server
        // Generous: a busy main thread delays the handshake, and a failed attempt backs off.
        try await eventuallyOnMain("the remote host to connect and publish its workspace", timeout: .seconds(30)) {
            connection.phase == .connected && connection.state == server.state
        }
        return connection
    }

    func stop() { host.stop() }
}

// MARK: Waiting

/// `eventually` for main-actor tests whose condition awaits (server queries): polls every
/// 10ms on the main actor and throws `WaitTimeout` naming `what`.
@MainActor
func eventuallyAsync(
    _ what: String,
    timeout: Duration = defaultWaitTimeout,
    _ condition: @MainActor () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    if try await condition() { return }
    throw TimedOut(what: what)
}

struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

// MARK: Shell

struct ShellFailure: Error, CustomStringConvertible {
    let script: String
    let status: Int32
    let stderr: String
    var description: String { "`\(script)` exited \(status): \(stderr)" }
}

/// Runs `script` with `/bin/sh` (no user dotfiles), for git setup a test drives directly.
@discardableResult
func sh(_ script: String, in dir: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.currentDirectoryURL = dir
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ShellFailure(script: script, status: process.terminationStatus, stderr: String(decoding: errData, as: UTF8.self))
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The canonical form git and the app report for a scratch path (/tmp → /private/tmp).
func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

// MARK: Extension socket

private final class SendableClient: @unchecked Sendable {
    let client: ExtensionClient
    init(_ client: ExtensionClient) { self.client = client }
}

extension AppHarness {
    /// Sends one request over the real extension socket, as an agent's pi extension does, and
    /// waits for the reply off the main actor (the main actor is what answers it).
    func extensionRequest(_ message: ExtensionMessage) async throws -> ExtensionReply {
        let box = SendableClient(try ExtensionClient(path: scratch.socketPath))
        try box.client.send(message)
        return try await Task.detached { try box.client.readReply(timeout: .seconds(20)) }.value
    }
}
