import Foundation
import Testing
@testable import ShepherdSessions
import ShepherdTestSupport

/// Shepherd's launcher (`<home>/bin/pi`) and `restore-env.sh`, run for real against a stand-in
/// engine that prints what it was given: what pi sees, what an agent's shell commands get back,
/// what it refuses, and the guards that keep the home apart from "your pi".
@Suite("Shepherd's pi launcher", .integrationTimeLimit)
struct PiLauncherTests {
    /// A scratch home whose engine prints its arguments, then `name=value` for each variable the
    /// launcher decides.
    static func home(in dir: URL, engine name: String = "pi-engine", create: Bool = true) throws -> PiHome {
        let engine = dir.appendingPathComponent(name)
        if create {
            try """
                #!/bin/sh
                printf 'arg=%s\\n' "$@"
                env | grep -E '^(PI_|JITI_|NODE_|OPENSSL_CONF|_SHEPHERD_STASH_)' | sort

                """.write(to: engine, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        }
        let home = PiHome(directory: dir.appendingPathComponent("support/pi", isDirectory: true),
                          engine: PiEngine(command: [engine.path], packageDirectory: "/engine/package", version: "0.87.1", node: .onPath("node")))
        try home.install()
        return home
    }

    struct Run { let status: Int32; let out: [String]; let err: String }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, out: String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init),
                   err: String(decoding: errors, as: UTF8.self))
    }

    static let userEnvironment = [
        "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(),
        "PI_CODING_AGENT_DIR": "/their/pi", "PI_OFFLINE": "0", "PI_EXPERIMENTAL": "1",
        "NODE_OPTIONS": "--require /their/hook.cjs", "NODE_EXTRA_CA_CERTS": "/their/ca.pem",
        "JITI_ALIAS": #"{"a":"b c"}"#, "OPENSSL_CONF": "/their/openssl.cnf",
    ]

    /// pi sees Shepherd's pins and none of the environment's pi, jiti or Node settings, except
    /// corporate CAs; each is set aside, exactly as it was.
    @Test func piSeesThePinsAndNothingOfTheUsersPiJitiOrNode() throws {
        let dir = try makeScratchDirectory("launcher")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = try Self.home(in: dir)

        let result = try Self.run(home.launcher.path, ["--mode", "rpc", "it's"], environment: Self.userEnvironment)

        #expect(result.status == 0, "\(result.err)")
        let lines = Set(result.out)
        #expect(result.out.prefix(3) == ["arg=--mode", "arg=rpc", "arg=it's"])
        for (key, value) in home.pins { #expect(lines.contains("\(key)=\(value)"), "\(key): \(result.out)") }
        #expect(lines.contains("NODE_EXTRA_CA_CERTS=/their/ca.pem"))
        for key in ["NODE_OPTIONS", "JITI_ALIAS", "OPENSSL_CONF", "PI_EXPERIMENTAL"] {
            #expect(!lines.contains { $0.hasPrefix(key + "=") }, "\(key) reached pi")
            #expect(lines.contains("_SHEPHERD_STASH_\(key)=\(Self.userEnvironment[key]!)"))
        }
        #expect(lines.contains("_SHEPHERD_STASH_PI_CODING_AGENT_DIR=/their/pi") && lines.contains("_SHEPHERD_STASH_PI_OFFLINE=0"))
    }

    /// `restore-env.sh`, as the bash tool sources it before a command: the pins go, and what
    /// the launcher set aside comes back as it was, spaces and quotes included, in bash and zsh.
    @Test(arguments: ["/bin/bash", "/bin/zsh"])
    func anAgentsShellCommandsGetTheUsersEnvironmentBack(shell: String) throws {
        let dir = try makeScratchDirectory("restore")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = try Self.home(in: dir)
        // What pi's environment is once the launcher has run: the engine prints it.
        let launched = try Self.run(home.launcher.path, [], environment: Self.userEnvironment)
        var piEnvironment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        for line in launched.out where !line.hasPrefix("arg=") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { piEnvironment[parts[0]] = parts[1] }
        }

        let command = home.shellCommandPrefix + "\n" + #"printf '%s|%s|%s|%s|%s\n' "${NODE_OPTIONS-unset}" "${JITI_ALIAS-unset}" "${PI_OFFLINE-unset}" "${PI_CODING_AGENT_DIR-unset}" "${PI_PACKAGE_DIR-unset}""#
        let result = try Self.run(shell, ["-c", command], environment: piEnvironment)

        #expect(result.status == 0, "\(result.err)")
        #expect(result.out == [#"--require /their/hook.cjs|{"a":"b c"}|0|/their/pi|unset"#])
    }

    /// pi's own package and config commands change nothing of Shepherd's pi.
    @Test(arguments: PiHome.refusedSubcommands)
    func theLauncherRefusesPisPackageCommands(_ subcommand: String) throws {
        let dir = try makeScratchDirectory("refuse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = try Self.home(in: dir)
        let result = try Self.run(home.launcher.path, [subcommand, "npm:@x/y"], environment: ["PATH": "/usr/bin:/bin"])
        #expect(result.status == 2)
        #expect(result.out.isEmpty, "the engine never ran")
        #expect(result.err.contains("Settings ▸ Pi"))
    }

    /// A missing engine is a missing command (127), which the agent's start names.
    @Test func aMissingEngineExitsAsAMissingCommand() throws {
        let dir = try makeScratchDirectory("missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = try Self.home(in: dir, engine: "gone", create: false)
        let result = try Self.run(home.launcher.path, ["--mode", "rpc"], environment: ["PATH": "/usr/bin:/bin"])
        #expect(result.status == 127)
        #expect(result.err.contains("Shepherd's pi engine is missing"))
    }

    /// Installing writes the launcher, restore-env.sh, the marker and settings.json, each once.
    @Test func installingWritesShepherdsFilesOnce() throws {
        let dir = try makeScratchDirectory("install")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = try Self.home(in: dir)
        let files = FileManager.default
        #expect(files.isExecutableFile(atPath: home.launcher.path))
        #expect(files.fileExists(atPath: home.marker.path) && files.fileExists(atPath: home.restoreEnv.path))
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.settings)) as? [String: Any])
        #expect(settings["shellCommandPrefix"] as? String == home.shellCommandPrefix)
        let before = try files.attributesOfItem(atPath: home.launcher.path)[.modificationDate] as? Date
        try home.install()
        #expect(try files.attributesOfItem(atPath: home.launcher.path)[.modificationDate] as? Date == before)
        #expect(!files.fileExists(atPath: home.settings.path + ".lock"))
    }

    /// A sessions folder that is a symlink out of the home is refused before pi is given it.
    @Test func aSessionFolderOutsideTheHomeIsRefused() throws {
        let dir = try makeScratchDirectory("outside")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = try Self.home(in: dir)
        let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.sessions, withDestinationURL: elsewhere)
        #expect(throws: PiLaunch.OutsideHome.self) {
            try PiLaunch.agent(home: home, cwd: dir.path, sessionID: "s", model: nil, thinking: nil, extensions: [])
        }
    }

    /// "Your pi" holding a Shepherd home's marker is the same folder: no pi starts.
    @Test func aYourPiMarkedAsAShepherdHomeStartsNoPi() throws {
        let dir = try makeScratchDirectory("marker")
        defer { try? FileManager.default.removeItem(at: dir) }
        let theirs = dir.appendingPathComponent("theirs", isDirectory: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        let home = PiHome(directory: dir.appendingPathComponent("ours", isDirectory: true), engine: PiSetup.app.engine)
        #expect(PiSetup.check(home, yourPi: YourPi(agentDirectory: theirs)) == nil)
        try Data().write(to: theirs.appendingPathComponent(PiHome.markerName))
        #expect(PiSetup.check(home, yourPi: YourPi(agentDirectory: theirs)) != nil)
    }

    /// A home that overlaps "your pi" is refused before anything is written into it.
    @Test func preparingAnOverlappingHomeWritesNothing() throws {
        let dir = try makeScratchDirectory("overlap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let theirs = dir.appendingPathComponent("theirs", isDirectory: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        let setup = PiSetup(engine: PiSetup.app.engine, home: theirs.appendingPathComponent("shepherd/pi"),
                            yourPi: YourPiLocator(.fixed(theirs)))
        #expect(setup.prepare() != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: theirs.path).isEmpty)
    }

    /// Startup files that point PI_CODING_AGENT_DIR at Shepherd's own pi home make that folder
    /// no "your pi" to read, but the terminal pi would share the home: no pi starts there, and
    /// nothing is written into it.
    @Test func startupFilesThatPointYourPiAtShepherdsHomeStartNoPi() throws {
        let dir = try makeScratchDirectory("yours-ours")
        defer { try? FileManager.default.removeItem(at: dir) }
        let support = dir.appendingPathComponent("support", isDirectory: true)
        let zdotdir = dir.appendingPathComponent("zdot", isDirectory: true)
        for folder in [support, zdotdir] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "export PI_CODING_AGENT_DIR='\(support.path)/pi'\n".write(to: zdotdir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["ZDOTDIR"] = zdotdir.path
        environment["HOME"] = dir.path

        let locator = YourPiLocator.forEnvironment(environment, supportDirectory: support, honoursOverride: false)
        let setup = PiSetup(engine: PiSetup.app.engine, home: support.appendingPathComponent("pi", isDirectory: true), yourPi: locator)
        let problem = try #require(setup.prepare())
        #expect(locator.resolve() == nil, "a folder inside a support folder is never read as your pi")
        #expect(locator.refusedDirectory()?.standardizedFileURL.path == support.appendingPathComponent("pi").path)
        #expect(problem.message.contains("PI_CODING_AGENT_DIR"))
        #expect(!FileManager.default.fileExists(atPath: setup.home.path), "nothing was written into the shared folder")
    }

    /// A `bin` in the home that links elsewhere (into the user's pi) gets no launcher: the home
    /// is refused instead.
    @Test func aBinFolderThatLeadsOutOfTheHomeGetsNoLauncher() throws {
        let dir = try makeScratchDirectory("bin-link")
        defer { try? FileManager.default.removeItem(at: dir) }
        let theirs = dir.appendingPathComponent("theirs/bin", isDirectory: true)
        let home = dir.appendingPathComponent("support/pi", isDirectory: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("bin"), withDestinationURL: theirs)
        let setup = PiSetup(engine: PiSetup.app.engine, home: home)

        #expect(setup.prepare() != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: theirs.path).isEmpty)
    }
}
