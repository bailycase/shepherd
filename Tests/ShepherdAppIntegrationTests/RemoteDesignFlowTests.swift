import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import Testing
@testable import ShepherdApp

/// A host's designs on this Mac (`designs.v1`): listed on the Designs page under the host's
/// name, opened on the same canvas beside the design agent's chat on the host, drawn here from
/// files fetched by hash, and changed through the host.
@Suite("Remote designs", .mainActorExclusive)
@MainActor
struct RemoteDesignFlowTests {
    /// A host with the Design tool on and the checkout design drawn by an agent there.
    private func host(_ local: AppHarness, _ remote: RemoteHostHarness)
        async throws -> (ShepherdViewModel, RemoteHostStore.Connection, Design, AgentID) {
        local.settings.designToolEnabled = true
        remote.host.settings.designToolEnabled = true
        let space = Fixture.space("acme-web", path: remote.host.dir.path)
        var agent = Fixture.agent("Checkout funnel dashboard", in: space)
        let design = Design(name: "Checkout funnel dashboard", agentID: agent.agent.id, createdAt: 1_000)
        agent.agent.designID = design.id
        let vm = try await local.start(with: ShepherdState())
        vm.designNetwork = .none
        vm.designLiveCap = 0
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        _ = try await remote.host.server.createDesign(design)
        try await DesignFixtures.draw(Array(DesignFixtures.checkout.prefix(2)), in: design.id, on: remote.host.server)
        let connection = try await remote.connect(local.remoteHosts, name: "build-01")
        return (vm, connection, design, agent.agent.id)
    }

    @Test func aHostsDesignOpensOnTheCanvasAndChangesThroughTheHost() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let (vm, connection, design, agentID) = try await host(local, remote)
        #expect(connection.supportsDesigns)
        let hostServer = remote.host.server

        // The Designs page lists it under the host's name.
        await vm.loadRemoteDesigns()
        let section = try #require(vm.remoteDesignSections.first)
        #expect(section.name == "build-01")
        #expect(section.cards.map(\.name) == ["Checkout funnel dashboard"])
        #expect(section.cards.first?.detail == "2 boards")
        #expect(vm.designsPage.hosts == [section])

        // Opening it shows its agent's layout on the host, drawn as the design's screen.
        let ref = RemoteDesignRef(hostID: connection.id, designID: design.id)
        vm.openRemoteDesign(ref)
        #expect(vm.selectedRemoteAgent == RemoteAgentRef(hostID: connection.id, agentID: agentID))
        #expect(vm.remoteDesign(drawnBy: RemoteAgentRef(hostID: connection.id, agentID: agentID))?.design.id == design.id)
        let screen = try #require(vm.remoteDesignScreen(ref))
        vm.remoteDesignVisibility(ref, visible: true)
        let opened = try await hostServer.designSnapshot(design.id)
        try await eventuallyOnMain("the canvas to read the host's design") { screen.snapshot == opened }
        #expect(screen.boards.map(\.id) == ["A.dc.html", "B.dc.html"])

        // A board moved here is written on the host, once.
        let task = screen.move(NWBoardMove(board: "B.dc.html", offset: CGSize(width: 40, height: 20), ended: true))
        await task?.value
        #expect(screen.moveWrites == 1)
        let b = try #require(DesignPath("B.dc.html"))
        let moved = try #require(try await hostServer.designSnapshot(design.id).index.boards[b])
        #expect(moved.x == 1280 + 80 + 40 && moved.y == 20)

        // A write on the host is pushed, and the canvas pulls it.
        let rewritten = try await hostServer.writeDesignBoard(design.id, path: try #require(DesignPath("A.dc.html")),
                                                              source: DesignFixtures.source(DesignFixtures.checkout[0], note: "v2"))
        try await eventuallyOnMain("the host's write to reach the canvas") { screen.snapshot?.revision == rewritten.revision }

        // A comment made here is kept on the host and handed to its design agent.
        let board = try #require(DesignPath("A.dc.html"))
        let element = try #require(DesignElementID(board: board.viewName, tid: 2, path: [1]))
        screen.beginComment(on: DesignElementPick(board: board, id: element, rect: CGRect(x: 0, y: 0, width: 1280, height: 800),
                                                  kind: .shape, label: nil, tag: "card"))
        screen.draftText = "Tighten the header."
        await screen.submitComment()?.value
        let kept = try await hostServer.designComments(design.id)
        #expect(kept.comments.map(\.text) == ["Tighten the header."])
        try await eventuallyOnMain("the comment on the canvas") { screen.comments.map(\.id) == kept.comments.map(\.id) }

        // Off screen, the host stops pushing its changes.
        vm.remoteDesignVisibility(ref, visible: false)
        #expect(vm.visibleRemoteDesigns.isEmpty)
    }

    /// A host that doesn't serve designs (its Design tool off) shows none, and turning it on
    /// there brings them without reconnecting.
    @Test func aHostsDesignsFollowItsExperiment() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let (vm, connection, design, _) = try await host(local, remote)

        remote.host.settings.designToolEnabled = false
        try await eventuallyOnMain("the host to stop offering designs") { !connection.supportsDesigns }
        await vm.loadRemoteDesigns()
        #expect(vm.remoteDesignSections.isEmpty)
        #expect(vm.remoteDesign(drawnBy: RemoteAgentRef(hostID: connection.id, agentID: try #require(design.agentID))) == nil,
                "its agent opens as a plain thread")

        remote.host.settings.designToolEnabled = true
        try await eventuallyOnMain("the host to offer designs again") { connection.supportsDesigns }
        await vm.loadRemoteDesigns()
        #expect(vm.remoteDesignSections.first?.cards.map(\.name) == ["Checkout funnel dashboard"])
    }
}
