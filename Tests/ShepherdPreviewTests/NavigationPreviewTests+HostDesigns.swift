import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Designs through the background host (slice 2): a design's thread is back in the sidebar's
/// Recents, and the Designs page and the canvas are the app's own, the same as in process.
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
        }
        try expectSameRenders("this-mac-design-sidebar-in-process", "this-mac-design-sidebar-client")
        try expectSameRenders("this-mac-designs-page-in-process", "this-mac-designs-page-client")
    }
}
