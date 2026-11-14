import Foundation
import Testing
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdApp

/// The app is a client of its host: another process that owns the workspace is followed when it
/// answers (`HostSupervisorIntegrationTests`), and one that holds it without ever answering fails
/// the launch, which ends the app (`ShepherdMacApp`'s `failed`) with no model made.
@Suite("App startup ownership", .integrationTimeLimit)
@MainActor
struct ServerStartupRefusalTests {
    final class Model {}

    @Test func anOwnerThatNeverAnswersFailsTheLaunchBeforeAnyModelIsMade() async throws {
        let fixture = try HostSupervisorIntegrationTests.Fixture()
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        owner.arguments = [fixture.script, "silent", fixture.socket, fixture.folder.path]
        try owner.run()
        defer { if owner.isRunning { kill(owner.processIdentifier, SIGKILL) } }
        // Its lock is the only sign of it: the supervisor asks for the lock by taking it for an instant.
        try await eventuallyOnMain("the owner holds the workspace lock") {
            let fd = open(fixture.folder.appendingPathComponent("server.lock").path, O_RDWR | O_CLOEXEC)
            defer { if fd >= 0 { close(fd) } }
            return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0
        }

        var configuration = fixture.configuration("serve")
        configuration.silentOwner = .milliseconds(300)
        let supervisor = HostSupervisor(configuration)
        defer { supervisor.stop() }
        var made = 0
        var failure: Error?
        let launch = ShepherdLaunch<Model>(start: { try supervisor.start() }, makeModel: { made += 1; return Model() },
                                           failed: { failure = $0 })
        await launch.begin()?.value

        #expect(failure is BackgroundHostClient.HostStarting, "the launch failed as a workspace in use: \(String(describing: failure))")
        #expect(made == 0 && launch.model == nil, "nothing that acts on the workspace was made")
        #expect(supervisor.childPID == nil, "the owner's workspace is not contested")
    }
}
