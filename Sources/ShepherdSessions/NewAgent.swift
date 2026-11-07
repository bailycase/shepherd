import Foundation
import ShepherdCore
import ShepherdProtocol

/// What a new agent starts from: the New Agent sheet, ⌘N, a worktree, a design, an automation.
public struct NewAgentConfig {
    public var spaceID: SpaceID
    public var workingDirectory: String
    public var reservedAgentID: AgentID?
    public var coordinatorFor: ProjectID?
    public var model: String?
    public var thinking: ThinkingLevel
    public var initialPrompt: String?
    /// Go to pi with the opening prompt (the New thread page's attachments).
    public var initialImages: [NativeImage] = []
    /// Design references send their opening message after the session starts.
    public var openingReferencesPending = false
    /// A caller-chosen starting name (worktree agents wear their branch
    /// leaf). Provisional like a prompt-derived name: pi's namer retitles it
    /// from the agent's first prompt when auto-naming is on.
    public var initialName: String?
    /// The branch of the git worktree this agent was created on, when
    /// Shepherd made one for it. Persisted on the agent so the sidebar can
    /// render it as a worktree of its space.
    public var worktreeBranch: String?
    /// The base the worktree branched from; Finalize targets the PR at it.
    public var worktreeBase: String?
    /// Actual checkout path for imported worktrees whose directory name does
    /// not follow Shepherd's generated repo-branch convention.
    public var worktreePath: String?
    /// An automation's watch agent: spawned with SHEPHERD_AUTOMATION=1 so
    /// the panes extension withholds the automation_* tools (a watcher must
    /// never create watchers).
    public var isAutomation = false
    /// Resume an existing pi session (a forked subagent transcript already in the cwd's
    /// session directory) instead of a fresh one keyed by the agent id.
    public var piSessionID: String?
    /// The design this agent draws: it launches with the design tools, keeps its name (the
    /// design's), and has no row of its own in Recents.
    public var designID: DesignID?
    /// The speed it starts on; nil takes Settings ▸ Agents ▸ Speed for new threads.
    public var serviceTier: ServiceTier?
    /// A triggered automation's run thread (`Agent.automationOrigin`).
    public var automationOrigin: AutomationOrigin?

    public init(spaceID: SpaceID, workingDirectory: String, reservedAgentID: AgentID? = nil, coordinatorFor: ProjectID? = nil,
                model: String? = nil, thinking: ThinkingLevel, initialPrompt: String? = nil, initialImages: [NativeImage] = [],
                openingReferencesPending: Bool = false, initialName: String? = nil, worktreeBranch: String? = nil,
                worktreeBase: String? = nil, worktreePath: String? = nil, isAutomation: Bool = false,
                piSessionID: String? = nil, designID: DesignID? = nil, serviceTier: ServiceTier? = nil,
                automationOrigin: AutomationOrigin? = nil) {
        self.spaceID = spaceID
        self.workingDirectory = workingDirectory
        self.reservedAgentID = reservedAgentID
        self.coordinatorFor = coordinatorFor
        self.model = model
        self.thinking = thinking
        self.initialPrompt = initialPrompt
        self.initialImages = initialImages
        self.openingReferencesPending = openingReferencesPending
        self.initialName = initialName
        self.worktreeBranch = worktreeBranch
        self.worktreeBase = worktreeBase
        self.worktreePath = worktreePath
        self.isAutomation = isAutomation
        self.piSessionID = piSessionID
        self.designID = designID
        self.serviceTier = serviceTier
        self.automationOrigin = automationOrigin
    }

    /// The name an agent wears until pi's namer proposes a real title: its
    /// opening prompt, collapsed to one line and truncated on a word boundary.
    /// ⌘N agents have no prompt, so they start as "New agent".
    public static func provisionalName(for prompt: String?) -> String {
        let flattened = (prompt ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flattened.isEmpty else { return "New agent" }
        let limit = 48
        guard flattened.count > limit else { return flattened }
        let clipped = flattened.prefix(limit)
        // Prefer cutting at the last space so the label never ends mid-word.
        let stem = clipped.lastIndex(of: " ").map { clipped[..<$0] } ?? clipped
        return stem.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The new agent, its tab, and the tab's one pane, placed after its space's last tab in `state`. A new agent is
    /// exactly its thread: terminals are the agent's to open (the panes extension) or the
    /// user's (⌘D, ⌘J); starting with one put an idle shell in front of every new agent.
    public func thread(id: AgentID, in state: ShepherdState, defaultServiceTier: ServiceTier) -> (agent: Agent, tab: ShepherdCore.Tab, pane: LeafPane) {
        let primary = LeafPane(cwd: (workingDirectory as NSString).expandingTildeInPath, agentID: id)
        let order = (state.tabs.filter { $0.spaceID == spaceID }.map(\.order).max() ?? -1) + 1
        let tab = ShepherdCore.Tab(spaceID: spaceID, order: order, layout: .leaf(primary))
        var agent = Agent(
            id: id,
            name: initialName ?? Self.provisionalName(for: initialPrompt),
            spaceID: spaceID,
            tabID: tab.id,
            paneID: primary.id,
            status: .idle,
            model: model,
            thinkingLevel: thinking,
            // Provisional: pi's namer replaces it with a real title from the
            // agent's opening prompt, whether that prompt came from the sheet
            // or was typed into the TUI afterwards (⌘N). A design names itself.
            nameIsFinal: designID != nil || coordinatorFor != nil,
            piSessionID: piSessionID,
            worktreeBranch: worktreeBranch,
            worktreeBase: worktreeBase,
            worktreePath: worktreePath,
            // A new agent leads its activity group.
            lastActiveAt: SessionServer.nowMilliseconds(),
            designID: designID,
            coordinatorFor: coordinatorFor,
            serviceTier: serviceTier ?? defaultServiceTier
        )
        agent.automationOrigin = automationOrigin
        return (agent, tab, primary)
    }
}
