import Foundation

/// Every line that starts pi, or the node Shepherd's own scripts run on, built in one place from
/// the engine `PiEngine` located. Nothing else in Shepherd names `pi` or `node` on a launch line,
/// so moving to another engine changes the engine and nothing here. `PiLaunchTests` pins each line.
///
/// Each runs in a login shell, as today: it carries the user's PATH to pi's tools and their
/// provider keys to pi. Every value on a line is single-quoted.
public enum PiLaunch {
    /// `/bin/zsh -l -c <script> [positional…]`: the positional words are the script's `$0`, `$1`, ….
    public struct Line: Equatable, Sendable {
        public var script: String
        public var positional: [String]

        public init(script: String, positional: [String] = []) {
            self.script = script
            self.positional = positional
        }

        public var argv: [String] { ["/bin/zsh", "-l", "-c", script] + positional }
    }

    /// An agent's `pi --mode rpc`, reopening the pi session it was last in. The `cd` runs after
    /// the login shell's startup files, so a `cd` in them can't move pi away from the agent's
    /// folder. `model` and `thinking` go only to a fresh session; `extensions` load in order.
    public static func agent(engine: PiEngine, cwd: String, sessionID: String, model: String?, thinking: String?,
                             extensions: [String]) -> Line {
        var script = "cd -- \(quoted(cwd)) && exec \(word(engine.pi)) --mode rpc --session-id \(quoted(sessionID))"
        if let model { script += " --model \(quoted(model))" }
        if let thinking { script += " --thinking \(quoted(thinking))" }
        for path in extensions { script += " -e \(quoted(path))" }
        return Line(script: script)
    }

    /// pi's model catalog (`pi --list-models`).
    public static func listModels(engine: PiEngine) -> Line {
        Line(script: "exec \(word(engine.pi)) --list-models")
    }

    /// A one-shot draft (PR descriptions, commit messages from review): the prompt alone on
    /// `model`, with no session, tools, extensions, skills, templates, themes or context files.
    public static func draft(engine: PiEngine, model: String, prompt: String) -> Line {
        Line(script: "exec \(word(engine.pi)) --print --no-session --no-tools --no-extensions --no-skills "
            + "--no-prompt-templates --no-themes --no-context-files --no-approve --thinking low "
            + "--model \(quoted(model)) -- \(quoted(prompt))")
    }

    /// pi with plain arguments (`--version`, `update`), its output dropped when asked.
    public static func command(engine: PiEngine, arguments: [String], discardingOutput: Bool = false) -> Line {
        let words = ([word(engine.pi)] + arguments.map(quoted)).joined(separator: " ")
        return Line(script: "exec \(words)\(discardingOutput ? " >/dev/null 2>&1" : "")")
    }

    /// Settings ▸ Skills' reader: node with the script on stdin, told where pi's executable is
    /// so it can import pi's own loader (`shepherd-pi-skills.mjs`).
    public static func skillsReader(engine: PiEngine) -> Line {
        let piExecutable = switch engine.pi {
        case .onPath(let name): "\"$(command -v \(quoted(name)) 2>/dev/null)\""
        case .executable(let path): quoted(path)
        }
        return Line(script: "exec \(word(engine.node)) --input-type=module - \(piExecutable)")
    }

    /// Settings ▸ MCP servers' probe: the agents' MCP client, run by node with `probe`.
    public static func mcpProbe(engine: PiEngine, client: String) -> Line {
        Line(script: "exec \(word(engine.node)) \"$0\" probe", positional: [client])
    }

    /// What the native children extension starts a child with when pi's own runtime isn't node
    /// or bun: handed to the agent as `SHEPHERD_PI_EXECUTABLE`, and run without a shell.
    public static func childExecutable(engine: PiEngine) -> String {
        switch engine.pi {
        case .onPath(let name): name
        case .executable(let path): path
        }
    }

    /// The variable that carries `childExecutable` to an agent's extensions.
    public static let childExecutableEnvKey = "SHEPHERD_PI_EXECUTABLE"

    /// A program as a shell word: a plain name bare, anything else quoted.
    static func word(_ program: PiEngine.Program) -> String {
        switch program {
        case .onPath(let name):
            name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) } && !name.isEmpty ? name : quoted(name)
        case .executable(let path):
            quoted(path)
        }
    }

    /// Single-quote wrapping with '"'"' for an embedded single quote.
    public static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
