import ShepherdProtocol

/// Shell panes keep the user's login command and configuration untouched.
enum ShellIntegration {
    static func command(shell: [String]) -> SessionCommand {
        // PTYSession merges with the app environment, which can itself have
        // been launched from an agent. Empty values disable agent-only hooks.
        let env = Dictionary(uniqueKeysWithValues: [
            "SHEPHERD_AGENT_ID", "SHEPHERD_SOCKET", "SHEPHERD_EXT_STATUS",
            "SHEPHERD_EXT_PANES", "SHEPHERD_NEEDS_NAME", "SHEPHERD_AUTOMATION",
            "SHEPHERD_MODEL", "SHEPHERD_INSTRUCTIONS_DIR", "SHEPHERD_SUGGEST_FILES",
        ].map { ($0, "") })
        return SessionCommand(argv: shell, env: env)
    }
}
