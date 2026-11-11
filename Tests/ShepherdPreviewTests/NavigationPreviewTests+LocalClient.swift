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

/// This Mac's window as the host's client matches the in-process app's, recorded before its
/// server went (always-host 7b): `Baselines/<surface>-<light|dark>.png`, byte for byte.
extension PreviewTests {
    /// The in-process app's renders, in the source tree (excluded from the target's resources).
    nonisolated static let baselines = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Baselines")

    /// `surface`'s light and dark renders are the baseline's bytes. `masking` (pixel rects, from the top left) is text no
    /// later run can repeat: a clock time, a scratch folder's random name. Then the pixels outside those rects match.
    func expectBaseline(_ surface: String, masking masks: [CGRect] = []) throws {
        let directory = try #require(Preview.directory)
        for mode in ["light", "dark"] {
            let name = "\(surface)-\(mode).png"
            let render = try Data(contentsOf: directory.appendingPathComponent(name)), baseline = try Data(contentsOf: Self.baselines.appendingPathComponent(name))
            if masks.isEmpty {
                #expect(render == baseline, "\(name) differs from the in-process baseline")
            } else {
                #expect(try pixels(render, masking: masks) == pixels(baseline, masking: masks), "\(name) differs from the in-process baseline outside \(masks)")
            }
        }
    }

    /// A PNG's RGBA bytes, top row first, with `masks` cleared, and its size.
    private func pixels(_ png: Data, masking masks: [CGRect]) throws -> [Int] {
        let image = try #require(NSBitmapImageRep(data: png)?.cgImage)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for mask in masks {
            for y in max(0, Int(mask.minY))..<min(height, Int(mask.maxY)) {
                for x in max(0, Int(mask.minX))..<min(width, Int(mask.maxX)) { bytes.replaceSubrange((y * width + x) * 4..<(y * width + x + 1) * 4, with: [0, 0, 0, 0]) }
            }
        }
        return [width, height] + bytes.map(Int.init)
    }

    @Test func localHostWorkspaceMatchesTheInProcessBaseline() async throws {
        let space = Space(name: "acme-web", path: try makeScratchDirectory("acme-web").path)
        let names = ["Fix the checkout total rounding", "Upgrade the payments SDK", "Write release notes for 2.4"]
        let records = names.enumerated().map { index, name -> (Agent, ShepherdCore.Tab) in
            let id = AgentID()
            let pane = LeafPane(cwd: space.path, agentID: id)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: index, layout: .leaf(pane))
            return (Agent(id: id, name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id,
                          status: index == 0 ? .working : .done, nameIsFinal: true), tab)
        }
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        try await workspace.seed(ShepherdState(spaces: [space], tabs: records.map(\.1), agents: records.map(\.0)))
        workspace.vm.selectAgent(records[1].0.id)
        try await Preview.render("this-mac", size: CGSize(width: 1280, height: 760)) { RootView(vm: workspace.vm) }
        try expectBaseline("this-mac")
    }
}

/// More of the window as the host's client: the New thread page and Delete worktree agent.
extension PreviewTests {
    @Test func localHostNewThreadAndWorktreeDeleteMatchTheInProcessBaseline() async throws {
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

        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        try await workspace.seed(fixture)
        let vm = workspace.vm
        vm.openNewThread(in: space.id)
        try await eventuallyOnMain("the New thread page's defaults") { !vm.newThread.loadingDefaults }
        try await Preview.render("this-mac-new-thread", size: CGSize(width: 1280, height: 760)) { RootView(vm: vm) }
        // The place menu open: This Mac's "No space" first, then its space.
        #expect(NewThreadPlaces.sections(NewThreadState.hosts(vm), chosen: vm.newThread.place).flatMap(\.options).map(\.title)
            == ["No space", "acme-web"])
        try await Preview.render("this-mac-new-thread-places", size: CGSize(width: 1000, height: 700)) {
            NewThreadPage(vm: vm, chrome: PageHeaderChrome(), placeOpen: true)
        }

        let dialog = WorktreeDeleteDialog(vm: vm, agent: agent)
        try await Preview.render("this-mac-delete-worktree", size: CGSize(width: AppLayout.confirmSheetWideWidth, height: 420),
                                 untilGone: "Checking", showing: "Unreconciled work") {
            WorktreeDeleteDialog(agent: agent, path: shownPath, settings: vm.settings, probe: dialog.probe, cancel: {}, delete: { _ in })
        }
        try expectBaseline("this-mac-new-thread")
        // The space's folder is a scratch repo, its name random each run.
        try expectBaseline("this-mac-new-thread-places", masking: [CGRect(x: 220, y: 452, width: 200, height: 22)])
        try expectBaseline("this-mac-delete-worktree")
    }
}

/// Automations as This Mac's own (always-host 3): the Automations page, run log and sidebar.
extension PreviewTests {
    @Test func localHostAutomationsMatchTheInProcessBaseline() async throws {
        let pageSize = CGSize(width: 1440 - AppLayout.sidebarDefaultWidth, height: 848)
        let folder = try makeScratchDirectory("acme-web")
        let space = Space(name: "acme-web", path: folder.path)
        let runs = Space(name: "Automations", path: "~", hidden: true)
        // Each thread last active two hours ago, so the render reads the baseline's ages.
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
        // Off, so the host starts no run of its own.
        let automations = [
            Automation(name: "Triage new issues", prompt: "Look at what came in overnight and say what needs a person.",
                       cwd: shown, enabled: false, agentID: triage.0.id),
            Automation(name: "Weekly dependency bumps", prompt: "Bump the dependencies and open a pull request.",
                       cwd: shown, enabled: false, agentID: bumps.0.id),
            cleanup,
        ]
        let records = [thread, triage, bumps, past]
        let fixture = ShepherdState(spaces: [space, runs], tabs: records.map(\.1), agents: records.map(\.0), automations: automations)
        // The page's clocks tick from when the host logged its runs, so the page's fixture has
        // none: both watchers ask, and the off automation never ran.
        var asking = bumps
        asking.0.status = .blocked
        let page = ShepherdState(spaces: [space, runs], tabs: [thread.1, triage.1, asking.1], agents: [thread.0, triage.0, asking.0],
                                 automations: [automations[0], automations[1],
                                               Automation(name: "Stale branch cleanup", prompt: "List branches merged a month ago.",
                                                          cwd: shown, enabled: false)])
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        try await workspace.seed(fixture)
        let vm = workspace.vm
        await vm.loadAutomationPageRuns()
        // The two watchers' runs and the past run's thread, each open.
        try await eventuallyOnMain("the run log of each live run") {
            vm.openAutomationRuns.count == 3 && vm.localAutomationRuns.values.joined().count == 3
        }
        #expect(vm.automationHosts.map(\.id) == [PageHost.localID])
        #expect(vm.blockedCount == 1, "the watcher asking counts in Needs you")
        try await Preview.render("this-mac-automations-sidebar", size: CGSize(width: 260, height: 520)) {
            SidebarView(vm: vm).frame(width: 260).background(Color.sh.bgBase)
        }

        try await workspace.server.putState(page)
        try await eventuallyOnMain("the page's fixture and its runs") {
            vm.state.automations.map(\.id) == page.automations.map(\.id) && vm.state.agents.map(\.status) == page.agents.map(\.status)
                && vm.openAutomationRuns.values.map(\.result) == [.needsYou, .needsYou]
        }
        await vm.loadAutomationPageRuns()
        try await Preview.render("this-mac-automations-page", size: pageSize) { AutomationsDestination(vm: vm) }
        vm.automationsPageSelection = AutomationKey(host: PageHost.localID, automation: automations[0].id)
        try await Preview.render("this-mac-automation-runs", size: pageSize) { AutomationsDestination(vm: vm) }
        // A run's row reads the date and time the host logged it, and its result moves with that text's width.
        let runRow = CGRect(x: 875, y: 356, width: 190, height: 26)
        try expectBaseline("this-mac-automations-page", masking: [runRow])
        try expectBaseline("this-mac-automation-runs", masking: [runRow])
        try expectBaseline("this-mac-automations-sidebar")
    }
}

/// The whole sidebar as This Mac's own (always-host 5): every thread kind, one that can't start
/// for want of a sign-in (its pi stopped before anything here opened it) and the Needs you count.
extension PreviewTests {
    @Test func localHostSidebarMatchesTheInProcessBaseline() async throws {
        try StubPi.installAsEngine()
        let folder = try makeScratchDirectory("acme-web")
        let space = Space(name: "acme-web", path: folder.path)
        let runs = Space(name: "Automations", path: "~", hidden: true)
        let designs = Space.designs()
        // Each thread last active two hours ago, so the render reads the baseline's ages.
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

        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        workspace.settings.designToolEnabled = true
        let vm = workspace.vm, server = workspace.server
        try await workspace.seed(fixture)
        _ = try await server.createDesign(design)
        try await eventuallyOnMain("the workspace as the app's own", timeout: .seconds(30)) {
            Set(vm.state.agents.map(\.id)) == Set(records.map(\.0.id)) && vm.state.designs.map(\.id) == [design.id]
        }
        // Something other than this window opens the thread: its pi starts and stops.
        Task { _ = try? await server.nativeThread(agentID: signIn.0.id, request: .snapshot()) }
        try await eventuallyOnMain("the thread to wait for a sign-in", timeout: .seconds(30)) {
            vm.notSignedIn[signIn.0.id] != nil && vm.cannotStart.contains(signIn.0.id)
        }
        #expect(vm.threadStores.existing(for: signIn.0.id) == nil)
        #expect(Set(vm.sidebarLists.needsYou.map(\.id)) == [.local(asks.0.id), .local(signIn.0.id), .local(watcher.0.id)])
        #expect(vm.blockedCount == 2, "the badge counts the question and the watcher")
        try await Preview.render("this-mac-sidebar", size: CGSize(width: 260, height: 620)) {
            SidebarView(vm: vm).frame(width: 260).background(Color.sh.bgBase)
        }
        try expectBaseline("this-mac-sidebar")
    }
}
