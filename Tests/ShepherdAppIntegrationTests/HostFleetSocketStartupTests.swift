import Foundation
import ShepherdProtocol
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

    @Test func theFirstLocalHelloIncludesFleetIdentityAndCapabilities() async throws {
        let h = try ScratchServer()
        defer { h.stop() }
        await blocking { h.server.configureFleet(name: "acme-mac", advertises: false) }
        let socket = h.dir.appendingPathComponent("host.sock").path
        let hello = try NDJSON.encode(RemoteRequest.hello(id: 1, token: "", clientName: "test",
                                                          protocolVersion: RemoteProtocol.version))
        let firstReply = Locked<Result<RemoteReply, Error>?>(nil)
        let client = Task.detached {
            do {
                let connection = Locked<ExtensionClient?>(nil)
                try await eventually("host.sock to accept the first client", timeout: .seconds(5)) {
                    guard let wire = try? ExtensionClient(path: socket) else { return false }
                    connection.withValue { $0 = wire }
                    return true
                }
                let reply = try await blocking {
                    let wire = try #require(connection.current)
                    try wire.sendRaw(hello)
                    return try NDJSON.decode(RemoteReply.self, from: wire.readLine(timeout: .seconds(5)))
                }
                firstReply.withValue { $0 = .success(reply) }
            } catch {
                firstReply.withValue { $0 = .failure(error) }
            }
        }
        await SessionHost.serve(h.server, socket: socket, recovering: false, respawn: { _ in fatalError("no recovery") },
                                configure: { _ in
            // A busy main actor cannot resume serve between the bind and this first hello.
            DispatchQueue.main.async {
                do { try holdingMain(until: "the first local hello reply", timeout: .seconds(15)) { firstReply.current != nil } }
                catch { Issue.record(error) }
            }
        }, startFleet: true)
        await client.value
        let reply = try #require(firstReply.current).get()
        guard case .helloOk(1, _, let capabilities, _, let hostID) = reply else {
            Issue.record("expected helloOk, got \(reply)")
            return
        }
        #expect(capabilities.contains(RemoteProtocol.fleetViewCapability))
        #expect(hostID != nil)
    }
}
