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
/// owns nothing, takes the host's workspace as its own (`connectLocalHost`).
@Suite("The app as the background host's client", .mainActorExclusive)
@MainActor
struct LocalClientTests {
    /// The app, as `ShepherdApp` makes it when the host answers, connected to `socket`.
    private static func app(socket: String, token: String, host: ScratchServer) async throws
        -> (ShepherdViewModel, RemoteHostStore, SessionServer, RemoteHostStore.Connection, URL, ScratchDefaults) {
        let clientDir = try makeScratchDirectory("cli")
        let defaults = ScratchDefaults()
        let idle = BackgroundHostClient.idleServer(directory: clientDir)
        let hosts = RemoteHostStore(defaults: defaults, childRefreshInterval: .milliseconds(200))
        let vm = ShepherdViewModel(
            server: idle, ownsWorkspace: false, settings: AppSettings(store: defaults), keybindings: KeybindingsStore(store: defaults),
            themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
            remoteHosts: hosts, sidebarDefaults: defaults, themeInstaller: { _ in }, restoresAgentsAtLaunch: false, checkoutReader: nil,
            hooks: HooksModel(home: clientDir.appendingPathComponent("hooks-home").path, support: clientDir.appendingPathComponent("hooks-support")),
            apps: AppsModel(home: clientDir.appendingPathComponent("apps-home").path))
        let connection = vm.connectLocalHost(socket: socket, token: token)
        try await eventuallyOnMain("the host's workspace", timeout: .seconds(30)) {
            // Designs reach a client only while the host serves them, so they aren't compared.
            connection.phase == RemoteHostStore.Phase.connected && connection.state.spaces == host.server.state.spaces
                && connection.state.agents == host.server.state.agents
        }
        return (vm, hosts, idle, connection, clientDir, defaults)
    }

    @Test func aNewerAppAsksItsHostToDrainAndHearsWhenItsHostIsGone() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        host.server.hostBuild = "1201"
        let asked = Locked(0)
        host.server.onDrainRequest = { asked.withValue { $0 += 1 } }
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        let hosts = RemoteHostStore(defaults: ScratchDefaults(), childRefreshInterval: .milliseconds(200))
        hosts.appBuild = "1202"
        var lost = 0
        hosts.onLocalHostLost = { lost += 1 }
        let connection = hosts.addLocalHost(name: "This Mac", socket: socket, token: token)
        defer { hosts.removeHost(id: connection.id) }
        try await eventuallyOnMain("the app to connect") { connection.phase == .connected }
        try await eventuallyOnMain("the older host to be asked to drain") { asked.current == 1 }

        host.stop()
        try await eventuallyOnMain("the app to hear its host is gone") { lost >= 1 }
    }

    @Test func theAppDrawsTheHostsBoardsAndWithNoAppTheHostSaysItsWindowIsClosed() async throws {
        _ = NSApplication.shared
        let host = try ScratchServer()
        defer { host.stop() }
        host.server.relayDesignDrawingToApp()
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let design = Design(name: "Two", createdAt: 1_000)
        _ = try await host.server.createDesign(design)
        _ = try await host.server.writeDesignBoard(design.id, path: try DesignPath.validate("Two.dc.html"), source: DesignAgentRenderFlowTests.board)
        _ = try await host.server.updateDesignIndex(design.id, patch: .object(["boards": .object([
            "Two.dc.html": .object(["x": .number(0), "y": .number(0), "w": .number(400), "h": .number(300), "title": .string("Two")]),
        ])]))
        let request = DesignRenderRequest(path: "Two.dc.html")
        do {
            _ = try await host.server.renderDesignBoard(design.id, request: request)
            Issue.record("drew with no app")
        } catch let failure as DesignRenderFailure {
            #expect(failure.code == "render_unavailable" && failure.message.contains("Shepherd's window"))
        }

        let (vm, hosts, _, _, clientDir, _) = try await Self.app(socket: socket, token: token, host: host)
        defer {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
        }
        vm.designNetwork = .none
        let rendered = try await host.server.renderDesignBoard(design.id, request: request)
        #expect(rendered.image.mimeType == "image/png" && rendered.text.hasPrefix("Two.dc.html at 400×300"))
    }

    /// Add Space opens This Mac's own picker; what it adds goes to the host (`LocalHostRoutingTests`).
    @Test func addSpaceAddsToTheHost() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let (vm, hosts, _, _, clientDir, _) = try await Self.app(socket: socket, token: token, host: host)
        defer {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
        }
        vm.addSpaceFromPanel()
        #expect(vm.spacePickerTarget == .local)
    }

    @Test func theHostsAgentDrivesTheAppsPageWithNoTunnel() async throws {
        _ = NSApplication.shared
        let host = try ScratchServer()
        defer { host.stop() }
        let space = Fixture.space(path: host.dir.path)
        let agent = Fixture.agent("web", in: space)
        try await host.server.putState(Fixture.state(spaces: [space], agents: [agent]))
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let (vm, hosts, _, connection, clientDir, _) = try await Self.app(socket: socket, token: token, host: host)
        defer {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
        }
        let web = try TinyWebServer(pages: BrowserAgentTests.pages)
        try await web.start()
        defer { web.stop() }

        // No Browser tab is shown and nothing claimed it: the host hands the call to the app.
        let extensionClient = try ExtensionClient(path: host.socketPath)
        try extensionClient.send(.helloBrowser(agentID: agent.agent.id))
        let url = "http://localhost:\(web.port)/checkout"
        try extensionClient.send(.browser(id: 1, agentID: agent.agent.id, request: .open(url: url, note: nil)))
        let reply = try await Task.detached { try extensionClient.readReply(timeout: .seconds(60)) }.value
        guard case .browserResult(1, let text, _) = reply else { Issue.record("expected a result, got \(reply)"); return }
        #expect(text.contains("Checkout"))
        // The thread is the app's own, so the page is its local one, as in process.
        let session = try #require(vm.browsers.existing(agent.agent.id))
        #expect(session.url?.absoluteString == url, "the app's page loaded the dev server on this Mac's own loopback")
        #expect(vm.browsers.existing(RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id)) == nil)
    }

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

        let (vm, hosts, idle, connection, clientDir, defaults) = try await Self.app(socket: socket, token: token, host: host)
        defer {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
        }
        #expect(connection.capabilities.contains(RemoteProtocol.localCapability))
        #expect(defaults.data(forKey: RemoteHostStore.defaultsKey).map { String(decoding: $0, as: UTF8.self) } ?? "[]" == "[]",
                "the host on this Mac is found again each launch, never saved")

        // New thread, This Mac's own, made on the host.
        vm.openNewThread(in: space.id)
        #expect(vm.newThread.place == NewThreadPlace(host: nil, space: space.id))
        vm.newThread.prompt = "Check the build"
        try await eventuallyOnMain("the host's defaults") { vm.newThread.blocker(vm) == nil }
        vm.newThread.send(vm)
        try await eventuallyOnMain("the host's new thread to be selected", timeout: .seconds(20)) {
            vm.selectedAgentID.map { id in host.server.state.agents.contains { $0.id == id } } == true
        }
        let ref = RemoteAgentRef(hostID: connection.id, agentID: try #require(vm.selectedAgentID))
        let row = try #require((vm.sidebarLists.needsYou + vm.sidebarLists.working + vm.sidebarLists.done + vm.sidebarLists.recents)
            .first { $0.id == .local(ref.agentID) })
        // The host on this Mac is This Mac itself: a local row, one This Mac to start threads on,
        // the Hosts page's This Mac card counts its threads, and it isn't a host to remove.
        if case .tag = row.accessory { Issue.record("a thread of this Mac's host wears a host tag") }
        #expect(NewThreadState.hosts(vm).map(\.name) == ["This Mac"])
        #expect(hosts.connections.isEmpty, "This Mac is no host the UI lists")
        try await eventuallyOnMain("the host to leave its threads' banners to the app") { host.server.localAppConnected }
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
