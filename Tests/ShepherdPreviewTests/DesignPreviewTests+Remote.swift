import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// A host's design on this Mac (`designs.v1`): the Designs page listing it under the host's name,
/// and its canvas beside the design agent's chat on the host, drawn here from the files the host
/// served. A real in-process host with its Design tool on, and a stub pi drawing there.
extension DesignPreviewTests {
    @MainActor
    struct RemoteDesignHost {
        let server: ScratchServer
        let port: UInt16
        let token: String
        let design: Design
        let agent: Agent

        init() async throws {
            server = try ScratchServer(dir: try makeScratchDirectory("host"))
            let host = server.server
            let space = Space(name: "acme-web", path: server.dir.path)
            let session = try await host.createSession(params: CreateSessionParams(cwd: server.dir.path, command: StubPi.command, runtime: .rpc))
            let id = AgentID()
            let pane = LeafPane(sessionID: session.id, cwd: space.path, agentID: id)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
            var agent = Agent(id: id, name: "Checkout funnel dashboard", spaceID: space.id, tabID: tab.id, paneID: pane.id,
                              status: .idle, nameIsFinal: true)
            let design = Design(name: "Checkout funnel dashboard", agentID: agent.id, createdAt: 1_000)
            agent.designID = design.id
            try await host.putState(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
            _ = try await host.createDesign(design)
            try await DesignFixtures.draw(DesignFixtures.checkout, in: design.id, on: host, perRow: 3)
            host.setDesignsServed(true)
            let tokenURL = server.dir.appendingPathComponent("remote-token")
            port = try host.startRemoteListener(port: 0, tokenURL: tokenURL)
            token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            self.design = design
            self.agent = agent
        }

        func connect(_ workspace: PreviewWorkspace) async throws -> RemoteHostStore.Connection {
            workspace.vm.remoteHosts.addHost(name: "build-01", host: "127.0.0.1", port: port, token: token)
            let connection = try #require(workspace.vm.remoteHosts.connections.last)
            let host = server.server
            try await eventuallyOnMain("the host to connect with its designs", timeout: .seconds(30)) {
                connection.phase == .connected && connection.state == host.state && connection.supportsDesigns
            }
            return connection
        }
    }

    /// A workspace with the Design tool on and nothing of its own, connected to the host.
    private func remoteWorkspace() async throws -> (PreviewWorkspace, RemoteDesignHost, RemoteHostStore.Connection) {
        let workspace = try PreviewWorkspace()
        workspace.settings.designToolEnabled = true
        workspace.vm.designNetwork = .none
        workspace.vm.designLiveCap = 0
        let host = try await RemoteDesignHost()
        let connection = try await host.connect(workspace)
        return (workspace, host, connection)
    }

    /// The Designs page with a host's design under its name (not drawn: NavDesigns shows This
    /// Mac's alone).
    @Test func designsPageRemote() async throws {
        let (workspace, host, connection) = try await remoteWorkspace()
        defer { workspace.stop(); host.server.stop() }
        let vm = workspace.vm
        await vm.loadRemoteDesigns()
        #expect(vm.remoteDesignSections.map(\.name) == ["build-01"])
        try await Preview.render("page-designs-remote", size: CGSize(width: 1440 - AppLayout.sidebarDefaultWidth, height: 848), ready: {
            vm.remoteDesignRenderings[connection.id]?.thumbnails.image(host.design.id) != nil
        }) {
            DesignsDestination(vm: vm)
        }
    }

    /// A host's design opened on this Mac: the canvas beside its agent's chat on the host, the
    /// boards drawn here from the files the host served.
    @Test func designScreenRemote() async throws {
        let (workspace, host, connection) = try await remoteWorkspace()
        defer { workspace.stop(); host.server.stop() }
        let vm = workspace.vm
        let ref = RemoteDesignRef(hostID: connection.id, designID: host.design.id)
        vm.openRemoteDesign(ref)
        #expect(vm.selectedRemoteAgent == RemoteAgentRef(hostID: connection.id, agentID: host.agent.id))
        let screen = try #require(vm.remoteDesignScreen(ref))
        try await Preview.render("app-window-design-remote", size: CGSize(width: 1440, height: 900), ready: {
            if screen.snapshot != nil, screen.picks.isEmpty { screen.select("A.dc.html") }
            return screen.isDrawn && !screen.picks.isEmpty
        }) {
            RootView(vm: vm)
        }
    }
}
