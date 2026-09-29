import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Shepherd's own pi, launched the way the app launches it, through the stub engine: every agent
/// starts its launcher in Shepherd's home whatever the (decoy) startup files say, and a restored
/// agent adopts its conversation from "your pi" without anything of your pi changing.
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
        #expect(launch.argv.starts(with: ["-e", home.directory.appendingPathComponent("shepherd-cliproxyapi.ts").path, "--mode", "rpc"]) && launch.argv.contains("--model"))

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

    /// The conversation a restored agent had in "your pi" (a plain file, and one reached through a
    /// symlink) is copied into Shepherd's home as bytes before it launches, so it resumes rather
    /// than starting afresh; "your pi" is byte-identical afterwards, with no lock left in it.
    @Test func aRestoredAgentAdoptsItsConversationFromYourPiAndLeavesItUntouched() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let plainDir = app.dir.appendingPathComponent("plain", isDirectory: true)
        let linkedDir = app.dir.appendingPathComponent("linked", isDirectory: true)
        let outside = app.dir.appendingPathComponent("outside", isDirectory: true)
        for dir in [plainDir, linkedDir, outside] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let space = Fixture.space(path: app.dir.path)
        var plain = Fixture.agent("plain", in: space, order: 0, cwd: plainDir.path, piSession: SessionID())
        var linked = Fixture.agent("linked", in: space, order: 1, cwd: linkedDir.path, piSession: SessionID())
        plain.agent.model = "anthropic/claude-opus-4-5"
        linked.agent.model = "anthropic/claude-opus-4-5"

        // "Your pi", as the user's terminal pi left it: one file, one symlink to a file elsewhere.
        let yours = TestProcess.piAgentDirectory
        let plainFolder = yours.appendingPathComponent("sessions/\(PiSessionFolder.name(forCwd: plainDir.path))", isDirectory: true)
        let linkedFolder = yours.appendingPathComponent("sessions/\(PiSessionFolder.name(forCwd: linkedDir.path))", isDirectory: true)
        for folder in [plainFolder, linkedFolder] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let plainName = "2026-09-20T00-00-00-000Z_\(plain.agent.effectivePiSessionID).jsonl"
        let linkedName = "2026-09-20T00-00-00-000Z_\(linked.agent.effectivePiSessionID).jsonl"
        let plainBytes = Data(Self.history(plain.agent.effectivePiSessionID, cwd: plainDir.path).utf8)
        let linkedBytes = Data(Self.history(linked.agent.effectivePiSessionID, cwd: linkedDir.path).utf8)
        try plainBytes.write(to: plainFolder.appendingPathComponent(plainName))
        try linkedBytes.write(to: outside.appendingPathComponent("real.jsonl"))
        try FileManager.default.createSymbolicLink(at: linkedFolder.appendingPathComponent(linkedName),
                                                   withDestinationURL: outside.appendingPathComponent("real.jsonl"))
        let before = try Self.tree(yours)

        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [plain, linked]), restoringAgents: true)

        let home = app.server.pi.files
        for (agent, name, bytes) in [(plain, plainName, plainBytes), (linked, linkedName, linkedBytes)] {
            let sessionID = agent.agent.effectivePiSessionID
            try await eventuallyAsync("\(agent.agent.name)'s pi to start") { Self.launch(of: sessionID) != nil }
            let copy = home.sessionDirectory(forCwd: agent.piPane.cwd).appendingPathComponent(name)
            #expect(try Data(contentsOf: copy) == bytes, "\(agent.agent.name): its conversation, copied")
            var info = stat()
            #expect(lstat(copy.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1, "bytes, never a link")
            let launch = try #require(Self.launch(of: sessionID))
            #expect(!launch.argv.contains("--model"), "\(agent.agent.name) resumed its conversation instead of starting afresh")
            #expect(!vm.cannotStart.contains(agent.agent.id))
        }
        #expect(try Self.tree(yours) == before, "your pi is byte-identical")
        #expect(!(try Self.tree(yours).keys.contains { $0.hasSuffix(".lock") }), "no lock was taken in your pi")
        #expect(try Data(contentsOf: outside.appendingPathComponent("real.jsonl")) == linkedBytes)
    }

    /// A session file as pi writes one: its header and two entries.
    static func history(_ sessionID: String, cwd: String) -> String {
        [
            #"{"type":"session","version":3,"id":"\#(sessionID)","timestamp":"2026-09-20T00:00:00.000Z","cwd":"\#(PiSessionFile.realPath(cwd))"}"#,
            #"{"type":"message","id":"e0","parentId":null,"timestamp":"2026-09-20T00:00:01.000Z","message":{"role":"user","content":"Hello!","timestamp":1}}"#,
            #"{"type":"message","id":"e1","parentId":"e0","timestamp":"2026-09-20T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Hi."}],"stopReason":"stop","timestamp":2}}"#,
        ].joined(separator: "\n") + "\n"
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
