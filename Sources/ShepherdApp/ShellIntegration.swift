import ShepherdProtocol

/// Shell panes keep the user's login command and configuration untouched.
enum ShellIntegration {
    static func command(shell: [String]) -> SessionCommand {
        // PTYSession merges with the app environment, which can itself have
        // been launched from an agent. Empty values disable agent-only hooks, and
        // leave `pi` in a pane to the user's own pi: pi's home, package and
        // offline switches come from their startup files, never from an agent's.
        let env = Dictionary(uniqueKeysWithValues: [
            "SHEPHERD_AGENT_ID", "SHEPHERD_SOCKET", "SHEPHERD_EXT_STATUS",
            "SHEPHERD_EXT_PANES", "SHEPHERD_NEEDS_NAME", "SHEPHERD_AUTOMATION",
            "SHEPHERD_MODEL", "SHEPHERD_INSTRUCTIONS_DIR", "SHEPHERD_SUGGEST_FILES",
            "SHEPHERD_EXT_MCP", "SHEPHERD_EXT_MCP_CLIENT", "SHEPHERD_EXT_MCP_CONFIG", "SHEPHERD_EXT_MCP_CACHE",
            "SHEPHERD_EXT_MCP_PROJECT", "SHEPHERD_PI_EXECUTABLE",
            "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR", "PI_PACKAGE_DIR", "PI_OFFLINE", "PI_SUBAGENTS_TEMP_ROOT",
        ].map { ($0, "") })
        return SessionCommand(argv: shell, env: env)
    }
}
