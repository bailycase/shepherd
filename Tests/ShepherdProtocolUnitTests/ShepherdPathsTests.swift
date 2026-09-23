import Foundation
import Testing
import ShepherdProtocol

/// Every path resolves against an explicit environment, so nothing here touches the process's.
@Suite("Support directory paths")
struct ShepherdPathsTests {
    private static func environment(_ value: String?) -> [String: String] {
        value.map { [ShepherdPaths.supportDirectoryEnvKey: $0] } ?? [:]
    }

    @Test(arguments: [nil, "/tmp/shepherd-dev"])
    func socketStateAndTokenLiveTogetherInTheSupportDirectory(_ override: String?) {
        let env = Self.environment(override)
        let directory = ShepherdPaths.supportDirectory(environment: env)
        #expect(ShepherdPaths.socketURL(environment: env) == directory.appendingPathComponent("shepherd.sock"))
        #expect(ShepherdPaths.stateURL(environment: env) == directory.appendingPathComponent("state.json"))
        #expect(ShepherdPaths.remoteTokenURL(environment: env) == directory.appendingPathComponent("remote-token"))
    }

    @Test func defaultsToShepherdInApplicationSupport() {
        let directory = ShepherdPaths.supportDirectory(environment: [:])
        #expect(directory.lastPathComponent == "Shepherd")
        #expect(directory.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    @Test func theOverrideMovesEveryPath() {
        let env = Self.environment("/tmp/shepherd-dev/../shepherd-dev2")
        #expect(ShepherdPaths.supportDirectory(environment: env).path == "/tmp/shepherd-dev2")
        #expect(ShepherdPaths.stateURL(environment: env).path == "/tmp/shepherd-dev2/state.json")
    }

    @Test func aTildeOverrideExpandsToHome() {
        #expect(ShepherdPaths.supportDirectory(environment: Self.environment("~/Shepherd-dev")).path == NSHomeDirectory() + "/Shepherd-dev")
    }

    @Test(arguments: ["", "   "])
    func aBlankOverrideIsIgnored(_ value: String) {
        #expect(ShepherdPaths.supportDirectory(environment: Self.environment(value)) == ShepherdPaths.supportDirectory(environment: [:]))
    }
}
