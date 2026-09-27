import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Deleting and importing designs end to end on a real server with the stub pi
/// (DesignLifecycleStates): Delete takes an open design back to Designs and off every surface,
/// its agent stopped, and Undo brings it all back, its agent starting again when it opens; an
/// import fills its card, opens the design and starts its agent; a failed import leaves nothing;
/// the same project again offers a copy; Delete design system keeps what designs installed.
@Suite("Design lifecycle", .mainActorExclusive)
@MainActor
struct DesignLifecycleFlowTests {
    private func start(_ app: AppHarness) async throws -> ShepherdViewModel {
        app.settings.designToolEnabled = true
        let vm = try await app.start(with: ShepherdState())
        vm.designNetwork = .none
        return vm
    }

    /// A design opened on screen, drawn by a live stub agent.
    private func openDesign(_ app: AppHarness, _ vm: ShepherdViewModel, name: String = "Checkout funnel dashboard") async throws -> Design {
        let design = Design(name: name, createdAt: 1_000)
        _ = try await app.server.createDesign(design)
        let board = DesignFixtures.Board(path: "A.dc.html", title: "A · phone", width: 390, height: 844, accent: "#4f46e5")
        _ = try await app.server.writeDesignBoard(design.id, path: DesignPath(board.path)!, source: DesignFixtures.source(board))
        _ = try await app.server.updateDesignIndex(design.id, patch: DesignFixtures.layout([board]))
        try await eventuallyOnMain("the design to arrive") { vm.state.designs.contains { $0.id == design.id } }
        vm.openDesign(design.id)
        try await eventuallyOnMain("its agent on screen") { vm.shownDesign?.id == design.id }
        return try #require(vm.state.designs.first { $0.id == design.id })
    }

    @Test func deletingAnOpenDesignGoesBackToDesignsAndUndoBringsItAllBack() async throws {
        try StubPi.installOnPath()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await start(app)
        let design = try await openDesign(app, vm)
        let agent = try #require(vm.selectedAgent)
        try await eventuallyOnMain("the agent's pi to run") { vm.sessions.liveSession(forPane: agent.paneID!) != nil }
        let session = try #require(vm.sessions.liveSession(forPane: agent.paneID!))

        vm.requestDesignDelete(.local(design.id))
        try await eventuallyOnMain("the dialog") { vm.designDeleteRequest != nil }
        let request = try #require(vm.designDeleteRequest)
        #expect(request.words.title == "Delete “Checkout funnel dashboard”?")
        #expect(request.words.lines.first?.lead == "1 board")
        vm.confirmDesignDelete(request)

        try await eventuallyOnMain("the toast") { vm.designToast != nil }
        #expect(vm.shownDestination == .designs, "the window goes back to Designs")
        #expect(!vm.state.designs.contains { $0.id == design.id })
        #expect(!vm.state.agents.contains { $0.id == agent.id })
        #expect(!vm.designsPage.cards.contains { $0.id == design.id })
        #expect(!vm.sidebarLists.recents.contains { $0.id == .design(design.id) })
        let toast = try #require(vm.designToast)
        #expect(toast.name == design.name && !toast.isFailure)
        let server = app.server
        try await eventuallyAsync("the agent's process to stop") { await server.sessionInfo(sessionID: session)?.isAlive != true }

        vm.performDesignToast(toast)

        try await eventuallyOnMain("the design back") { vm.state.designs.contains { $0.id == design.id } }
        #expect(vm.designToast == nil)
        #expect(vm.state.agents.contains { $0.id == agent.id && $0.designID == design.id }, "its agent and chat, back")
        #expect(vm.designsPage.cards.contains { $0.id == design.id })
        #expect(vm.sidebarLists.recents.contains { $0.id == .design(design.id) })
        vm.openDesign(design.id)
        try await eventuallyOnMain("its agent on screen again") { vm.shownDesign?.id == design.id && vm.selectedAgentID == agent.id }
        let restored = try #require(vm.state.agents.first { $0.id == agent.id })
        try await eventuallyOnMain("a fresh pi for it") { vm.sessions.liveSession(forPane: restored.paneID!) != nil }
    }

    /// Deleted elsewhere (another device, through this host): the window showing it goes back to
    /// Designs rather than to another thread.
    @Test func aDesignDeletedElsewhereTakesItsWindowBackToDesigns() async throws {
        try StubPi.installOnPath()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await start(app)
        let design = try await openDesign(app, vm)

        _ = try await app.server.deleteDesign(design.id)

        try await eventuallyOnMain("the window back on Designs") { vm.shownDestination == .designs }
        #expect(vm.shownDesign == nil)
    }

    @Test func importingAZipFillsItsCardThenOpensTheDesignWithItsSystem() async throws {
        try StubPi.installOnPath()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await start(app)
        let zip = try makeScratchDirectory("zip").appendingPathComponent("checkout-funnel.zip")
        try TestZip.make(Self.project()).write(to: zip)

        vm.importDesignProject(zip)
        #expect(vm.designImporting?.file == "checkout-funnel.zip")
        #expect(vm.shownDestination == .designs)

        try await eventuallyOnMain("the imported design on screen") { vm.shownDesign?.name == "Checkout funnel" }
        #expect(vm.designImporting == nil && vm.designImportPrompt == nil)
        let design = try #require(vm.shownDesign)
        #expect(design.importedFrom?.file == "checkout-funnel.zip" && design.systemNamespace == "checkout-ds")
        try await eventuallyOnMain("its system in the catalog") { vm.designSystems.summary("checkout-ds") != nil }
        #expect(vm.designsPage.systems.first { $0.name == "Checkout DS" }?.source == "came with Checkout funnel")
        // Its agent's first message has it read the design and change nothing.
        let agent = try #require(vm.selectedAgent)
        let server = app.server
        try await eventuallyAsync("pi to get the import's brief", timeout: .seconds(20)) {
            guard case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: agent.id, request: .snapshot()) else { return false }
            return snapshot.messages.contains { $0.role == "user" && $0.blocks.first?.text.hasPrefix("This design was imported from Claude Design") == true }
        }

        // The same project again: a separate copy under the next number, or the one there is.
        vm.openDestination(.designs)
        vm.importDesignProject(zip)
        try await eventuallyOnMain("the question") { vm.designImportPrompt != nil }
        guard case .again(_, let existing, let copyName)? = vm.designImportPrompt else { Issue.record("expected ImportAgain"); return }
        #expect(existing.id == design.id && copyName == "Checkout funnel 2")
        vm.resolveDesignImport(try #require(vm.designImportPrompt))
        try await eventuallyOnMain("the copy on screen") { vm.shownDesign?.name == "Checkout funnel 2" }
        #expect(vm.state.designs.map(\.name).sorted() == ["Checkout funnel", "Checkout funnel 2"])
        #expect(await app.server.designSystemSummaries().filter { $0.info.namespace.hasPrefix("checkout-ds") }.count == 1)
    }

    @Test func aFailedImportSaysWhyAndLeavesNothing() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await start(app)
        let zip = try makeScratchDirectory("zip").appendingPathComponent("checkout-funnel.zip")
        try TestZip.make([.file("checkout/readme.txt", "no canvas here")]).write(to: zip)

        vm.importDesignProject(zip)

        try await eventuallyOnMain("the failure") { vm.designImportPrompt != nil }
        #expect(vm.designImportPrompt == .failed(file: "checkout-funnel.zip", .notAProject))
        #expect(vm.designImporting == nil && vm.state.designs.isEmpty)
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: app.server.designs.directory.path)) ?? [])
        #expect(leftovers.isEmpty, "nothing half imported")
        vm.cancelDesignImport(try #require(vm.designImportPrompt))
        #expect(vm.designImportPrompt == nil)
    }

    @Test func deletingASystemSaysWhoUsesItAndTheyKeepTheirCopy() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await start(app)
        let design = Design(name: "Events explorer", createdAt: 1_000)
        _ = try await app.server.createDesign(design)
        _ = try await app.server.writeDesignSystem(DesignSystemWrite(namespace: "acme-web", tokens: .object([
            "format": .string("shepherd-tokens/1"), "namespace": .string("acme-web"),
            "colors": .array([.object(["name": .string("--accent"), "value": .string("#4f46e5")])])]), install: true), for: design.id)
        await vm.loadDesignSystems()
        try await eventuallyOnMain("the design drawn in it") { vm.state.designs.first?.systemNamespace == "acme-web" }

        vm.requestDesignSystemDelete(.system("acme-web"))
        let request = try #require(vm.designSystemDeleteRequest)
        #expect(request.words.lines.first?.lead == "Used by 1 design; they keep their copy.")
        vm.confirmDesignSystemDelete(request)

        try await eventuallyOnMain("the system gone") { vm.designSystems.summary("acme-web") == nil }
        #expect(vm.designToast == nil)
        let copy = try #require(app.server.designs.projectFolder(for: design.id)).appendingPathComponent("ds/acme-web/tokens.json")
        #expect(FileManager.default.fileExists(atPath: copy.path), "the design keeps its copy")
    }

    /// A Claude Design export: a folder holding project/ with a canvas, one board and its system.
    static func project() -> [TestZip.Entry] {
        [.file("checkout-funnel/project/canvas.json", #"""
         {"v":3,"title":"Checkout funnel","createdOnFiles":{"at":"2026-09-20T10:00:00Z"},
          "boards":{"Funnel.dc.html":{"x":0,"y":0,"w":390,"h":844,"title":"Funnel"}},"order":["Funnel.dc.html"],
          "designSystems":[{"title":"Checkout DS","namespace":"checkout-ds"}]}
         """#),
         .file("checkout-funnel/project/Funnel.dc.html", DesignFixtures.source(DesignFixtures.checkout[3])),
         .file("checkout-funnel/project/ds/checkout-ds/tokens.json",
               ##"{"format":"shepherd-tokens/1","name":"Checkout DS","namespace":"checkout-ds","colors":[{"name":"--accent","value":"#0f766e"}]}"##)]
    }
}
