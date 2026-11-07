import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The app as the background host's client (`SHEPHERD_BACKGROUND_HOST=1`): a headless host serves
/// threads and terminals on its local socket, and the app's view model, on an idle server that
/// owns nothing, shows and drives them through the remote-host paths.
@Suite("The app as the background host's client", .mainActorExclusive)
@MainActor
struct LocalClientTests {
    @Test func theAppShowsCreatesSendsToAndOpensATerminalOfTheHostsThreads() async throws {
        try StubPi.installAsEngine()
        _ = NSApplication.shared
        let host = try ScratchServer()
        defer { host.stop() }
        host.server.serveThreads(ThreadHosting(defaults: {
            ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                   worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
        }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let space = Space(name: "acme-web", path: host.dir.path)
        try await host.server.addSpace(space)
        #expect(RemoteHostClient.localSocketAnswers(socket))

        // The app, as `ShepherdApp` makes it when the host answers.
        let clientDir = try makeScratchDirectory("cli")
        defer { try? FileManager.default.removeItem(at: clientDir) }
        let defaults = ScratchDefaults()
        let idle = BackgroundHostClient.idleServer(directory: clientDir)
        let hosts = RemoteHostStore(defaults: defaults, childRefreshInterval: .milliseconds(200))
        let vm = ShepherdViewModel(
            server: idle, ownsWorkspace: false, settings: AppSettings(store: defaults), keybindings: KeybindingsStore(store: defaults),
            themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
            remoteHosts: hosts, sidebarDefaults: defaults, themeInstaller: { _ in }, restoresAgentsAtLaunch: false, checkoutReader: nil,
            hooks: HooksModel(home: clientDir.appendingPathComponent("hooks-home").path, support: clientDir.appendingPathComponent("hooks-support")),
            apps: AppsModel(home: clientDir.appendingPathComponent("apps-home").path))
        defer { for connection in hosts.connections { hosts.removeHost(id: connection.id) } }
        let connection = hosts.addLocalHost(name: "This Mac", socket: socket, token: token)
        try await eventuallyOnMain("the host's workspace", timeout: .seconds(30)) {
            connection.phase == RemoteHostStore.Phase.connected && connection.state == host.server.state
        }
        #expect(connection.capabilities.contains(RemoteProtocol.localCapability))
        #expect(defaults.data(forKey: RemoteHostStore.defaultsKey).map { String(decoding: $0, as: UTF8.self) } ?? "[]" == "[]",
                "the host on this Mac is found again each launch, never saved")

        // New thread, through the remote path.
        vm.openNewThread(in: space.id, hostID: connection.id)
        #expect(vm.newThread.place == NewThreadPlace(host: connection.id, space: space.id))
        vm.newThread.prompt = "Check the build"
        try await eventuallyOnMain("the host's defaults") { vm.newThread.blocker(vm) == nil }
        vm.newThread.send(vm)
        try await eventuallyOnMain("the host's new thread to be selected", timeout: .seconds(20)) {
            vm.selectedRemoteAgent.map { ref in host.server.state.agents.contains { $0.id == ref.agentID } } == true
        }
        let ref = try #require(vm.selectedRemoteAgent)
        let row = try #require((vm.sidebarLists.needsYou + vm.sidebarLists.working + vm.sidebarLists.done + vm.sidebarLists.recents)
            .first { $0.id == .remote(ref) })
        // The host on this Mac reads as This Mac: no host tag, one This Mac to start threads on,
        // the Hosts page's This Mac card counts its threads, and it isn't a host to remove.
        if case .tag = row.accessory { Issue.record("a thread of this Mac's host wears a host tag") }
        #expect(NewThreadState.hosts(vm).map(\.name) == ["This Mac"])
        #expect(vm.hostsPageModel(agentVersion: nil).cards.count == 1)
        #expect(hosts.pairedConnections.isEmpty)

        // A send, as the composer sends it.
        try await eventuallyAsync("its pi to serve", timeout: .seconds(20)) {
            if case .snapshot(let snapshot)? = try? await hosts.nativeThread(ref, request: .snapshot()) { return !snapshot.piSessionID.isEmpty }
            return false
        }
        try await hosts.sendUserMessage(ref, text: "hello from the app")
        try await eventuallyAsync("the turn on the host", timeout: .seconds(20)) {
            guard case .snapshot(let snapshot)? = try? await host.server.nativeThread(agentID: ref.agentID, request: .snapshot()) else { return false }
            return snapshot.messages.contains { $0.role == "user" && $0.blocks.contains { $0.text == "hello from the app" } }
        }

        // A terminal: opened on the host, its shell started there, attached here.
        let agent = try #require(host.server.state.agents.first { $0.id == ref.agentID })
        let pane = try await hosts.openPane(hostID: connection.id, agentID: ref.agentID, relativeTo: agent.paneID!, axis: .vertical)
        try await eventuallyOnMain("the terminal in the app's copy of the workspace") {
            connection.state.tabs.first { $0.id == agent.tabID }?.layout.leaf(withID: pane)?.sessionID != nil
        }
        let session = try #require(connection.state.tabs.first { $0.id == agent.tabID }?.layout.leaf(withID: pane)?.sessionID)
        let remotePane = try #require(hosts.paneSession(connection: connection, sessionID: session))
        remotePane.noteGrid(cols: 100, rows: 30)
        try await eventuallyOnMain("the terminal to attach") { remotePane.phase == RemotePaneSession.Phase.live }

        // The host serves this Mac, not the app; nothing lands in the app's own workspace.
        vm.setRemoteListenerEnabled(true, persist: false)
        #expect(vm.remoteListenerBoundPort == nil && vm.remoteListenerFailure == nil)
        #expect(idle.state.agents.isEmpty && idle.state.spaces.isEmpty)
    }
}
