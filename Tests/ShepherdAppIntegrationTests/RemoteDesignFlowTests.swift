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
        let task = screen.move(SHBoardMove(board: "B.dc.html", offset: CGSize(width: 40, height: 20), ended: true))
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

        // The shared Comments list reveals the board and resolves through this host, too.
        let comment = try #require(kept.comments.first)
        screen.resized(CGSize(width: 900, height: 800))
        screen.viewport = SHCanvasViewport(offset: CGPoint(x: -10_000, y: -10_000), zoom: 1)
        screen.revealComment(comment.id)
        #expect(screen.selectedWhole == [board] && screen.visibleBoards.contains(board))
        #expect(screen.openThread?.id == comment.id)
        await screen.resolve(comment.id)?.value
        #expect(try await hostServer.designComments(design.id).comments.first?.isOpen == false)
        #expect(screen.openCards.isEmpty && screen.openThread == nil)

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

    /// A host's design whose agent is gone opens here: the host's app starts a fresh one
    /// (`design.agent.v1`). Duplicate, Export's files and the host's New design go through it too.
    @Test func aHostsDesignWithoutAnAgentOpensAndChangesThroughTheHost() async throws {
        try StubPi.installAsEngine()
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let (vm, connection, _, _) = try await host(local, remote)
        let hostServer = remote.host.server
        let bare = Design(name: "Onboarding", createdAt: 2_000)
        _ = try await hostServer.createDesign(bare)
        try await DesignFixtures.draw(Array(DesignFixtures.checkout.prefix(1)), in: bare.id, on: hostServer)
        try await eventuallyOnMain("the design to reach this Mac") { connection.state.designs.contains { $0.id == bare.id } }
        #expect(connection.supportsDesignCapability(RemoteProtocol.designAgentCapability))

        let ref = RemoteDesignRef(hostID: connection.id, designID: bare.id)
        vm.openRemoteDesign(ref)
        try await eventuallyOnMain("the host's fresh agent on screen", timeout: .seconds(30)) {
            vm.selectedRemoteAgent.flatMap { vm.remoteDesign(drawnBy: $0) }?.design.id == bare.id
        }
        #expect(hostServer.state.agents.filter { $0.designID == bare.id }.count == 1)
        #expect(vm.remoteActionError == nil)

        // Export draws from this Mac's synced copy.
        let files = try await connection.designs.source(bare.id).exportFiles(boards: [try #require(DesignPath("A.dc.html"))])
        #expect(files.members.map(\.rawValue) == ["A.dc.html"] && files.sources.count == 1)

        // Duplicate is the host's own; its copy lists with the host's designs.
        vm.performDesignMenu(.duplicate, on: .remote(ref))
        try await eventuallyOnMain("the copy on the host") { hostServer.state.designs.contains { $0.name == "Onboarding copy" } }

        // New design with the host chosen makes it there, and its canvas opens here.
        vm.openNewDesign()
        vm.newDesign.choose(host: connection.id)
        vm.newDesign.brief = "A settings page"
        #expect(vm.newDesign.blocker(vm) == nil)
        vm.newDesign.send(vm)
        try await eventuallyOnMain("the host's new design on screen", timeout: .seconds(30)) {
            !vm.newDesign.starting && vm.selectedRemoteAgent.flatMap { vm.remoteDesign(drawnBy: $0) }?.design.name != bare.name
                && vm.selectedRemoteAgent.flatMap { vm.remoteDesign(drawnBy: $0) } != nil
        }
        #expect(hostServer.state.designs.count == 4)
    }

    /// Implement in a thread… from a host's design sends the piece to one of that host's threads
    /// (`design.references.v1`): the host pins it, resolves and fences it, and its pi reads it.
    @Test func aHostsDesignPieceGoesToTheHostsOwnThread() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        local.settings.designToolEnabled = true
        remote.host.settings.designToolEnabled = true
        let space = Fixture.space(path: remote.host.dir.path)
        let log = remote.host.dir.appendingPathComponent("pi.log")
        let thread = try await remote.host.liveAgent("Build checkout", in: space, log: log)
        var drawer = Fixture.agent("Checkout", in: space, order: 1)
        let design = Design(name: "Checkout", agentID: drawer.agent.id, createdAt: 1_000)
        drawer.agent.designID = design.id
        let hostVM = try await remote.host.start(with: Fixture.state(spaces: [space], agents: [thread, drawer]))
        hostVM.designNetwork = .none
        _ = try await remote.host.server.createDesign(design)
        try await DesignFixtures.draw(Array(DesignFixtures.checkout.prefix(1)), in: design.id, on: remote.host.server)
        let vm = try await local.start(with: ShepherdState())
        vm.designNetwork = .none
        vm.designLiveCap = 0
        let connection = try await remote.connect(local.remoteHosts, name: "build-01")
        #expect(connection.supportsDesignCapability(RemoteProtocol.designReferencesCapability))

        let ref = RemoteDesignRef(hostID: connection.id, designID: design.id)
        let screen = try #require(vm.remoteDesignScreen(ref))
        #expect(screen.referenceActions != nil)
        await screen.refresh()
        #expect(vm.designMenu(.remote(ref), context: .toolbar).items.contains { $0.action == .implement })
        screen.implementSelection(designName: design.name)
        let model = try #require(vm.implementSheet)
        #expect(model.hostID == connection.id && model.hostName == "build-01")
        #expect(model.threads.map(\.id) == [thread.agent.id], "the host's own thread, never its design's agent")
        try await eventuallyOnMain("the host to pin the piece", timeout: .seconds(30)) { model.prepared != nil || model.error != nil }
        #expect(model.error == nil)
        #expect(model.prepared?.reference.host == .remote(connection.id))

        model.message = "Build the checkout"
        model.opensThread = true
        let before = AppHarness.prompts(in: log).count
        vm.sendImplementSheet(model)
        try await eventuallyOnMain("the send", timeout: .seconds(60)) { vm.implementSheet == nil || model.error != nil }
        #expect(model.error == nil)
        try await eventuallyAsync("the host's pi to get the message", timeout: .seconds(60)) { AppHarness.prompts(in: log).count > before }
        let prompt = try #require(AppHarness.prompts(in: log).last)
        let record = try #require(DesignReferenceFence.parse(prompt)?.records.first)
        #expect(record.design == "Checkout" && DesignReference(string: record.ref)?.host == .local)
        #expect(vm.selectedRemoteAgent == RemoteAgentRef(hostID: connection.id, agentID: thread.agent.id))

        // The host's thread has chips and the @ picker for the host's designs, named as the host sees them.
        let target = RemoteAgentRef(hostID: connection.id, agentID: thread.agent.id)
        let chips = try #require(vm.remoteDesignReferenceChips(for: target))
        #expect(vm.remoteDesignReferenceChips(for: RemoteAgentRef(hostID: connection.id, agentID: drawer.agent.id)) == nil,
                "a design's own chat has none")
        await chips.loadCatalog()
        let row = try #require(chips.catalog?.designs.first)
        #expect(row.title == "Checkout" && row.reference.host == .local)
        chips.io.wantPictures(.design(design.id, name: design.name))
        try await eventuallyOnMain("the design's boards in the picker", timeout: .seconds(30)) { chips.catalog?.boards[design.id]?.isEmpty == false }
        let board = try #require(chips.catalog?.boards[design.id]?.first)
        try await chips.io.attach(board.reference)
        let store = vm.remoteThreadStores.store(for: target)
        let attached = try #require(store.attachedReferences.first)
        #expect(attached.reference.host == .local && attached.reference.revision != nil && attached.reference.board == board.reference.board)
        // Another Mac's design never joins it.
        await #expect(throws: DesignReferenceFailure.self) {
            try await chips.io.attach(DesignReference(host: .remote(UUID()), designID: design.id)!)
        }
        store.detachReference(attached.id)

        // A sent chip reads what the host kept.
        let payloadID = try #require(record.payloadID)
        await chips.loadSent(payloadID)
        #expect(chips.sent[payloadID]?.crumbs.first == "Checkout")
        #expect(chips.sent[payloadID]?.freshness == .current)
    }

    /// "Build one from a repo" in a host's space, from this Mac: the host starts the build, its
    /// agent's thread opens here, and the host's section shows it building until it writes one.
    @Test func aHostsSystemIsBuiltFromHere() async throws {
        try StubPi.installAsEngine()
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let (vm, connection, _, _) = try await host(local, remote)
        let hostServer = remote.host.server
        let space = try #require(connection.state.spaces.first)
        await vm.loadRemoteDesigns()
        let section = try #require(vm.remoteDesignSections.first)
        #expect(section.projects?.map(\.id) == [space.id], "the host's spaces, for its Build tile")

        vm.buildRemoteSystem(host: connection.id, in: space.id)
        try await eventuallyOnMain("the host's build agent on screen", timeout: .seconds(30)) {
            guard let selected = vm.selectedRemoteAgent, let agent = connection.state.agents.first(where: { $0.id == selected.agentID }) else { return false }
            return connection.state.designs.contains { $0.buildsSystem && $0.id == agent.designID && $0.sourceSpaceID == space.id }
        }
        #expect(hostServer.state.designs.filter(\.buildsSystem).count == 1)
        await vm.loadRemoteDesigns()
        let building = try #require(vm.remoteDesignSections.first?.systems.first)
        guard case .remoteBuild = building.id else { Issue.record("expected the build's card, got \(building.id)"); return }
        #expect(building.source == "\(space.name) · building")

        // A second build of the same space answers the one there.
        let existing = try #require(hostServer.state.designs.first { $0.buildsSystem })
        let again = try await connection.designs.request(.buildSystem(spaceID: space.id))
        guard case .created(let answered, _) = again else { Issue.record("expected the build, got \(again)"); return }
        #expect(answered == existing.id && hostServer.state.designs.filter(\.buildsSystem).count == 1)

        // Its card's Delete stops and deletes it on the host, after the build's dialog.
        #expect(vm.designSystemMenu(building.id).items.contains { $0.action == .deleteSystem })
        vm.requestDesignSystemDelete(building.id)
        let request = try #require(vm.designSystemDeleteRequest)
        #expect(request.words.confirm == "Stop and delete")
        vm.confirmDesignSystemDelete(request)
        try await eventuallyOnMain("the build gone on the host") { !hostServer.state.designs.contains(where: \.buildsSystem) }
        #expect(vm.designToast == nil)
    }

    /// A Claude Design ZIP from this Mac is imported on the host as its own Import does: the
    /// design, its agent started there; the same project again comes in as a copy.
    @Test func aProjectIsImportedOnTheHost() async throws {
        try StubPi.installAsEngine()
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let (_, connection, _, _) = try await host(local, remote)
        let hostServer = remote.host.server
        #expect(connection.supportsDesignCapability(RemoteProtocol.designImportCapability))
        let zip = try makeScratchDirectory("zip").appendingPathComponent("checkout-funnel.zip")
        try TestZip.make(DesignLifecycleFlowTests.project()).write(to: zip)

        let (design, agent) = try await connection.designs.importProject(file: zip)
        let made = try #require(hostServer.state.designs.first { $0.id == design })
        #expect(made.name == "Checkout funnel" && made.importedFrom != nil)
        #expect(agent != nil)
        try await eventuallyOnMain("its agent on the host") { hostServer.state.agents.contains { $0.designID == design } }

        let (copy, _) = try await connection.designs.importProject(file: zip)
        #expect(copy != design)
        #expect(hostServer.state.designs.first { $0.id == copy }?.name != made.name, "the same project again comes in as a copy")
    }
}
