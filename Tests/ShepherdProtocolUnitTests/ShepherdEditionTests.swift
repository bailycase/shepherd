import Testing
import ShepherdProtocol

/// Shepherd and Shepherd Nightly run side by side; the bundle identifier says which one a
/// process is, and everything each app keeps to itself follows from that.
@Suite("App editions")
struct ShepherdEditionTests {
    @Test(arguments: [
        ("com.bailycase.shepherd.nightly", ShepherdEdition.nightly),
        ("com.bailycase.shepherd", .main),
        // The Dev scheme's own id: Shepherd, with preferences apart from the installed app.
        ("com.bailycase.shepherd.dev", .main),
        // Not Shepherd Nightly: a SwiftPM tool, a test runner, anything unbundled.
        ("com.apple.dt.xctest.tool", .main),
        ("com.bailycase.shepherd.nightly.extra", .main),
        (nil, .main),
    ] as [(String?, ShepherdEdition)])
    func theBundleIdentifierDecidesTheEdition(bundleIdentifier: String?, edition: ShepherdEdition) {
        #expect(ShepherdEdition(bundleIdentifier: bundleIdentifier) == edition)
    }

    @Test func eachEditionsIdentifierMapsBackToIt() {
        #expect(ShepherdEdition(bundleIdentifier: ShepherdEdition.mainBundleIdentifier) == .main)
        #expect(ShepherdEdition(bundleIdentifier: ShepherdEdition.nightlyBundleIdentifier) == .nightly)
    }

    @Test(arguments: [
        (ShepherdEdition.main, "Shepherd", "Shepherd", UInt16(7433)),
        (.nightly, "Shepherd Nightly", "Shepherd Nightly", 7434),
    ])
    func eachEditionHasItsOwnNameFolderAndListenerPort(edition: ShepherdEdition, name: String, folder: String, port: UInt16) {
        #expect(edition.displayName == name)
        #expect(edition.supportDirectoryName == folder)
        #expect(edition.defaultRemoteListenerPort == port)
    }

    @Test func bothAppsCanServeAtOnce() {
        #expect(ShepherdEdition.main.defaultRemoteListenerPort != ShepherdEdition.nightly.defaultRemoteListenerPort)
        #expect(ShepherdEdition.main.supportDirectoryName != ShepherdEdition.nightly.supportDirectoryName)
    }
}
