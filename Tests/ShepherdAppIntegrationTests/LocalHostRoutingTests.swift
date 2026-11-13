import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The background host's workspace as the app's own (`adoptLocalHost`): the host's threads are
/// the app's local threads (local rows, `selectedAgentID`, the local menus and dialogs), and
/// what the app changes reaches the host underneath the same view-model methods.
@Suite("The background host's workspace as the app's own", .mainActorExclusive)
@MainActor
struct LocalHostRoutingTests {
    @MainActor
    struct Setup {
        let host: ScratchServer
        let vm: ShepherdViewModel
        let hosts: RemoteHostStore
        let space: Space
        let clientDir: URL

        func stop() {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
            host.stop()
        }

        func onHost(_ id: AgentID) -> Agent? { host.server.state.agents.first { $0.id == id } }
    }

    /// A host serving threads and worktrees in `acme-web` (a repo whose `main` its remote has),
    /// with `agents` in it, and the app as its client taking its workspace as its own.
    static func setUp(agents names: [String] = [], worktree: String? = nil,
                      settings configure: (AppSettings) -> Void = { _ in },
                      pins: (ShepherdState) -> [String] = { _ in [] },
                      beforeConnect: (ShepherdViewModel) async -> Void = { _ in }) async throws -> Setup {
        let host = try ScratchServer()
        host.server.serveThreads(ThreadHosting(defaults: {
            ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                   worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
        }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        _ = host.server.serveAgentQueries(WorktreeHosting(defaults: { .init(generateDescription: false) },
                                                          deleteAgent: { id, _ in try await host.server.deleteAgent(id) }))
        let origin = host.dir.appendingPathComponent("origin.git"), repo = host.dir.appendingPathComponent("acme-web")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "# acme-web\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try git(["init", "-q", "--bare", origin.path], in: host.dir)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Acme Tests"], ["config", "user.email", "tests@example.com"],
                     ["add", "."], ["commit", "-qm", "initial"], ["remote", "add", "origin", origin.path], ["push", "-q", "-u", "origin", "main"]] {
            _ = try git(args, in: repo)
        }
        let space = Space(name: "acme-web", path: repo.path)
        try await host.server.addSpace(space)
        for (index, name) in names.enumerated() {
            let id = AgentID()
            let pane = LeafPane(cwd: repo.path, agentID: id)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: index, layout: .leaf(pane))
            try await host.server.addAgent(Agent(id: id, name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true), withTab: tab)
        }
        if let worktree {
            let checkout = try GitWorktree.add(repo: repo.path, branch: worktree)
            let pane = LeafPane(cwd: checkout)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: names.count, layout: .leaf(pane))
            try await host.server.addAgent(Agent(name: worktree, spaceID: space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true,
                                                 worktreeBranch: worktree, worktreeBase: "main", worktreePath: checkout), withTab: tab)
        }

        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let clientDir = try makeScratchDirectory("cli")
        let defaults = ScratchDefaults()
        defaults.set(pins(host.server.state), forKey: SidebarPins.defaultsKey)
        let settings = AppSettings(store: defaults)
        configure(settings)
        let hosts = RemoteHostStore(defaults: defaults, childRefreshInterval: .milliseconds(200))
        let vm = ShepherdViewModel(settings: settings,
            keybindings: KeybindingsStore(store: defaults),
            themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
            remoteHosts: hosts, sidebarDefaults: defaults, themeInstaller: { _ in },
            hooks: HooksModel(home: clientDir.appendingPathComponent("hooks-home").path, support: clientDir.appendingPathComponent("hooks-support")),
            apps: AppsModel(home: clientDir.appendingPathComponent("apps-home").path))
        // As `ShepherdApp` connects it.
        await beforeConnect(vm)
        vm.connectLocalHost(socket: socket, token: token)
        try await eventuallyOnMain("the host's workspace as the app's", timeout: .seconds(30)) {
            vm.state.agents == host.server.state.agents && vm.state.spaces == host.server.state.spaces
        }
        return Setup(host: host, vm: vm, hosts: hosts, space: space, clientDir: clientDir)
    }

    @Test func theHostsThreadsAreTheAppsOwn() async throws {
        let s = try await Self.setUp(agents: ["Fix the login redirect", "Upgrade the payments SDK"])
        defer { s.stop() }
        let ids = s.host.server.state.agents.map(\.id)

        #expect(s.hosts.connections.isEmpty, "This Mac is no host the UI lists")
        try await eventuallyOnMain("the host to leave its threads' banners to the app") { s.host.server.localAppConnected }
        let rows = (s.vm.sidebarLists.needsYou + s.vm.sidebarLists.working + s.vm.sidebarLists.done + s.vm.sidebarLists.recents).map(\.id)
        #expect(Set(rows) == Set(ids.map { SidebarRowID.local($0) }))
        #expect(NewThreadState.hosts(s.vm).map(\.name) == [NewThreadPlaces.thisMac])
        #expect(NewThreadState.hosts(s.vm).first?.spaces.map(\.id) == [s.space.id])

        s.vm.selectAgent(ids[0])
        #expect(s.vm.selectedAgentID == ids[0] && s.vm.selectedRemoteAgent == nil)
    }

    /// Pins made before the background host connects survive the connection: the app never
    /// prunes This Mac's pins against an empty or filtered copy of the host's workspace.
    @Test func pinsSurviveConnectingToTheHost() async throws {
        let s = try await Self.setUp(agents: ["Fix the login redirect", "Upgrade the payments SDK"],
                                     pins: { state in state.agents.map { "local:\($0.id.rawValue)" } },
                                     // At launch the idle server's empty workspace can be adopted
                                     // (and pruned against) before the host is connected.
                                     beforeConnect: { vm in vm.adopt(ShepherdState()); vm.pruneSidebarPins() })
        defer { s.stop() }
        let ids = s.host.server.state.agents.map(\.id)
        try await eventuallyOnMain("the host to leave its threads' banners to the app") { s.host.server.localAppConnected }
        s.vm.pruneSidebarPins()
        #expect(Set(ids.map { SidebarRowID.local($0) }).isSubset(of: Set(s.vm.sidebarLists.pinned.map(\.id))))
    }

    /// The host's automations and their runs are This Mac's own: the app's workspace holds them,
    /// the Automations page lists them under This Mac with no host section, and a run opens as a
    /// local thread (`LocalClientTests` drives their actions).
    @Test func automationsAreThisMacsOwn() async throws {
        let s = try await Self.setUp(agents: ["Fix the login redirect"])
        defer { s.stop() }
        var state = s.host.server.state
        let automation = Automation(name: "Nightly triage", prompt: "triage", cwd: s.space.path)
        let pane = LeafPane(cwd: s.space.path)
        let tab = ShepherdCore.Tab(spaceID: s.space.id, order: 1, layout: .leaf(pane))
        var run = Agent(name: "Triage #12", spaceID: s.space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true)
        run.automationOrigin = AutomationOrigin(automationID: automation.id)
        state.automations = [automation]
        state.agents.append(run)
        state.tabs.append(tab)
        try await s.host.server.putState(state)
        let thisMac = try #require(s.hosts.localHost)
        try await eventuallyOnMain("the host's automation to reach the app") {
            thisMac.state.automations.map(\.id) == [automation.id] && thisMac.state.agents.contains { $0.id == run.id }
        }

        try await eventuallyOnMain("the automation and its run as the app's own") {
            s.vm.state.automations.map(\.id) == [automation.id] && s.vm.state.agents.contains { $0.id == run.id }
        }
        #expect(s.vm.automationHosts.map(\.id) == [PageHost.localID])
        #expect(s.vm.automationHosts.first?.state.automations.map(\.id) == [automation.id])
        #expect(s.hosts.connections.isEmpty, "no other surface lists This Mac")
        #expect(s.vm.sidebarLists.all.contains { $0.id == .local(run.id) })
        s.vm.selectAgent(run.id)
        #expect(s.vm.selectedAgentID == run.id && s.vm.selectedRemoteAgent == nil)
    }

    @Test func renameAndDeleteReachTheHost() async throws {
        let s = try await Self.setUp(agents: ["Fix the login redirect", "Upgrade the payments SDK"])
        defer { s.stop() }
        let (first, second) = (s.host.server.state.agents[0].id, s.host.server.state.agents[1].id)

        s.vm.renameAgent(first, to: "Fix the checkout redirect")
        try await eventuallyOnMain("the host to rename it") { s.onHost(first)?.name == "Fix the checkout redirect" }
        try await eventuallyOnMain("the app to show it") { s.vm.state.agents.first { $0.id == first }?.name == "Fix the checkout redirect" }

        // Delete asks first, in This Mac's own dialog.
        s.vm.requestDeleteAgent(second)
        #expect(s.vm.agentDeleteTarget == second && s.vm.remoteDeleteTarget == nil)
        s.vm.agentDeleteTarget = nil
        s.vm.deleteAgent(second)
        try await eventuallyOnMain("the host to delete it") { s.onHost(second) == nil && !s.vm.state.agents.contains { $0.id == second } }
        #expect(s.vm.actionError == nil)
    }

    /// The project menu's rename, base, hide, order and remove reach the host (`spaceAction`).
    @Test func spaceChangesReachTheHost() async throws {
        let s = try await Self.setUp(agents: ["Fix the login redirect"])
        defer { s.stop() }
        let other = try makeScratchDirectory("acme-api")
        let added = try #require(await s.vm.addSpace(at: other, select: false))
        func onHost() -> [Space] { s.host.server.state.spaces }

        s.vm.renameSpace(s.space.id, to: "Acme Web")
        s.vm.setWorktreeBase("origin/release", for: s.space.id)
        s.vm.setProjectHiddenFromSidebar(s.space.id, true)
        try await eventuallyOnMain("the host to rename, base and hide it") {
            onHost().first { $0.id == s.space.id }.map { $0.name == "Acme Web" && $0.worktreeBase == "origin/release" && $0.sidebarHidden } == true
        }
        s.vm.moveProject(s.space.id, before: added)
        try await eventuallyOnMain("the host to reorder") { onHost().map(\.id) == [s.space.id, added] }
        s.vm.deleteSpace(s.space.id)
        try await eventuallyOnMain("the host to remove it and its threads") {
            onHost().map(\.id) == [added] && s.host.server.state.agents.isEmpty && s.vm.state.spaces.map(\.id) == [added]
        }
        #expect(s.vm.actionError == nil)
        try? FileManager.default.removeItem(at: other)
    }

    @Test func aNewThreadStartsOnTheHostAndIsSelectedHere() async throws {
        try StubPi.installAsEngine()
        let s = try await Self.setUp()
        defer { s.stop() }

        s.vm.openNewThread(in: s.space.id)
        #expect(s.vm.newThread.place == NewThreadPlace(host: nil, space: s.space.id))
        s.vm.newThread.prompt = "Check the build"
        try await eventuallyOnMain("the new thread's defaults") { s.vm.newThread.blocker(s.vm) == nil }
        s.vm.newThread.send(s.vm)
        try await eventuallyOnMain("the host's new thread, selected here", timeout: .seconds(20)) {
            s.vm.selectedAgentID.map { s.onHost($0) != nil } == true
        }
        #expect(s.vm.selectedRemoteAgent == nil)
        #expect(s.vm.newThread.error == nil)
    }

    /// A new thread in a worktree: the checkout is made here, as in process, and the host's
    /// thread runs in it; a standalone thread gets its own folder on the host.
    @Test func aWorktreeThreadAndAStandaloneThreadStartOnTheHost() async throws {
        try StubPi.installAsEngine()
        let s = try await Self.setUp()
        defer { s.stop() }

        s.vm.openNewThread(in: s.space.id)
        s.vm.newThread.worktree = true
        s.vm.newThread.worktreeBranch = .named("agent/fix-login")
        s.vm.newThread.prompt = "Fix the login redirect"
        try await eventuallyOnMain("the new thread's defaults") { s.vm.newThread.blocker(s.vm) == nil }
        s.vm.newThread.send(s.vm)
        try await eventuallyOnMain("the host's worktree thread", timeout: .seconds(20)) {
            s.vm.selectedAgentID.flatMap(s.onHost)?.worktreeBranch == "agent/fix-login"
        }
        let agent = try #require(s.vm.selectedAgentID.flatMap(s.onHost))
        #expect(agent.worktreePath.map { FileManager.default.fileExists(atPath: $0) } == true)
        #expect(s.vm.newThread.error == nil)

        // "No space" in the place menu, as in process: This Mac's first option, a standalone thread.
        s.vm.openNewThread(in: s.space.id)
        let sections = NewThreadPlaces.sections(NewThreadState.hosts(s.vm), chosen: s.vm.newThread.place)
        #expect(sections.map(\.title) == [NewThreadPlaces.thisMac])
        let noSpace = try #require(sections.first?.options.first)
        #expect(noSpace.title == "No space")
        let place = try #require(NewThreadPlaces.place(noSpace))
        s.vm.newThread.choose(host: place.host, space: place.space, vm: s.vm)
        #expect(s.vm.newThread.place == NewThreadPlace(host: nil, space: nil))
        s.vm.newThread.prompt = "Compare approaches to organizing research notes"
        try await eventuallyOnMain("the standalone thread's defaults") { s.vm.newThread.blocker(s.vm) == nil }
        s.vm.newThread.send(s.vm)
        try await eventuallyOnMain("the host's standalone thread", timeout: .seconds(20)) {
            s.vm.selectedAgentID.flatMap(s.onHost).map { $0.id != agent.id } == true
        }
        let standalone = try #require(s.vm.selectedAgentID.flatMap(s.onHost))
        #expect(s.host.server.state.spaces.first { $0.id == standalone.spaceID }?.holdsThreads == true)
        #expect(standalone.worktreeBranch == nil && s.vm.newThread.error == nil)
        #expect(s.vm.state.agents.contains { $0.id == standalone.id }, "a local thread of the app's own")
    }

    @Test func aTerminalOpensAndClosesOnTheHost() async throws {
        _ = NSApplication.shared
        let s = try await Self.setUp(agents: ["Fix the login redirect"])
        defer { s.stop() }
        let agent = s.host.server.state.agents[0]
        s.vm.selectAgent(agent.id)

        s.vm.newTerminalTab()
        try await eventuallyOnMain("the host's terminal in the app's layout") {
            (s.vm.state.tabs.first { $0.id == agent.tabID }?.layout.leaves.count ?? 0) == 2
        }
        let terminal = try #require(s.vm.state.tabs.first { $0.id == agent.tabID }?.layout.leaves.first { $0.id != agent.paneID })
        #expect(s.host.server.state.tabs.first { $0.id == agent.tabID }?.layout.contains(terminal.id) == true)
        // The host adds the pane to the layout, then starts its shell and answers the open. Closing before that
        // answer makes the open fail ("unknown pane"), which is a different thing from closing a terminal.
        try await eventuallyOnMain("the open to be answered") { s.vm.focusedPaneID == terminal.id }

        #expect(s.vm.closeLocalPane(terminal.id))
        try await eventuallyOnMain("the host to close it") {
            s.host.server.state.tabs.first { $0.id == agent.tabID }?.layout.leaves.count == 1
        }
        #expect(s.vm.actionError == nil, "\(String(describing: s.vm.actionError))")
    }

    @Test func deletingAWorktreeThreadIsThisMacsDelete() async throws {
        // Ask: This Mac's own dialog, never the host sheet.
        do {
            let s = try await Self.setUp(worktree: "agent/fix-login")
            defer { s.stop() }
            let id = s.host.server.state.agents[0].id
            s.vm.requestDeleteAgent(id)
            #expect(s.vm.worktreeDeleteTarget == id && s.vm.remoteWorktreeSheet == nil)
        }
        // A remembered removal with nothing to lose just deletes.
        do {
            let s = try await Self.setUp(worktree: "agent/fix-login") { $0.worktreeDeleteAction = .removeWorktree }
            defer { s.stop() }
            let agent = s.host.server.state.agents[0]
            s.vm.requestDeleteAgent(agent.id)
            try await eventuallyOnMain("the host to remove the thread and checkout", timeout: .seconds(20)) {
                s.onHost(agent.id) == nil && !FileManager.default.fileExists(atPath: agent.worktreePath ?? "")
            }
            #expect(s.vm.worktreeDeleteTarget == nil && s.vm.actionError == nil)
        }
        // With unreconciled work: the dialog, with the host's warning; confirming removes it.
        do {
            let s = try await Self.setUp(worktree: "agent/fix-login") { $0.worktreeDeleteAction = .removeWorktree }
            defer { s.stop() }
            let agent = s.host.server.state.agents[0]
            let checkout = try #require(agent.worktreePath)
            try "draft\n".write(to: URL(fileURLWithPath: checkout).appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            s.vm.requestDeleteAgent(agent.id)
            try await eventuallyOnMain("This Mac's dialog") { s.vm.worktreeDeleteTarget == agent.id }
            #expect(s.vm.hostWorktreeInfo?.warning == "1 uncommitted change")
            s.vm.worktreeDeleteTarget = nil
            s.vm.deleteWorktreeAgent(agent.id, removeWorktree: true)
            try await eventuallyOnMain("the host to remove it", timeout: .seconds(20)) {
                s.onHost(agent.id) == nil && !FileManager.default.fileExists(atPath: checkout)
            }
        }
        // Keep worktree: the thread goes, the checkout stays.
        do {
            let s = try await Self.setUp(worktree: "agent/fix-login") { $0.worktreeDeleteAction = .keepWorktree }
            defer { s.stop() }
            let agent = s.host.server.state.agents[0]
            s.vm.requestDeleteAgent(agent.id)
            try await eventuallyOnMain("the host to delete the thread") { s.onHost(agent.id) == nil }
            #expect(FileManager.default.fileExists(atPath: agent.worktreePath ?? ""))
        }
    }

    /// Locate Folder…: the host moves the space and its threads' folders, and the app starts
    /// them again there.
    @Test func locateFolderMovesTheSpaceOnTheHost() async throws {
        let s = try await Self.setUp(agents: ["Fix the login redirect"])
        defer { s.stop() }
        let moved = s.host.dir.appendingPathComponent("acme-web-moved")
        try FileManager.default.moveItem(at: URL(fileURLWithPath: s.space.path), to: moved)
        await s.vm.relocateSpace(s.space.id, to: moved.path)
        let canonical = moved.resolvingSymlinksInPath().path
        #expect(s.host.server.state.spaces.first?.path == canonical)
        let agent = try #require(s.host.server.state.agents.first)
        #expect(s.host.server.state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd == canonical)
        try await eventuallyOnMain("the app to show the new folder") { s.vm.state.spaces.first?.path == canonical }
        // The folder check runs off the main thread after a state change, so the mark it put on the moved folder clears a moment later.
        try await eventuallyOnMain("the moved space to stop reading as missing") { !s.vm.missingSpaces.contains(s.space.id) }
        #expect(s.vm.actionError == nil)
    }

    /// The notify tool's banner reaches the app (which posts it, so its click opens the thread
    /// here), and the thread the app shows is the one the host's phone pushes skip.
    @Test func notifyBannersAndTheWatchedThreadReachTheApp() async throws {
        let s = try await Self.setUp(agents: ["Fix the login redirect"])
        defer { s.stop() }
        let agent = s.host.server.state.agents[0]
        let banners = ThreadBanners(server: s.host.server, state: { s.host.server.state },
                                    sink: { var sink = ThreadBanners.Sink(post: { _ in Issue.record("the host posted it") }, remove: { _ in },
                                                                          isWatching: { _ in false }, notifyOnTurnFinished: { true })
                                            sink.quiet = { s.host.server.localAppConnected }
                                            return sink }())
        banners.observeServer()
        var heard: [String] = []
        let posting = s.hosts.onLocalAgentNotify
        s.hosts.onLocalAgentNotify = { id, title, body in heard.append(title); posting?(id, title, body) }
        try await eventuallyOnMain("the app to be the host's own") { s.host.server.localAppConnected }
        let pi = try ExtensionClient(path: s.host.socketPath)
        defer { pi.closeConnection() }
        try pi.send(.notify(agentID: agent.id, title: "CI passed", body: "PR #42 is green"))
        try await eventuallyOnMain("the app to hear the banner") { heard == ["CI passed"] }

        s.hosts.focusLocalThread(agent.id)
        let server = s.host.server
        try await eventuallyAsync("the host to know the watched thread") {
            (try? await server.enqueue { @Sendable in server.pushNotifications.focused }) == agent.id
        }
    }

    /// A thread nobody opened here whose pi can't start shows its sign-in card and its Needs you
    /// row, as in process: one that stopped while the app was connected, and both for an app that
    /// connects afterwards. Retry everyone waiting starts each again on the host.
    @Test func startProblemsOfUnopenedThreadsReachTheAppAndRetryEveryoneStartsThem() async throws {
        try StubPi.installAsEngine()
        let s = try await Self.setUp(agents: ["Fix the login redirect", "Upgrade the payments SDK"])
        defer { s.stop() }
        let server = s.host.server
        let ids = server.state.agents.map(\.id)
        let startup = URL(fileURLWithPath: s.space.path).appendingPathComponent("stub-pi-startup.json")
        try JSONSerialization.data(withJSONObject: [
            "exit": "1", "stderr": "No models available. Use /login to log into a provider via OAuth or API key.",
        ]).write(to: startup)
        // Another device opens each thread on the host; this app never does.
        for id in ids { Task { _ = try? await server.nativeThread(agentID: id, request: .snapshot()) } }
        try await eventuallyOnMain("both threads to wait for a sign-in", timeout: .seconds(30)) {
            Set(s.vm.notSignedIn.keys) == Set(ids) && s.vm.cannotStart == Set(ids)
        }
        #expect(ids.allSatisfy { s.vm.threadStores.existing(for: $0) == nil }, "the app opened neither thread")
        #expect(Set(s.vm.sidebarLists.needsYou.map(\.id)) == Set(ids.map { SidebarRowID.local($0) }))

        // An app that connects now hears both at once.
        let late = try Self.connectApp(to: s.host)
        defer { late.stop() }
        try await eventuallyOnMain("the late app to hear both", timeout: .seconds(30)) {
            Set(late.vm.notSignedIn.keys) == Set(ids) && late.vm.cannotStart == Set(ids)
        }

        try FileManager.default.removeItem(at: startup)
        #expect(s.vm.retrySignedOutAgents(nil) == 2)
        try await eventuallyOnMain("both threads to start again and their cards to go", timeout: .seconds(30)) {
            s.vm.notSignedIn.isEmpty && s.vm.cannotStart.isEmpty && late.vm.notSignedIn.isEmpty && late.vm.cannotStart.isEmpty
        }
        try await eventuallyOnMain("both threads' pis to serve on the host", timeout: .seconds(30)) {
            server.state.agents.allSatisfy { $0.lastFailure == nil }
        }
    }

    /// Another app on this Mac taking `host`'s workspace as its own.
    @MainActor
    struct App {
        let vm: ShepherdViewModel
        let hosts: RemoteHostStore
        let dir: URL
        func stop() {
            for connection in hosts.allConnections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    static func connectApp(to host: ScratchServer) throws -> App {
        let token = try String(contentsOf: host.dir.appendingPathComponent("remote-token"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = try makeScratchDirectory("cli")
        let defaults = ScratchDefaults()
        let hosts = RemoteHostStore(defaults: defaults, childRefreshInterval: .milliseconds(200))
        let vm = ShepherdViewModel(settings: AppSettings(store: defaults),
            keybindings: KeybindingsStore(store: defaults),
            themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
            remoteHosts: hosts, sidebarDefaults: defaults, themeInstaller: { _ in },
            hooks: HooksModel(home: dir.appendingPathComponent("hooks-home").path, support: dir.appendingPathComponent("hooks-support")),
            apps: AppsModel(home: dir.appendingPathComponent("apps-home").path))
        vm.connectLocalHost(socket: host.dir.appendingPathComponent("h.sock").path, token: token)
        return App(vm: vm, hosts: hosts, dir: dir)
    }
}
