import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// The app as the background host's client (`SHEPHERD_BACKGROUND_HOST=1`): its own workspace is
/// empty, and the host on this Mac reads as This Mac, through its local socket.
extension PreviewTests {
    @Test func localClientWorkspace() async throws {
        let workspace = try PreviewWorkspace(ownsWorkspace: false)
        let host = try ScratchServer(dir: try makeScratchDirectory("host"))
        defer { workspace.stop(); host.stop() }
        host.server.serveThreads(ThreadHosting(defaults: {
            ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                   worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
        }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        let space = Space(name: "acme-web", path: host.dir.path)
        let names = ["Fix the checkout total rounding", "Upgrade the payments SDK", "Write release notes for 2.4"]
        let records = names.enumerated().map { index, name -> (Agent, ShepherdCore.Tab) in
            let id = AgentID()
            let pane = LeafPane(cwd: host.dir.path, agentID: id)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: index, layout: .leaf(pane))
            return (Agent(id: id, name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id,
                          status: index == 0 ? .working : .done, nameIsFinal: true), tab)
        }
        try await host.server.putState(ShepherdState(spaces: [space], tabs: records.map(\.1), agents: records.map(\.0)))
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let vm = workspace.vm
        let connection = vm.remoteHosts.addLocalHost(name: NewThreadPlaces.thisMac, socket: socket, token: token)
        try await eventuallyOnMain("the host on this Mac to connect", timeout: .seconds(30)) {
            connection.phase == .connected && connection.state == host.server.state
        }
        vm.openNewThread()
        try await Preview.render("local-client-workspace", size: CGSize(width: 1280, height: 760)) {
            RootView(vm: vm)
        }
    }

    /// A thread of the host on this Mac draws the branch card beside its transcript, as the app's
    /// own threads do, and no branch chip in the toolbar.
    @Test func localClientThreadBranchCard() async throws {
        let workspace = try PreviewWorkspace(ownsWorkspace: false)
        let host = try ScratchServer(dir: try makeScratchDirectory("host"))
        defer { workspace.stop(); host.stop() }
        host.server.serveThreads(ThreadHosting(defaults: {
            ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                   worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
        }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        let repo = host.dir.appendingPathComponent("payments").path
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=Preview", "-c", "user.email=preview@example.com", "-C", repo] + arguments
            try process.run(); process.waitUntilExit()
        }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try (1...8).map { "line \($0)" }.joined(separator: "\n").write(toFile: repo + "/outbox.go", atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-q", "-m", "start"])
        try git(["switch", "-q", "-c", "agent/refund-events"])
        // The branch's work: 71 lines in, 8 out, committed.
        try (1...71).map { "refund \($0)" }.joined(separator: "\n").write(toFile: repo + "/outbox.go", atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "Emit refund events"])
        // main moves on by three.
        try git(["switch", "-q", "main"])
        for n in 1...3 { try "\(n)".write(toFile: repo + "/main-\(n).txt", atomically: true, encoding: .utf8); try git(["add", "."]); try git(["commit", "-q", "-m", "main \(n)"]) }
        try git(["switch", "-q", "agent/refund-events"])
        let space = Space(name: "payments", path: repo)
        let id = AgentID(), other = AgentID()
        let pane = LeafPane(cwd: repo, agentID: id), otherPane = LeafPane(cwd: repo, agentID: other)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let otherTab = ShepherdCore.Tab(spaceID: space.id, order: 1, layout: .leaf(otherPane))
        var agent = Agent(id: id, name: "Add refund events", spaceID: space.id, tabID: tab.id, paneID: pane.id, status: .done, nameIsFinal: true)
        agent.worktreeBranch = "agent/refund-events"
        agent.worktreePath = repo
        agent.worktreeBase = "main"
        var peer = Agent(id: other, name: "Webhook retries", spaceID: space.id, tabID: otherTab.id, paneID: otherPane.id, status: .blocked, nameIsFinal: true)
        peer.worktreeBranch = "agent/webhook-retries"
        try await host.server.putState(ShepherdState(spaces: [space], tabs: [tab, otherTab], agents: [agent, peer]))
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let vm = workspace.vm
        let connection = vm.remoteHosts.addLocalHost(name: NewThreadPlaces.thisMac, socket: socket, token: token)
        try await eventuallyOnMain("the host on this Mac to connect", timeout: .seconds(30)) {
            connection.phase == .connected && connection.state == host.server.state
        }
        vm.selectRemoteAgent(hostID: connection.id, agentID: id)
        // The card reads itself once it shows.
        let store = vm.branchCardStore(for: id)
        for width in [1280.0, 1440.0] {
            try await Preview.render("local-client-branch-card-\(Int(width))", size: CGSize(width: width, height: 760), ready: { store.status != nil }) {
                RootView(vm: vm)
            }
        }
        #expect(store.card?.branch == "agent/refund-events")
        #expect(store.card?.others.map(\.branch) == ["agent/webhook-retries"])
    }
    /// Delete Worktree Agent on a thread of the host on this Mac: This Mac's own dialog, with the
    /// checkout and loss warning the host reports.
    @Test func localClientDeleteWorktreeDialog() async throws {
        let workspace = try PreviewWorkspace(ownsWorkspace: false)
        let host = try ScratchServer(dir: try makeScratchDirectory("host"))
        let repo = try makeScratchRepo()
        defer { workspace.stop(); host.stop(); try? FileManager.default.removeItem(at: repo) }
        _ = host.server.serveAgentQueries(WorktreeHosting(defaults: { .init(generateDescription: false) },
                                                          deleteAgent: { id, _ in try await host.server.deleteAgent(id) }))
        let space = Space(name: "acme-web", path: repo.path)
        try await host.server.addSpace(space)
        let checkout = try GitWorktree.add(repo: repo.path, branch: "agent/fix-login")
        try "draft\n".write(to: URL(fileURLWithPath: checkout).appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let pane = LeafPane(cwd: checkout)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "Fix the login redirect", spaceID: space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true,
                          worktreeBranch: "agent/fix-login", worktreeBase: "main", worktreePath: checkout)
        try await host.server.addAgent(agent, withTab: tab)
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let vm = workspace.vm
        let connection = vm.remoteHosts.addLocalHost(name: NewThreadPlaces.thisMac, socket: socket, token: token)
        try await eventuallyOnMain("the host on this Mac to connect", timeout: .seconds(30)) {
            connection.phase == .connected && connection.state.agents.contains { $0.id == agent.id }
        }
        let target = RemoteAgentRef(hostID: connection.id, agentID: agent.id)
        vm.requestRemoteDelete(target)
        let item = try #require(vm.thisMacWorktreeDelete)
        try await Preview.render("sheet-delete-worktree-this-mac", size: CGSize(width: AppLayout.confirmSheetWideWidth, height: 420),
                                 untilGone: "Checking", showing: "Unreconciled work") {
            // The host's warning; a made-up path in place of this machine's scratch folder.
            WorktreeDeleteDialog(agent: item.agent, path: "~/Developer/acme-web-worktrees/agent-fix-login", settings: vm.settings,
                                 probe: { try await vm.thisMacWorktreeInfo(target).warning }, cancel: {}, delete: { _ in })
        }
    }
}

/// The background host's workspace as the app's own (`adoptLocalHost`): the same fixture, in
/// process and as the host's client, renders the same window.
extension PreviewTests {
    @Test func localHostWorkspaceMatchesInProcess() async throws {
        let space = Space(name: "acme-web", path: try makeScratchDirectory("acme-web").path)
        let names = ["Fix the checkout total rounding", "Upgrade the payments SDK", "Write release notes for 2.4"]
        let records = names.enumerated().map { index, name -> (Agent, ShepherdCore.Tab) in
            let id = AgentID()
            let pane = LeafPane(cwd: space.path, agentID: id)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: index, layout: .leaf(pane))
            return (Agent(id: id, name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id,
                          status: index == 0 ? .working : .done, nameIsFinal: true), tab)
        }
        let fixture = ShepherdState(spaces: [space], tabs: records.map(\.1), agents: records.map(\.0))

        let local = try PreviewWorkspace()
        defer { local.stop() }
        try await local.seed(fixture)
        local.vm.selectAgent(records[1].0.id)
        try await Preview.render("this-mac-in-process", size: CGSize(width: 1280, height: 760)) { RootView(vm: local.vm) }

        let workspace = try PreviewWorkspace(ownsWorkspace: false)
        let host = try ScratchServer(dir: try makeScratchDirectory("host"))
        defer { workspace.stop(); host.stop() }
        host.server.serveThreads(ThreadHosting(defaults: {
            ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                   worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
        }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        try await host.server.putState(fixture)
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let vm = workspace.vm
        vm.connectLocalHost(socket: socket, token: token)
        try await eventuallyOnMain("the host's workspace as the app's", timeout: .seconds(30)) { vm.state.agents == host.server.state.agents }
        vm.selectAgent(records[1].0.id)
        try await Preview.render("this-mac-client", size: CGSize(width: 1280, height: 760)) { RootView(vm: vm) }
        let directory = try #require(Preview.directory)
        for mode in ["light", "dark"] {
            #expect(try Data(contentsOf: directory.appendingPathComponent("this-mac-in-process-\(mode).png"))
                == Data(contentsOf: directory.appendingPathComponent("this-mac-client-\(mode).png")), "the \(mode) windows differ")
        }
    }
}

/// More of the window, in process and as the background host's client with its workspace taken
/// as the app's own: the New thread page and Delete worktree agent, from the same fixture.
extension PreviewTests {
    /// A host serving `state` on its local socket, and `workspace`'s app taking it as its own.
    private func adoptHost(_ state: ShepherdState, into workspace: PreviewWorkspace) async throws -> ScratchServer {
        let host = try ScratchServer(dir: try makeScratchDirectory("host"))
        host.server.serveThreads(ThreadHosting(defaults: {
            ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                   worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
        }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        _ = host.server.serveAgentQueries(WorktreeHosting(defaults: { .init(generateDescription: false) },
                                                          deleteAgent: { id, _ in try await host.server.deleteAgent(id) }))
        try await host.server.putState(state)
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let vm = workspace.vm
        vm.connectLocalHost(socket: socket, token: token)
        try await eventuallyOnMain("the host's workspace as the app's", timeout: .seconds(30)) { vm.state.agents == host.server.state.agents }
        return host
    }

    func expectSameRenders(_ a: String, _ b: String) throws {
        let directory = try #require(Preview.directory)
        for mode in ["light", "dark"] {
            #expect(try Data(contentsOf: directory.appendingPathComponent("\(a)-\(mode).png"))
                == Data(contentsOf: directory.appendingPathComponent("\(b)-\(mode).png")), "\(a) and \(b) differ in \(mode)")
        }
    }

    @Test func localHostNewThreadAndWorktreeDeleteMatchInProcess() async throws {
        let repo = try makeScratchRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let checkout = try GitWorktree.add(repo: repo.path, branch: "agent/fix-login")
        try "draft\n".write(to: URL(fileURLWithPath: checkout).appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let space = Space(name: "acme-web", path: repo.path)
        let id = AgentID()
        let pane = LeafPane(cwd: checkout, agentID: id)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: id, name: "Fix the login redirect", spaceID: space.id, tabID: tab.id, paneID: pane.id, status: .done,
                          nameIsFinal: true, worktreeBranch: "agent/fix-login", worktreeBase: "main", worktreePath: checkout)
        let fixture = ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
        // A made-up path in place of this machine's scratch folder.
        let shownPath = "~/Developer/acme-web-worktrees/agent-fix-login"

        for mode in ["in-process", "client"] {
            let workspace = try PreviewWorkspace(ownsWorkspace: mode == "in-process")
            var host: ScratchServer?
            defer { workspace.stop(); host?.stop() }
            if mode == "in-process" { try await workspace.seed(fixture) } else { host = try await adoptHost(fixture, into: workspace) }
            let vm = workspace.vm
            vm.openNewThread(in: space.id)
            try await eventuallyOnMain("the New thread page's defaults") { !vm.newThread.loadingDefaults }
            try await Preview.render("this-mac-new-thread-\(mode)", size: CGSize(width: 1280, height: 760)) { RootView(vm: vm) }
            // The place menu open: This Mac's "No space" first, then its space.
            #expect(NewThreadPlaces.sections(NewThreadState.hosts(vm), chosen: vm.newThread.place).flatMap(\.options).map(\.title)
                == ["No space", "acme-web"])
            try await Preview.render("this-mac-new-thread-places-\(mode)", size: CGSize(width: 1000, height: 700)) {
                NewThreadPage(vm: vm, chrome: PageHeaderChrome(), placeOpen: true)
            }

            let dialog = WorktreeDeleteDialog(vm: vm, agent: agent)
            try await Preview.render("this-mac-delete-worktree-\(mode)", size: CGSize(width: AppLayout.confirmSheetWideWidth, height: 420),
                                     untilGone: "Checking", showing: "Unreconciled work") {
                WorktreeDeleteDialog(agent: agent, path: shownPath, settings: vm.settings, probe: dialog.probe, cancel: {}, delete: { _ in })
            }
        }
        try expectSameRenders("this-mac-new-thread-in-process", "this-mac-new-thread-client")
        try expectSameRenders("this-mac-new-thread-places-in-process", "this-mac-new-thread-places-client")
        try expectSameRenders("this-mac-delete-worktree-in-process", "this-mac-delete-worktree-client")
    }
}

/// Designs, automations and Projects keep the background host's section on their pages while the
/// app takes the rest of its workspace as its own (`ShepherdViewModel.mirrored`): the same pages as
/// with This Mac shown as a host (`SHEPHERD_THIS_MAC_LOCAL=0`), from the same host.
extension PreviewTests {
    @Test func localHostFeaturePagesMatchThisMacAsAHost() async throws {
        let pageSize = CGSize(width: 1440 - AppLayout.sidebarDefaultWidth, height: 848)
        let host = try ScratchServer(dir: try makeScratchDirectory("host"))
        defer { host.stop() }
        host.server.serveThreads(ThreadHosting(defaults: {
            ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                   worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
        }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        let space = Space(name: "acme-web", path: host.dir.path)
        let runs = Space(name: "Automations", path: "~", hidden: true)
        func agent(_ name: String, in space: Space, order: Int, status: AgentStatus = .idle) -> (Agent, ShepherdCore.Tab) {
            let id = AgentID()
            let pane = LeafPane(cwd: space.path, agentID: id)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: order, layout: .leaf(pane))
            return (Agent(id: id, name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id, status: status, nameIsFinal: true), tab)
        }
        let thread = agent("Fix the checkout total rounding", in: space, order: 0)
        let watcher = agent("Triage new issues", in: runs, order: 0, status: .blocked)
        var drawer = agent("Checkout funnel dashboard", in: space, order: 1)
        let design = Design(name: "Checkout funnel dashboard", agentID: drawer.0.id, createdAt: 1_000)
        drawer.0.designID = design.id
        let automation = Automation(name: "Triage new issues", prompt: "Look at what came in overnight and say what needs a person.",
                                    cwd: "~/Developer/acme-web", enabled: false, agentID: watcher.0.id)
        let records = [thread, watcher, drawer]
        try await host.server.putState(ShepherdState(spaces: [space, runs], tabs: records.map(\.1), agents: records.map(\.0),
                                                     automations: [automation]))
        host.server.setProjectsEnabled(true)
        guard case .project(let project) = try await host.server.logicalProjects(
            .create(projectID: ProjectID(), name: "Release 2.4", goal: "Ship the 2.4 release notes and changelog.")) else {
            Issue.record("no Project"); return
        }
        _ = try await host.server.createDesign(design)
        try await DesignFixtures.draw(DesignFixtures.checkout, in: design.id, on: host.server, perRow: 3)
        host.server.designSystems.register(ShepherdDesignSystem.builtIn())
        host.server.setDesignsServed(true)
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        for mode in ["host", "local"] {
            let workspace = try PreviewWorkspace(ownsWorkspace: false)
            defer { workspace.stop() }
            workspace.settings.designToolEnabled = true
            workspace.settings.projectsEnabled = true
            let vm = workspace.vm
            vm.designNetwork = .none
            vm.designLiveCap = 0
            let connection = mode == "local" ? vm.connectLocalHost(socket: socket, token: token)
                : vm.remoteHosts.addLocalHost(name: NewThreadPlaces.thisMac, socket: socket, token: token)
            try await eventuallyOnMain("This Mac's host with its designs, automation and Project", timeout: .seconds(30)) {
                connection.phase == .connected && connection.supportsDesigns && connection.supportsLogicalProjects
                    && connection.state.automations.count == 1 && connection.state.projects.count == 1
            }
            if mode == "local" {
                try await eventuallyOnMain("the ordinary thread as the app's own") { vm.state.agents.map(\.id) == [thread.0.id] }
                #expect(vm.remoteHosts.connections.isEmpty)
            }

            await vm.loadAutomationPageRuns()
            vm.automationsPageSelection = AutomationKey(host: connection.id, automation: automation.id)
            try await Preview.render("this-mac-automations-\(mode)", size: pageSize) { AutomationsDestination(vm: vm) }

            await vm.loadRemoteDesigns()
            try await Preview.render("this-mac-designs-\(mode)", size: pageSize, ready: {
                vm.remoteDesignRenderings[connection.id]?.thumbnails.image(design.id) != nil
            }) { DesignsDestination(vm: vm) }

            vm.openLogicalProject(LogicalProjectRef(home: .host(connection.id), id: project.id))
            #expect(vm.shownDestination == .project)
            try await Preview.render("this-mac-project-\(mode)", size: pageSize) { LogicalProjectDestination(vm: vm) }
            for connection in vm.remoteHosts.allConnections { vm.remoteHosts.removeHost(id: connection.id) }
        }
        try expectSameRenders("this-mac-automations-host", "this-mac-automations-local")
        try expectSameRenders("this-mac-designs-host", "this-mac-designs-local")
        try expectSameRenders("this-mac-project-host", "this-mac-project-local")
    }
}
