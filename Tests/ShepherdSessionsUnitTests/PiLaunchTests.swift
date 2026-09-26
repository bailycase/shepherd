import Foundation
import ShepherdProtocol
import Testing
@testable import ShepherdSessions

/// Every line Shepherd starts its pi (or the node beside it) with, pinned: `PiLaunch` is the only
/// place that names either, and every pi line execs the launcher in Shepherd's pi home.
@Suite("pi launch lines")
struct PiLaunchTests {
    static let app = "/Applications/Shepherd.app/Contents"
    static let engine = PiEngine(command: ["\(app)/Helpers/node", "\(app)/Resources/pi-engine/dist/bundle/cli.js"],
                                 packageDirectory: "\(app)/Resources/pi-engine", version: "0.87.1",
                                 node: .executable("\(app)/Helpers/node"))
    /// Shepherd's pi home, in a support folder with a space in it.
    static let home = PiHome(directory: URL(fileURLWithPath: "/Users/me/Library/Application Support/Shepherd/pi", isDirectory: true),
                             engine: engine)
    static let launcher = "'/Users/me/Library/Application Support/Shepherd/pi/bin/pi'"
    static let sessions = "/Users/me/Library/Application Support/Shepherd/pi/sessions"

    static let cwd = "/Users/me/My Project/it's"
    static let status = "/Users/me/Library/Application Support/Shepherd/shepherd-status.ts"
    static let panes = "/Users/me/Library/Application Support/Shepherd/shepherd-panes.ts"

    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let line: PiLaunch.Line
        let script: String
        var positional: [String] = []

        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "a fresh agent, with its model, thinking level and extensions",
            line: try! PiLaunch.agent(home: home, cwd: cwd, sessionID: "s-1", model: "anthropic/claude-sonnet-4-5", thinking: "high",
                                      extensions: [status, panes]),
            script: #"cd -- '/Users/me/My Project/it'"'"'s' && exec "# + launcher
                + #" --mode rpc --session-dir '/Users/me/Library/Application Support/Shepherd/pi/sessions/--Users-me-My Project-it'"'"'s--'"#
                + #" --session-id 's-1' --model 'anthropic/claude-sonnet-4-5' --thinking 'high'"#
                + #" -e '/Users/me/Library/Application Support/Shepherd/shepherd-status.ts' -e '/Users/me/Library/Application Support/Shepherd/shepherd-panes.ts'"#),
        Row(name: "a resumed agent",
            line: try! PiLaunch.agent(home: home, cwd: "/repo", sessionID: "it's", model: nil, thinking: nil, extensions: [status]),
            script: #"cd -- '/repo' && exec "# + launcher + #" --mode rpc --session-dir '\#(sessions)/--repo--' --session-id 'it'"'"'s'"#
                + #" -e '/Users/me/Library/Application Support/Shepherd/shepherd-status.ts'"#),
        Row(name: "a cwd with a colon and a backslash, named as pi names its folder",
            line: try! PiLaunch.agent(home: home, cwd: #"/w/a:b\c"#, sessionID: "s", model: nil, thinking: "low", extensions: []),
            script: #"cd -- '/w/a:b\c' && exec "# + launcher + #" --mode rpc --session-dir '\#(sessions)/--w-a-b-c--' --session-id 's' --thinking 'low'"#),
        Row(name: "the model catalog, from inside the home",
            line: PiLaunch.listModels(home: home),
            script: "cd -- '/Users/me/Library/Application Support/Shepherd/pi' && exec \(launcher) --list-models"),
        Row(name: "a PR description or commit message draft",
            line: PiLaunch.draft(home: home, model: "anthropic/claude-haiku-4-5", prompt: "Summarise it's change"),
            script: "exec \(launcher)"
                + #" --print --no-session --no-tools --no-extensions --no-skills --no-prompt-templates --no-themes --no-context-files --no-approve --thinking low --model 'anthropic/claude-haiku-4-5' -- 'Summarise it'"'"'s change'"#),
        Row(name: "a start Shepherd refuses",
            line: PiLaunch.refused(PiHomeProblem("the homes overlap")),
            script: #"print -r -u2 -- 'Shepherd won'"'"'t start pi: the homes overlap'; exit 78"#),
        Row(name: "the MCP probe, on the engine's node",
            line: PiLaunch.mcpProbe(engine: engine, client: "/Users/me/Library/Application Support/Shepherd/shepherd-mcp-client.mjs"),
            script: #"exec '/Applications/Shepherd.app/Contents/Helpers/node' "$0" probe"#,
            positional: ["/Users/me/Library/Application Support/Shepherd/shepherd-mcp-client.mjs"]),
        Row(name: "the MCP probe on the tests' node",
            line: PiLaunch.mcpProbe(engine: PiEngine(command: ["/scratch/pi-engine"], packageDirectory: nil, version: nil, node: .onPath("node")),
                                    client: "/c.mjs"),
            script: #"exec node "$0" probe"#,
            positional: ["/c.mjs"]),
    ]

    @Test(arguments: rows)
    func everyLaunchLineIsPinned(_ row: Row) {
        #expect(row.line.script == row.script)
        #expect(row.line.positional == row.positional)
        #expect(row.line.argv == ["/bin/zsh", "-l", "-c", row.script] + row.positional)
    }

    /// No pi line names a `pi` or `node` for the shell to look up: each execs the launcher.
    @Test func noPiLineLooksPiUpOnPath() throws {
        let lines = [
            try PiLaunch.agent(home: Self.home, cwd: "/r", sessionID: "s", model: "m", thinking: "high", extensions: ["/e.ts"]),
            PiLaunch.listModels(home: Self.home), PiLaunch.draft(home: Self.home, model: "m", prompt: "pi"),
        ]
        for line in lines {
            #expect(line.script.contains("exec \(Self.launcher) "), "\(line.script)")
            #expect(!line.script.contains("exec pi") && !line.script.contains("command -v"), "\(line.script)")
        }
    }

    /// Signing in types the launcher into a terminal pane: pi's TUI with no session.
    @Test func signingInOpensShepherdsPiWithNoSession() {
        #expect(PiLaunch.signIn(home: Self.home) == "\(Self.launcher) --no-session")
    }

    /// The skills reader runs the engine's node itself, with no shell; the tests' node is found by
    /// `env`.
    @Test func theSkillsReaderRunsTheEnginesNode() {
        #expect(PiLaunch.skillsReader(engine: Self.engine) == ["\(Self.app)/Helpers/node", "--input-type=module", "-"])
        let tests = PiEngine(command: ["/s/pi-engine"], packageDirectory: nil, version: nil, node: .onPath("node"))
        #expect(PiLaunch.skillsReader(engine: tests) == ["/usr/bin/env", "node", "--input-type=module", "-"])
    }

    /// A program name that isn't a plain word is quoted like any other value.
    @Test(arguments: [("node", "node"), ("node-2.0_rc", "node-2.0_rc"), ("my node", "'my node'"), ("", "''"), ("$(x)", "'$(x)'")])
    func namesOnPathAreBareOnlyWhenPlain(_ name: String, word: String) {
        #expect(PiLaunch.word(.onPath(name)) == word)
    }
}

/// Which engine the launcher starts: the app's own, never a pi on PATH, or in a Debug build the
/// override's file.
@Suite("pi engine")
struct PiEngineTests {
    /// An app with no engine inside (this test's bundle path never has one).
    static let app = URL(fileURLWithPath: "/nonexistent/Shepherd.app")
    static let missing = PiEngine.missing(app: app)

    @Test(arguments: [
        ([:], true, missing),
        (["SHEPHERD_PI_ENGINE": ""], true, missing),
        (["SHEPHERD_PI_ENGINE": "  "], true, missing),
        (["SHEPHERD_PI_ENGINE": "/scratch/bin/pi-engine"], true,
         PiEngine(command: ["/scratch/bin/pi-engine"], packageDirectory: nil, version: nil, node: .onPath("node"))),
        (["SHEPHERD_PI_ENGINE": "/scratch/bin/../bin/pi-engine"], true,
         PiEngine(command: ["/scratch/bin/pi-engine"], packageDirectory: nil, version: nil, node: .onPath("node"))),
        (["SHEPHERD_PI_ENGINE": "/scratch/bin/pi-engine"], false, missing),
    ] as [([String: String], Bool, PiEngine)])
    func theOverrideNamesTheEngineOnlyWhereItIsHonoured(_ environment: [String: String], honoured: Bool, expected: PiEngine) {
        #expect(PiEngine.locate(environment: environment, app: Self.app, honoursOverride: honoured) == expected)
    }

    /// A missing engine keeps the paths it should have had, so the launcher says what's missing,
    /// and never becomes a `pi` or `node` looked up on PATH.
    @Test func aMissingEngineIsNeverLookedUpOnPath() {
        let contents = "/nonexistent/Shepherd.app/Contents"
        #expect(Self.missing.command == ["\(contents)/Helpers/node", "\(contents)/Resources/pi-engine/dist/bundle/cli.js"])
        #expect(Self.missing.packageDirectory == "\(contents)/Resources/pi-engine")
        #expect(Self.missing.node == .executable("\(contents)/Helpers/node"))
        #expect(Self.missing.version == nil)
    }

    /// A relative override is a file, resolved against the working directory, never a name to
    /// look up on PATH.
    @Test func aRelativeOverrideIsStillAFile() {
        let engine = PiEngine.locate(environment: ["SHEPHERD_PI_ENGINE": "pi"], app: Self.app, honoursOverride: true)
        #expect(engine.command.count == 1 && engine.command[0].hasPrefix("/") && engine.command[0].hasSuffix("/pi"))
    }

    /// Debug builds (this one) honour the override; Release builds never do.
    @Test func onlyDebugBuildsHonourTheOverride() {
        #if DEBUG
        #expect(PiEngine.honoursOverride)
        #else
        #expect(!PiEngine.honoursOverride)
        #endif
    }
}

/// Shepherd's pi home follows the support folder, never the app's own `PI_CODING_AGENT_DIR`, and
/// "your pi" comes from the override a test process sets, or from nowhere under the engine
/// override.
@Suite("pi setup")
struct PiSetupTests {
    @Test(arguments: [
        (["SHEPHERD_SUPPORT_DIR": "/scratch/support"], "/scratch/support/pi"),
        (["SHEPHERD_SUPPORT_DIR": "/scratch/support", "PI_CODING_AGENT_DIR": "/scratch/decoy"], "/scratch/support/pi"),
        (["SHEPHERD_SUPPORT_DIR": "/scratch/My Support/../Support"], "/scratch/Support/pi"),
    ] as [([String: String], String)])
    func theHomeIsTheSupportFoldersPi(_ environment: [String: String], home: String) {
        let setup = PiSetup.resolve(environment: environment, app: PiEngineTests.app)
        #expect(setup.home.path == home)
        #expect(setup.sessionsRoot.path == home + "/sessions")
        #expect(setup.launcher.path == home + "/bin/pi")
        #expect(setup.catalog.home == setup.home)
    }

    /// Without the override, each edition's own support folder holds its home: nothing is shared
    /// between Shepherd, Shepherd Nightly and the Dev build (whose scheme sets the override).
    @Test(arguments: ShepherdEdition.allCases)
    func eachEditionHasItsOwnHome(_ edition: ShepherdEdition) {
        let setup = PiSetup.resolve(environment: [:], app: PiEngineTests.app, edition: edition)
        #expect(setup.home.path == ShepherdPaths.supportDirectory(environment: [:], edition: edition).appendingPathComponent("pi").path)
        #expect(setup.home.deletingLastPathComponent().lastPathComponent == edition.supportDirectoryName)
    }

    @Test(arguments: [
        (["SHEPHERD_YOUR_PI": "/scratch/pi-agent"], true, "/scratch/pi-agent"),
        (["SHEPHERD_YOUR_PI": "/scratch/pi-agent", "SHEPHERD_PI_ENGINE": "/scratch/bin/pi-engine"], true, "/scratch/pi-agent"),
        (["SHEPHERD_PI_ENGINE": "/scratch/bin/pi-engine"], true, nil),
        (["SHEPHERD_PI_ENGINE": "/scratch/bin/pi-engine", "SHEPHERD_YOUR_PI": " "], true, nil),
    ] as [([String: String], Bool, String?)])
    func yourPiComesFromTheOverrideOrNowhereInTests(_ environment: [String: String], honoured: Bool, expected: String?) {
        let locator = YourPiLocator.forEnvironment(environment, supportDirectory: URL(fileURLWithPath: "/scratch/support"),
                                                   honoursOverride: honoured)
        #expect(locator.resolve()?.agentDirectory.path == expected)
    }
}
