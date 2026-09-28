import Foundation
import Testing
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("App startup ownership", .integrationTimeLimit)
struct ServerStartupRefusalTests {
    @Test func aRejectedAppExitsBeforeConstructingItsWorkspace() async {
        // The exit-test process has its own isolated support directory. No UI or agent starts.
        await #expect(processExitsWith: .exitCode(1)) {
            await recordingErrors {
                let owner = SessionServer(socketPath: ShepherdPaths.socketURL().path,
                                          stateURL: ShepherdPaths.stateURL(),
                                          modelCatalog: { ScratchServer.standInModels })
                try owner.start()
                defer { owner.stop() }
                await MainActor.run { _ = ShepherdMacApp() }
            }
        }
    }
}
