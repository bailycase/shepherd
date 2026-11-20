import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A rename shows in the sidebar row and the header the moment it is submitted, the host stays the
/// only writer, and the outcome reconciles with whatever snapshots arrive.
@Suite("Optimistic thread rename", .mainActorExclusive)
@MainActor
struct ThreadRenameTests {
    private func sidebarTitle(_ vm: ShepherdViewModel, _ row: SidebarRowID) -> String? {
        vm.sidebarLists.all.first { $0.id == row }?.title
    }

    private func header(_ vm: ShepherdViewModel, _ row: SidebarRowID) -> String? {
        hostName(vm, row).map { vm.presentedThreadName(row, hostName: $0) }
    }

    private func hostName(_ vm: ShepherdViewModel, _ row: SidebarRowID) -> String? { vm.hostThreadName(row) }

    @Test func thisMacsRenameShowsAtOnceKeepsTheSnapshotAndSettlesOnTheHost() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("old name", in: space)
        let id = agent.agent.id
        let original = Fixture.state(spaces: [space], agents: [agent])
        let vm = try await app.start(with: original)

        vm.renameAgent(id, to: "  New name \n")

        #expect(sidebarTitle(vm, .local(id)) == "New name")
        #expect(header(vm, .local(id)) == "New name")
        #expect(vm.state.agents.first?.name == "old name", "the host's snapshot is not edited")
        // A snapshot from before the rename lands while it is pending: the person's name stays.
        vm.adopt(original)
        #expect(sidebarTitle(vm, .local(id)) == "New name")

        try await eventuallyOnMain("the host's name to arrive and the overlay to leave") {
            vm.state.agents.first?.name == "New name" && !vm.pendingRenames.isPending(.local(id))
        }
        #expect(app.server.state.agents.first?.nameIsFinal == true)
        #expect(sidebarTitle(vm, .local(id)) == "New name")
    }

    @Test func thisMacsLatestRenameWinsAndTheHostEndsOnIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("old name", in: space)
        let id = agent.agent.id
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        vm.renameAgent(id, to: "First")
        vm.renameAgent(id, to: "Second")
        #expect(sidebarTitle(vm, .local(id)) == "Second")
        vm.renameAgent(id, to: "old name")
        #expect(sidebarTitle(vm, .local(id)) == "old name", "back to the original is a rename too")
        vm.renameAgent(id, to: "Third")

        try await eventuallyOnMain("the host to end on the last name") {
            app.server.state.agents.first?.name == "Third" && !vm.pendingRenames.isPending(.local(id))
        }
        #expect(sidebarTitle(vm, .local(id)) == "Third")
    }

    @Test func thisMacsRefusedRenameShowsTheHostNameAgainAndSaysWhy() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("old name", in: space)
        let id = agent.agent.id
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        // A directory where state.json belongs makes the host's write fail.
        try FileManager.default.removeItem(at: app.scratch.stateURL)
        try FileManager.default.createDirectory(at: app.scratch.stateURL, withIntermediateDirectories: true)

        vm.renameAgent(id, to: "Doomed")
        #expect(sidebarTitle(vm, .local(id)) == "Doomed")

        try await eventuallyOnMain("the refusal to restore the name") { vm.actionError != nil }
        #expect(vm.actionError?.title == "Couldn’t rename the agent")
        #expect(sidebarTitle(vm, .local(id)) == "old name" && header(vm, .local(id)) == "old name")
        #expect(app.server.state.agents.first?.name == "old name")
    }

    @Test func aPairedHostsRenameShowsAtOnceAndReconcilesWithItsSnapshots() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let space = Fixture.space(path: remote.host.dir.path)
        let agent = Fixture.agent("old name", in: space)
        let vm = try await local.start()
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let connection = try await remote.connect(local.remoteHosts)
        let ref = RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id)
        let row = SidebarRowID.remote(ref)
        let before = connection.state

        vm.performRemoteAction(ref, action: .rename(name: "Paired name"))

        #expect(sidebarTitle(vm, row) == "Paired name" && header(vm, row) == "Paired name")
        #expect(connection.state == before, "the host's snapshot is not edited")

        try await eventuallyOnMain("the paired host to take the name and the overlay to leave") {
            remote.host.server.state.agents.first?.name == "Paired name" && connection.state == remote.host.server.state
                && !vm.pendingRenames.isPending(row)
        }
        #expect(sidebarTitle(vm, row) == "Paired name")
        #expect(vm.state.agents.isEmpty, "nothing of the host's thread leaked into This Mac's state")
    }

    @Test func aPairedHostsRefusedRenameRestoresItsNameWithTheReason() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let space = Fixture.space(path: remote.host.dir.path)
        let agent = Fixture.agent("old name", in: space)
        let vm = try await local.start()
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let connection = try await remote.connect(local.remoteHosts)
        let ref = RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id)
        try FileManager.default.removeItem(at: remote.host.scratch.stateURL)
        try FileManager.default.createDirectory(at: remote.host.scratch.stateURL, withIntermediateDirectories: true)

        vm.renameThread(.remote(ref), to: "First")
        vm.renameThread(.remote(ref), to: "Doomed")
        #expect(sidebarTitle(vm, .remote(ref)) == "Doomed")

        try await eventuallyOnMain("the refusal to restore the name") { vm.actionError != nil }
        #expect(sidebarTitle(vm, .remote(ref)) == "old name")
        #expect(remote.host.server.state.agents.first?.name == "old name")
    }
}
