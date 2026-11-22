import Foundation
import Testing
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("App startup ownership", .mainActorExclusive)
@MainActor
struct ServerStartupRefusalTests {
    final class Model {}

    @Test func launchKeepsWaitingForASilentOwnerUntilStopped() async throws {
        let h = try ScratchServer()
        defer { h.stop() }
        let elapsed = Locked(Duration.zero)
        let release = DispatchSemaphore(value: 0)
        var configuration = HostSupervisor.Configuration(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
            socket: h.dir.appendingPathComponent("host.sock").path, lock: h.dir.appendingPathComponent("server.lock").path)
        configuration.sleep = { step in
            elapsed.withValue { $0 += step }
            if elapsed.current >= .seconds(8) { release.wait() }
        }
        let supervisor = HostSupervisor(configuration)
        defer { supervisor.stop(); release.signal() }
        var failure: Error?
        let launch = ShepherdLaunch<Model>(start: { try supervisor.start() }, makeModel: { Model() }, failed: { failure = $0 })
        launch.begin()
        try await eventuallyOnMain("eight seconds of silence") { elapsed.current >= .seconds(8) }
        #expect(launch.model == nil)
        #expect(supervisor.childPID == nil, "the owner's workspace is not contested")

        supervisor.stop()
        release.signal()
        try await eventuallyOnMain("launch wait ends after stop") { failure != nil }
        #expect(failure is CancellationError, "launch ended with \(String(describing: failure))")
        #expect(launch.model == nil)
    }
}
