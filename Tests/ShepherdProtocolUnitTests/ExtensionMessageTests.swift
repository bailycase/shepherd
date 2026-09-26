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
             .updateAutomation, .deleteAutomation, .startAutomation, .stopAutomation:
            return Wire.caseName(message)
        }
    }
    static let caseCount = 27

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
             .agents, .message, .agentRequest, .agentResult:
            return Wire.caseName(reply)
        }
    }
    static let caseCount = 12

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
    ]

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

    @Test func aPushedMessageWithoutAnIDDecodesAsIDZero() throws {
        #expect(try Wire.decode(ExtensionReply.self, #"{"type":"message","text":"hi"}"#) == .message(id: 0, text: "hi"))
    }

    @Test func emptyCollectionsRoundTrip() throws {
        for reply in [ExtensionReply.agents(id: 2, agents: []), .automations(id: 2, automations: []), .panes(id: 2, panes: [])] {
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
