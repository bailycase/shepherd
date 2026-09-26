import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Shepherd's own pi, launched the way the app launches it, through the stub engine: every agent
/// starts its launcher in Shepherd's home whatever the (decoy) startup files say.
@Suite("Shepherd's pi home, launched", .mainActorExclusive)
@MainActor
struct PiHomeLaunchTests {
    /// The stub engine's record of the launch for `sessionID`.
    static func launch(of sessionID: String) -> StubPi.Launch? {
        StubPi.launches().last { $0.argv.contains("--session-id") && $0.argv.contains(sessionID) }
    }

    @Test func anAgentStartsShepherdsPiInItsOwnHomeDespiteTheStartupFiles() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))

        let id = try await vm.startAgent(NewAgentConfig(spaceID: space.id, workingDirectory: app.dir.path, model: "anthropic/claude-opus-4-5",
                                                        thinking: .high, initialPrompt: "hello"), selectAfter: false)
        let agent = try #require(vm.state.agents.first { $0.id == id })
        let sessionID = agent.effectivePiSessionID
        try await eventuallyAsync("the stub engine to record the launch") { Self.launch(of: sessionID) != nil }
        let launch = try #require(Self.launch(of: sessionID))
        let home = app.server.pi.files

        // The launcher's line: pi in the agent's folder, its sessions in Shepherd's home.
        #expect(launch.cwd == PiSessionFile.realPath(app.dir.path), "the startup files' cd / never moved pi")
        let sessionDir = try #require(launch.argv.firstIndex(of: "--session-dir").map { launch.argv[$0 + 1] })
        #expect(sessionDir == home.sessionDirectory(forCwd: app.dir.path).path)
        #expect(launch.argv.starts(with: ["--mode", "rpc"]) && launch.argv.contains("--model"))

        // Every pin wins over the decoys, which pi never sees; they wait for its shell commands.
        for (key, value) in home.pins where key != "PI_PACKAGE_DIR" { #expect(launch.env[key] == value, "\(key)") }
        #expect(launch.env["PI_CODING_AGENT_DIR"] == TestProcess.piHome.standardizedFileURL.path)
        for key in ["PI_PACKAGE_DIR", "NODE_OPTIONS", "JITI_ALIAS", "PI_EXPERIMENTAL"] { #expect(launch.env[key] == nil, "\(key) reached pi") }
        let decoy = TestProcess.piDecoyDirectory.path
        #expect(launch.env["_SHEPHERD_STASH_NODE_OPTIONS"] == "--require=\(decoy)/node-options.cjs")
        #expect(launch.env["_SHEPHERD_STASH_PI_CODING_AGENT_DIR"] == decoy + "/agent")

        // Shepherd's files are in its home; your pi has none of them.
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.settings)) as? [String: Any])
        #expect(settings["shellCommandPrefix"] as? String == home.shellCommandPrefix)
        #expect(FileManager.default.fileExists(atPath: home.marker.path))
        #expect(!FileManager.default.fileExists(atPath: TestProcess.piAgentDirectory.appendingPathComponent(PiHome.markerName).path))
    }

    /// Every path under `root` (links as links), with its bytes.
    static func tree(_ root: URL) throws -> [String: Data] {
        var tree: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let url = root.appendingPathComponent(path)
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                tree[path] = Data(("link:" + target).utf8)
            } else {
                tree[path] = FileManager.default.contents(atPath: url.path) ?? Data()
            }
        }
        return tree
    }
}
