import Foundation

/// What the Context card's system-prompt breakdown calls each tool's group: "browser tools",
/// "terminal tools", "MCP". The host knows a tool by name only (pi lists the definitions in its
/// system messages and says no more), so the group is read off the name, by the table
/// `Tests/Extensions/context-tools.json` holds for every tool Shepherd registers
/// (`ContextToolGroupsTests` checks the two agree). A name no row lists, such as an MCP server's
/// tool set to Each tool on its own or a tool one of the user's extensions registers, is "other tools".
enum ContextToolGroups {
    static let labels: [String: String] = [
        "pi": "pi tools", "terminal": "terminal tools", "agent": "agent tools", "automation": "automation tools",
        "review": "review tool", "subagents": "subagent tools", "browser": "browser tools", "mcp": "MCP", "design": "design tools",
        "instructions": "instruction suggestions", "other": "other tools",
    ]

    private static let piTools: Set<String> = ["read", "bash", "edit", "write", "grep", "find", "ls", "powershell"]
    private static let designTools: Set<String> = [
        "design_get", "design_note", "design_read", "board_write", "board_edit", "boards_edit", "board_search", "board_render", "board_extract",
        "canvas_update", "design_check", "comment_list", "comment_reply", "system_read", "system_write", "checkpoint_create",
        "checkpoint_list", "checkpoint_restore", "markup_propose",
    ]

    /// The group a tool belongs to: a key of `labels`.
    static func id(forTool name: String) -> String {
        if piTools.contains(name) { return "pi" }
        if name.hasPrefix("terminal_") { return "terminal" }
        if name.hasPrefix("agent_") { return "agent" }
        if name.hasPrefix("automation_") || name == "notify" { return "automation" }
        if name == "review_diff" { return "review" }
        if name.hasPrefix("shepherd_child_") || name == "shepherd_workflow" || name == "shepherd_mission" || name == "shepherd_parent_message" { return "subagents" }
        if name.hasPrefix("browser_") { return "browser" }
        if name == "mcp" { return "mcp" }
        if designTools.contains(name) { return "design" }
        if name == "suggest_instruction" { return "instructions" }
        return "other"
    }

    static func label(forTool name: String) -> String { labels[id(forTool: name)] ?? "other tools" }
}
