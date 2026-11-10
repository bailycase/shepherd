import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Designs through the background host (slices 2 and 2b): a design's thread is back in the sidebar's
/// Recents, and the Designs page, the canvas with a thread's note, a thread's composer with a
/// reference chip and the Git panel are the app's own, the same as in process.
extension PreviewTests {
    @Test func localHostDesignsMatchInProcess() async throws {
        let space = Space(name: "acme-web", path: try makeScratchDirectory("acme-web").path)
        let designs = Space.designs()
        func agent(_ name: String, in space: Space, order: Int, status: AgentStatus) -> (Agent, ShepherdCore.Tab) {
            let id = AgentID()
            let pane = LeafPane(cwd: space.path, agentID: id)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: order, layout: .leaf(pane))
            return (Agent(id: id, name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id, status: status, nameIsFinal: true), tab)
        }
        let thread = agent("Fix the checkout total rounding", in: space, order: 0, status: .done)
        var drawer = agent("Checkout funnel dashboard", in: designs, order: 0, status: .done)
        let design = Design(name: "Checkout funnel dashboard", agentID: drawer.0.id, createdAt: 1_000)
        drawer.0.designID = design.id
        let fixture = ShepherdState(spaces: [space, designs], tabs: [thread.1, drawer.1], agents: [thread.0, drawer.0])
        func draw(_ server: SessionServer) async throws {
            _ = try await server.createDesign(design)
            try await DesignFixtures.draw(Array(DesignFixtures.checkout.prefix(3)), in: design.id, on: server, perRow: 3)
            server.designSystems.register(ShepherdDesignSystem.builtIn())
        }

        let config = try #require(ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"])
        let remoteRoot = try makeScratchDirectory("remote")
        _ = try? git(["config", "--file", config, "user.name", "Ada"], in: remoteRoot)
        _ = try? git(["config", "--file", config, "user.email", "ada@example.com"], in: remoteRoot)
        // One remote path for both: the panel shows its URL.
        let remote = remoteRoot.appendingPathComponent("checkout-design.git")
        let a = try #require(DesignPath("A.dc.html"))
        let card = try #require(DesignElementID(board: a.viewName, tid: 7, path: [1, 1, 0]))
        let viewport = SHCanvasViewport(offset: CGPoint(x: SHDesignMetrics.fitLeading, y: SHDesignMetrics.fitFrameTop), zoom: 0.55)

        for mode in ["in-process", "client"] {
            let workspace = try PreviewWorkspace(ownsWorkspace: mode == "in-process")
            var host: ScratchServer?
            defer { workspace.stop(); host?.stop() }
            workspace.settings.designToolEnabled = true
            let vm = workspace.vm
            vm.designNetwork = .none
            vm.designLiveCap = 0
            if mode == "in-process" {
                try await workspace.seed(fixture)
                try await draw(workspace.server)
            } else {
                let made = try ScratchServer(dir: try makeScratchDirectory("host"))
                host = made
                made.server.serveThreads(ThreadHosting(defaults: {
                    ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                           worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
                }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
                try await made.server.putState(fixture)
                try await draw(made.server)
                made.server.setDesignsServed(true)
                let socket = made.dir.appendingPathComponent("h.sock").path
                let tokenURL = made.dir.appendingPathComponent("remote-token")
                try made.server.startLocalListener(path: socket, tokenURL: tokenURL)
                let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                vm.connectLocalHost(socket: socket, token: token)
            }
            try await eventuallyOnMain("the design and its thread as the app's own", timeout: .seconds(30)) {
                vm.state.designs.map(\.id) == [design.id] && Set(vm.state.agents.map(\.id)) == [thread.0.id, drawer.0.id]
            }

            // The sidebar: the design's thread in Recents beside the ordinary one.
            vm.selectAgent(thread.0.id)
            try await Preview.render("this-mac-design-sidebar-\(mode)", size: CGSize(width: 1280, height: 760)) { RootView(vm: vm) }

            // The Designs page, its card drawn from the owner's folder.
            vm.openDestination(.designs)
            await vm.loadDesignThumbnails()
            vm.designThumbnailVisibility(.local(design.id), visible: true)
            try await Preview.render("this-mac-designs-page-\(mode)", size: CGSize(width: 1280, height: 760), ready: {
                vm.designRendering.thumbnails.image(design.id) != nil
            }) { RootView(vm: vm) }

            // The canvas: a thread's note on A's step card, its card open (RefNoteBack).
            let owner = host?.server ?? workspace.server
            let note = try await owner.designs.addThreadNote(design.id, DesignThreadNote(
                agentID: thread.0.id, thread: thread.0.name, board: a, element: card, label: "Step 1 90%", revision: 1,
                text: "Implemented on `agent/checkout-rounding`. Totals round once, at the end.", createdAt: 1_700_000_000_000))
            vm.selectSidebarRow(.design(design.id))
            let screen = vm.designScreen(design.id)
            await screen.refresh()
            await screen.refreshNotes()
            #expect(screen.threadNotes.map(\.id) == [note.id])
            screen.noteRects[note.id] = CGRect(x: 32, y: 78, width: 396, height: 80)
            screen.openThread(DesignScreenModel.notePinID(note.id))
            try await Preview.render("this-mac-design-note-\(mode)", size: CGSize(width: 1280, height: 760), ready: {
                if screen.viewport != viewport { screen.viewport = viewport }
                return screen.isDrawn && screen.openThreadNote?.id == note.id
            }) { RootView(vm: vm) }

            // A thread's composer with the step card's chip (RefPasted).
            vm.selectAgent(thread.0.id)
            _ = try await vm.attachDesignReference(try #require(DesignReference(designID: design.id, board: a, element: card)), to: thread.0.id)
            try await Preview.render("this-mac-design-ref-chip-\(mode)", size: CGSize(width: 1280, height: 760)) { RootView(vm: vm) }

            // The Git panel: shared, A changed, its preview open (GitDesignChanges).
            try? FileManager.default.removeItem(at: remote)
            _ = try git(["init", "-q", "--bare", "-b", "main", remote.path], in: remoteRoot)
            _ = try await owner.shareDesignWithGit(design.id, url: remote.path, message: "Add checkout funnel design")
            let source = try await owner.designBoard(design.id, path: a).source
            _ = try await owner.writeDesignBoard(design.id, path: a, source: source.replacingOccurrences(of: ">Step 1</div>", with: ">Checkout started · 12,904</div>"),
                                                 baseRevision: nil)
            vm.selectSidebarRow(.design(design.id))
            let git = vm.designGit(design.id)
            vm.refreshDesignGit(design.id)
            try await eventuallyOnMain("the change in the Git state", timeout: .seconds(30)) { git.state?.status.files.count == 1 }
            git.message = "Show absolute counts in the checkout funnel"
            vm.pressDesignGitChip(design.id)
            vm.selectDesignGitFile(design.id, path: "project/A.dc.html")
            try await Preview.render("this-mac-design-git-\(mode)", size: CGSize(width: 1280, height: 760), ready: {
                if screen.viewport != viewport { screen.viewport = viewport }
                return screen.isDrawn && git.preview != nil && git.state?.status.fetchedAt != nil && !git.working
            }) { RootView(vm: vm) }
        }
        try expectSameRenders("this-mac-design-sidebar-in-process", "this-mac-design-sidebar-client")
        try expectSameRenders("this-mac-designs-page-in-process", "this-mac-designs-page-client")
        try expectSameRenders("this-mac-design-note-in-process", "this-mac-design-note-client")
        try expectSameRenders("this-mac-design-ref-chip-in-process", "this-mac-design-ref-chip-client")
        try expectSameRenders("this-mac-design-git-in-process", "this-mac-design-git-client")
    }
}
