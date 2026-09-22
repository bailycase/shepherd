import Foundation
import Testing
import ShepherdProtocol

/// Mutates `SHEPHERD_SUPPORT_DIR`, so the suite is serialized; nothing else in this target reads
/// it.
@Suite("Support directory paths", .serialized)
struct ShepherdPathsTests {
    private static let key = ShepherdPaths.supportDirectoryEnvKey

    private static func withOverride<T>(_ value: String?, _ body: () throws -> T) rethrows -> T {
        let saved = ProcessInfo.processInfo.environment[key]
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
        defer { if let saved { setenv(key, saved, 1) } else { unsetenv(key) } }
        return try body()
    }

    @Test func socketStateAndTokenLiveTogetherInTheSupportDirectory() {
        let directory = ShepherdPaths.supportDirectory()
        #expect(ShepherdPaths.socketURL() == directory.appendingPathComponent("shepherd.sock"))
        #expect(ShepherdPaths.stateURL() == directory.appendingPathComponent("state.json"))
        #expect(ShepherdPaths.remoteTokenURL() == directory.appendingPathComponent("remote-token"))
    }

    @Test func defaultsToShepherdInApplicationSupport() {
        Self.withOverride(nil) {
            let directory = ShepherdPaths.supportDirectory()
            #expect(directory.lastPathComponent == "Shepherd")
            #expect(directory.deletingLastPathComponent().lastPathComponent == "Application Support")
        }
    }

    @Test func theOverrideMovesEveryPath() {
        Self.withOverride("/tmp/shepherd-dev/../shepherd-dev2") {
            #expect(ShepherdPaths.supportDirectory().path == "/tmp/shepherd-dev2")
            #expect(ShepherdPaths.stateURL().path == "/tmp/shepherd-dev2/state.json")
        }
    }

    @Test func aTildeOverrideExpandsToHome() {
        Self.withOverride("~/Shepherd-dev") {
            #expect(ShepherdPaths.supportDirectory().path == NSHomeDirectory() + "/Shepherd-dev")
        }
    }

    @Test(arguments: ["", "   "])
    func aBlankOverrideIsIgnored(_ value: String) {
        Self.withOverride(value) {
            #expect(ShepherdPaths.supportDirectory().lastPathComponent == "Shepherd")
        }
    }
}
