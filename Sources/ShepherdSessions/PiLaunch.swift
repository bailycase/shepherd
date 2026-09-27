import Foundation

/// Every line that starts Shepherd's pi, or the node Shepherd's own scripts run on, built in one
/// place. Each pi line execs the launcher in Shepherd's pi home (`PiHome.launcher`), never a
/// `pi` looked up on PATH; the launcher pins the home and starts the engine. `PiLaunchTests`
/// pins each line.
///
/// The pi lines run in a login shell: it carries the user's PATH to pi's tools and their
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

    /// A session path outside Shepherd's pi home (principle 4: pi writes only Shepherd's files).
    public struct OutsideHome: Error, CustomStringConvertible, Equatable {
        public let path: String
        public var description: String { "Shepherd hands pi only session paths inside its own pi home, not \(path)." }
    }

    /// An agent's `pi --mode rpc` in `cwd`, reopening the pi session it was last in, with its
    /// sessions in `home.sessionDirectory(forCwd:)` (`--session-dir`, which wins over anything the
    /// environment or a project's settings say). The `cd` runs after the login shell's startup
    /// files, so a `cd` in them can't move pi. `model` and `thinking` go only to a fresh session;
    /// `extensions` load in order. `untrustedProject` (an agent in the user's home folder, whose
    /// project folder `~/.pi` holds their own pi) passes `--no-approve`, so pi loads no project
    /// code or settings there whatever a trust decision says. Throws when the session folder
    /// resolves outside the home.
    public static func agent(home: PiHome, cwd: String, sessionID: String, model: String?, thinking: String?,
                             extensions: [String], untrustedProject: Bool = false) throws -> Line {
        let sessionDirectory = home.sessionDirectory(forCwd: cwd).path
        guard home.contains(sessionDirectory) else { throw OutsideHome(path: sessionDirectory) }
        var script = "cd -- \(quoted(cwd)) && exec \(quoted(home.launcher.path)) --mode rpc --session-dir \(quoted(sessionDirectory))"
            + " --session-id \(quoted(sessionID))"
        if untrustedProject { script += " --no-approve" }
        if let model { script += " --model \(quoted(model))" }
        if let thinking { script += " --thinking \(quoted(thinking))" }
        for path in extensions { script += " -e \(quoted(path))" }
        return Line(script: script)
    }

    /// pi's model catalog (`pi --list-models`), from inside the home, so a project's `.pi` never
    /// applies (a cwd of `~` would make `~/.pi` the project).
    public static func listModels(home: PiHome) -> Line {
        Line(script: "cd -- \(quoted(home.directory.path)) && exec \(quoted(home.launcher.path)) --list-models")
    }

    /// Whether `cwd` is the user's home folder, which no agent's pi trusts as a project.
    public static func isHomeFolder(_ cwd: String, userHome: String) -> Bool {
        PiHome.canonical(cwd) == PiHome.canonical(userHome)
    }

    /// A one-shot draft (PR descriptions, commit messages from review): the prompt alone on
    /// `model`, with no session, tools, extensions, skills, templates, themes or context files.
    public static func draft(home: PiHome, model: String, prompt: String) -> Line {
        Line(script: "exec \(quoted(home.launcher.path)) --print --no-session --no-tools --no-extensions --no-skills "
            + "--no-prompt-templates --no-themes --no-context-files --no-approve --thinking low "
            + "--model \(quoted(model)) -- \(quoted(prompt))")
    }

    /// What a terminal pane types to open Shepherd's pi for signing in: pi's own TUI, with no
    /// session, where `/login` signs in to a provider for Shepherd's pi alone. It runs in the
    /// home, in a subshell so the pane's own shell stays where it was: an agent's folder of `~`
    /// would make `~/.pi` the TUI's project, which it may offer to trust.
    public static func signIn(home: PiHome) -> String {
        "(cd -- \(quoted(home.directory.path)) && exec \(quoted(home.launcher.path)) --no-session)"
    }

    /// A line that starts no pi and says why (`PiHomeProblem`), exiting `refusedExitCode`, so the
    /// agent's start fails with the reason (`NativeStartProblem.Kind.homeUnsafe`).
    public static func refused(_ problem: PiHomeProblem) -> Line {
        Line(script: "print -r -u2 -- \(quoted(refusalPrefix + problem.message)); exit \(refusedExitCode)")
    }

    /// How a refused start begins its one line, and exits.
    public static let refusalPrefix = "Shepherd won't start pi: "
    public static let refusedExitCode: Int32 = 78

    /// Settings ▸ MCP servers' probe: the agents' MCP client, run by the engine's node with
    /// `probe`, in a login shell, so the servers it starts find what an agent's would. Like the
    /// launcher, it drops the startup files' pi, jiti and Node settings first (keeping
    /// `NODE_EXTRA_CA_CERTS`): an agent's client never sees them, and a `NODE_OPTIONS` hook of the
    /// user's must not load into Shepherd's node.
    public static func mcpProbe(engine: PiEngine, client: String) -> Line {
        Line(script: clearedEnvironment + "exec \(word(engine.node)) \"$0\" probe", positional: [client])
    }

    /// Shell words that unset every `PI_*`, `JITI_*`, `NODE_*` and `OPENSSL_CONF` but
    /// `NODE_EXTRA_CA_CERTS`, for a line that runs Shepherd's node after a login shell.
    static let clearedEnvironment = "_shepherd_ca=${NODE_EXTRA_CA_CERTS-}; unset -m 'PI_*' 'JITI_*' 'NODE_*' 'OPENSSL_CONF'; "
        + "[[ -n $_shepherd_ca ]] && export NODE_EXTRA_CA_CERTS=$_shepherd_ca; unset _shepherd_ca; "

    /// The engine's node as argv: its path, or `env` finding the tests' node on PATH.
    static func node(_ engine: PiEngine) -> [String] {
        switch engine.node {
        case .executable(let path): [path]
        case .onPath(let name): ["/usr/bin/env", name]
        }
    }

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
