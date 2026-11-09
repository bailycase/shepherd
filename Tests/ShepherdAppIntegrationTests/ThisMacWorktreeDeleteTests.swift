import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Delete Worktree Agent on a thread of the background host on this Mac does what it does to an
/// in-process thread (`requestWorktreeDelete`): Settings ▸ Worktrees' choice, This Mac's dialog,
/// and a remembered removal that just deletes unless work would be lost. Never the paired host's sheet.
@Suite("Deleting a worktree thread of the host on this Mac", .mainActorExclusive)
@MainActor
struct ThisMacWorktreeDeleteTests {
    @MainActor
    private struct Setup {
        let host: ScratchServer
        let vm: ShepherdViewModel
        let hosts: RemoteHostStore
        let target: RemoteAgentRef
        let checkout: String
        let clientDir: URL

        func stop() {
            for connection in hosts.connections { hosts.removeHost(id: connection.id) }
            try? FileManager.default.removeItem(at: clientDir)
            host.stop()
        }

        var agentOnHost: Bool { host.server.state.agents.contains { $0.id == target.agentID } }
    }

    /// A host serving a worktree thread whose branch its remote already has (nothing to lose),
    /// and the app as its client with Settings ▸ Worktrees at `action`.
    private func setUp(_ action: WorktreeDeleteAction) async throws -> Setup {
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
        let checkout = try GitWorktree.add(repo: repo.path, branch: "agent/fix-login")
        let pane = LeafPane(cwd: checkout)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "fix-login", spaceID: space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true,
                          worktreeBranch: "agent/fix-login", worktreeBase: "main", worktreePath: checkout)
        try await host.server.addAgent(agent, withTab: tab)

        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let clientDir = try makeScratchDirectory("cli")
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        settings.worktreeDeleteAction = action
        let hosts = RemoteHostStore(defaults: defaults, childRefreshInterval: .milliseconds(200))
        let vm = ShepherdViewModel(
            server: BackgroundHostClient.idleServer(directory: clientDir), ownsWorkspace: false, settings: settings,
            keybindings: KeybindingsStore(store: defaults),
            themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
            remoteHosts: hosts, sidebarDefaults: defaults, themeInstaller: { _ in }, restoresAgentsAtLaunch: false, checkoutReader: nil,
            hooks: HooksModel(home: clientDir.appendingPathComponent("hooks-home").path, support: clientDir.appendingPathComponent("hooks-support")),
            apps: AppsModel(home: clientDir.appendingPathComponent("apps-home").path))
        let connection = hosts.addLocalHost(name: "This Mac", socket: socket, token: token)
        try await eventuallyOnMain("the host's thread", timeout: .seconds(30)) {
            connection.phase == RemoteHostStore.Phase.connected && connection.state.agents.contains { $0.id == agent.id }
        }
        return Setup(host: host, vm: vm, hosts: hosts, target: RemoteAgentRef(hostID: connection.id, agentID: agent.id),
                     checkout: checkout, clientDir: clientDir)
    }

    @Test func askOpensThisMacsDialogAndDeletesNothing() async throws {
        let s = try await setUp(.ask)
        defer { s.stop() }
        s.vm.requestRemoteDelete(s.target)

        #expect(s.vm.thisMacWorktreeDelete?.target == s.target)
        #expect(s.vm.remoteWorktreeSheet == nil, "never the paired host's sheet")
        #expect(s.agentOnHost)
        // The dialog's probe reads the host's checkout.
        let info = try await s.vm.thisMacWorktreeInfo(s.target)
        #expect(info.warning == nil && info.branch == "agent/fix-login")
    }

    @Test func keepWorktreeDeletesTheThreadAndKeepsItsCheckout() async throws {
        let s = try await setUp(.keepWorktree)
        defer { s.stop() }
        s.vm.requestRemoteDelete(s.target)

        try await eventuallyOnMain("the host to delete the thread") { !s.agentOnHost }
        #expect(s.vm.thisMacWorktreeDelete == nil && s.vm.remoteWorktreeSheet == nil)
        #expect(FileManager.default.fileExists(atPath: s.checkout))
    }

    @Test func aRememberedRemovalWithNothingToLoseJustDeletes() async throws {
        let s = try await setUp(.removeWorktree)
        defer { s.stop() }
        s.vm.requestRemoteDelete(s.target)

        try await eventuallyOnMain("the host to remove the thread and checkout", timeout: .seconds(20)) {
            !s.agentOnHost && !FileManager.default.fileExists(atPath: s.checkout)
        }
        try await eventuallyOnMain("the row to go") {
            s.hosts.connections.first?.state.agents.contains { $0.id == s.target.agentID } == false
        }
        #expect(s.vm.thisMacWorktreeDelete == nil && s.vm.remoteWorktreeSheet == nil)
        #expect(s.vm.actionError == nil)
    }

    @Test func aRememberedRemovalWithUnreconciledWorkAsksWithTheWarning() async throws {
        let s = try await setUp(.removeWorktree)
        defer { s.stop() }
        try "draft\n".write(to: URL(fileURLWithPath: s.checkout).appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        s.vm.requestRemoteDelete(s.target)

        try await eventuallyOnMain("This Mac's dialog") { s.vm.thisMacWorktreeDelete != nil }
        #expect(s.vm.thisMacWorktreeDelete?.info?.warning == "1 uncommitted change")
        #expect(s.vm.remoteWorktreeSheet == nil)
        #expect(s.agentOnHost && FileManager.default.fileExists(atPath: s.checkout))

        // "Delete agent and worktree" in the dialog: the host removes what the dialog warned about.
        let info = try #require(s.vm.thisMacWorktreeDelete?.info)
        s.vm.thisMacWorktreeDelete = nil
        s.vm.deleteThisMacWorktreeAgent(s.target, removing: info)
        try await eventuallyOnMain("the host to remove the thread and checkout", timeout: .seconds(20)) {
            !s.agentOnHost && !FileManager.default.fileExists(atPath: s.checkout)
        }
        #expect(s.vm.actionError == nil)
    }
}
