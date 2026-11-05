import Foundation

/// The twelve hook events, in Settings order, with what Settings says
/// about each.
public enum HookEvent: String, CaseIterable, Codable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case stop = "Stop"
    case notification = "Notification"
    case sessionEnd = "SessionEnd"

    /// The Settings label ("Before a tool runs").
    public var label: String {
        switch self {
        case .sessionStart: "When a thread starts"
        case .userPromptSubmit: "When you send a message"
        case .preToolUse: "Before a tool runs"
        case .permissionRequest: "When a tool asks to run"
        case .postToolUse: "After a tool runs"
        case .preCompact: "Before compaction"
        case .postCompact: "After compaction"
        case .subagentStart: "When a subagent starts"
        case .subagentStop: "When a subagent finishes"
        case .stop: "When the agent finishes"
        case .notification: "When the agent needs you"
        case .sessionEnd: "When a thread ends"
        }
    }

    /// One line on what a hook on this event can do.
    public var effect: String {
        switch self {
        case .sessionStart: "Add context"
        case .userPromptSubmit: "Block the message, add context"
        case .preToolUse: "Allow, deny, ask, change the input"
        case .permissionRequest: "Loaded, never fires: Shepherd's tools never ask"
        case .postToolUse: "Send feedback to the agent"
        case .preCompact, .postCompact: "Notify"
        case .subagentStart: "Add context"
        case .subagentStop: "Send the subagent back"
        case .stop: "Send the agent back (at most 3 in a row)"
        case .notification: "Notify"
        case .sessionEnd: "Notify; 1 s limit"
        }
    }

    /// What the matcher is tested against, or nil when the event takes none.
    public var matcherHint: String? {
        switch self {
        case .sessionStart: "Source: startup, resume, compact"
        case .preToolUse, .permissionRequest, .postToolUse: "Tool name, e.g. Edit|Write or Bash"
        case .preCompact, .postCompact: "manual or auto"
        case .subagentStart, .subagentStop: "Profile name, e.g. scout"
        case .notification: "Reason: question, failed, signed out"
        case .userPromptSubmit, .stop, .sessionEnd: nil
        }
    }

    /// Seconds a handler without its own `timeout` gets.
    public var defaultTimeout: Double { self == .sessionEnd ? 1 : 60 }
    /// The most a handler may ask for (`SessionEnd` caps at 3 s), or nil for no cap.
    public var maximumTimeout: Double? { self == .sessionEnd ? 3 : nil }
}

/// Matchers and tool names.
public enum HookMatcher {
    /// Claude Code tool name → the agent's tool. `mcp__…` names are the same on both sides.
    public static let claudeToAgent: KeyValuePairs<String, String> = [
        "Bash": "bash", "Read": "read", "Edit": "edit", "MultiEdit": "edit",
        "Write": "write", "Grep": "grep", "Glob": "find", "LS": "ls",
    ]

    /// The agent's built-in tools, in the order Settings lists them.
    public static let agentTools = ["bash", "read", "edit", "write", "grep", "find", "ls"]

    /// The Claude Code names for an agent tool (`edit` → `Edit`, `MultiEdit`); empty when none.
    public static func claudeNames(forAgentTool tool: String) -> [String] {
        claudeToAgent.filter { $0.value == tool }.map { $0.key }
    }

    /// The Claude Code name for an agent tool (the first), else the tool's own name.
    public static func claudeName(forAgentTool tool: String) -> String {
        claudeNames(forAgentTool: tool).first ?? tool
    }

    /// Whether `matcher` is a regular expression Shepherd can test (empty and `*` always are).
    public static func isValid(_ matcher: String) -> Bool { regex(matcher) != nil || isWildcard(matcher) }

    /// Whether `matcher` matches the whole of `name` (`^(?:…)$`); empty or `*` match everything.
    /// An invalid expression matches nothing.
    public static func matches(_ matcher: String, name: String) -> Bool {
        if isWildcard(matcher) { return true }
        guard let regex = regex(matcher) else { return false }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// Whether `matcher` matches an agent tool by its own name or any of its Claude Code names.
    public static func matches(_ matcher: String, agentTool tool: String) -> Bool {
        ([tool] + claudeNames(forAgentTool: tool)).contains { matches(matcher, name: $0) }
    }

    /// The tools of `tools` (default: the built-ins) that `matcher` matches, in their order.
    public static func agentTools(matching matcher: String, among tools: [String] = agentTools) -> [String] {
        tools.filter { matches(matcher, agentTool: $0) }
    }

    private static func isWildcard(_ matcher: String) -> Bool { matcher.isEmpty || matcher == "*" }

    // ponytail: ICU regular expressions, close to but not exactly JavaScript's; exotic syntax may differ from the runtime.
    private static func regex(_ matcher: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "^(?:" + matcher + ")$")
    }
}
