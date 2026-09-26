import Foundation
import ShepherdSessions
import ShepherdTestSupport
import Testing

/// The isolation every test process gets when it loads (`Tests/ShepherdTestIsolation`), as the
/// login shells the app spawns see it: `pi` and `gh` are the process's stand-ins, never the
/// user's tools, whatever the system startup files do to PATH; the app's pi is a stand-in engine;
/// and the startup files carry decoys a launch line has to win over.
@Suite("Test process isolation", .integrationTimeLimit)
struct TestIsolationTests {
    enum Launch: String, CaseIterable, CustomTestStringConvertible {
        /// The environment `swift test` was started with, from a terminal.
        case inherited
        /// What Xcode or launchd hands a process: nix-darwin's /etc/zshenv then rebuilds PATH
        /// from scratch, and macOS's path_helper moves the system directories first.
        case minimal

        var testDescription: String { rawValue }

        var environment: [String: String] {
            let inherited = ProcessInfo.processInfo.environment
            switch self {
            case .inherited:
                return inherited
            case .minimal:
                var env = ["PATH": "\(TestProcess.binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"]
                for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "ZDOTDIR"] { env[key] = inherited[key] }
                return env
            }
        }
    }

    @Test(arguments: Launch.allCases)
    func aLoginShellResolvesPiAndGhToTheStandIns(launch: Launch) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v pi; command -v gh"]
        process.environment = launch.environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let bin = TestProcess.binDirectory
        let resolved = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(resolved == [bin.appendingPathComponent("pi").path, bin.appendingPathComponent("gh").path])
    }

    /// Run `line` in a login shell with the process's environment, and return its stdout lines.
    private func run(_ line: PiLaunch.Line, cwd: URL? = nil) throws -> (status: Int32, lines: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: line.argv[0])
        process.arguments = Array(line.argv.dropFirst())
        if let cwd { process.currentDirectoryURL = cwd }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
    }

    /// The app's engine in a test process is the stand-in `SHEPHERD_PI_ENGINE` names, which
    /// refuses to run, as a missing command would, until a test installs the stub over it. Its
    /// home is the scratch support folder's, never the process's `PI_CODING_AGENT_DIR`, and "your
    /// pi" is the scratch one.
    @Test func theAppsPiIsTheStandInEngineInTheScratchHome() throws {
        #expect(PiSetup.app.engine.command == [TestProcess.piEngine.path])
        #expect(PiSetup.app.home.path == TestProcess.piHome.standardizedFileURL.path)
        #expect(PiSetup.app.home.path != TestProcess.piAgentDirectory.standardizedFileURL.path)
        #expect(PiSetup.app.yourPi.resolve()?.agentDirectory.path == TestProcess.piAgentDirectory.standardizedFileURL.path)
        let result = try run(PiLaunch.Line(script: "exec '\(TestProcess.binDirectory.appendingPathComponent("pi").path)' --version"))
        #expect(result.status == 127)
    }

    /// A login shell carries the decoys, as a user's startup files might, and none of them points
    /// at the scratch pi the app reads.
    @Test func loginShellsCarryTheDecoys() throws {
        let result = try run(PiLaunch.Line(script: #"print -r -- "$PI_CODING_AGENT_DIR"; print -r -- "$PI_PACKAGE_DIR"; "#
            + #"print -r -- "$NODE_OPTIONS"; print -r -- "$PI_OFFLINE"; print -r -- "$JITI_ALIAS"; print -r -- "$PI_EXPERIMENTAL""#))
        let decoy = TestProcess.piDecoyDirectory.path
        #expect(result.lines == [decoy + "/agent", decoy + "/package", "--require=\(decoy)/node-options.cjs", "0",
                                 #"{"shepherd-decoy":""# + decoy + #""}"#, "1"])
        #expect(!decoy.hasPrefix(TestProcess.piAgentDirectory.path) && !TestProcess.piAgentDirectory.path.hasPrefix(decoy))
    }

    /// A scratch home whose engine prints where it runs, its arguments, and the variables the
    /// launcher decides.
    private func scratchHome(_ dir: URL) throws -> PiHome {
        let engine = dir.appendingPathComponent("pi-engine")
        try """
            #!/bin/sh
            pwd -P
            printf '%s\\n' "$@"
            for name in PI_CODING_AGENT_DIR PI_PACKAGE_DIR PI_OFFLINE NODE_OPTIONS JITI_ALIAS PI_EXPERIMENTAL _SHEPHERD_STASH_NODE_OPTIONS; do
              eval "printf '%s=%s\\n' $name \"\\${$name-unset}\""
            done

            """.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        let home = PiHome(directory: dir.appendingPathComponent("support/pi", isDirectory: true),
                          engine: PiEngine(command: [engine.path], packageDirectory: nil, version: nil, node: .onPath("node")))
        try home.install()
        return home
    }

    /// An agent's line starts pi in the agent's folder although the startup files move a shell
    /// that starts Shepherd's pi to `/`, and the launcher's pins win over every decoy: the decoys
    /// are set aside, never seen by pi.
    @Test func anAgentsLineKeepsItsFolderAndHomeDespiteTheStartupFiles() throws {
        let dir = try makeScratchDirectory("engine")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cwd = dir.appendingPathComponent("it's a folder", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let home = try scratchHome(dir)

        let agent = try run(try PiLaunch.agent(home: home, cwd: cwd.path, sessionID: "s-1", model: nil, thinking: nil, extensions: ["/e.ts"]),
                            cwd: cwd)
        #expect(agent.status == 0)
        let real = try #require(realpath(cwd.path, nil))
        defer { free(real) }
        let decoy = TestProcess.piDecoyDirectory.path
        #expect(agent.lines == [
            String(cString: real), "--mode", "rpc", "--session-dir", home.sessionDirectory(forCwd: cwd.path).path, "--session-id", "s-1",
            "-e", "/e.ts",
            "PI_CODING_AGENT_DIR=\(home.directory.path)", "PI_PACKAGE_DIR=unset", "PI_OFFLINE=1", "NODE_OPTIONS=unset", "JITI_ALIAS=unset",
            "PI_EXPERIMENTAL=unset", "_SHEPHERD_STASH_NODE_OPTIONS=--require=\(decoy)/node-options.cjs",
        ])

        let catalog = try run(PiLaunch.listModels(home: home), cwd: cwd)
        #expect(catalog.lines.prefix(2) == [PiHome.canonical(home.directory.path), "--list-models"])
    }
}
