import ShepherdProtocol
import ShepherdSessions

/// Shell panes keep the user's login command and configuration untouched.
enum ShellIntegration {
    static func command(shell: [String]) -> SessionCommand {
        // PTYSession merges with the app environment, which can itself have
        // been launched from an agent. Empty values disable agent-only hooks, and
        // leave `pi` in a pane to the user's own pi: pi's home, package and
        // offline switches come from their startup files, never from an agent's.
        let env = Dictionary(uniqueKeysWithValues: PiHome.agentOnlyEnvironment.map { ($0, "") })
        return SessionCommand(argv: shell, env: env)
    }
}
