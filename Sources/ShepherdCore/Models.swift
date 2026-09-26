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

/// A pane layout: an agent's thread plus any terminal panes opened beside it, or a host-side
/// utility terminal (`inspectorFor`). Global shells and space shell workspaces are gone; the
/// server drops their tabs from older state files at startup, and the shell-only keys those
/// tabs carried (`name`, `nameIsFinal`, `restoreCommand`) are ignored when decoding.
public struct Tab: Codable, Hashable, Sendable, Identifiable {
    public var id: TabID
    /// The tab's space. Optional only so state files with global shells (nil) still decode.
    public var spaceID: SpaceID?
    public var order: Int
    public var layout: PaneNode
    /// Set on a host-side utility terminal opened for a remote client (a remote
    /// `gh auth login`). Session-scoped: the server purges them at startup and deletes them
    /// with their agent. Decodes nil from older state files.
    public var inspectorFor: AgentID?

    public init(
        id: TabID = TabID(),
        spaceID: SpaceID?,
        order: Int,
        layout: PaneNode,
        inspectorFor: AgentID? = nil
    ) {
        self.id = id
        self.spaceID = spaceID
        self.order = order
        self.layout = layout
        self.inspectorFor = inspectorFor
    }
}

/// How a session's process is driven. Every agent runs `pi --mode rpc`; PTYs serve shells.
/// Raw values are the wire spelling and must not change.
public enum SessionRuntime: String, Codable, Hashable, Sendable {
    /// A PTY rendered by Ghostty (shells and auxiliary panes).
    case pty = "terminal"
    /// `pi --mode rpc` on pipes; Shepherd is the only UI.
    case rpc
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
    /// (the branch name, e.g. "agent/calm-stone-3831"). Display-only
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
    /// When the agent last started or finished a turn or was sent a message (ms since 1970):
    /// the order of the sidebar's Recents, which a streamed token or a repeated status report
    /// never moves. Live state, set by the host (and by the app when it creates the agent) and
    /// broadcast; written to state.json only along with another change. Nil from older hosts
    /// and state files.
    public var lastActiveAt: Double?
    /// What the agent is waiting on you for: the title of the question pi is asking in its
    /// thread. Live state, set by the host while a question is open and broadcast, so the
    /// sidebar's Needs you can say why without reading the thread. Never written to state.json
    /// (`ShepherdState.persisted`). Nil when nothing is asked, and from older hosts.
    public var waitingOn: String?
    /// The agent's own word or two for that question ("retention?"), when its asking tool
    /// carried one (the status extension's `short`). Live like `waitingOn`, set and cleared with
    /// it, and never written to state.json. Nil when the agent gave none, and from older hosts:
    /// the sidebar then cuts the question itself.
    public var waitingReason: String?
    /// The branch the agent's checkout is on and how many files differ from its HEAD, as the host
    /// last read them (`git status`). Live state: refreshed by the host after the agent's tool
    /// calls, turns, commits and focus, and broadcast so remote clients draw the same header.
    /// Nil until the host has read it, when the directory is no repository, and from older hosts.
    public var checkout: AgentCheckout?
    /// The design this agent draws (the Design tool): its extension and skill load with it.
    /// Decodes nil from older state files; startup clears it when the design is gone.
    public var designID: DesignID?

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
        worktreePath: String? = nil,
        lastActiveAt: Double? = nil,
        waitingOn: String? = nil,
        waitingReason: String? = nil,
        checkout: AgentCheckout? = nil,
        designID: DesignID? = nil
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
        self.lastActiveAt = lastActiveAt
        self.waitingOn = waitingOn
        self.waitingReason = waitingReason
        self.checkout = checkout
        self.designID = designID
    }

    /// The pi session to launch this agent with. Falls back to the agent's id,
    /// which is what a brand-new agent starts in.
    public var effectivePiSessionID: String {
        piSessionID ?? id.rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, spaceID, tabID, paneID, status, model, thinkingLevel, nameIsFinal
        case piSessionID, worktreeBranch, worktreeBase, worktreePath, lastActiveAt, waitingOn, waitingReason, checkout, designID, runtime
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
        // A level this build does not know (a newer build's) reads as none: pi's default.
        thinkingLevel = (try? c.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel)) ?? nil
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
        // Absent before Recents, and from hosts that don't report them.
        lastActiveAt = try c.decodeIfPresent(Double.self, forKey: .lastActiveAt)
        waitingOn = try c.decodeIfPresent(String.self, forKey: .waitingOn)
        waitingReason = try c.decodeIfPresent(String.self, forKey: .waitingReason)
        // Absent before the header's branch chip, and from hosts that don't read it.
        checkout = try c.decodeIfPresent(AgentCheckout.self, forKey: .checkout)
        // Absent before the Design tool.
        designID = try c.decodeIfPresent(DesignID.self, forKey: .designID)
        // `runtime` is ignored: agents from the terminal era ("terminal") relaunch over RPC in
        // the same pi session, which is the whole migration.
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(spaceID, forKey: .spaceID)
        try c.encode(tabID, forKey: .tabID)
        try c.encodeIfPresent(paneID, forKey: .paneID)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(thinkingLevel, forKey: .thinkingLevel)
        try c.encode(nameIsFinal, forKey: .nameIsFinal)
        try c.encodeIfPresent(piSessionID, forKey: .piSessionID)
        try c.encodeIfPresent(worktreeBranch, forKey: .worktreeBranch)
        try c.encodeIfPresent(worktreeBase, forKey: .worktreeBase)
        try c.encodeIfPresent(worktreePath, forKey: .worktreePath)
        try c.encodeIfPresent(lastActiveAt, forKey: .lastActiveAt)
        try c.encodeIfPresent(waitingOn, forKey: .waitingOn)
        try c.encodeIfPresent(waitingReason, forKey: .waitingReason)
        try c.encodeIfPresent(checkout, forKey: .checkout)
        try c.encodeIfPresent(designID, forKey: .designID)
        // Older remote clients default a missing runtime to terminal and would try to attach a
        // PTY that does not exist.
        try c.encode(SessionRuntime.rpc, forKey: .runtime)
    }
}

/// An agent's checkout as its host last read it: the branch (a short commit when detached) and
/// the number of files that differ from HEAD, untracked ones included, so it matches the review's
/// file count for the working tree.
public struct AgentCheckout: Codable, Hashable, Sendable {
    public var branch: String
    public var changedFiles: Int

    public init(branch: String, changedFiles: Int) {
        self.branch = branch
        self.changedFiles = changedFiles
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

/// A design (the Design tool): a canvas of HTML boards drawn by its design agent. Its files live
/// in the support directory's `designs/<id>/` (docs/designs.md); this record is what the
/// workspace keeps about it.
public struct Design: Codable, Hashable, Sendable, Identifiable {
    public var id: DesignID
    /// The name on its card and in Recents, kept equal to its canvas.json `title`.
    public var name: String
    /// The project it belongs to: its agent works in this space's directory.
    public var spaceID: SpaceID
    /// The agent that draws it. Nil until one is attached, and cleared when that agent is
    /// removed: opening the design then starts a fresh one.
    public var agentID: AgentID?
    /// The design system it is drawn in (a `ds/<namespace>` folder name), if any.
    public var systemNamespace: String?
    /// When it was created and last changed (ms since 1970). A board write moves
    /// `lastActiveAt` as live state, written to state.json along with another change.
    public var createdAt: Double
    public var lastActiveAt: Double
    /// How many boards its canvas lists. Live state the host derives from its files and
    /// broadcasts; never written to state.json (`ShepherdState.persisted`). Nil until read.
    public var boardCount: Int?
    /// Made by "Build one from a repo": its agent builds a design system from the project, and
    /// its screen is that system's page (DZSystem) rather than a canvas. It has no card and no
    /// Recents row of its own. Decodes false from older state files.
    public var buildsSystem: Bool

    public init(
        id: DesignID = DesignID(),
        name: String,
        spaceID: SpaceID,
        agentID: AgentID? = nil,
        systemNamespace: String? = nil,
        createdAt: Double,
        lastActiveAt: Double? = nil,
        boardCount: Int? = nil,
        buildsSystem: Bool = false
    ) {
        self.id = id
        self.name = name
        self.spaceID = spaceID
        self.agentID = agentID
        self.systemNamespace = systemNamespace
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt ?? createdAt
        self.boardCount = boardCount
        self.buildsSystem = buildsSystem
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, spaceID, agentID, systemNamespace, createdAt, lastActiveAt, boardCount, buildsSystem
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(DesignID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        spaceID = try c.decode(SpaceID.self, forKey: .spaceID)
        agentID = try c.decodeIfPresent(AgentID.self, forKey: .agentID)
        systemNamespace = try c.decodeIfPresent(String.self, forKey: .systemNamespace)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        lastActiveAt = try c.decode(Double.self, forKey: .lastActiveAt)
        boardCount = try c.decodeIfPresent(Int.self, forKey: .boardCount)
        buildsSystem = try c.decodeIfPresent(Bool.self, forKey: .buildsSystem) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(spaceID, forKey: .spaceID)
        try c.encodeIfPresent(agentID, forKey: .agentID)
        try c.encodeIfPresent(systemNamespace, forKey: .systemNamespace)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastActiveAt, forKey: .lastActiveAt)
        try c.encodeIfPresent(boardCount, forKey: .boardCount)
        // Only a system build says so, so a design's record reads as it did before.
        if buildsSystem { try c.encode(buildsSystem, forKey: .buildsSystem) }
    }
}

/// The server's authoritative snapshot.
public struct ShepherdState: Codable, Hashable, Sendable {
    public var spaces: [Space]
    public var tabs: [Tab]
    public var agents: [Agent]
    public var automations: [Automation]
    public var designs: [Design]

    public init(spaces: [Space] = [], tabs: [Tab] = [], agents: [Agent] = [], automations: [Automation] = [],
                designs: [Design] = []) {
        self.spaces = spaces
        self.tabs = tabs
        self.agents = agents
        self.automations = automations
        self.designs = designs
    }

    private enum CodingKeys: String, CodingKey {
        case spaces, tabs, agents, automations, designs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spaces = try c.decode([Space].self, forKey: .spaces)
        tabs = try c.decode([Tab].self, forKey: .tabs)
        agents = try c.decode([Agent].self, forKey: .agents)
        // Absent in pre-automation state files.
        automations = try c.decodeIfPresent([Automation].self, forKey: .automations) ?? []
        // Absent before the Design tool.
        designs = try c.decodeIfPresent([Design].self, forKey: .designs) ?? []
        // `subagents` in older state.json files is ignored: agents now nest
        // their children inside their own pi process (pi-subagents), so
        // Shepherd has no separate entity to track.
    }
}

extension ShepherdState {
    /// The state as state.json keeps it: without what only a running host knows (the question
    /// each agent waits on and its short reason, and each design's board count).
    public var persisted: ShepherdState {
        let waiting = agents.contains(where: { $0.waitingOn != nil || $0.waitingReason != nil })
        let counted = designs.contains(where: { $0.boardCount != nil })
        guard waiting || counted else { return self }
        var state = self
        for index in state.agents.indices {
            state.agents[index].waitingOn = nil
            state.agents[index].waitingReason = nil
        }
        for index in state.designs.indices {
            state.designs[index].boardCount = nil
        }
        return state
    }

    /// Whether every agent's level is one a client from before minimal, xhigh and max decodes.
    public var usesOnlyLegacyThinkingLevels: Bool {
        agents.allSatisfy { $0.thinkingLevel.map(ThinkingLevel.legacy.contains) ?? true }
    }

    /// The state as such a client can decode it: each agent's level clamped to
    /// `ThinkingLevel.legacy` (only a fresh session starts with it, and pi clamps it anyway).
    public func legacyThinkingLevels() -> ShepherdState {
        guard !usesOnlyLegacyThinkingLevels else { return self }
        var state = self
        for index in state.agents.indices {
            state.agents[index].thinkingLevel = state.agents[index].thinkingLevel?.clamped(to: ThinkingLevel.legacy)
        }
        return state
    }
}

extension ShepherdState {
    /// Whether an agent draws one of this workspace's designs. Its thread is that design's chat,
    /// never an ordinary thread (docs/designs.md › Design agents and ordinary threads).
    public func isDesignAgent(_ agent: Agent) -> Bool {
        guard let design = agent.designID else { return false }
        return designs.contains { $0.id == design }
    }

    public func isDesignAgent(_ agentID: AgentID) -> Bool {
        agents.first { $0.id == agentID }.map(isDesignAgent) ?? false
    }

    /// The workspace as a remote client gets it: without its designs, the agents that draw them,
    /// or their layouts. No client has a design screen yet, so any of it would show as a thread.
    public var withoutDesigns: ShepherdState {
        guard !designs.isEmpty else { return self }
        var state = self
        let drawers = agents.filter(isDesignAgent)
        let ids = Set(drawers.map(\.id)), tabs = Set(drawers.map(\.tabID))
        state.agents.removeAll { ids.contains($0.id) }
        state.tabs.removeAll { tabs.contains($0.id) }
        state.designs = []
        return state
    }
}
