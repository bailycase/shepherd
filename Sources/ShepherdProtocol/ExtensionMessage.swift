import Foundation
import ShepherdCore

/// Wire traffic between pi extensions and the Unix socket the app hosts
/// (NDJSON, one message per line).
///
/// The status extension (`Extensions/shepherd-status.ts`) and the namer
/// (`Extensions/shepherd-namer.ts`) fire and forget. The panes extension
/// (`Extensions/shepherd-panes.ts`) issues id-correlated requests and reads
/// `ExtensionReply` lines on the same connection, so an agent can drive its
/// own workspace: open panes, run commands in them, read what they printed,
/// and close them.
public enum ExtensionMessage: Codable, Hashable, Sendable {
    /// Lifecycle status for one agent.
    case setAgentStatus(agentID: AgentID, status: AgentStatus)
    /// Generated title from the namer extension. The server applies it only
    /// while the agent's name is still provisional.
    case setAgentName(agentID: AgentID, name: String)
    /// The pi session the agent is now in. `/new` and `/resume` move pi to a
    /// different session, and the agent must reopen that one next launch.
    case setAgentSession(agentID: AgentID, piSessionID: String)
    /// Full replacement of an agent's live subagent (child run) projection,
    /// from the subagents extension. Display-only: never persisted.
    case setAgentChildren(agentID: AgentID, children: [ChildRun])
    /// A custom system notification from the notify extension's tool.
    /// Fire-and-forget, like status: never persisted, dies with the app.
    case notify(agentID: AgentID, title: String, body: String)
    /// The panes extension registered this connection for pushes: the app
    /// may deliver unsolicited `ExtensionReply.message` frames (peer-thread
    /// messages) on it from now on. Fire-and-forget.
    case helloAgent(agentID: AgentID)

    // MARK: Pane control (request/reply)

    /// Panes in the requesting agent's layout, with their current screens.
    case listPanes(id: Int, agentID: AgentID)
    /// Split an existing pane (default: the agent's own) and start a shell in
    /// the new half.
    case openPane(id: Int, agentID: AgentID, axis: SplitAxis, cwd: String?, relativeTo: PaneID?, command: String?)
    /// Close a pane. The agent's own pi pane is never closable this way.
    case closePane(id: Int, agentID: AgentID, paneID: PaneID)
    /// Make a pane the focused one in its layout.
    case focusPane(id: Int, agentID: AgentID, paneID: PaneID)
    /// Type text into a pane. `submit` appends a newline, running it.
    case sendPaneInput(id: Int, agentID: AgentID, paneID: PaneID, text: String, submit: Bool)
    /// Current visible screen of a pane, as plain text rows.
    case readPane(id: Int, agentID: AgentID, paneID: PaneID)

    // MARK: Agent peers (request/reply)

    /// The fleet: every top-level agent thread, for agent_send targeting.
    case listAgents(id: Int, agentID: AgentID)
    /// Type a framed message into another agent's pi prompt. Queued by pi
    /// naturally when the target is mid-turn.
    case sendToAgent(id: Int, agentID: AgentID, targetAgentID: AgentID, text: String)
    /// Spawn a new top-level agent thread with an opening prompt.
    case spawnAgent(id: Int, agentID: AgentID, cwd: String, prompt: String)

    // MARK: Automations (request/reply)

    /// Create a persisted automation. Unlike pane control this may come from
    /// any pi session (the automation skill), so `agentID` is optional —
    /// there may be no Shepherd agent behind the caller.
    case createAutomation(id: Int, name: String, prompt: String, cwd: String, enabled: Bool, start: Bool)
    /// All saved automations with their run state.
    case listAutomations(id: Int)
    /// Update fields by automation id; nil fields keep their value.
    case updateAutomation(id: Int, automationID: AutomationID, name: String?, prompt: String?, cwd: String?, enabled: Bool?)
    /// Remove the saved automation (a running agent keeps running).
    case deleteAutomation(id: Int, automationID: AutomationID)
    /// Start a stopped automation's watch agent.
    case startAutomation(id: Int, automationID: AutomationID)
    /// Stop a running automation by deleting its watch agent.
    case stopAutomation(id: Int, automationID: AutomationID)

    private enum CodingKeys: String, CodingKey {
        case type, id, agentID, status, name, piSessionID, children
        case paneID, axis, cwd, relativeTo, command, text, submit
        case title, body
        case prompt, enabled, start, automationID, targetAgentID
    }

    private enum Kind: String, Codable {
        case setAgentStatus, setAgentName, setAgentSession, setAgentChildren, notify, helloAgent
        case listPanes, openPane, closePane, focusPane, sendPaneInput, readPane
        case createAutomation, listAutomations, updateAutomation, deleteAutomation
        case startAutomation, stopAutomation
        case listAgents, sendToAgent, spawnAgent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .setAgentStatus:
            self = .setAgentStatus(
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                status: try c.decode(AgentStatus.self, forKey: .status)
            )
        case .setAgentName:
            self = .setAgentName(
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                name: try c.decode(String.self, forKey: .name)
            )
        case .setAgentSession:
            self = .setAgentSession(
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                piSessionID: try c.decode(String.self, forKey: .piSessionID)
            )
        case .setAgentChildren:
            self = .setAgentChildren(
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                children: try c.decode([ChildRun].self, forKey: .children)
            )
        case .notify:
            self = .notify(
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                title: try c.decode(String.self, forKey: .title),
                body: try c.decodeIfPresent(String.self, forKey: .body) ?? ""
            )
        case .helloAgent:
            self = .helloAgent(agentID: try c.decode(AgentID.self, forKey: .agentID))
        case .listPanes:
            self = .listPanes(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID)
            )
        case .openPane:
            self = .openPane(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                axis: try c.decodeIfPresent(SplitAxis.self, forKey: .axis) ?? .vertical,
                cwd: try c.decodeIfPresent(String.self, forKey: .cwd),
                relativeTo: try c.decodeIfPresent(PaneID.self, forKey: .relativeTo),
                command: try c.decodeIfPresent(String.self, forKey: .command)
            )
        case .closePane:
            self = .closePane(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                paneID: try c.decode(PaneID.self, forKey: .paneID)
            )
        case .focusPane:
            self = .focusPane(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                paneID: try c.decode(PaneID.self, forKey: .paneID)
            )
        case .sendPaneInput:
            self = .sendPaneInput(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                paneID: try c.decode(PaneID.self, forKey: .paneID),
                text: try c.decode(String.self, forKey: .text),
                submit: try c.decodeIfPresent(Bool.self, forKey: .submit) ?? true
            )
        case .readPane:
            self = .readPane(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                paneID: try c.decode(PaneID.self, forKey: .paneID)
            )
        case .listAgents:
            self = .listAgents(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID)
            )
        case .sendToAgent:
            self = .sendToAgent(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                targetAgentID: try c.decode(AgentID.self, forKey: .targetAgentID),
                text: try c.decode(String.self, forKey: .text)
            )
        case .spawnAgent:
            self = .spawnAgent(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                cwd: try c.decode(String.self, forKey: .cwd),
                prompt: try c.decode(String.self, forKey: .prompt)
            )
        case .createAutomation:
            self = .createAutomation(
                id: try c.decode(Int.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                prompt: try c.decode(String.self, forKey: .prompt),
                cwd: try c.decode(String.self, forKey: .cwd),
                enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                start: try c.decodeIfPresent(Bool.self, forKey: .start) ?? true
            )
        case .listAutomations:
            self = .listAutomations(id: try c.decode(Int.self, forKey: .id))
        case .updateAutomation:
            self = .updateAutomation(
                id: try c.decode(Int.self, forKey: .id),
                automationID: try c.decode(AutomationID.self, forKey: .automationID),
                name: try c.decodeIfPresent(String.self, forKey: .name),
                prompt: try c.decodeIfPresent(String.self, forKey: .prompt),
                cwd: try c.decodeIfPresent(String.self, forKey: .cwd),
                enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled)
            )
        case .deleteAutomation:
            self = .deleteAutomation(
                id: try c.decode(Int.self, forKey: .id),
                automationID: try c.decode(AutomationID.self, forKey: .automationID)
            )
        case .startAutomation:
            self = .startAutomation(
                id: try c.decode(Int.self, forKey: .id),
                automationID: try c.decode(AutomationID.self, forKey: .automationID)
            )
        case .stopAutomation:
            self = .stopAutomation(
                id: try c.decode(Int.self, forKey: .id),
                automationID: try c.decode(AutomationID.self, forKey: .automationID)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setAgentStatus(let agentID, let status):
            try c.encode(Kind.setAgentStatus, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(status, forKey: .status)
        case .setAgentName(let agentID, let name):
            try c.encode(Kind.setAgentName, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(name, forKey: .name)
        case .setAgentSession(let agentID, let piSessionID):
            try c.encode(Kind.setAgentSession, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(piSessionID, forKey: .piSessionID)
        case .setAgentChildren(let agentID, let children):
            try c.encode(Kind.setAgentChildren, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(children, forKey: .children)
        case .notify(let agentID, let title, let body):
            try c.encode(Kind.notify, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(title, forKey: .title)
            try c.encode(body, forKey: .body)
        case .helloAgent(let agentID):
            try c.encode(Kind.helloAgent, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
        case .listPanes(let id, let agentID):
            try c.encode(Kind.listPanes, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
        case .openPane(let id, let agentID, let axis, let cwd, let relativeTo, let command):
            try c.encode(Kind.openPane, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(axis, forKey: .axis)
            try c.encodeIfPresent(cwd, forKey: .cwd)
            try c.encodeIfPresent(relativeTo, forKey: .relativeTo)
            try c.encodeIfPresent(command, forKey: .command)
        case .closePane(let id, let agentID, let paneID):
            try c.encode(Kind.closePane, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(paneID, forKey: .paneID)
        case .focusPane(let id, let agentID, let paneID):
            try c.encode(Kind.focusPane, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(paneID, forKey: .paneID)
        case .sendPaneInput(let id, let agentID, let paneID, let text, let submit):
            try c.encode(Kind.sendPaneInput, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(paneID, forKey: .paneID)
            try c.encode(text, forKey: .text)
            try c.encode(submit, forKey: .submit)
        case .readPane(let id, let agentID, let paneID):
            try c.encode(Kind.readPane, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(paneID, forKey: .paneID)
        case .listAgents(let id, let agentID):
            try c.encode(Kind.listAgents, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
        case .sendToAgent(let id, let agentID, let targetAgentID, let text):
            try c.encode(Kind.sendToAgent, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(targetAgentID, forKey: .targetAgentID)
            try c.encode(text, forKey: .text)
        case .spawnAgent(let id, let agentID, let cwd, let prompt):
            try c.encode(Kind.spawnAgent, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(cwd, forKey: .cwd)
            try c.encode(prompt, forKey: .prompt)
        case .createAutomation(let id, let name, let prompt, let cwd, let enabled, let start):
            try c.encode(Kind.createAutomation, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(prompt, forKey: .prompt)
            try c.encode(cwd, forKey: .cwd)
            try c.encode(enabled, forKey: .enabled)
            try c.encode(start, forKey: .start)
        case .listAutomations(let id):
            try c.encode(Kind.listAutomations, forKey: .type)
            try c.encode(id, forKey: .id)
        case .updateAutomation(let id, let automationID, let name, let prompt, let cwd, let enabled):
            try c.encode(Kind.updateAutomation, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(automationID, forKey: .automationID)
            try c.encodeIfPresent(name, forKey: .name)
            try c.encodeIfPresent(prompt, forKey: .prompt)
            try c.encodeIfPresent(cwd, forKey: .cwd)
            try c.encodeIfPresent(enabled, forKey: .enabled)
        case .deleteAutomation(let id, let automationID):
            try c.encode(Kind.deleteAutomation, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(automationID, forKey: .automationID)
        case .startAutomation(let id, let automationID):
            try c.encode(Kind.startAutomation, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(automationID, forKey: .automationID)
        case .stopAutomation(let id, let automationID):
            try c.encode(Kind.stopAutomation, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(automationID, forKey: .automationID)
        }
    }
}

/// One live (or just-finished) pi-subagents child run under an agent, as
/// mirrored by the subagents extension. Ephemeral display state: rows live in
/// the GUI only and die with the run, the pi process, or the app.
public struct ChildRun: Codable, Hashable, Sendable, Identifiable {
    /// pi-subagents async run id. With `childIndex` this identifies a row.
    public var runID: String
    /// Lane index inside a workflow run; nil for a single-agent run.
    public var childIndex: Int?
    /// Display label — the workflow lane key or the agent profile name.
    public var label: String
    /// pi-subagents state verbatim (running/complete/failed/…). Kept as a
    /// string on purpose: their vocabulary can grow without breaking decode.
    public var state: String
    /// Milliseconds since epoch, matching the snapshot's clock.
    public var startedAt: Double?
    public var endedAt: Double?
    public var currentTool: String?
    public var needsAttention: Bool
    public var attentionText: String?
    /// Run artifact directory, for a later inspector.
    public var asyncDir: String?

    public var id: String { childIndex.map { "\(runID)#\($0)" } ?? runID }

    /// Anything not yet finished counts as live, including unknown future
    /// states — a row must never be swept while possibly still running.
    public var isTerminal: Bool {
        ["complete", "failed", "stopped", "paused", "rejected"].contains(state)
    }

    public init(
        runID: String,
        childIndex: Int? = nil,
        label: String,
        state: String,
        startedAt: Double? = nil,
        endedAt: Double? = nil,
        currentTool: String? = nil,
        needsAttention: Bool = false,
        attentionText: String? = nil,
        asyncDir: String? = nil
    ) {
        self.runID = runID
        self.childIndex = childIndex
        self.label = label
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.currentTool = currentTool
        self.needsAttention = needsAttention
        self.attentionText = attentionText
        self.asyncDir = asyncDir
    }
}

/// One top-level agent thread as reported to peers (agent_list).
public struct AgentPeerInfo: Codable, Hashable, Sendable {
    public var id: AgentID
    public var name: String
    /// AgentStatus raw value, kept stringly so the vocabulary can grow.
    public var status: String
    public var cwd: String
    /// True for the requesting agent's own row.
    public var isSelf: Bool

    public init(id: AgentID, name: String, status: String, cwd: String, isSelf: Bool) {
        self.id = id
        self.name = name
        self.status = status
        self.cwd = cwd
        self.isSelf = isSelf
    }
}

/// One automation as reported to extension clients: the persisted fields
/// plus its live run state.
public struct AutomationInfo: Codable, Hashable, Sendable {
    public var id: AutomationID
    public var name: String
    public var prompt: String
    public var cwd: String
    public var enabled: Bool
    /// Status of the running watch agent ("working", "done", …), nil when
    /// stopped.
    public var agentStatus: String?

    public init(id: AutomationID, name: String, prompt: String, cwd: String, enabled: Bool, agentStatus: String?) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.cwd = cwd
        self.enabled = enabled
        self.agentStatus = agentStatus
    }
}

/// One pane in an agent's layout, as reported to the panes extension.
public struct PaneInfo: Codable, Hashable, Sendable {
    public var id: PaneID
    public var cwd: String
    /// True for the pane running the agent's own pi process. It is the
    /// agent's own terminal, so it cannot be closed or typed into.
    public var isAgentPane: Bool
    public var isFocused: Bool
    /// Whether the pane's process is still running.
    public var isAlive: Bool

    public init(id: PaneID, cwd: String, isAgentPane: Bool, isFocused: Bool, isAlive: Bool) {
        self.id = id
        self.cwd = cwd
        self.isAgentPane = isAgentPane
        self.isFocused = isFocused
        self.isAlive = isAlive
    }
}

/// App → extension replies, correlated by request `id`.
public enum ExtensionReply: Codable, Hashable, Sendable {
    case ok(id: Int)
    case error(id: Int, code: String, message: String)
    case panes(id: Int, panes: [PaneInfo])
    case paneOpened(id: Int, pane: PaneInfo)
    /// Visible rows of a pane's screen, trailing blank lines trimmed.
    case paneContent(id: Int, paneID: PaneID, lines: [String])
    /// Saved automations with their live run state.
    case automations(id: Int, automations: [AutomationInfo])
    /// The fleet, for agent_list / agent_spawn replies.
    case agents(id: Int, agents: [AgentPeerInfo])
    /// Unsolicited push on a helloAgent-registered connection: a peer-thread
    /// message for this agent. `id` is always 0 (no request to correlate).
    case message(id: Int, text: String)

    private enum CodingKeys: String, CodingKey {
        case type, id, code, message, panes, pane, paneID, lines, automations, agents, text
    }

    private enum Kind: String, Codable {
        case ok, error, panes, paneOpened, paneContent, automations, agents, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .ok:
            self = .ok(id: try c.decode(Int.self, forKey: .id))
        case .error:
            self = .error(
                id: try c.decode(Int.self, forKey: .id),
                code: try c.decode(String.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message)
            )
        case .panes:
            self = .panes(
                id: try c.decode(Int.self, forKey: .id),
                panes: try c.decode([PaneInfo].self, forKey: .panes)
            )
        case .paneOpened:
            self = .paneOpened(
                id: try c.decode(Int.self, forKey: .id),
                pane: try c.decode(PaneInfo.self, forKey: .pane)
            )
        case .paneContent:
            self = .paneContent(
                id: try c.decode(Int.self, forKey: .id),
                paneID: try c.decode(PaneID.self, forKey: .paneID),
                lines: try c.decode([String].self, forKey: .lines)
            )
        case .automations:
            self = .automations(
                id: try c.decode(Int.self, forKey: .id),
                automations: try c.decode([AutomationInfo].self, forKey: .automations)
            )
        case .agents:
            self = .agents(
                id: try c.decode(Int.self, forKey: .id),
                agents: try c.decode([AgentPeerInfo].self, forKey: .agents)
            )
        case .message:
            self = .message(
                id: try c.decodeIfPresent(Int.self, forKey: .id) ?? 0,
                text: try c.decode(String.self, forKey: .text)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok(let id):
            try c.encode(Kind.ok, forKey: .type)
            try c.encode(id, forKey: .id)
        case .error(let id, let code, let message):
            try c.encode(Kind.error, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        case .panes(let id, let panes):
            try c.encode(Kind.panes, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(panes, forKey: .panes)
        case .paneOpened(let id, let pane):
            try c.encode(Kind.paneOpened, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(pane, forKey: .pane)
        case .paneContent(let id, let paneID, let lines):
            try c.encode(Kind.paneContent, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(paneID, forKey: .paneID)
            try c.encode(lines, forKey: .lines)
        case .automations(let id, let automations):
            try c.encode(Kind.automations, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(automations, forKey: .automations)
        case .agents(let id, let agents):
            try c.encode(Kind.agents, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agents, forKey: .agents)
        case .message(let id, let text):
            try c.encode(Kind.message, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
        }
    }
}
