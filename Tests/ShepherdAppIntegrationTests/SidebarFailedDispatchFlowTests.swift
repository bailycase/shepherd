import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A thread that has no Mac to run on yet, or failed before it had one, in the sidebar: Delete stops one that hasn't started and removes one that
/// failed (on this Mac, surviving a relaunch), and Try again asks the host to start a failed one again.
@Suite("Sidebar threads with no thread yet", .mainActorExclusive)
@MainActor
struct SidebarFailedDispatchFlowTests {
    static let studio = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!

    static func record(_ state: FleetDispatchState) -> FleetDispatchRecord {
        var record = FleetDispatchRecord(kind: .userThread, parentHostID: UUID(), parentHostName: "MacBook Pro", requestedHost: studio.uuidString,
                                         state: state, failure: state == .failed ? FleetDispatchCode.hostNotReady : nil,
                                         failureDetail: state == .failed ? "bearcli" : nil, title: "test", task: "", repoKey: "github.com/acme/web", createdAt: 1)
        record.updatedAt = Date().timeIntervalSince1970 * 1000
        return record
    }

    @Test func deleteRemovesAFailedThreadOnThisMacAndItStaysGoneAfterARelaunch() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let record = Self.record(.failed)
        vm.fleetPage.update(FleetSnapshot(enabled: true, hostID: UUID(), name: "MacBook Pro", dispatches: [record]))
        #expect(vm.sidebarLists.done.map(\.id) == [.dispatch(record.id)] && vm.sidebarLists.working.isEmpty)

        vm.markAllSidebarDoneSeen()
        #expect(vm.sidebarLists.done.map(\.id) == [.dispatch(record.id)], "marking Done read leaves it: only Try again or Delete ends it")

        vm.deleteDispatch(record.id)
        #expect(vm.sidebarLists.all.isEmpty)
        #expect(vm.fleet.problem == nil, "nothing is asked of the host: its record stays for the Recent work log")

        let relaunched = ShepherdViewModel(pi: app.server.pi, settings: app.settings, keybindings: app.keybindings, themeManager: app.themeManager,
                                           remoteHosts: app.remoteHosts, sidebarDefaults: app.defaults, themeInstaller: { _ in })
        #expect(relaunched.dismissedDispatches == [record.id])
    }

    @Test func deleteOnAThreadThatHasNotStartedAsksTheHostToStopIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let waiting = Self.record(.waitingWake)
        vm.fleetPage.update(FleetSnapshot(enabled: true, hostID: UUID(), name: "MacBook Pro", dispatches: [waiting]))
        #expect(vm.sidebarLists.working.map(\.id) == [.dispatch(waiting.id)])
        vm.deleteDispatch(waiting.id)
        // The host holds no such record, so its refusal is what shows the cancel reached it; the row stays until the host's snapshot says it ended.
        try await eventuallyOnMain("the host's answer to the cancel") { vm.fleet.problem == "This Mac has no such thread." }
        #expect(vm.dismissedDispatches.isEmpty)
    }

    @Test func tryAgainAsksTheHostToStartTheThreadAgain() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        // The host answers a retry of a thread it doesn't hold with its own refusal: the action reached it as `retryDispatch`.
        await vm.retryDispatch(UUID())
        #expect(vm.fleet.problem == "This Mac has no such thread.")
    }
}
