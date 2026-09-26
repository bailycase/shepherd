import Foundation
import Testing
@testable import ShepherdSessions

/// Every line Shepherd starts pi (or the node beside it) with, pinned: `PiLaunch` is the only
/// place that names either, so a line that changes shows up here.
@Suite("pi launch lines")
struct PiLaunchTests {
    /// The user's pi, found on the login shell's PATH (the app today).
    static let user = PiEngine.userPi
    /// Another engine, at a path with a space and a quote in it (the tests' override).
    static let other = PiEngine(pi: .executable("/scratch/it's here/pi-engine"), node: .onPath("node"))

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
            line: PiLaunch.agent(engine: user, cwd: cwd, sessionID: "s-1", model: "anthropic/claude-sonnet-4-5", thinking: "high",
                                 extensions: [status, panes]),
            script: #"cd -- '/Users/me/My Project/it'"'"'s' && exec pi --mode rpc --session-id 's-1' --model 'anthropic/claude-sonnet-4-5' --thinking 'high' -e '/Users/me/Library/Application Support/Shepherd/shepherd-status.ts' -e '/Users/me/Library/Application Support/Shepherd/shepherd-panes.ts'"#),
        Row(name: "a resumed agent",
            line: PiLaunch.agent(engine: user, cwd: "/repo", sessionID: "it's", model: nil, thinking: nil, extensions: [status]),
            script: #"cd -- '/repo' && exec pi --mode rpc --session-id 'it'"'"'s' -e '/Users/me/Library/Application Support/Shepherd/shepherd-status.ts'"#),
        Row(name: "an agent on another engine",
            line: PiLaunch.agent(engine: other, cwd: cwd, sessionID: "s-1", model: nil, thinking: "low", extensions: [status]),
            script: #"cd -- '/Users/me/My Project/it'"'"'s' && exec '/scratch/it'"'"'s here/pi-engine' --mode rpc --session-id 's-1' --thinking 'low' -e '/Users/me/Library/Application Support/Shepherd/shepherd-status.ts'"#),
        Row(name: "the model catalog",
            line: PiLaunch.listModels(engine: user),
            script: "exec pi --list-models"),
        Row(name: "the model catalog on another engine",
            line: PiLaunch.listModels(engine: other),
            script: #"exec '/scratch/it'"'"'s here/pi-engine' --list-models"#),
        Row(name: "a PR description or commit message draft",
            line: PiLaunch.draft(engine: user, model: "anthropic/claude-haiku-4-5", prompt: "Summarise it's change"),
            script: #"exec pi --print --no-session --no-tools --no-extensions --no-skills --no-prompt-templates --no-themes --no-context-files --no-approve --thinking low --model 'anthropic/claude-haiku-4-5' -- 'Summarise it'"'"'s change'"#),
        Row(name: "a draft on another engine",
            line: PiLaunch.draft(engine: other, model: "m", prompt: "p"),
            script: #"exec '/scratch/it'"'"'s here/pi-engine' --print --no-session --no-tools --no-extensions --no-skills --no-prompt-templates --no-themes --no-context-files --no-approve --thinking low --model 'm' -- 'p'"#),
        Row(name: "pi's version",
            line: PiLaunch.command(engine: user, arguments: ["--version"]),
            script: "exec pi '--version'"),
        Row(name: "an update, its output dropped",
            line: PiLaunch.command(engine: user, arguments: ["update", "--extensions"], discardingOutput: true),
            script: "exec pi 'update' '--extensions' >/dev/null 2>&1"),
        Row(name: "a command on another engine",
            line: PiLaunch.command(engine: other, arguments: ["--version"]),
            script: #"exec '/scratch/it'"'"'s here/pi-engine' '--version'"#),
        Row(name: "the skills reader",
            line: PiLaunch.skillsReader(engine: user),
            script: #"exec node --input-type=module - "$(command -v 'pi' 2>/dev/null)""#),
        Row(name: "the skills reader on another engine",
            line: PiLaunch.skillsReader(engine: other),
            script: #"exec node --input-type=module - '/scratch/it'"'"'s here/pi-engine'"#),
        Row(name: "the MCP probe",
            line: PiLaunch.mcpProbe(engine: user, client: "/Users/me/Library/Application Support/Shepherd/shepherd-mcp-client.mjs"),
            script: #"exec node "$0" probe"#,
            positional: ["/Users/me/Library/Application Support/Shepherd/shepherd-mcp-client.mjs"]),
        Row(name: "the MCP probe on an engine with its own node",
            line: PiLaunch.mcpProbe(engine: PiEngine(pi: .executable("/e/pi"), node: .executable("/e/My Node/node")), client: "/c.mjs"),
            script: #"exec '/e/My Node/node' "$0" probe"#,
            positional: ["/c.mjs"]),
    ]

    @Test(arguments: rows)
    func everyLaunchLineIsPinned(_ row: Row) {
        #expect(row.line.script == row.script)
        #expect(row.line.positional == row.positional)
        #expect(row.line.argv == ["/bin/zsh", "-l", "-c", row.script] + row.positional)
    }

    /// Under another engine nothing on any line names a bare `pi` for the shell to look up.
    @Test func anotherEngineIsNeverLookedUpOnPath() {
        let lines = [
            PiLaunch.agent(engine: Self.other, cwd: "/r", sessionID: "s", model: "m", thinking: "high", extensions: ["/e.ts"]),
            PiLaunch.listModels(engine: Self.other), PiLaunch.draft(engine: Self.other, model: "m", prompt: "pi"),
            PiLaunch.command(engine: Self.other, arguments: ["--version"]), PiLaunch.skillsReader(engine: Self.other),
        ]
        for line in lines {
            #expect(!line.script.contains("exec pi"), "\(line.script)")
            #expect(!line.script.contains("command -v"), "\(line.script)")
        }
    }

    /// What a native child falls back to when pi's runtime isn't node or bun: the engine's pi.
    @Test func childrenFallBackToTheEnginesPi() {
        #expect(PiLaunch.childExecutable(engine: Self.user) == "pi")
        #expect(PiLaunch.childExecutable(engine: Self.other) == "/scratch/it's here/pi-engine")
    }

    /// A program name that isn't a plain word is quoted like any other value.
    @Test(arguments: [("pi", "pi"), ("pi-2.0_rc", "pi-2.0_rc"), ("my pi", "'my pi'"), ("", "''"), ("$(x)", "'$(x)'")])
    func namesOnPathAreBareOnlyWhenPlain(_ name: String, word: String) {
        #expect(PiLaunch.word(.onPath(name)) == word)
    }
}

/// Which pi Shepherd starts: the user's today, or in a Debug build the override's file.
@Suite("pi engine")
struct PiEngineTests {
    @Test(arguments: [
        ([:], true, PiEngine.userPi),
        (["SHEPHERD_PI_ENGINE": ""], true, PiEngine.userPi),
        (["SHEPHERD_PI_ENGINE": "  "], true, PiEngine.userPi),
        (["SHEPHERD_PI_ENGINE": "/scratch/bin/pi-engine"], true, PiEngine(pi: .executable("/scratch/bin/pi-engine"), node: .onPath("node"))),
        (["SHEPHERD_PI_ENGINE": "/scratch/bin/../bin/pi-engine"], true, PiEngine(pi: .executable("/scratch/bin/pi-engine"), node: .onPath("node"))),
        (["SHEPHERD_PI_ENGINE": "/scratch/bin/pi-engine"], false, PiEngine.userPi),
    ] as [([String: String], Bool, PiEngine)])
    func theOverrideNamesTheEngineOnlyWhereItIsHonoured(_ environment: [String: String], honoured: Bool, expected: PiEngine) {
        #expect(PiEngine.locate(environment: environment, honoursOverride: honoured) == expected)
    }

    /// A relative override is a file, resolved against the working directory, never a name to
    /// look up on PATH.
    @Test func aRelativeOverrideIsStillAFile() {
        let engine = PiEngine.locate(environment: ["SHEPHERD_PI_ENGINE": "pi"], honoursOverride: true)
        guard case .executable(let path) = engine.pi else {
            Issue.record("expected a file, got \(engine.pi)")
            return
        }
        #expect(path.hasPrefix("/") && path.hasSuffix("/pi"))
    }

    /// Debug builds (this one) honour the override; Release builds never do.
    @Test func onlyDebugBuildsHonourTheOverride() {
        #if DEBUG
        #expect(PiEngine.honoursOverride)
        #else
        #expect(!PiEngine.honoursOverride)
        #endif
    }

    /// The setup an environment gives: the engine, and pi's agent directory as the home, the
    /// sessions root and "your pi" (one folder until Shepherd has a home of its own).
    @Test func aSetupFollowsItsEnvironment() {
        let setup = PiSetup.resolve(environment: ["SHEPHERD_PI_ENGINE": "/scratch/bin/pi-engine", "PI_CODING_AGENT_DIR": "/scratch/pi-agent"])
        #expect(setup.engine == PiEngine.locate(environment: ["SHEPHERD_PI_ENGINE": "/scratch/bin/pi-engine"]))
        #expect(setup.home.path == "/scratch/pi-agent")
        #expect(setup.yourPi.path == "/scratch/pi-agent")
        #expect(setup.sessionsRoot.path == "/scratch/pi-agent/sessions")
        #expect(setup.catalog.home.path == "/scratch/pi-agent" && setup.catalog.engine == setup.engine)
    }
}
