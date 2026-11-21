import Darwin
import Testing
import ShepherdProtocol
@testable import ShepherdApp
import ShepherdSessions

/// The app as its host's client.
@Suite("Background host client")
struct BackgroundHostClientTests {
    @Test func aNewerAppAsksAnOlderHostThatDrainsToDrain() {
        let drains: Set<String> = [RemoteProtocol.hostDrainCapability]
        #expect(BackgroundHostClient.asksToDrain(appBuild: "1202", hostBuild: "1201", capabilities: drains))
        #expect(!BackgroundHostClient.asksToDrain(appBuild: "1201", hostBuild: "1201", capabilities: drains), "same build")
        #expect(!BackgroundHostClient.asksToDrain(appBuild: "1200", hostBuild: "1201", capabilities: drains),
                "an older app connects with what it understands")
        #expect(!BackgroundHostClient.asksToDrain(appBuild: "1202", hostBuild: "1201", capabilities: []),
                "an older host drains once it sees the new bundle")
        #expect(!BackgroundHostClient.asksToDrain(appBuild: "1202", hostBuild: nil, capabilities: drains))
    }
}
