import Foundation
import Testing
@testable import ShepherdProtocol

/// Both the extension socket and state.json live under the support directory,
/// and the server refuses to bind over a live socket — so a release build and
/// a development build can only run side by side if that directory can be
/// overridden.
@Suite("Shepherd paths")
struct ShepherdPathsTests {
    @Test func defaultsToApplicationSupport() {
        // The override is read from the environment, which this test does not
        // set, so this is the shipping location.
        #expect(ProcessInfo.processInfo.environment[ShepherdPaths.supportDirectoryEnvKey] == nil)
        let directory = ShepherdPaths.supportDirectory()
        #expect(directory.lastPathComponent == "Shepherd")
        #expect(directory.path.contains("Application Support"))
    }

    /// Socket and state must stay together: overriding the directory has to
    /// move both, or two builds would share one of them.
    @Test func socketAndStateLiveInTheSupportDirectory() {
        let directory = ShepherdPaths.supportDirectory()
        #expect(ShepherdPaths.socketURL().deletingLastPathComponent() == directory)
        #expect(ShepherdPaths.stateURL().deletingLastPathComponent() == directory)
        #expect(ShepherdPaths.socketURL().lastPathComponent == "shepherd.sock")
        #expect(ShepherdPaths.stateURL().lastPathComponent == "state.json")
    }
}
