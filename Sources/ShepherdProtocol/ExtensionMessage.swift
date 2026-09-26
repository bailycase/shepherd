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
    /// The children extension registered this connection as the control
    /// channel for its agent's native child runs: the app may send
    /// `ExtensionReply.childCommand` frames on it (card buttons, inspector steer).
    case helloChildren(agentID: AgentID)
    /// Outcome of a `childCommand`; `error` is nil on success.
    case childCommandResult(id: Int, error: String?)

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
    /// Blocking request/reply: opens a native diff review pane; the reply
    /// carries the user's formatted review text.
    case requestReview(id: Int, agentID: AgentID, cwd: String?, reference: String?)

    // MARK: Suggested instructions (request/reply)

    /// The instructions extension's `suggest_instruction`: one line the agent learned the hard
    /// way, for a root instruction file (`AGENTS.md` when `file` is nil), and why. It waits for
    /// the user (Settings ▸ Experiments); answered with `ExtensionReply.suggestion`.
    case suggestInstruction(id: Int, agentID: AgentID, line: String, reason: String, file: InstructionFile?)

    // MARK: Agent peers (request/reply)

    /// The fleet: every top-level agent thread, for agent_send targeting.
    case listAgents(id: Int, agentID: AgentID)
    /// Type a framed message into another agent's pi prompt. Queued by pi
    /// naturally when the target is mid-turn.
    case sendToAgent(id: Int, agentID: AgentID, targetAgentID: AgentID, text: String)
    /// Spawn a new top-level agent thread with an opening prompt.
    case spawnAgent(id: Int, agentID: AgentID, cwd: String, prompt: String)

    /// Read, steer, interrupt, or poll another live agent (relayed to the target's panes
    /// extension as `ExtensionReply.agentRequest`, never inferred from saved status), or ask
    /// the user to delete it. Answered with `ExtensionReply.agentResult`.
    case coordinateAgent(id: Int, agentID: AgentID, targetAgentID: AgentID, request: AgentCoordinationRequest)
    /// The target's answer to a relayed `agentRequest`, by the server's `requestID`. Accepted
    /// only from the connection the request went to.
    case agentResponse(agentID: AgentID, requestID: String, result: AgentCoordinationResult)
    /// The caller gave up on its `coordinateAgent` `id` (cancelled or timed out). A pending
    /// deletion dialog closes; a steer or interrupt already dispatched is not undone.
    case cancelAgentRequest(id: Int, agentID: AgentID)

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

    // MARK: Designs (request/reply)

    /// The design extension's `design_read`: the design's index, revision and board hashes
    /// (`ExtensionReply.design`), or with `path` one board's source (`designBoard`). Only the
    /// agent drawing the design may read it. `path` stays a string so a bad one is answered
    /// (`invalid_path`) rather than dropped as undecodable.
    case designRead(id: Int, agentID: AgentID, designID: DesignID, path: String?)
    /// `board_write`: one board's whole source, when the design is still at `baseRevision` (nil:
    /// whatever it is at). Answered with `designWritten`.
    case designWriteBoard(id: Int, agentID: AgentID, designID: DesignID, path: String, source: String, baseRevision: UInt64?)
    /// `canvas_update`: a JSON merge patch for the design's canvas.json (`DesignIndex.merging`).
    /// Answered with `designWritten`.
    case designUpdateIndex(id: Int, agentID: AgentID, designID: DesignID, changes: JSONValue, baseRevision: UInt64?)
    /// `comment_list`: the design's comments (`ExtensionReply.designComments`).
    case designComments(id: Int, agentID: AgentID, designID: DesignID)
    /// `comment_reply`: the design agent's answer under a comment's pin, once the change it asked
    /// for is made (`ExtensionReply.designComment`). `commentID` stays a string so a bad one is
    /// answered (`no_such_comment`). The agent can't resolve a comment: only the viewer does.
    case designCommentReply(id: Int, agentID: AgentID, designID: DesignID, commentID: String, text: String)
    /// `system_read`: without `namespace`, every design system this host has and the ones the
    /// design installed (`ExtensionReply.designSystems`); with it, that system whole
    /// (`designSystem`). `namespace` stays a string so a bad one is answered (`invalid_namespace`).
    case designSystemRead(id: Int, agentID: AgentID, designID: DesignID, namespace: String?)
    /// `system_write`: a system's tokens and files, written to the support directory's
    /// `design-systems/<namespace>/` (only by the agent of the design that built it), and with
    /// `install` copied into the agent's design. Answered with `designSystemWritten`.
    case designSystemWrite(id: Int, agentID: AgentID, designID: DesignID, system: DesignSystemWrite)

    private enum CodingKeys: String, CodingKey {
        case type, id, agentID, status, name, piSessionID, children
        case paneID, axis, cwd, relativeTo, command, text, submit, reference
        case title, body
        case prompt, enabled, start, automationID, targetAgentID, request, requestID, result
        case error
        case line, reason, file
        case designID, path, source, baseRevision, changes, commentID
        case namespace, system
    }

    private enum Kind: String, Codable {
        case setAgentStatus, setAgentName, setAgentSession, setAgentChildren, notify, helloAgent
        case helloChildren, childCommandResult
        case listPanes, openPane, closePane, focusPane, sendPaneInput, readPane, requestReview
        case createAutomation, listAutomations, updateAutomation, deleteAutomation
        case startAutomation, stopAutomation
        case listAgents, sendToAgent, spawnAgent, coordinateAgent, agentResponse, cancelAgentRequest
        case suggestInstruction
        case designRead, designWriteBoard, designUpdateIndex, designComments, designCommentReply
        case designSystemRead, designSystemWrite
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
        case .helloChildren:
            self = .helloChildren(agentID: try c.decode(AgentID.self, forKey: .agentID))
        case .childCommandResult:
            self = .childCommandResult(id: try c.decode(Int.self, forKey: .id), error: try c.decodeIfPresent(String.self, forKey: .error))
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
        case .requestReview:
            self = .requestReview(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                cwd: try c.decodeIfPresent(String.self, forKey: .cwd),
                reference: try c.decodeIfPresent(String.self, forKey: .reference)
            )
        case .suggestInstruction:
            self = .suggestInstruction(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                line: try c.decode(String.self, forKey: .line),
                reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "",
                file: try c.decodeIfPresent(InstructionFile.self, forKey: .file)
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
        case .coordinateAgent:
            self = .coordinateAgent(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                targetAgentID: try c.decode(AgentID.self, forKey: .targetAgentID),
                request: try c.decode(AgentCoordinationRequest.self, forKey: .request)
            )
        case .agentResponse:
            self = .agentResponse(
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                requestID: try c.decode(String.self, forKey: .requestID),
                result: try c.decode(AgentCoordinationResult.self, forKey: .result)
            )
        case .cancelAgentRequest:
            self = .cancelAgentRequest(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID)
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
        case .designRead:
            self = .designRead(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                designID: try c.decode(DesignID.self, forKey: .designID),
                path: try c.decodeIfPresent(String.self, forKey: .path)
            )
        case .designWriteBoard:
            self = .designWriteBoard(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                designID: try c.decode(DesignID.self, forKey: .designID),
                path: try c.decode(String.self, forKey: .path),
                source: try c.decode(String.self, forKey: .source),
                baseRevision: try c.decodeIfPresent(UInt64.self, forKey: .baseRevision)
            )
        case .designUpdateIndex:
            self = .designUpdateIndex(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                designID: try c.decode(DesignID.self, forKey: .designID),
                changes: try c.decode(JSONValue.self, forKey: .changes),
                baseRevision: try c.decodeIfPresent(UInt64.self, forKey: .baseRevision)
            )
        case .designComments:
            self = .designComments(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                designID: try c.decode(DesignID.self, forKey: .designID)
            )
        case .designCommentReply:
            self = .designCommentReply(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                designID: try c.decode(DesignID.self, forKey: .designID),
                commentID: try c.decode(String.self, forKey: .commentID),
                text: try c.decode(String.self, forKey: .text)
            )
        case .designSystemRead:
            self = .designSystemRead(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                designID: try c.decode(DesignID.self, forKey: .designID),
                namespace: try c.decodeIfPresent(String.self, forKey: .namespace)
            )
        case .designSystemWrite:
            self = .designSystemWrite(
                id: try c.decode(Int.self, forKey: .id),
                agentID: try c.decode(AgentID.self, forKey: .agentID),
                designID: try c.decode(DesignID.self, forKey: .designID),
                system: try c.decode(DesignSystemWrite.self, forKey: .system)
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
        case .helloChildren(let agentID):
            try c.encode(Kind.helloChildren, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
        case .childCommandResult(let id, let error):
            try c.encode(Kind.childCommandResult, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(error, forKey: .error)
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
        case .requestReview(let id, let agentID, let cwd, let reference):
            try c.encode(Kind.requestReview, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encodeIfPresent(cwd, forKey: .cwd)
            try c.encodeIfPresent(reference, forKey: .reference)
        case .suggestInstruction(let id, let agentID, let line, let reason, let file):
            try c.encode(Kind.suggestInstruction, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(line, forKey: .line)
            try c.encode(reason, forKey: .reason)
            try c.encodeIfPresent(file, forKey: .file)
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
        case .coordinateAgent(let id, let agentID, let targetAgentID, let request):
            try c.encode(Kind.coordinateAgent, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(targetAgentID, forKey: .targetAgentID)
            try c.encode(request, forKey: .request)
        case .agentResponse(let agentID, let requestID, let result):
            try c.encode(Kind.agentResponse, forKey: .type)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(result, forKey: .result)
        case .cancelAgentRequest(let id, let agentID):
            try c.encode(Kind.cancelAgentRequest, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
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
        case .designRead(let id, let agentID, let designID, let path):
            try c.encode(Kind.designRead, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(designID, forKey: .designID)
            try c.encodeIfPresent(path, forKey: .path)
        case .designWriteBoard(let id, let agentID, let designID, let path, let source, let baseRevision):
            try c.encode(Kind.designWriteBoard, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(designID, forKey: .designID)
            try c.encode(path, forKey: .path)
            try c.encode(source, forKey: .source)
            try c.encodeIfPresent(baseRevision, forKey: .baseRevision)
        case .designUpdateIndex(let id, let agentID, let designID, let changes, let baseRevision):
            try c.encode(Kind.designUpdateIndex, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(designID, forKey: .designID)
            try c.encode(changes, forKey: .changes)
            try c.encodeIfPresent(baseRevision, forKey: .baseRevision)
        case .designComments(let id, let agentID, let designID):
            try c.encode(Kind.designComments, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(designID, forKey: .designID)
        case .designCommentReply(let id, let agentID, let designID, let commentID, let text):
            try c.encode(Kind.designCommentReply, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(designID, forKey: .designID)
            try c.encode(commentID, forKey: .commentID)
            try c.encode(text, forKey: .text)
        case .designSystemRead(let id, let agentID, let designID, let namespace):
            try c.encode(Kind.designSystemRead, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(designID, forKey: .designID)
            try c.encodeIfPresent(namespace, forKey: .namespace)
        case .designSystemWrite(let id, let agentID, let designID, let system):
            try c.encode(Kind.designSystemWrite, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(agentID, forKey: .agentID)
            try c.encode(designID, forKey: .designID)
            try c.encode(system, forKey: .system)
        }
    }
}

/// Operations served by a live pi extension through its public context API.
public struct AgentCoordinationRequest: Codable, Hashable, Sendable {
    public enum Operation: String, Codable, Sendable { case read, steer, interrupt, status, delete }
    public var operation: Operation
    public var text: String?
    public var limit: Int?
    public var after: String?

    public init(operation: Operation, text: String? = nil, limit: Int? = nil, after: String? = nil) {
        self.operation = operation
        self.text = text
        self.limit = limit
        self.after = after
    }
}

/// Text is bounded by the recipient. A code denotes an error, not a dispatch acknowledgment.
public struct AgentCoordinationResult: Codable, Hashable, Sendable {
    public var text: String
    public var idle: Bool?
    public var sessionID: String?
    public var connectionID: String?
    public var code: String?

    public init(text: String, idle: Bool? = nil, sessionID: String? = nil, connectionID: String? = nil, code: String? = nil) {
        self.text = text
        self.idle = idle
        self.sessionID = sessionID
        self.connectionID = connectionID
        self.code = code
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

    // MARK: Card fields (native children only; all optional so pi-subagents rows still decode)

    /// Agent profile name ("worker").
    public var role: String?
    /// "provider/id".
    public var model: String?
    public var thinking: String?
    /// "background" (shepherd_child_start) or "async" (workflow with async:true).
    public var context: String?
    public var step: ChildStep?
    public var turns: Int?
    public var toolCalls: Int?
    public var tokens: Int?
    /// Context-window fill of the child's own session, 0–100.
    public var contextPercent: Double?
    public var lastActivity: ChildActivity?
    /// Present while `needsAttention`.
    public var question: ChildQuestion?
    /// Present once `state == complete`.
    public var result: ChildResultSummary?
    /// "exit 1 · context limit reached after 41 turns"; present when failed.
    public var exitReason: String?
    /// The parent's `shepherd_child_start` tool call id, so the card can replace that row.
    public var toolCallID: String?
    /// The delegated task (inspector GOAL block).
    public var task: String?
    /// Final assistant text once complete (card summary prose).
    public var output: String?
    /// The child's pi session JSONL, for the inspector transcript.
    public var sessionFile: String?
    /// Files the child edited or wrote, with line counts aggregated per path (≤ 32 entries).
    public var files: [ChildFileChange]?
    /// First two sentences of the final output, ≤ 240 characters.
    public var summary: String?
    /// The child's own pi session id (a fork copies its transcript under a fresh id).
    public var sessionID: String?
    /// The directory the child ran in; file links resolve against it.
    public var cwd: String?
    /// A cooperative pause is requested; the next provider request waits for Continue.
    public var paused: Bool?

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
        asyncDir: String? = nil,
        role: String? = nil,
        model: String? = nil,
        thinking: String? = nil,
        context: String? = nil,
        step: ChildStep? = nil,
        turns: Int? = nil,
        toolCalls: Int? = nil,
        tokens: Int? = nil,
        contextPercent: Double? = nil,
        lastActivity: ChildActivity? = nil,
        question: ChildQuestion? = nil,
        result: ChildResultSummary? = nil,
        exitReason: String? = nil,
        toolCallID: String? = nil,
        task: String? = nil,
        output: String? = nil,
        sessionFile: String? = nil,
        files: [ChildFileChange]? = nil,
        summary: String? = nil,
        sessionID: String? = nil,
        cwd: String? = nil,
        paused: Bool? = nil
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
        self.role = role
        self.model = model
        self.thinking = thinking
        self.context = context
        self.step = step
        self.turns = turns
        self.toolCalls = toolCalls
        self.tokens = tokens
        self.contextPercent = contextPercent
        self.lastActivity = lastActivity
        self.question = question
        self.result = result
        self.exitReason = exitReason
        self.toolCallID = toolCallID
        self.task = task
        self.output = output
        self.sessionFile = sessionFile
        self.files = files
        self.summary = summary
        self.sessionID = sessionID
        self.cwd = cwd
        self.paused = paused
    }
}

/// One path a child touched: edit/write calls aggregated (inspector RESULT block).
public struct ChildFileChange: Codable, Hashable, Sendable {
    public var path: String
    public var added: Int
    public var removed: Int
    public init(path: String, added: Int, removed: Int) { self.path = path; self.added = added; self.removed = removed }
}

public struct ChildStep: Codable, Hashable, Sendable {
    public var index: Int
    public var total: Int
    public init(index: Int, total: Int) { self.index = index; self.total = total }
}

public struct ChildDiff: Codable, Hashable, Sendable {
    public var added: Int
    public var removed: Int
    public init(added: Int, removed: Int) { self.added = added; self.removed = removed }
}

/// The child's latest tool call: the one in flight, else its most recent finished call.
public struct ChildActivity: Codable, Hashable, Sendable {
    /// "tool" once the call finished, "running" while it runs. Older children extensions
    /// reported finished calls only.
    public var kind: String
    public var tool: String
    public var preview: String?
    public var diff: ChildDiff?
    /// Milliseconds since epoch.
    public var at: Double
    public init(kind: String = "tool", tool: String, preview: String? = nil, diff: ChildDiff? = nil, at: Double) {
        self.kind = kind; self.tool = tool; self.preview = preview; self.diff = diff; self.at = at
    }

    public static let runningKind = "running"
    public var isRunning: Bool { kind == Self.runningKind }
}

public struct ChildQuestion: Codable, Hashable, Sendable {
    public var text: String
    public var options: [String]?
    /// The child's word or two for the question ("retention?"), for its parent's Needs you row.
    /// Absent when the child gave none, and from older extensions.
    public var short: String?
    public init(text: String, options: [String]? = nil, short: String? = nil) {
        self.text = text; self.options = options; self.short = short
    }
}

public struct ChildResultSummary: Codable, Hashable, Sendable {
    public var files: Int
    public var added: Int
    public var removed: Int
    public var tools: Int
    public var tokens: Int
    public init(files: Int, added: Int, removed: Int, tools: Int, tokens: Int) {
        self.files = files; self.added = added; self.removed = removed; self.tools = tools; self.tokens = tokens
    }
}

/// App → children extension: drive one native child run. Mirrors the tool functions.
public enum ChildCommandAction: String, Codable, Hashable, Sendable { case message, cancel, resume, pause, `continue` }

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
    /// Sent on a `helloChildren` connection; answered by `ExtensionMessage.childCommandResult`.
    /// `mode` (steer/followUp) applies to `message`.
    case childCommand(id: Int, runID: String, action: ChildCommandAction, text: String?, mode: NativeThreadDelivery?)
    case ok(id: Int)
    case error(id: Int, code: String, message: String)
    case panes(id: Int, panes: [PaneInfo])
    case paneOpened(id: Int, pane: PaneInfo)
    /// Visible rows of a pane's screen, trailing blank lines trimmed.
    case paneContent(id: Int, paneID: PaneID, lines: [String])
    /// The user's formatted review text from a native diff-review pane.
    case reviewResult(id: Int, text: String)
    /// Saved automations with their live run state.
    case automations(id: Int, automations: [AutomationInfo])
    /// The fleet, for agent_list / agent_spawn replies.
    case agents(id: Int, agents: [AgentPeerInfo])
    /// Unsolicited push on a helloAgent-registered connection: a peer-thread
    /// message for this agent. `id` is always 0 (no request to correlate).
    case message(id: Int, text: String)
    /// What became of a `suggestInstruction` line.
    case suggestion(id: Int, outcome: SuggestionOutcome)

    /// Unsolicited, to the target's registered connection: serve `request` and answer with
    /// `ExtensionMessage.agentResponse`. `requestID` is the server's token, independent of the
    /// caller's own request ids; `id` is always 0.
    case agentRequest(id: Int, requestID: String, targetAgentID: AgentID, request: AgentCoordinationRequest)
    /// The outcome of a `coordinateAgent`, correlated by the caller's `id`. A `code` means it
    /// failed.
    case agentResult(id: Int, result: AgentCoordinationResult)

    /// A `designRead` without a path: the design's index, revision and board hashes.
    case design(id: Int, snapshot: DesignSnapshot)
    /// A `designRead` with a path: that board's source.
    case designBoard(id: Int, board: DesignBoardSource)
    /// What a `designWriteBoard` or `designUpdateIndex` left behind.
    case designWritten(id: Int, result: DesignWriteResult)
    /// A `designComments`: every comment of the design, open and resolved, with their revision.
    case designComments(id: Int, comments: DesignComments)
    /// A `designCommentReply`: the comment with the reply under it.
    case designComment(id: Int, comment: DesignComment)
    /// A `designSystemRead` without a namespace: every system, and the design's installed ones.
    case designSystems(id: Int, listing: DesignSystemListing)
    /// A `designSystemRead` with a namespace: that system whole.
    case designSystem(id: Int, system: DesignSystemRead)
    /// What a `designSystemWrite` left behind.
    case designSystemWritten(id: Int, result: DesignSystemWriteResult)

    private enum CodingKeys: String, CodingKey {
        case requestID, targetAgentID, request, result
        case type, id, code, message, panes, pane, paneID, lines, automations, agents, text
        case runID, action, mode
        case outcome
        case snapshot, board
        case comments, comment
        case listing, system
    }

    private enum Kind: String, Codable {
        case childCommand, agentRequest, agentResult
        case ok, error, panes, paneOpened, paneContent, reviewResult, automations, agents, message
        case suggestion
        case design, designBoard, designWritten, designComments, designComment
        case designSystems, designSystem, designSystemWritten
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .childCommand:
            self = .childCommand(
                id: try c.decode(Int.self, forKey: .id),
                runID: try c.decode(String.self, forKey: .runID),
                action: try c.decode(ChildCommandAction.self, forKey: .action),
                text: try c.decodeIfPresent(String.self, forKey: .text),
                mode: try c.decodeIfPresent(NativeThreadDelivery.self, forKey: .mode)
            )
        case .agentRequest:
            self = .agentRequest(
                id: try c.decode(Int.self, forKey: .id),
                requestID: try c.decode(String.self, forKey: .requestID),
                targetAgentID: try c.decode(AgentID.self, forKey: .targetAgentID),
                request: try c.decode(AgentCoordinationRequest.self, forKey: .request)
            )
        case .agentResult:
            self = .agentResult(
                id: try c.decode(Int.self, forKey: .id),
                result: try c.decode(AgentCoordinationResult.self, forKey: .result)
            )
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
        case .reviewResult:
            self = .reviewResult(
                id: try c.decode(Int.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text)
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
        case .suggestion:
            self = .suggestion(
                id: try c.decode(Int.self, forKey: .id),
                outcome: try c.decode(SuggestionOutcome.self, forKey: .outcome)
            )
        case .design:
            self = .design(
                id: try c.decode(Int.self, forKey: .id),
                snapshot: try c.decode(DesignSnapshot.self, forKey: .snapshot)
            )
        case .designBoard:
            self = .designBoard(
                id: try c.decode(Int.self, forKey: .id),
                board: try c.decode(DesignBoardSource.self, forKey: .board)
            )
        case .designWritten:
            self = .designWritten(
                id: try c.decode(Int.self, forKey: .id),
                result: try c.decode(DesignWriteResult.self, forKey: .result)
            )
        case .designComments:
            self = .designComments(
                id: try c.decode(Int.self, forKey: .id),
                comments: try c.decode(DesignComments.self, forKey: .comments)
            )
        case .designComment:
            self = .designComment(
                id: try c.decode(Int.self, forKey: .id),
                comment: try c.decode(DesignComment.self, forKey: .comment)
            )
        case .designSystems:
            self = .designSystems(
                id: try c.decode(Int.self, forKey: .id),
                listing: try c.decode(DesignSystemListing.self, forKey: .listing)
            )
        case .designSystem:
            self = .designSystem(
                id: try c.decode(Int.self, forKey: .id),
                system: try c.decode(DesignSystemRead.self, forKey: .system)
            )
        case .designSystemWritten:
            self = .designSystemWritten(
                id: try c.decode(Int.self, forKey: .id),
                result: try c.decode(DesignSystemWriteResult.self, forKey: .result)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .childCommand(let id, let runID, let action, let text, let mode):
            try c.encode(Kind.childCommand, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(runID, forKey: .runID)
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(text, forKey: .text)
            try c.encodeIfPresent(mode, forKey: .mode)
        case .agentRequest(let id, let requestID, let targetAgentID, let request):
            try c.encode(Kind.agentRequest, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(targetAgentID, forKey: .targetAgentID)
            try c.encode(request, forKey: .request)
        case .agentResult(let id, let result):
            try c.encode(Kind.agentResult, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
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
        case .reviewResult(let id, let text):
            try c.encode(Kind.reviewResult, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
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
        case .suggestion(let id, let outcome):
            try c.encode(Kind.suggestion, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(outcome, forKey: .outcome)
        case .design(let id, let snapshot):
            try c.encode(Kind.design, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(snapshot, forKey: .snapshot)
        case .designBoard(let id, let board):
            try c.encode(Kind.designBoard, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(board, forKey: .board)
        case .designWritten(let id, let result):
            try c.encode(Kind.designWritten, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        case .designComments(let id, let comments):
            try c.encode(Kind.designComments, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(comments, forKey: .comments)
        case .designComment(let id, let comment):
            try c.encode(Kind.designComment, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(comment, forKey: .comment)
        case .designSystems(let id, let listing):
            try c.encode(Kind.designSystems, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(listing, forKey: .listing)
        case .designSystem(let id, let system):
            try c.encode(Kind.designSystem, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(system, forKey: .system)
        case .designSystemWritten(let id, let result):
            try c.encode(Kind.designSystemWritten, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(result, forKey: .result)
        }
    }
}
