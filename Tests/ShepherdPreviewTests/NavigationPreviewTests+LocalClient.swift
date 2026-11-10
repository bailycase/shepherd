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
    func adoptHost(_ state: ShepherdState, into workspace: PreviewWorkspace) async throws -> ScratchServer {
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

/// Automations as This Mac's own (always-host 3): the same fixture, in process and as the
/// background host's client, renders the same Automations page, run log and sidebar.
extension PreviewTests {
    @Test func localHostAutomationsMatchInProcess() async throws {
        let pageSize = CGSize(width: 1440 - AppLayout.sidebarDefaultWidth, height: 848)
        let folder = try makeScratchDirectory("acme-web")
        let space = Space(name: "acme-web", path: folder.path)
        let runs = Space(name: "Automations", path: "~", hidden: true)
        // Each thread last active two hours ago, so both renders read the same ages.
        let active = (Date().timeIntervalSince1970 - 7_200) * 1000
        func agent(_ name: String, in space: Space, order: Int, status: AgentStatus) -> (Agent, ShepherdCore.Tab) {
            let id = AgentID()
            let pane = LeafPane(cwd: space.path, agentID: id)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: order, layout: .leaf(pane))
            var agent = Agent(id: id, name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id, status: status, nameIsFinal: true)
            agent.lastActiveAt = active
            return (agent, tab)
        }
        let thread = agent("Fix the checkout total rounding", in: space, order: 0, status: .done)
        let triage = agent("Triage new issues", in: runs, order: 0, status: .blocked)
        let bumps = agent("Weekly dependency bumps", in: runs, order: 1, status: .working)
        // A made-up folder in place of this machine's scratch one.
        let shown = "~/Developer/acme-web"
        let cleanup = Automation(name: "Stale branch cleanup", prompt: "List branches merged a month ago.", cwd: shown, enabled: false)
        var past = agent("Clean up merged branches", in: space, order: 1, status: .done)
        past.0.automationOrigin = AutomationOrigin(automationID: cleanup.id)
        // Off, so neither owner starts a run of its own.
        let automations = [
            Automation(name: "Triage new issues", prompt: "Look at what came in overnight and say what needs a person.",
                       cwd: shown, enabled: false, agentID: triage.0.id),
            Automation(name: "Weekly dependency bumps", prompt: "Bump the dependencies and open a pull request.",
                       cwd: shown, enabled: false, agentID: bumps.0.id),
            cleanup,
        ]
        let records = [thread, triage, bumps, past]
        let fixture = ShepherdState(spaces: [space, runs], tabs: records.map(\.1), agents: records.map(\.0), automations: automations)
        // The page's clocks tick from when each owner logged its runs, so the page's fixture has
        // none: both watchers ask, and the off automation never ran.
        var asking = bumps
        asking.0.status = .blocked
        let page = ShepherdState(spaces: [space, runs], tabs: [thread.1, triage.1, asking.1], agents: [thread.0, triage.0, asking.0],
                                 automations: [automations[0], automations[1],
                                               Automation(name: "Stale branch cleanup", prompt: "List branches merged a month ago.",
                                                          cwd: shown, enabled: false)])
        // A run's start reads to the minute: not across one between the two renders.
        let second = Calendar.current.component(.second, from: Date())
        if second >= 50 { try await Task.sleep(for: .seconds(61 - second)) }

        for mode in ["in-process", "client"] {
            let workspace = try PreviewWorkspace(ownsWorkspace: mode == "in-process")
            var host: ScratchServer?
            defer { workspace.stop(); host?.stop() }
            if mode == "in-process" { try await workspace.seed(fixture) } else { host = try await adoptHost(fixture, into: workspace) }
            let vm = workspace.vm
            await vm.loadAutomationPageRuns()
            // The two watchers' runs and the past run's thread, each open.
            try await eventuallyOnMain("the run log of each live run") {
                vm.openAutomationRuns.count == 3 && vm.localAutomationRuns.values.joined().count == 3
            }
            #expect(vm.automationHosts.map(\.id) == [PageHost.localID])
            #expect(vm.blockedCount == 1, "the watcher asking counts in Needs you")
            try await Preview.render("this-mac-automations-sidebar-\(mode)", size: CGSize(width: 260, height: 520)) {
                SidebarView(vm: vm).frame(width: 260).background(Color.sh.bgBase)
            }

            if let host { try await host.server.putState(page) } else { try await workspace.server.putState(page) }
            try await eventuallyOnMain("the page's fixture and its runs") {
                vm.state.automations.map(\.id) == page.automations.map(\.id) && vm.state.agents.map(\.status) == page.agents.map(\.status)
                    && vm.openAutomationRuns.values.map(\.result) == [.needsYou, .needsYou]
            }
            await vm.loadAutomationPageRuns()
            try await Preview.render("this-mac-automations-page-\(mode)", size: pageSize) { AutomationsDestination(vm: vm) }
            vm.automationsPageSelection = AutomationKey(host: PageHost.localID, automation: automations[0].id)
            try await Preview.render("this-mac-automation-runs-\(mode)", size: pageSize) { AutomationsDestination(vm: vm) }
        }
        try expectSameRenders("this-mac-automations-page-in-process", "this-mac-automations-page-client")
        try expectSameRenders("this-mac-automation-runs-in-process", "this-mac-automation-runs-client")
        try expectSameRenders("this-mac-automations-sidebar-in-process", "this-mac-automations-sidebar-client")
    }
}

/// The whole sidebar as This Mac's own (always-host 5): every thread kind, one that can't start
/// for want of a sign-in (its pi stopped before anything here opened it) and the Needs you count,
/// the same in process and as the background host's client.
extension PreviewTests {
    @Test func localHostSidebarMatchesInProcess() async throws {
        try StubPi.installAsEngine()
        let folder = try makeScratchDirectory("acme-web")
        let space = Space(name: "acme-web", path: folder.path)
        let runs = Space(name: "Automations", path: "~", hidden: true)
        let designs = Space.designs()
        // Each thread last active two hours ago, so both renders read the same ages.
        let active = (Date().timeIntervalSince1970 - 7_200) * 1000
        func agent(_ name: String, in space: Space, order: Int, status: AgentStatus,
                   edit: (inout Agent) -> Void = { _ in }) -> (Agent, ShepherdCore.Tab) {
            let id = AgentID()
            let pane = LeafPane(cwd: space.path, agentID: id)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: order, layout: .leaf(pane))
            var agent = Agent(id: id, name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id, status: status, nameIsFinal: true)
            agent.lastActiveAt = active
            edit(&agent)
            return (agent, tab)
        }
        let done = agent("Fix the checkout total rounding", in: space, order: 0, status: .done)
        let asks = agent("Pick the receipt date format", in: space, order: 1, status: .blocked) {
            $0.waitingOn = "Which date format should receipts use?"
            $0.waitingReason = "date format"
        }
        let worktree = agent("Add refund events", in: space, order: 2, status: .done) {
            $0.worktreeBranch = "agent/refund-events"
            $0.worktreeBase = "main"
        }
        let signIn = agent("Write release notes for 2.4", in: space, order: 3, status: .idle)
        let watcher = agent("Triage new issues", in: runs, order: 0, status: .blocked)
        var drawer = agent("Checkout funnel dashboard", in: designs, order: 0, status: .done)
        let design = Design(name: "Checkout funnel dashboard", agentID: drawer.0.id, createdAt: 1_000)
        drawer.0.designID = design.id
        let automation = Automation(name: "Triage new issues", prompt: "Look at what came in overnight and say what needs a person.",
                                    cwd: "~/Developer/acme-web", enabled: false, agentID: watcher.0.id)
        let records = [done, asks, worktree, signIn, watcher, drawer]
        let fixture = ShepherdState(spaces: [space, runs, designs], tabs: records.map(\.1), agents: records.map(\.0),
                                    automations: [automation])
        // pi can't reach a model in the folder: the thread that starts there waits for a sign-in.
        try JSONSerialization.data(withJSONObject: ["exit": "1", "stderr": "No models available. Use /login to log into a provider."])
            .write(to: folder.appendingPathComponent("stub-pi-startup.json"))

        for mode in ["in-process", "client"] {
            let workspace = try PreviewWorkspace(ownsWorkspace: mode == "in-process")
            var host: ScratchServer?
            defer { workspace.stop(); host?.stop() }
            workspace.settings.designToolEnabled = true
            let vm = workspace.vm
            let owner: SessionServer
            if mode == "in-process" {
                try await workspace.seed(fixture)
                _ = try await workspace.server.createDesign(design)
                owner = workspace.server
            } else {
                let made = try ScratchServer(dir: try makeScratchDirectory("host"))
                host = made
                made.server.serveThreads(ThreadHosting(defaults: {
                    ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                           worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
                }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
                try await made.server.putState(fixture)
                _ = try await made.server.createDesign(design)
                made.server.setDesignsServed(true)
                let socket = made.dir.appendingPathComponent("h.sock").path
                let tokenURL = made.dir.appendingPathComponent("remote-token")
                try made.server.startLocalListener(path: socket, tokenURL: tokenURL)
                let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                vm.connectLocalHost(socket: socket, token: token)
                owner = made.server
            }
            try await eventuallyOnMain("the workspace as the app's own", timeout: .seconds(30)) {
                Set(vm.state.agents.map(\.id)) == Set(records.map(\.0.id)) && vm.state.designs.map(\.id) == [design.id]
            }
            // Something other than this window opens the thread: its pi starts and stops.
            Task { _ = try? await owner.nativeThread(agentID: signIn.0.id, request: .snapshot()) }
            try await eventuallyOnMain("the thread to wait for a sign-in", timeout: .seconds(30)) {
                vm.notSignedIn[signIn.0.id] != nil && vm.cannotStart.contains(signIn.0.id)
            }
            #expect(vm.threadStores.existing(for: signIn.0.id) == nil || mode == "in-process")
            #expect(Set(vm.sidebarLists.needsYou.map(\.id)) == [.local(asks.0.id), .local(signIn.0.id), .local(watcher.0.id)])
            #expect(vm.blockedCount == 2, "the badge counts the question and the watcher, as in process")
            try await Preview.render("this-mac-sidebar-\(mode)", size: CGSize(width: 260, height: 620)) {
                SidebarView(vm: vm).frame(width: 260).background(Color.sh.bgBase)
            }
        }
        try expectSameRenders("this-mac-sidebar-in-process", "this-mac-sidebar-client")
    }
}
