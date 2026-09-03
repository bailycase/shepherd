public struct Space: Codable, Hashable, Sendable, Identifiable {
    public var id: SpaceID
    public var name: String
    public var path: String
    /// Hidden spaces never render in the sidebar tree or space pickers. The
    /// reserved automations space is the only producer: automation agents
    /// must live in a space (the state contract), but their UI is the
    /// AUTOMATIONS section, not a space row. Decodes false from old files.
    public var hidden: Bool

    public init(
        id: SpaceID = SpaceID(),
        name: String,
        path: String,
        hidden: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, hidden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SpaceID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

public struct Tab: Codable, Hashable, Sendable, Identifiable {
    public var id: TabID
    /// nil for a global shell — a workspace outside every space (the sidebar's
    /// SHELLS section). Space tabs always carry their space.
    public var spaceID: SpaceID?
    public var order: Int
    public var layout: PaneNode
    /// Set on the ephemeral layout hosting an agent's subagent-inspector
    /// pane. Inspector tabs are session-scoped UI: the server purges them at
    /// startup (their viewer process died with the app) and deletes them
    /// with their agent. Decodes nil from older state files.
    public var inspectorFor: AgentID?
    /// Display name for global shells ("~/src", "logs"). Space tabs derive
    /// their identity from agents and never need one.
    public var name: String?
    /// True when a shell name was explicitly assigned by the user.
    public var nameIsFinal: Bool
    /// The command a shell was running when last observed ("pi", "htop"),
    /// re-typed into the fresh shell on the first spawn after relaunch —
    /// processes die with the app, so this is how a shell "restores".
    /// Shell-only, like `name`.
    public var restoreCommand: String?

    public init(
        id: TabID = TabID(),
        spaceID: SpaceID?,
        order: Int,
        layout: PaneNode,
        inspectorFor: AgentID? = nil,
        name: String? = nil,
        nameIsFinal: Bool = false,
        restoreCommand: String? = nil
    ) {
        self.id = id
        self.spaceID = spaceID
        self.order = order
        self.layout = layout
        self.inspectorFor = inspectorFor
        self.name = name
        self.nameIsFinal = nameIsFinal
        self.restoreCommand = restoreCommand
    }

    /// A global shell: no space, no agents, just a terminal workspace.
    public var isShell: Bool { spaceID == nil }

    private enum CodingKeys: String, CodingKey {
        case id, spaceID, order, layout, inspectorFor, name, nameIsFinal, restoreCommand
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(TabID.self, forKey: .id)
        spaceID = try c.decodeIfPresent(SpaceID.self, forKey: .spaceID)
        order = try c.decode(Int.self, forKey: .order)
        layout = try c.decode(PaneNode.self, forKey: .layout)
        inspectorFor = try c.decodeIfPresent(AgentID.self, forKey: .inspectorFor)
        // `name`/`restoreCommand` are shell-only. Daemon-era state files
        // carried a (now meaningless) title on every space tab; dropping it
        // there keeps those files converging on the next write.
        name = spaceID == nil ? try c.decodeIfPresent(String.self, forKey: .name) : nil
        // Older shell names were user-assigned; preserve them rather than
        // guessing whether "~" was automatic or explicit.
        nameIsFinal = spaceID == nil ? (try c.decodeIfPresent(Bool.self, forKey: .nameIsFinal) ?? true) : false
        restoreCommand = spaceID == nil ? try c.decodeIfPresent(String.self, forKey: .restoreCommand) : nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(spaceID, forKey: .spaceID)
        try c.encode(order, forKey: .order)
        try c.encode(layout, forKey: .layout)
        try c.encodeIfPresent(inspectorFor, forKey: .inspectorFor)
        if isShell {
            try c.encodeIfPresent(name, forKey: .name)
            try c.encode(nameIsFinal, forKey: .nameIsFinal)
            try c.encodeIfPresent(restoreCommand, forKey: .restoreCommand)
        }
    }
}

public struct Agent: Codable, Hashable, Sendable, Identifiable {
    public var id: AgentID
    /// Sidebar title. Starts as the agent's opening prompt (truncated) and is
    /// replaced once pi's namer proposes a real title, unless `nameIsFinal`.
    public var name: String
    public var spaceID: SpaceID
    public var tabID: TabID
    public var paneID: PaneID?
    public var status: AgentStatus
    public var model: String?
    public var thinkingLevel: ThinkingLevel?
    /// True once the name is settled — either the namer landed a title or the
    /// user renamed the agent by hand. The namer never overwrites a final
    /// name — a manual title is never clobbered.
    public var nameIsFinal: Bool
    /// The pi session this agent is currently in. Defaults to the agent's own
    /// id, but `/new` and `/resume` move pi to a different session — the
    /// extension reports the change so relaunching reopens what the user was
    /// last working in rather than the original conversation.
    public var piSessionID: String?
    /// Set when the agent was created on a git worktree Shepherd made for it
    /// (the branch name, e.g. "worktree/calm-stone-3831"). Display-only
    /// identity — the sidebar renders such agents as worktrees of their
    /// space. Decodes nil from older state files.
    public var worktreeBranch: String?
    /// The base the worktree branched from ("origin/main", "feat/x") —
    /// recorded at creation so Finalize can target the PR at the branch the
    /// work actually started from. Decodes nil from older state files.
    public var worktreeBase: String?
    /// The actual checkout path. Shepherd-created worktrees can derive it
    /// from repo + branch; imported worktrees may use any directory name.
    public var worktreePath: String?

    public init(
        id: AgentID = AgentID(),
        name: String,
        spaceID: SpaceID,
        tabID: TabID,
        paneID: PaneID? = nil,
        status: AgentStatus = .idle,
        model: String? = nil,
        thinkingLevel: ThinkingLevel? = nil,
        nameIsFinal: Bool = false,
        piSessionID: String? = nil,
        worktreeBranch: String? = nil,
        worktreeBase: String? = nil,
        worktreePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.spaceID = spaceID
        self.tabID = tabID
        self.paneID = paneID
        self.status = status
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.nameIsFinal = nameIsFinal
        self.piSessionID = piSessionID
        self.worktreeBranch = worktreeBranch
        self.worktreeBase = worktreeBase
        self.worktreePath = worktreePath
    }

    /// The pi session to launch this agent with. Falls back to the agent's id,
    /// which is what a brand-new agent starts in.
    public var effectivePiSessionID: String {
        piSessionID ?? id.rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, spaceID, tabID, paneID, status, model, thinkingLevel, nameIsFinal
        case piSessionID, worktreeBranch, worktreeBase, worktreePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(AgentID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        spaceID = try c.decode(SpaceID.self, forKey: .spaceID)
        tabID = try c.decode(TabID.self, forKey: .tabID)
        paneID = try c.decodeIfPresent(PaneID.self, forKey: .paneID)
        status = try c.decode(AgentStatus.self, forKey: .status)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        thinkingLevel = try c.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel)
        // Absent in pre-autoname state.json files; those names were picked by a
        // human (or the old name generator) and must not be overwritten.
        nameIsFinal = try c.decodeIfPresent(Bool.self, forKey: .nameIsFinal) ?? true
        // Absent before session tracking; those agents are still in the
        // session named after their own id.
        piSessionID = try c.decodeIfPresent(String.self, forKey: .piSessionID)
        // Absent before worktree agents existed.
        worktreeBranch = try c.decodeIfPresent(String.self, forKey: .worktreeBranch)
        worktreeBase = try c.decodeIfPresent(String.self, forKey: .worktreeBase)
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
    }
}

/// A saved monitoring/recurring task: a prompt run by a normal agent when
/// started. The automation persists; its agent is ordinary and ephemeral.
public struct Automation: Codable, Hashable, Sendable, Identifiable {
    public var id: AutomationID
    /// Sidebar row title ("pr-watch #4821").
    public var name: String
    /// The opening prompt its agent is launched with.
    public var prompt: String
    /// Working directory the agent runs in; resolved to a space at start.
    public var cwd: String
    /// Enabled automations auto-start their agent on app launch.
    public var enabled: Bool
    /// The agent currently running this automation, nil when stopped.
    /// Cleared at server startup (sessions die with the app) unless the
    /// automation is enabled and restarts.
    public var agentID: AgentID?

    public init(
        id: AutomationID = AutomationID(),
        name: String,
        prompt: String,
        cwd: String,
        enabled: Bool = true,
        agentID: AgentID? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.cwd = cwd
        self.enabled = enabled
        self.agentID = agentID
    }
}

/// The server's authoritative snapshot.
public struct ShepherdState: Codable, Hashable, Sendable {
    public var spaces: [Space]
    public var tabs: [Tab]
    public var agents: [Agent]
    public var automations: [Automation]

    public init(spaces: [Space] = [], tabs: [Tab] = [], agents: [Agent] = [], automations: [Automation] = []) {
        self.spaces = spaces
        self.tabs = tabs
        self.agents = agents
        self.automations = automations
    }

    private enum CodingKeys: String, CodingKey {
        case spaces, tabs, agents, automations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spaces = try c.decode([Space].self, forKey: .spaces)
        tabs = try c.decode([Tab].self, forKey: .tabs)
        agents = try c.decode([Agent].self, forKey: .agents)
        // Absent in pre-automation state files.
        automations = try c.decodeIfPresent([Automation].self, forKey: .automations) ?? []
        // `subagents` in older state.json files is ignored: agents now nest
        // their children inside their own pi process (pi-subagents), so
        // Shepherd has no separate entity to track.
    }
}
