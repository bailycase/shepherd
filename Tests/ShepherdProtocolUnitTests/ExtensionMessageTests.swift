import Foundation
import Testing
import ShepherdCore
@testable import ShepherdProtocol

/// The local extension socket: `Extensions/*.ts` write these with `JSON.stringify` and read the
/// replies by hand, so both the Swift round trip and the exact hand-written shapes are contract.
@Suite("Extension socket messages")
struct ExtensionMessageTests {
    static let agent = AgentID(rawValue: "a1")
    static let pane = PaneID(rawValue: "p1")
    static let automation = AutomationID(rawValue: "au1")

    /// Exhaustive on purpose: a new case fails to compile here. Add it, bump `caseCount`, and
    /// give it a sample below.
    static func caseName(_ message: ExtensionMessage) -> String {
        switch message {
        case .setAgentStatus, .setAgentName, .setAgentSession, .setAgentChildren, .notify, .helloAgent,
             .helloChildren, .childCommandResult, .listPanes, .openPane, .closePane, .focusPane,
             .sendPaneInput, .readPane, .requestReview, .listAgents, .sendToAgent, .spawnAgent,
             .coordinateAgent, .agentResponse, .cancelAgentRequest, .createAutomation, .listAutomations,
             .updateAutomation, .deleteAutomation, .startAutomation, .stopAutomation, .suggestInstruction,
             .designRead, .designWriteBoard, .designUpdateIndex, .designComments, .designCommentReply,
             .designSystemRead, .designSystemWrite, .designProposeComments, .mcpCredentials, .mcpReport:
            return Wire.caseName(message)
        }
    }
    static let caseCount = 38
    static let design = DesignID(rawValue: "d1")

    static let samples: [ExtensionMessage] = [
        .setAgentStatus(agentID: agent, status: .blocked),
        .setAgentName(agentID: agent, name: "Title with \"quotes\" and ünicode"),
        .setAgentSession(agentID: agent, piSessionID: "01a026dd-ce9a-7ea2-b1bb-195d958cca0c"),
        .setAgentChildren(agentID: agent, children: [
            ChildRun(runID: "r1", childIndex: 2, label: "src/jobs", state: "failed", startedAt: 1, endedAt: 2,
                     currentTool: "read", needsAttention: true, attentionText: "boom", asyncDir: "/tmp/a"),
            ChildRun(runID: "r2", label: "reviewer", state: "queued"),
        ]),
        .notify(agentID: agent, title: "CI passed", body: "PR #42 is green"),
        .helloAgent(agentID: agent),
        .helloChildren(agentID: agent),
        .childCommandResult(id: 2, error: "Child is not running"),
        .listPanes(id: 1, agentID: agent),
        .openPane(id: 2, agentID: agent, axis: .horizontal, cwd: "/tmp", relativeTo: pane, command: "npm run dev"),
        .closePane(id: 4, agentID: agent, paneID: pane),
        .focusPane(id: 5, agentID: agent, paneID: pane),
        .sendPaneInput(id: 7, agentID: agent, paneID: pane, text: "y", submit: false),
        .readPane(id: 8, agentID: agent, paneID: pane),
        .requestReview(id: 9, agentID: agent, cwd: "/tmp/repo", reference: "master..HEAD"),
        .listAgents(id: 16, agentID: agent),
        .sendToAgent(id: 17, agentID: agent, targetAgentID: AgentID(rawValue: "a2"), text: "CI is green"),
        .spawnAgent(id: 18, agentID: agent, cwd: "/tmp/repo", prompt: "Fix the tests."),
        .coordinateAgent(id: 19, agentID: agent, targetAgentID: AgentID(rawValue: "a2"),
                         request: AgentCoordinationRequest(operation: .read, limit: 10, after: "entry-1")),
        .agentResponse(agentID: AgentID(rawValue: "a2"), requestID: "server-token",
                       result: AgentCoordinationResult(text: "live activity snapshot", idle: true, sessionID: "s1", connectionID: "c1")),
        .cancelAgentRequest(id: 19, agentID: agent),
        .createAutomation(id: 9, name: "pr-watch", prompt: "watch it", cwd: "/tmp/repo", enabled: false, start: false),
        .listAutomations(id: 10),
        .updateAutomation(id: 11, automationID: automation, name: "renamed", prompt: "p", cwd: "/c", enabled: false),
        .deleteAutomation(id: 13, automationID: automation),
        .startAutomation(id: 14, automationID: automation),
        .stopAutomation(id: 15, automationID: automation),
        .suggestInstruction(id: 20, agentID: agent, line: "- Run `go mod tidy` with any dependency bump.",
                            reason: "CI failed twice on a stale go.sum.", file: .appendSystem),
        .designRead(id: 21, agentID: agent, designID: design, path: "flows/A-phone.dc.html"),
        .designWriteBoard(id: 22, agentID: agent, designID: design, path: "A.dc.html",
                          source: "<!doctype html>\n<x-dc><div style=\"width: 390px\">“Hi” · 👋</div></x-dc>\n", baseRevision: 7),
        .designUpdateIndex(id: 23, agentID: agent, designID: design, changes: .object([
            "title": .string("Checkout funnel"),
            "boards": .object(["A.dc.html": .object(["x": .number(0), "y": .number(0), "w": .number(1280), "h": .number(800)]),
                               "C.dc.html": .null]),
        ]), baseRevision: nil),
        .designComments(id: 24, agentID: agent, designID: design),
        .designCommentReply(id: 25, agentID: agent, designID: design, commentID: "7A1C2E7B-39F5-4B0C-9A40-0E8B1F3C5D21",
                            text: "Done on A and A · phone.\nWant counts too?"),
        .designSystemRead(id: 26, agentID: agent, designID: design, namespace: "acme-web"),
        .designSystemWrite(id: 27, agentID: agent, designID: design, system: DesignSystemWrite(
            namespace: "acme-web", title: "acme-web",
            tokens: .object(["colors": .array([.object(["name": .string("--accent"), "value": .string("#4f46e5"),
                                                        "source": .object(["file": .string("web/static/tokens.css"), "line": .number(8)])])])]),
            files: ["README.md": .string("# acme-web\n"), "components/old.html": .null],
            sources: ["web/static/tokens.css"], install: true, baseRevision: 2)),
        .designProposeComments(id: 28, agentID: agent, designID: design, call: "toolu_01",
                               proposals: [DesignMarkupProposal(element: "A-phone.dc.html#31:1/1/2", text: "Thicker bars on phone."),
                                           DesignMarkupProposal(element: "not an id", text: "Counts “here” too?")]),
        .mcpCredentials(id: 28, agentID: agent, server: "linear", reason: .unauthorized,
                        challenge: #"Bearer resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource""#),
        .mcpReport(agentID: agent, report: MCPServerReport(
            server: "postgres", status: MCPServerStatus(state: .connected), transport: .stdio, serverName: "Postgres MCP",
            tools: [MCPToolInfo(name: "query", title: "Query", description: "Run a read-only SQL query.",
                                inputSchema: .object(["type": .string("object"),
                                                      "properties": .object(["sql": .object(["type": .string("string")])])]))])),
    ]

    @Test func samplesCoverEveryCase() {
        #expect(Set(Self.samples.map(Self.caseName)).count == Self.caseCount)
    }

    @Test(arguments: samples)
    func roundTripsThroughNDJSON(_ message: ExtensionMessage) throws {
        #expect(try Wire.roundTrip(message) == message)
    }

    @Test(arguments: samples)
    func typeDiscriminatorIsTheCaseName(_ message: ExtensionMessage) throws {
        #expect(try Wire.object(message)["type"] as? String == Self.caseName(message))
    }

    @Test func encodingUsesSortedKeysOnOneLine() throws {
        let line = try NDJSON.encode(ExtensionMessage.setAgentStatus(agentID: Self.agent, status: .working))
        #expect(String(decoding: line, as: UTF8.self) == "{\"agentID\":\"a1\",\"status\":\"working\",\"type\":\"setAgentStatus\"}\n")
    }

    /// Exactly what the extensions write, key order and omitted optionals included.
    static let handWritten: [(json: String, expected: ExtensionMessage)] = [
        (#"{"type":"setAgentStatus","agentID":"a1","status":"working"}"#,
         .setAgentStatus(agentID: agent, status: .working)),
        (#"{"type":"setAgentName","agentID":"a1","name":"Fix plan mode over SSH"}"#,
         .setAgentName(agentID: agent, name: "Fix plan mode over SSH")),
        (#"{"type":"setAgentSession","agentID":"a1","piSessionID":"sess-9"}"#,
         .setAgentSession(agentID: agent, piSessionID: "sess-9")),
        (#"{"type":"notify","agentID":"a1","title":"Done"}"#,
         .notify(agentID: agent, title: "Done", body: "")),
        (#"{"type":"helloAgent","agentID":"a1"}"#, .helloAgent(agentID: agent)),
        (#"{"type":"helloChildren","agentID":"a1"}"#, .helloChildren(agentID: agent)),
        (#"{"type":"childCommandResult","id":7}"#, .childCommandResult(id: 7, error: nil)),
        (#"{"type":"openPane","id":7,"agentID":"a1"}"#,
         .openPane(id: 7, agentID: agent, axis: .vertical, cwd: nil, relativeTo: nil, command: nil)),
        (#"{"type":"sendPaneInput","id":8,"agentID":"a1","paneID":"p1","text":"ls"}"#,
         .sendPaneInput(id: 8, agentID: agent, paneID: pane, text: "ls", submit: true)),
        (#"{"type":"requestReview","id":4,"agentID":"a1"}"#,
         .requestReview(id: 4, agentID: agent, cwd: nil, reference: nil)),
        (#"{"type":"sendToAgent","id":3,"agentID":"a1","targetAgentID":"a2","text":"done"}"#,
         .sendToAgent(id: 3, agentID: agent, targetAgentID: AgentID(rawValue: "a2"), text: "done")),
        (#"{"type":"coordinateAgent","targetAgentID":"a2","request":{"operation":"steer","text":"change course"},"id":5,"agentID":"a1"}"#,
         .coordinateAgent(id: 5, agentID: agent, targetAgentID: AgentID(rawValue: "a2"),
                          request: AgentCoordinationRequest(operation: .steer, text: "change course"))),
        // agent_delete carries no approval: a stray "confirmed" key is ignored, never obeyed.
        (#"{"type":"coordinateAgent","targetAgentID":"a2","request":{"operation":"delete"},"confirmed":true,"id":6,"agentID":"a1"}"#,
         .coordinateAgent(id: 6, agentID: agent, targetAgentID: AgentID(rawValue: "a2"), request: AgentCoordinationRequest(operation: .delete))),
        (#"{"type":"agentResponse","agentID":"a1","requestID":"tok","result":{"text":"cursor is not on the current branch","code":"recipient_error"}}"#,
         .agentResponse(agentID: agent, requestID: "tok",
                        result: AgentCoordinationResult(text: "cursor is not on the current branch", code: "recipient_error"))),
        (#"{"type":"cancelAgentRequest","id":7,"agentID":"a1"}"#, .cancelAgentRequest(id: 7, agentID: agent)),
        (#"{"type":"createAutomation","id":1,"name":"pr-watch #4821","prompt":"Watch the PR.","cwd":"/tmp/repo"}"#,
         .createAutomation(id: 1, name: "pr-watch #4821", prompt: "Watch the PR.", cwd: "/tmp/repo", enabled: true, start: true)),
        (#"{"type":"updateAutomation","id":3,"automationID":"au1","enabled":false}"#,
         .updateAutomation(id: 3, automationID: automation, name: nil, prompt: nil, cwd: nil, enabled: false)),
        // No file means AGENTS.md; a missing reason is an empty one.
        (#"{"type":"suggestInstruction","id":2,"agentID":"a1","line":"- Ask for join keys first.","reason":"Two services re-ran."}"#,
         .suggestInstruction(id: 2, agentID: agent, line: "- Ask for join keys first.", reason: "Two services re-ran.", file: nil)),
        (#"{"type":"suggestInstruction","id":3,"agentID":"a1","line":"- Never force-push.","file":"APPEND_SYSTEM.md"}"#,
         .suggestInstruction(id: 3, agentID: agent, line: "- Never force-push.", reason: "", file: .appendSystem)),
        // The design extension spreads its payload first, then id, agentID and designID.
        (#"{"type":"designRead","id":1,"agentID":"a1","designID":"d1"}"#,
         .designRead(id: 1, agentID: agent, designID: design, path: nil)),
        // A path outside the grammar still decodes, so the server can answer it.
        (#"{"type":"designRead","path":"../x.dc.html","id":2,"agentID":"a1","designID":"d1"}"#,
         .designRead(id: 2, agentID: agent, designID: design, path: "../x.dc.html")),
        (#"{"type":"designWriteBoard","path":"A.dc.html","source":"<x-dc></x-dc>","id":3,"agentID":"a1","designID":"d1"}"#,
         .designWriteBoard(id: 3, agentID: agent, designID: design, path: "A.dc.html", source: "<x-dc></x-dc>", baseRevision: nil)),
        (#"{"type":"designWriteBoard","path":"A.dc.html","source":"s","baseRevision":4,"id":4,"agentID":"a1","designID":"d1"}"#,
         .designWriteBoard(id: 4, agentID: agent, designID: design, path: "A.dc.html", source: "s", baseRevision: 4)),
        (#"{"type":"designUpdateIndex","changes":{"boards":{"C.dc.html":null}},"baseRevision":6,"id":5,"agentID":"a1","designID":"d1"}"#,
         .designUpdateIndex(id: 5, agentID: agent, designID: design, changes: .object(["boards": .object(["C.dc.html": .null])]),
                            baseRevision: 6)),
        (#"{"type":"designComments","id":6,"agentID":"a1","designID":"d1"}"#,
         .designComments(id: 6, agentID: agent, designID: design)),
        // A comment id that isn't one still decodes, so the server can answer it.
        (#"{"type":"designCommentReply","commentID":"nope","text":"Done.","id":7,"agentID":"a1","designID":"d1"}"#,
         .designCommentReply(id: 7, agentID: agent, designID: design, commentID: "nope", text: "Done.")),
        (#"{"type":"designSystemRead","id":8,"agentID":"a1","designID":"d1"}"#,
         .designSystemRead(id: 8, agentID: agent, designID: design, namespace: nil)),
        // A namespace outside the grammar still decodes, so the server can answer it.
        (#"{"type":"designSystemRead","namespace":"Acme Web","id":9,"agentID":"a1","designID":"d1"}"#,
         .designSystemRead(id: 9, agentID: agent, designID: design, namespace: "Acme Web")),
        (#"{"type":"designSystemWrite","system":{"namespace":"night-watch","install":true},"id":10,"agentID":"a1","designID":"d1"}"#,
         .designSystemWrite(id: 10, agentID: agent, designID: design, system: DesignSystemWrite(namespace: "night-watch", install: true))),
        // markup_propose's frame; an element that isn't an id still decodes, so the server can answer it.
        (#"{"type":"designProposeComments","call":"call-7","proposals":[{"element":"A.dc.html#18:1/1/1","text":"Counts too"},{"element":"?","text":"x"}],"id":11,"agentID":"a1","designID":"d1"}"#,
         .designProposeComments(id: 11, agentID: agent, designID: design, call: "call-7",
                                proposals: [DesignMarkupProposal(element: "A.dc.html#18:1/1/1", text: "Counts too"),
                                            DesignMarkupProposal(element: "?", text: "x")])),
        // The MCP extension spreads its fields, then the link adds id last; a connect carries no challenge.
        (#"{"type":"mcpCredentials","agentID":"a1","server":"grafana","reason":"connect","id":1}"#,
         .mcpCredentials(id: 1, agentID: agent, server: "grafana", reason: .connect, challenge: nil)),
        (#"{"type":"mcpCredentials","agentID":"a1","server":"linear","reason":"forbidden","challenge":"Bearer error=\"insufficient_scope\", scope=\"issues:write\"","id":2}"#,
         .mcpCredentials(id: 2, agentID: agent, server: "linear", reason: .forbidden,
                         challenge: #"Bearer error="insufficient_scope", scope="issues:write""#)),
        // A state report: no scopes, no tools; a needsScopes report names them.
        (#"{"type":"mcpReport","agentID":"a1","report":{"server":"notion","status":{"state":"starting"}}}"#,
         .mcpReport(agentID: agent, report: MCPServerReport(server: "notion", status: MCPServerStatus(state: .starting)))),
        (#"{"type":"mcpReport","agentID":"a1","report":{"server":"linear","status":{"state":"needsScopes","scopes":["issues:write"],"message":"linear needs more access"},"transport":"streamableHTTP"}}"#,
         .mcpReport(agentID: agent, report: MCPServerReport(
            server: "linear", status: MCPServerStatus(state: .needsScopes, scopes: ["issues:write"], message: "linear needs more access"),
            transport: .streamableHTTP))),
        // Tools past the 900 KB frame budget arrive with empty schemas; a missing description is empty.
        (#"{"type":"mcpReport","agentID":"a1","report":{"server":"fake","status":{"state":"connected"},"transport":"stdio","serverName":"Fake MCP","tools":[{"name":"echo","title":"Echo","description":"Echo.","inputSchema":{}},{"name":"bare"}]}}"#,
         .mcpReport(agentID: agent, report: MCPServerReport(
            server: "fake", status: MCPServerStatus(state: .connected), transport: .stdio, serverName: "Fake MCP",
            tools: [MCPToolInfo(name: "echo", title: "Echo", description: "Echo.", inputSchema: .object([:])), MCPToolInfo(name: "bare")]))),
    ]

    @Test(arguments: handWritten)
    func decodesTheShapeExtensionsWrite(json: String, expected: ExtensionMessage) throws {
        #expect(try Wire.decode(ExtensionMessage.self, json) == expected)
    }

    @Test(arguments: [AgentCoordinationRequest.Operation.read, .steer, .interrupt, .status, .delete])
    func everyCoordinationOperationRoundTrips(_ operation: AgentCoordinationRequest.Operation) throws {
        let message = ExtensionMessage.coordinateAgent(id: 3, agentID: Self.agent, targetAgentID: AgentID(rawValue: "a2"),
                                                       request: AgentCoordinationRequest(operation: operation))
        #expect(try Wire.roundTrip(message) == message)
        #expect(try Wire.object(message)["request"] as? [String: String] == ["operation": operation.rawValue])
    }

    @Test func optionalFieldsAreOmittedRatherThanNull() throws {
        let object = try Wire.object(ExtensionMessage.updateAutomation(
            id: 1, automationID: Self.automation, name: nil, prompt: nil, cwd: nil, enabled: nil
        ))
        #expect(Set(object.keys) == ["type", "id", "automationID"])
    }

    @Test(arguments: [
        #"{"type":"launchMissiles","agentID":"a1"}"#,
        #"{"agentID":"a1","status":"idle"}"#,
        #"{"type":"setAgentStatus","agentID":"a1","status":"sleeping"}"#,
        #"{"type":"closePane","id":1,"agentID":"a1"}"#,
    ])
    func malformedMessagesFailToDecode(_ json: String) {
        #expect(throws: DecodingError.self) { try Wire.decode(ExtensionMessage.self, json) }
    }
}

@Suite("Extension socket replies")
struct ExtensionReplyTests {
    static let pane = PaneInfo(id: PaneID(rawValue: "p1"), cwd: "/tmp", isAgentPane: false, isFocused: true, isAlive: true)

    static func caseName(_ reply: ExtensionReply) -> String {
        switch reply {
        case .childCommand, .ok, .error, .panes, .paneOpened, .paneContent, .reviewResult, .automations,
             .agents, .message, .agentRequest, .agentResult, .suggestion, .design, .designBoard, .designWritten,
             .designComments, .designComment, .designSystems, .designSystem, .designSystemWritten, .designProposals, .mcpCredentials:
            return Wire.caseName(reply)
        }
    }
    static let caseCount = 23
    static let system = DesignSystemSummary(
        info: DesignSystemInfo(namespace: "acme-web", title: "acme-web", revision: 3, createdAt: 1_000, updatedAt: 2_000,
                               syncedAt: 2_000, ownerDesignID: DesignID(rawValue: "d1"), spaceID: SpaceID(rawValue: "s1"),
                               sources: ["web/static/tokens.css"]),
        counts: DesignSystemCounts(colors: 11, type: 4, lengths: 7, components: 9))
    static let tokens = DesignSystemTokens(
        name: "acme-web", namespace: "acme-web",
        colors: [.init(name: "--accent", value: "#4f46e5", source: .init(file: "web/static/tokens.css", line: 8))],
        type: [.init(name: "display", size: 26, weight: 700, sample: "Checkout funnel")],
        spacing: [.init(name: "--space-4", px: 16)], radii: [.init(name: "--radius-md", px: 8)],
        components: [.init(name: "Button", source: .init(file: "templates/partials/button.html"), specimen: "components/Button.html")])
    static let comment = DesignComment(
        id: UUID(uuidString: "7A1C2E7B-39F5-4B0C-9A40-0E8B1F3C5D21")!, number: 1, board: board, tid: 5, path: [1, 1, 0],
        label: "Checkout funnel 48,210", target: "Checkout funnel", rect: DesignCommentRect(x: 59, y: 288, w: 648, h: 216),
        text: "Show the absolute counts next to the percentages.", createdAt: 1_758_000_000_000,
        replies: [DesignCommentReply(id: UUID(uuidString: "0F7E9A3D-2B41-4C8E-8D7A-5E2B1C9F0A34")!, author: .agent,
                                     text: "Done on A and A · phone.", createdAt: 1_758_000_060_000)])

    static let board = DesignPath("A.dc.html")!
    static let snapshot = DesignSnapshot(
        designID: DesignID(rawValue: "d1"), revision: 4,
        index: DesignIndex(title: "Checkout funnel", boards: [board: DesignIndex.Board(x: 0, y: 0, w: 1280, h: 800, title: "A · Funnel first")],
                           order: [board]),
        boards: [board: "5e1f", DesignPath("B.dc.html")!: "77aa"]
    )

    static let samples: [ExtensionReply] = [
        .childCommand(id: 1, runID: "native-1", action: .message, text: "Replace everywhere", mode: .steer),
        .ok(id: 1),
        .error(id: 2, code: "no_such_pane", message: "pane is not in this agent's layout"),
        .panes(id: 3, panes: [pane]),
        .paneOpened(id: 4, pane: pane),
        .paneContent(id: 5, paneID: pane.id, lines: ["$ npm run dev", "listening on :3000"]),
        .reviewResult(id: 7, text: "Looks good.\n\nSummary: ready to merge."),
        .automations(id: 1, automations: [
            AutomationInfo(id: AutomationID(), name: "pr-watch", prompt: "watch", cwd: "/r", enabled: true, agentStatus: "working"),
            AutomationInfo(id: AutomationID(), name: "nightly", prompt: "check", cwd: "/t", enabled: false, agentStatus: nil),
        ]),
        .agents(id: 1, agents: [
            AgentPeerInfo(id: AgentID(), name: "worker", status: "working", cwd: "/tmp", isSelf: false),
            AgentPeerInfo(id: AgentID(), name: "me", status: "idle", cwd: "/tmp", isSelf: true),
        ]),
        .message(id: 0, text: "[from: worker] done"),
        .agentRequest(id: 0, requestID: "server-token", targetAgentID: AgentID(rawValue: "a2"),
                      request: AgentCoordinationRequest(operation: .steer, text: "[from: worker] change course")),
        .agentResult(id: 19, result: AgentCoordinationResult(text: "request cancelled", code: "cancelled")),
        .suggestion(id: 20, outcome: .dismissed),
        .design(id: 21, snapshot: snapshot),
        .designBoard(id: 22, board: DesignBoardSource(path: board, source: "<!doctype html>\n<x-dc>Hi</x-dc>\n", sha256: "5e1f", revision: 4)),
        .designWritten(id: 23, result: DesignWriteResult(revision: 5, changed: true, sha256: "9c0d", created: true,
                                                          warnings: [.innerHTML, .missingPreview], title: "Checkout funnel", boardCount: 1)),
        .designComments(id: 24, comments: DesignComments(revision: 3, comments: [
            comment, DesignComment(number: 2, board: DesignPath("flows/Cart.dc.html")!, tid: 2, path: [0, 1], text: "Bigger total",
                                   createdAt: 3, resolvedAt: 4, detached: true),
        ])),
        .designComment(id: 25, comment: comment),
        .designSystems(id: 26, listing: DesignSystemListing(
            systems: [DesignSystemSummary(info: DesignSystemInfo(namespace: "night-watch", title: "Night Watch", revision: 1, createdAt: 0),
                                          builtIn: true, counts: DesignSystemCounts(colors: 31, type: 9, lengths: 12)), system],
            installed: [DesignSystemInstalled(namespace: "acme-web", title: "acme-web", shepherd: true, version: "3", tokens: tokens,
                                              tokensFile: "ds/acme-web/tokens.json"),
                        DesignSystemInstalled(namespace: "cds", title: "CDS", shepherd: false, tokens: nil, tokensFile: nil)],
            primary: "acme-web")),
        .designSystem(id: 27, system: DesignSystemRead(summary: system, tokens: tokens, readme: "# acme-web\n",
                                                        files: ["README.md", "tokens.css", "tokens.json"])),
        .designSystemWritten(id: 28, result: DesignSystemWriteResult(
            summary: system, changed: true, installed: DesignWriteResult(revision: 9, changed: true, title: "Checkout", boardCount: 4),
            notes: ["tokens.css is the one you wrote"])),
        .designProposals(id: 29, proposals: [proposal]),
        .mcpCredentials(id: 29, credentials: MCPCredentials(bearer: "at-1", headers: ["X-Org": "acme"],
                                                            env: ["DATABASE_URI": "postgres://u:p@db/app"], expiresAtMs: 1_790_000_000_000)),
    ]

    static let proposal = DesignCommentDraft(board: DesignPath("A-phone.dc.html")!, tid: 31, path: [1, 1, 2], label: "Steps Cart viewed",
                                             target: "Steps list", text: "Thicker bars on phone.", proposal: "toolu_01#0")

    @Test func samplesCoverEveryCase() {
        #expect(Set(Self.samples.map(Self.caseName)).count == Self.caseCount)
    }

    @Test(arguments: samples)
    func roundTripsThroughNDJSON(_ reply: ExtensionReply) throws {
        #expect(try Wire.roundTrip(reply) == reply)
    }

    @Test(arguments: samples)
    func typeDiscriminatorIsTheCaseName(_ reply: ExtensionReply) throws {
        #expect(try Wire.object(reply)["type"] as? String == Self.caseName(reply))
    }

    /// The MCP extension reads `credentials.bearer`, `.headers`, `.env` and `.expiresAtMs` by hand,
    /// and leaves out nothing it needs when the app sends no token.
    @Test func mcpCredentialsHaveTheShapeTheExtensionReads() throws {
        let full = try Wire.object(ExtensionReply.mcpCredentials(id: 3, credentials: MCPCredentials(
            bearer: "at", headers: [:], env: ["TOKEN": "s"], expiresAtMs: 42)))
        #expect(full["id"] as? Int == 3)
        let credentials = try #require(full["credentials"] as? [String: Any])
        #expect(credentials["bearer"] as? String == "at")
        #expect(credentials["env"] as? [String: String] == ["TOKEN": "s"])
        #expect(credentials["headers"] as? [String: String] == [:])
        #expect(credentials["expiresAtMs"] as? Int == 42)
        let secretsOnly = try Wire.object(ExtensionReply.mcpCredentials(id: 4, credentials: MCPCredentials(env: ["A": "b"])))
        #expect(Set((secretsOnly["credentials"] as? [String: Any] ?? [:]).keys) == ["headers", "env"])
        #expect(try Wire.decode(ExtensionReply.self, #"{"type":"mcpCredentials","id":5,"credentials":{}}"#)
            == .mcpCredentials(id: 5, credentials: MCPCredentials()))
    }

    @Test(arguments: [ChildCommandAction.message, .cancel, .resume, .pause, .continue])
    func everyChildCommandActionRoundTrips(_ action: ChildCommandAction) throws {
        let reply = ExtensionReply.childCommand(id: 5, runID: "native-1", action: action, text: nil, mode: nil)
        #expect(try Wire.roundTrip(reply) == reply)
        #expect(try Wire.object(reply)["text"] == nil)
    }

    /// What the panes extension reads: the relayed request's token and operation, and a
    /// result whose `code` marks a failure.
    @Test func coordinationRepliesCarryTheShapeTheExtensionReads() throws {
        let request = try Wire.object(ExtensionReply.agentRequest(
            id: 0, requestID: "tok", targetAgentID: AgentID(rawValue: "a2"), request: AgentCoordinationRequest(operation: .interrupt)))
        #expect(request["requestID"] as? String == "tok" && request["targetAgentID"] as? String == "a2")
        #expect(request["request"] as? [String: String] == ["operation": "interrupt"])
        let result = try Wire.object(ExtensionReply.agentResult(id: 4, result: AgentCoordinationResult(text: "done")))
        #expect(result["result"] as? [String: String] == ["text": "done"])
    }

    /// What the design extension reads: the index as canvas.json, boards as a path → hash map, a
    /// board's source, and a write's revision, `created` and warning codes.
    @Test func designRepliesCarryTheShapeTheExtensionReads() throws {
        let design = try Wire.object(ExtensionReply.design(id: 1, snapshot: Self.snapshot))
        let snapshot = try #require(design["snapshot"] as? [String: Any])
        #expect(snapshot["revision"] as? Int == 4)
        #expect(snapshot["boards"] as? [String: String] == ["A.dc.html": "5e1f", "B.dc.html": "77aa"])
        let index = try #require(snapshot["index"] as? [String: Any])
        #expect(index["v"] as? Int == 3 && index["title"] as? String == "Checkout funnel")
        #expect(index["order"] as? [String] == ["A.dc.html"])
        #expect((index["boards"] as? [String: [String: Any]])?["A.dc.html"]?["title"] as? String == "A · Funnel first")

        let board = try Wire.object(ExtensionReply.designBoard(id: 2, board: DesignBoardSource(path: Self.board, source: "s", sha256: "h", revision: 4)))
        #expect(board["board"] as? [String: AnyHashable] == ["path": "A.dc.html", "source": "s", "sha256": "h", "revision": 4])

        let written = try Wire.object(ExtensionReply.designWritten(id: 3, result: DesignWriteResult(
            revision: 5, changed: true, created: false, warnings: [.globalKeyHandler], title: nil, boardCount: 2)))
        let result = try #require(written["result"] as? [String: Any])
        #expect(result["revision"] as? Int == 5 && result["changed"] as? Bool == true && result["created"] as? Bool == false)
        #expect(result["warnings"] as? [String] == ["global_key_handler"])
        #expect(result["boardCount"] as? Int == 2)
    }

    @Test func aPushedMessageWithoutAnIDDecodesAsIDZero() throws {
        #expect(try Wire.decode(ExtensionReply.self, #"{"type":"message","text":"hi"}"#) == .message(id: 0, text: "hi"))
    }

    /// What `comment_list` and `comment_reply` read: ids, numbers, the board by path, the
    /// element's halves, the words, replies with their author, and whether it is resolved.
    @Test func commentRepliesCarryTheShapeTheExtensionReads() throws {
        let list = try Wire.object(ExtensionReply.designComments(id: 1, comments: DesignComments(revision: 3, comments: [Self.comment])))
        let comments = try #require(list["comments"] as? [String: Any])
        #expect(comments["revision"] as? Int == 3)
        let first = try #require((comments["comments"] as? [[String: Any]])?.first)
        #expect(first["id"] as? String == "7A1C2E7B-39F5-4B0C-9A40-0E8B1F3C5D21" && first["number"] as? Int == 1)
        #expect(first["board"] as? String == "A.dc.html" && first["tid"] as? Int == 5 && first["path"] as? [Int] == [1, 1, 0])
        #expect(first["text"] as? String == "Show the absolute counts next to the percentages.")
        #expect(first["target"] as? String == "Checkout funnel" && first["detached"] as? Bool == false)
        #expect(first["resolvedAt"] == nil)
        let reply = try #require((first["replies"] as? [[String: Any]])?.first)
        #expect(reply["author"] as? String == "agent" && reply["text"] as? String == "Done on A and A · phone.")
        let one = try Wire.object(ExtensionReply.designComment(id: 2, comment: Self.comment))
        #expect((one["comment"] as? [String: Any])?["number"] as? Int == 1)
    }

    /// What `markup_propose` reads and hands the chat: each proposal's board by path, the
    /// element's halves, its names, words and proposal id.
    @Test func proposalRepliesCarryTheShapeTheExtensionReads() throws {
        let object = try Wire.object(ExtensionReply.designProposals(id: 3, proposals: [Self.proposal]))
        let first = try #require((object["proposals"] as? [[String: Any]])?.first)
        #expect(first["board"] as? String == "A-phone.dc.html" && first["tid"] as? Int == 31 && first["path"] as? [Int] == [1, 1, 2])
        #expect(first["target"] as? String == "Steps list" && first["text"] as? String == "Thicker bars on phone.")
        #expect(first["proposal"] as? String == "toolu_01#0")
    }

    @Test func emptyCollectionsRoundTrip() throws {
        for reply in [ExtensionReply.agents(id: 2, agents: []), .automations(id: 2, automations: []), .panes(id: 2, panes: []),
                      .designProposals(id: 2, proposals: [])] {
            #expect(try Wire.roundTrip(reply) == reply)
        }
    }
}

@Suite("Child run rows")
struct ChildRunTests {
    @Test(arguments: ["complete", "failed", "stopped", "paused", "rejected"])
    func finishedStatesAreTerminal(_ state: String) {
        #expect(ChildRun(runID: "r", label: "l", state: state).isTerminal)
    }

    @Test(arguments: ["running", "queued", "some-future-state", ""])
    func anythingElseCountsAsLive(_ state: String) {
        #expect(!ChildRun(runID: "r", label: "l", state: state).isTerminal)
    }

    @Test func identityIncludesTheLaneIndexWhenPresent() {
        #expect(ChildRun(runID: "run", label: "l", state: "running").id == "run")
        #expect(ChildRun(runID: "run", childIndex: 3, label: "l", state: "running").id == "run#3")
    }

    /// The children extension's exact `JSON.stringify` shape: a pi-subagents row with every
    /// optional omitted next to native rows carrying card fields.
    @Test func decodesTheSubagentsExtensionShape() throws {
        let json = #"""
        {"type":"setAgentChildren","agentID":"a","children":[
         {"runID":"run-2","label":"scout","state":"complete","needsAttention":false},
         {"runID":"native-1","label":"worker: restyle","state":"running","startedAt":1,"needsAttention":false,
          "role":"worker","model":"p/m","thinking":"high","context":"background","step":{"index":1,"total":3},
          "turns":78,"toolCalls":82,"tokens":922000,"contextPercent":62,
          "lastActivity":{"kind":"tool","tool":"edit","preview":"Sources/A.swift","diff":{"added":31,"removed":0},"at":2},
          "toolCallID":"call_1","task":"Restyle","sessionFile":"/tmp/c/session.jsonl","paused":true},
         {"runID":"native-2","label":"reviewer","state":"running","needsAttention":true,"attentionText":"Two names collide",
          "question":{"text":"Two names collide","options":["Replace everywhere","Rename new ones"],"short":"token names?"}},
         {"runID":"native-3","label":"tests","state":"complete","needsAttention":false,
          "result":{"files":2,"added":96,"removed":3,"tools":19,"tokens":118000},"output":"Added 6 tests.",
          "cwd":"/repo","files":[{"path":"Tests/A.swift","added":96,"removed":3}],"summary":"Added 6 tests.","sessionID":"child-3"},
         {"runID":"native-4","label":"docs","state":"failed","needsAttention":false,"exitReason":"exit 1 · context limit"}
        ]}
        """#
        guard case .setAgentChildren(_, let rows) = try Wire.decode(ExtensionMessage.self, json) else {
            Issue.record("expected setAgentChildren"); return
        }
        #expect(rows.count == 5)
        #expect(rows[0] == ChildRun(runID: "run-2", label: "scout", state: "complete"))
        #expect(rows[1].step == ChildStep(index: 1, total: 3))
        #expect(rows[1].lastActivity == ChildActivity(tool: "edit", preview: "Sources/A.swift", diff: ChildDiff(added: 31, removed: 0), at: 2))
        #expect(rows[1].contextPercent == 62 && rows[1].paused == true && rows[1].toolCallID == "call_1")
        #expect(rows[2].question == ChildQuestion(text: "Two names collide", options: ["Replace everywhere", "Rename new ones"],
                                                  short: "token names?"))
        #expect(rows[3].result == ChildResultSummary(files: 2, added: 96, removed: 3, tools: 19, tokens: 118000))
        #expect(rows[3].files == [ChildFileChange(path: "Tests/A.swift", added: 96, removed: 3)])
        #expect(rows[3].sessionID == "child-3" && rows[3].cwd == "/repo")
        #expect(rows[4].exitReason == "exit 1 · context limit")
        for row in rows { #expect(try Wire.roundTrip(row) == row) }
    }

    /// A question from an extension older than its short reason decodes without one.
    @Test func aChildQuestionWithoutAShortReasonDecodes() throws {
        let question = try Wire.decode(ChildQuestion.self, #"{"text":"Rename or replace?"}"#)
        #expect(question == ChildQuestion(text: "Rename or replace?"))
        #expect(try Wire.object(question).keys.sorted() == ["text"])
    }

    @Test func absentCardFieldsNeverAppearOnTheWire() throws {
        let object = try Wire.object(ChildRun(runID: "r", label: "l", state: "running"))
        #expect(Set(object.keys) == ["runID", "label", "state", "needsAttention"])
    }
}
