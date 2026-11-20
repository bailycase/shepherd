import Testing
@testable import ShepherdApp

/// The app as its host's client.
@Suite("Background host client")
struct BackgroundHostClientTests {
    @Test func onlyAKnownOlderHostNeedsAnUpdate() {
        #expect(BackgroundHostClient.needsUpdate(appBuild: "1202", hostBuild: "1201"))
        #expect(!BackgroundHostClient.needsUpdate(appBuild: "1201", hostBuild: "1201"))
        #expect(!BackgroundHostClient.needsUpdate(appBuild: "1200", hostBuild: "1201"))
        #expect(!BackgroundHostClient.needsUpdate(appBuild: "1202", hostBuild: nil))
    }
}
