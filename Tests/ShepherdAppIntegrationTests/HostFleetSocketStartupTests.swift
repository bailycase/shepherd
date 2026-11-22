import Foundation
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import ShepherdSessions

@Suite("Local socket before Fleet startup", .mainActorExclusive)
@MainActor
struct HostFleetSocketStartupTests {
    @Test func theLocalSocketAnswersBeforeFleetStartsEvenIfFleetFails() async throws {
        let h = try ScratchServer()
        defer { h.stop() }
        // Fleet cannot create its data directory over a file.
        try Data().write(to: h.dir.appendingPathComponent("fleet"))
        let socket = h.dir.appendingPathComponent("host.sock").path
        let socketAtFleetStart = Locked<Bool?>(nil)
        await blocking {
            h.server.configureFleet(clock: nil, pressure: { queue, facts in
                socketAtFleetStart.withValue { $0 = RemoteHostClient.localSocketAnswers(socket) }
                return FleetPressure(queue: queue, clock: Date.init, localFacts: facts)
            })
        }
        let host = ShepherdHost.Services(settings: AppSettings(store: ScratchDefaults()),
                                        mcpStore: MCPStore(dependencies: .app(pi: h.server.pi, openURL: { _ in }, copy: { _ in })),
                                        notifications: AgentNotifications(activate: {}), keepsAgentsRunning: { nil })
        await host.serve(h.server, socket: socket, recovering: false)
        try await eventuallyOnMain("Fleet startup to be attempted") { socketAtFleetStart.current != nil }
        #expect(socketAtFleetStart.current == true)
        #expect(await h.server.queue.testHop { h.server.fleet == nil })
        #expect(RemoteHostClient.localSocketAnswers(socket))
    }
}
