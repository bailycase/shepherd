import ShepherdCore

extension ExtensionMessage {
    /// The agent this message speaks for: the one whose pi wrote it (its actor, never a target such
    /// as `sendToAgent`'s `targetAgentID`). The server serves it only on a connection opened by
    /// that agent's own pi process (`SessionServer.extensionPeerCheck`; ARCHITECTURE.md ›
    /// Extensions and the extension socket).
    ///
    /// `nil` for the messages that name no agent at all: the automation requests, which any pi
    /// session may send, and the answer to a child command, which is bound to the connection the
    /// command went to.
    ///
    /// Exhaustive on purpose: a new message has to say whose voice it is.
    public var speaksFor: AgentID? {
        switch self {
        case .setAgentStatus(let agentID, _), .setAgentName(let agentID, _, _), .setAgentSession(let agentID, _),
             .setAgentChildren(let agentID, _), .notify(let agentID, _, _), .helloAgent(let agentID),
             .helloChildren(let agentID),
             .listPanes(_, let agentID), .openPane(_, let agentID, _, _, _, _), .closePane(_, let agentID, _),
             .focusPane(_, let agentID, _), .sendPaneInput(_, let agentID, _, _, _), .readPane(_, let agentID, _),
             .requestReview(_, let agentID, _, _),
             .suggestInstruction(_, let agentID, _, _, _),
             .listAgents(_, let agentID), .sendToAgent(_, let agentID, _, _, _), .spawnAgent(_, let agentID, _, _),
             .coordinateAgent(_, let agentID, _, _), .agentResponse(let agentID, _, _), .cancelAgentRequest(_, let agentID),
             .designRead(_, let agentID, _, _), .designWriteBoard(_, let agentID, _, _, _, _, _),
             .designEditBoard(_, let agentID, _, _, _, _, _), .designUpdateIndex(_, let agentID, _, _, _), .designComments(_, let agentID, _),
             .designEditBoards(_, let agentID, _, _), .designSearch(_, let agentID, _, _),
             .designCheckpoint(_, let agentID, _, _), .designRender(_, let agentID, _, _),
             .designCommentReply(_, let agentID, _, _, _), .designSystemRead(_, let agentID, _, _),
             .designSystemWrite(_, let agentID, _, _), .designProposeComments(_, let agentID, _, _, _),
             .designGet(_, let agentID, _, _), .designNote(_, let agentID, _, _),
             .mcpCredentials(_, let agentID, _, _, _), .mcpReport(let agentID, _),
             .helloBrowser(let agentID), .browser(_, let agentID, _):
            return agentID
        case .childCommandResult,
             .createAutomation, .listAutomations, .updateAutomation, .deleteAutomation, .startAutomation, .stopAutomation:
            return nil
        }
    }

    /// The `id` an `ExtensionReply` to this message carries, for the messages that are answered:
    /// what a refusal is addressed to. `nil` for the fire-and-forget ones (status, name, session,
    /// children, notify, MCP reports, the hellos, an agent's answer to a relayed request, and a
    /// cancellation).
    public var replyID: Int? {
        switch self {
        case .listPanes(let id, _), .openPane(let id, _, _, _, _, _), .closePane(let id, _, _),
             .focusPane(let id, _, _), .sendPaneInput(let id, _, _, _, _), .readPane(let id, _, _),
             .requestReview(let id, _, _, _),
             .suggestInstruction(let id, _, _, _, _),
             .listAgents(let id, _), .sendToAgent(let id, _, _, _, _), .spawnAgent(let id, _, _, _),
             .coordinateAgent(let id, _, _, _),
             .createAutomation(let id, _, _, _, _, _), .listAutomations(let id), .updateAutomation(let id, _, _, _, _, _),
             .deleteAutomation(let id, _), .startAutomation(let id, _), .stopAutomation(let id, _),
             .designRead(let id, _, _, _), .designWriteBoard(let id, _, _, _, _, _, _),
             .designEditBoard(let id, _, _, _, _, _, _), .designUpdateIndex(let id, _, _, _, _), .designComments(let id, _, _),
             .designEditBoards(let id, _, _, _), .designSearch(let id, _, _, _),
             .designCheckpoint(let id, _, _, _), .designRender(let id, _, _, _),
             .designCommentReply(let id, _, _, _, _), .designSystemRead(let id, _, _, _),
             .designSystemWrite(let id, _, _, _), .designProposeComments(let id, _, _, _, _),
             .designGet(let id, _, _, _), .designNote(let id, _, _, _),
             .mcpCredentials(let id, _, _, _, _), .browser(let id, _, _):
            return id
        case .setAgentStatus, .setAgentName, .setAgentSession, .setAgentChildren, .notify, .helloAgent, .helloChildren,
             .childCommandResult, .agentResponse, .cancelAgentRequest, .mcpReport, .helloBrowser:
            return nil
        }
    }
}
