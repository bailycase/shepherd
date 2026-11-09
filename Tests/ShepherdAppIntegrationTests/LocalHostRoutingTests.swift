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
                      settings configure: (AppSettings) -> Void = { _ in }) async throws -> Setup {
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
            let pane = LeafPane(cwd: repo.path)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: index, layout: .leaf(pane))
            try await host.server.addAgent(Agent(name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true), withTab: tab)
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
        let settings = AppSettings(store: defaults)
        configure(settings)
        let hosts = RemoteHostStore(defaults: defaults, childRefreshInterval: .milliseconds(200))
        let vm = ShepherdViewModel(
            server: BackgroundHostClient.idleServer(directory: clientDir), ownsWorkspace: false, settings: settings,
            keybindings: KeybindingsStore(store: defaults),
            themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
            remoteHosts: hosts, sidebarDefaults: defaults, themeInstaller: { _ in }, restoresAgentsAtLaunch: false, checkoutReader: nil,
            hooks: HooksModel(home: clientDir.appendingPathComponent("hooks-home").path, support: clientDir.appendingPathComponent("hooks-support")),
            apps: AppsModel(home: clientDir.appendingPathComponent("apps-home").path))
        vm.adoptLocalHost()
        hosts.addLocalHost(name: NewThreadPlaces.thisMac, socket: socket, token: token)
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
        let rows = (s.vm.sidebarLists.needsYou + s.vm.sidebarLists.working + s.vm.sidebarLists.done + s.vm.sidebarLists.recents).map(\.id)
        #expect(Set(rows) == Set(ids.map { SidebarRowID.local($0) }))
        #expect(NewThreadState.hosts(s.vm).map(\.name) == [NewThreadPlaces.thisMac])
        #expect(NewThreadState.hosts(s.vm).first?.spaces.map(\.id) == [s.space.id])

        s.vm.selectAgent(ids[0])
        #expect(s.vm.selectedAgentID == ids[0] && s.vm.selectedRemoteAgent == nil)
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

        #expect(s.vm.closeLocalPane(terminal.id))
        try await eventuallyOnMain("the host to close it") {
            s.host.server.state.tabs.first { $0.id == agent.tabID }?.layout.leaves.count == 1
        }
        #expect(s.vm.actionError == nil)
    }

    @Test func deletingAWorktreeThreadIsThisMacsDelete() async throws {
        // Ask: This Mac's own dialog, never the host sheet.
        do {
            let s = try await Self.setUp(worktree: "agent/fix-login")
            defer { s.stop() }
            let id = s.host.server.state.agents[0].id
            s.vm.requestDeleteAgent(id)
            #expect(s.vm.worktreeDeleteTarget == id && s.vm.remoteWorktreeSheet == nil && s.vm.thisMacWorktreeDelete == nil)
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
}
