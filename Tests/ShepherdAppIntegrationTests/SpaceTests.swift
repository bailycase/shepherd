import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Adding, renaming, and deleting spaces through the view model.
@Suite("Spaces", .mainActorExclusive)
@MainActor
struct SpaceTests {
    @Test func addingASpaceWithoutAnAgentCreatesOnlyTheSpaceAndSelectsIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let checkout = app.dir.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)

        let id = try #require(await vm.addSpace(at: checkout, createInitialAgent: false))

        #expect(app.server.state.spaces.map(\.id) == [id])
        #expect(app.server.state.spaces.first?.name == "checkout")
        #expect(app.server.state.tabs.isEmpty && app.server.state.agents.isEmpty)
        #expect(vm.selectedSpaceID == id && vm.selectedAgentID == nil)
    }

    @Test func aCheckoutWithAWorktreeOperationRunningCannotBecomeASpace() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        vm.hostBusyWorktrees.insert(canonical(app.dir))

        #expect(await vm.addSpace(at: app.dir, createInitialAgent: false) == nil)

        #expect(vm.remoteActionError != nil)
        #expect(app.server.state.spaces.isEmpty)
    }

    @Test func renamingASpaceChangesOnlyItsLabel() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("repo", path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        vm.renameSpace(space.id, to: "  Billing service ")
        await app.settle()

        #expect(app.server.state.spaces.first?.name == "Billing service")
        #expect(app.server.state.spaces.first?.path == space.path)
        #expect(app.server.state.tabs.first?.layout == agent.tab.layout)
    }

    @Test func deletingASpaceStopsItsAgentsButKeepsSpacesNestedInIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Fixture.space("parent", path: app.dir.path)
        let nested = Fixture.space("nested", path: app.dir.appendingPathComponent("nested").path)
        let doomed = try await app.liveAgent("doomed", in: parent)
        let survivor = Fixture.agent("survivor", in: nested)
        let vm = try await app.start(with: Fixture.state(spaces: [parent, nested], agents: [doomed, survivor]))
        vm.selectAgent(doomed.agent.id)

        vm.deleteSpace(parent.id)
        await app.settle()

        #expect(app.server.state.spaces.map(\.id) == [nested.id])
        #expect(app.server.state.agents.map(\.id) == [survivor.agent.id])
        #expect(app.server.state.tabs.map(\.id) == [survivor.tab.id])
        #expect(vm.selectedSpaceID == nested.id && vm.selectedAgentID == survivor.agent.id)
        let server = app.server, session = try #require(doomed.piPane.sessionID)
        try await eventuallyAsync("the deleted space's pi to stop") { await server.sessionInfo(sessionID: session)?.isAlive != true }
    }
}
