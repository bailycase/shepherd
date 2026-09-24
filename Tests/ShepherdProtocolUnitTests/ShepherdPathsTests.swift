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

    /// Each app keeps its own folder, so Shepherd Nightly never reads the everyday app's
    /// state.json or binds over its socket.
    @Test(arguments: [
        (ShepherdEdition.main, "Shepherd"),
        (.nightly, "Shepherd Nightly"),
    ])
    func eachEditionDefaultsToItsOwnFolderInApplicationSupport(edition: ShepherdEdition, folder: String) {
        let directory = ShepherdPaths.supportDirectory(environment: [:], edition: edition)
        #expect(directory.lastPathComponent == folder)
        #expect(directory.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    @Test func theProcessEditionIsTheEverydayAppOutsideShepherdNightly() {
        #expect(ShepherdPaths.supportDirectory(environment: [:]) == ShepherdPaths.supportDirectory(environment: [:], edition: .main))
    }

    @Test(arguments: ShepherdEdition.allCases)
    func theOverrideWinsForEveryEdition(edition: ShepherdEdition) {
        let env = Self.environment("/tmp/shepherd-dev")
        #expect(ShepherdPaths.supportDirectory(environment: env, edition: edition).path == "/tmp/shepherd-dev")
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
