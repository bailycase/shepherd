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
             .designRead, .designWriteBoard, .designEditBoard, .designUpdateIndex, .designComments, .designCommentReply,
             .designEditBoards, .designSearch, .designCheckpoint, .designRender, .designExtract,
             .designSystemRead, .designSystemWrite, .designProposeComments, .designGet, .designNote,
             .helloBrowser, .browser:
            return Wire.caseName(message)
        }
    }
    static let caseCount = 46
    static let design = DesignID(rawValue: "d1")

    static let samples: [ExtensionMessage] = [
        .setAgentStatus(agentID: agent, status: .blocked),
        .setAgentName(agentID: agent, name: "Title with \"quotes\" and ünicode", sessionID: "session-a"),
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
        .sendToAgent(id: 17, agentID: agent, targetAgentID: AgentID(rawValue: "a2"), text: "CI is green", delivery: .report),
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
        .designEditBoard(id: 34, agentID: agent, designID: design, path: "A.dc.html", edits: [
            DesignBoardEdit(find: "Pay now", replace: "Pay “now” · 👋"),
            DesignBoardEdit(find: "--accent: #4f46e5;", replace: "--accent: #4338ca;", all: true),
        ], baseRevision: 7, tokens: .snap),
        .designWriteBoard(id: 44, agentID: agent, designID: design, path: "A.dc.html", source: "<x-dc></x-dc>", baseRevision: nil, tokens: .strict),
        .designEditBoards(id: 45, agentID: agent, designID: design, request: DesignBatchEditRequest(
            boards: [.init(path: "A.dc.html"), .init(path: "B.dc.html", edits: [DesignBoardEdit(find: "Pay", replace: "Buy")])],
            edits: [DesignBoardEdit(find: "#4f46e5", replace: "var(--accent)", all: true)],
            atomic: true, dryRun: true, checkpoint: "before chip move", tokens: .warn, snapExisting: true, baseRevision: 7)),
        .designSearch(id: 46, agentID: agent, designID: design, query: DesignSearchQuery(
            text: "Pay now", regex: true, scope: .labels, ignoreCase: true, tag: "div", attribute: "aria-label", value: "Close",
            elementClass: "chip", usages: "Card", paths: ["A.dc.html"], limit: 10)),
        .designCheckpoint(id: 47, agentID: agent, designID: design, request: DesignCheckpointRequest(action: .restore, name: "before chip move")),
        .designRender(id: 48, agentID: agent, designID: design, request: DesignRenderRequest(
            path: "A.dc.html", width: 390, height: 844, scale: 2, props: .object(["density": .string("compact")]))),
        .designExtract(id: 49, agentID: agent, designID: design, request: DesignExtractRequest(
            path: "A.dc.html", element: "A.dc.html#4:0/1", piece: "Card", props: [.init(name: "label", text: "Pay “now”")],
            size: DesignBoardCheck.Size(width: 320, height: 120), frame: .init(x: 0, y: 1_000, w: 320, h: 120, title: "Card", page: "p1"),
            copies: ["B.dc.html"], allCopies: true, checkpoint: "before extract", baseRevision: 7)),
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
        .designGet(id: 29, agentID: agent, reference: "shepherd-design-ref://local/d1/flows%2FCart.dc.html#12:0/1@7", what: "element"),
        .designGet(id: 32, agentID: agent, reference: "shepherd-design-ref://local/d1@7", what: "image"),
        .designNote(id: 33, agentID: agent, reference: "shepherd-design-ref://local/d1/A.dc.html#2:0/1@7",
                    text: "Implemented in #142 on agent/checkout-funnel. Bars use --accent; “counts” use the table cell."),
        .helloBrowser(agentID: agent),
        .browser(id: 40, agentID: agent, request: .open(url: "http://localhost:5173/checkout", note: "opening the checkout")),
    ] + browserRequests.map { .browser(id: 41, agentID: agent, request: $0) }

    /// Every browser tool's request, with and without its optional parameters.
    static let browserRequests: [BrowserRequest] = [
        .open(url: "https://example.com/", note: nil),
        .read(selector: nil, maxChars: nil), .read(selector: "main > form", maxChars: 12_000),
        .click(ref: "e12", double: false, note: nil), .click(ref: "e12", double: true, note: "clicking through checkout"),
        .type(ref: "e3", text: "baily@acme.dev", clear: false, submit: false, note: nil),
        .type(ref: "e3", text: "line\nbreak “quoted” ünicode", clear: true, submit: true, note: "filling in the form"),
        .press(key: "Enter", note: nil), .press(key: "Control+a", note: "selecting all"),
        .scroll(direction: "down", amount: nil, ref: nil, note: nil), .scroll(direction: "up", amount: 400, ref: "e9", note: "scrolling"),
        .scroll(direction: nil, amount: nil, ref: "e9", note: nil),
        .wait(text: nil, ref: nil, gone: false, ms: 500, timeout: nil),
        .wait(text: "Order placed", ref: nil, gone: false, ms: nil, timeout: 15.5),
        .wait(text: nil, ref: "e7", gone: true, ms: nil, timeout: 2),
        .screenshot(ref: nil), .screenshot(ref: "e4"),
        .console(clear: false), .console(clear: true),
        .eval(expression: "document.title", note: nil), .eval(expression: "const a = 1;\nreturn a", note: "running a script"),
        .back(note: nil), .forward(note: "going forward"), .reload(note: nil),
    ]

    @Test func samplesCoverEveryCase() {
        #expect(Set(Self.samples.map(Self.caseName)).count == Self.caseCount)
    }

    /// The messages that name no agent at all, so no connection is bound to an agent by sending
    /// them: the automation requests (any pi session may send them) and the answer to a child
    /// command (bound to the connection the command went to).
    static let namesNoAgent: Set<String> = [
        "childCommandResult", "createAutomation", "listAutomations", "updateAutomation", "deleteAutomation",
        "startAutomation", "stopAutomation",
    ]
    /// Messages that carry an `id` and are never answered with one.
    static let neverAnswered: Set<String> = ["childCommandResult", "cancelAgentRequest"]

    /// The server serves a message only on a connection opened by the pi of the agent it speaks
    /// for: that agent is the one the message's wire form names as `agentID`.
    @Test(arguments: samples)
    func aMessageSpeaksForTheAgentItNames(_ message: ExtensionMessage) throws {
        let wire = try Wire.object(message)
        #expect(message.speaksFor?.rawValue == wire["agentID"] as? String)
        #expect((message.speaksFor == nil) == Self.namesNoAgent.contains(Self.caseName(message)))
    }

    @Test(arguments: samples)
    func aRefusalIsAddressedToTheIdOfTheRequestItAnswers(_ message: ExtensionMessage) throws {
        let wire = try Wire.object(message)
        let expected = Self.neverAnswered.contains(Self.caseName(message)) ? nil : wire["id"] as? Int
        #expect(message.replyID == expected)
    }

    @Test func aMessageNamingATargetSpeaksForItsSenderNotItsTarget() {
        let target = AgentID(rawValue: "a2")
        #expect(ExtensionMessage.sendToAgent(id: 1, agentID: Self.agent, targetAgentID: target, text: "hi").speaksFor == Self.agent)
        #expect(ExtensionMessage.coordinateAgent(id: 1, agentID: Self.agent, targetAgentID: target,
                                                 request: AgentCoordinationRequest(operation: .read)).speaksFor == Self.agent)
        #expect(ExtensionMessage.agentResponse(agentID: target, requestID: "t", result: AgentCoordinationResult(text: "")).speaksFor == target)
    }

    @Test func everyBrowserActionHasARequestSample() {
        #expect(Set(Self.browserRequests.map(\.action)) == Set(BrowserRequest.Action.allCases))
    }

    @Test(arguments: browserRequests)
    func aBrowserRequestRoundTripsOnItsOwn(_ request: BrowserRequest) throws {
        #expect(try Wire.roundTrip(request) == request)
        #expect(try Wire.object(request)["action"] as? String == request.action.rawValue)
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
        (#"{"type":"setAgentName","agentID":"a1","name":"Current title","sessionID":"session-b"}"#,
         .setAgentName(agentID: agent, name: "Current title", sessionID: "session-b")),
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
        // board_edit omits `all` unless it is true.
        (#"{"type":"designEditBoard","path":"A.dc.html","edits":[{"find":"Pay","replace":"Buy"},{"find":"a","replace":"b","all":true}],"id":12,"agentID":"a1","designID":"d1"}"#,
         .designEditBoard(id: 12, agentID: agent, designID: design, path: "A.dc.html",
                          edits: [DesignBoardEdit(find: "Pay", replace: "Buy"), DesignBoardEdit(find: "a", replace: "b", all: true)],
                          baseRevision: nil)),
        (#"{"type":"designEditBoard","path":"A.dc.html","edits":[{"find":"x","replace":"","all":false}],"baseRevision":3,"id":13,"agentID":"a1","designID":"d1"}"#,
         .designEditBoard(id: 13, agentID: agent, designID: design, path: "A.dc.html", edits: [DesignBoardEdit(find: "x", replace: "")],
                          baseRevision: 3)),
        // The write tools take a tokens mode; left out, the host warns.
        (#"{"type":"designWriteBoard","path":"A.dc.html","source":"s","tokens":"snap","id":18,"agentID":"a1","designID":"d1"}"#,
         .designWriteBoard(id: 18, agentID: agent, designID: design, path: "A.dc.html", source: "s", baseRevision: nil, tokens: .snap)),
        (#"{"type":"designEditBoard","path":"A.dc.html","edits":[{"find":"x","replace":"y"}],"tokens":"strict","id":19,"agentID":"a1","designID":"d1"}"#,
         .designEditBoard(id: 19, agentID: agent, designID: design, path: "A.dc.html", edits: [DesignBoardEdit(find: "x", replace: "y")],
                          baseRevision: nil, tokens: .strict)),
        // boards_edit nests its request; every option but the boards is left out when it isn't set.
        (#"{"type":"designEditBoards","request":{"boards":[{"path":"A.dc.html"},{"path":"B.dc.html","edits":[{"find":"a","replace":"b"}]}],"edits":[{"find":"x","replace":"y","all":true}]},"id":14,"agentID":"a1","designID":"d1"}"#,
         .designEditBoards(id: 14, agentID: agent, designID: design, request: DesignBatchEditRequest(
            boards: [.init(path: "A.dc.html"), .init(path: "B.dc.html", edits: [DesignBoardEdit(find: "a", replace: "b")])],
            edits: [DesignBoardEdit(find: "x", replace: "y", all: true)]))),
        (#"{"type":"designEditBoards","request":{"boards":[{"path":"A.dc.html"}],"edits":[{"find":"x","replace":"y"}],"atomic":true,"dryRun":true,"checkpoint":"before chip move","tokens":"snap","baseRevision":4},"id":15,"agentID":"a1","designID":"d1"}"#,
         .designEditBoards(id: 15, agentID: agent, designID: design, request: DesignBatchEditRequest(
            boards: [.init(path: "A.dc.html")], edits: [DesignBoardEdit(find: "x", replace: "y")], atomic: true, dryRun: true,
            checkpoint: "before chip move", tokens: .snap, baseRevision: 4))),
        // design_check's snap goes through the same message.
        (#"{"type":"designEditBoards","request":{"boards":[{"path":"A.dc.html"}],"snapExisting":true,"tokens":"snap"},"id":16,"agentID":"a1","designID":"d1"}"#,
         .designEditBoards(id: 16, agentID: agent, designID: design, request: DesignBatchEditRequest(
            boards: [.init(path: "A.dc.html")], tokens: .snap, snapExisting: true))),
        (#"{"type":"designSearch","query":{"text":"Pay now"},"id":17,"agentID":"a1","designID":"d1"}"#,
         .designSearch(id: 17, agentID: agent, designID: design, query: DesignSearchQuery(text: "Pay now"))),
        (#"{"type":"designSearch","query":{"tag":"div","attribute":"aria-label","value":"Close","class":"top","scope":"text","regex":true,"limit":5},"id":20,"agentID":"a1","designID":"d1"}"#,
         .designSearch(id: 20, agentID: agent, designID: design, query: DesignSearchQuery(
            regex: true, scope: .text, tag: "div", attribute: "aria-label", value: "Close", elementClass: "top", limit: 5))),
        (#"{"type":"designCheckpoint","request":{"action":"list"},"id":21,"agentID":"a1","designID":"d1"}"#,
         .designCheckpoint(id: 21, agentID: agent, designID: design, request: DesignCheckpointRequest(action: .list))),
        (#"{"type":"designCheckpoint","request":{"action":"create","name":"before chip move"},"id":22,"agentID":"a1","designID":"d1"}"#,
         .designCheckpoint(id: 22, agentID: agent, designID: design, request: DesignCheckpointRequest(action: .create, name: "before chip move"))),
        (#"{"type":"designRender","request":{"path":"A.dc.html"},"id":23,"agentID":"a1","designID":"d1"}"#,
         .designRender(id: 23, agentID: agent, designID: design, request: DesignRenderRequest(path: "A.dc.html"))),
        // board_extract leaves out what it wasn't given.
        (#"{"type":"designExtract","request":{"path":"A.dc.html","element":"4:0/1","piece":"Card"},"id":24,"agentID":"a1","designID":"d1"}"#,
         .designExtract(id: 24, agentID: agent, designID: design, request: DesignExtractRequest(path: "A.dc.html", element: "4:0/1", piece: "Card"))),
        (#"{"type":"designExtract","request":{"path":"A.dc.html","element":"4","piece":"Card","props":[{"name":"label","text":"Pay now"}],"size":{"width":320,"height":120},"frame":{"y":900,"title":"Card"},"allCopies":true,"checkpoint":"x","baseRevision":3},"id":25,"agentID":"a1","designID":"d1"}"#,
         .designExtract(id: 25, agentID: agent, designID: design, request: DesignExtractRequest(
            path: "A.dc.html", element: "4", piece: "Card", props: [.init(name: "label", text: "Pay now")],
            size: DesignBoardCheck.Size(width: 320, height: 120), frame: .init(y: 900, title: "Card"), allCopies: true, checkpoint: "x", baseRevision: 3))),
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
        // design_get's frame: the extension spreads its fields, then adds id and agentID; a bad ref or
        // aspect still decodes, so the server can answer it.
        (#"{"type":"designGet","reference":"shepherd-design-ref://local/d1/A.dc.html@3","what":"summary","id":12,"agentID":"a1"}"#,
         .designGet(id: 12, agentID: agent, reference: "shepherd-design-ref://local/d1/A.dc.html@3", what: "summary")),
        (#"{"type":"designGet","reference":"not a ref","what":"everything","id":13,"agentID":"a1"}"#,
         .designGet(id: 13, agentID: agent, reference: "not a ref", what: "everything")),
        // The browser extension registers, then asks; unset parameters are simply absent.
        (#"{"type":"helloBrowser","agentID":"a1"}"#, .helloBrowser(agentID: agent)),
        (#"{"type":"browser","id":1,"agentID":"a1","request":{"action":"open","url":"http://localhost:5173/"}}"#,
         .browser(id: 1, agentID: agent, request: .open(url: "http://localhost:5173/", note: nil))),
        (#"{"type":"browser","id":2,"agentID":"a1","request":{"action":"click","ref":"e12","double":true,"note":"clicking through checkout"}}"#,
         .browser(id: 2, agentID: agent, request: .click(ref: "e12", double: true, note: "clicking through checkout"))),
        (#"{"type":"browser","id":3,"agentID":"a1","request":{"action":"type","ref":"e3","text":"hi"}}"#,
         .browser(id: 3, agentID: agent, request: .type(ref: "e3", text: "hi", clear: false, submit: false, note: nil))),
        (#"{"type":"browser","id":4,"agentID":"a1","request":{"action":"wait","text":"Done","timeout":12}}"#,
         .browser(id: 4, agentID: agent, request: .wait(text: "Done", ref: nil, gone: false, ms: nil, timeout: 12))),
        (#"{"type":"browser","id":5,"agentID":"a1","request":{"action":"scroll","direction":"down","amount":300}}"#,
         .browser(id: 5, agentID: agent, request: .scroll(direction: "down", amount: 300, ref: nil, note: nil))),
        (#"{"type":"browser","id":6,"agentID":"a1","request":{"action":"console"}}"#,
         .browser(id: 6, agentID: agent, request: .console(clear: false))),
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
        case .parentInput, .childCommand, .ok, .error, .panes, .paneOpened, .paneContent, .reviewResult, .automations,
             .agents, .message, .agentRequest, .agentResult, .suggestion, .design, .designBoard, .designWritten, .designEdited,
             .designComments, .designComment, .designSystems, .designSystem, .designSystemWritten, .designProposals,
             .designBatchEdited, .designSearchResult, .designCheckpoints, .designRendered, .designExtracted,
             .designReference, .designNote, .browserResult:
            return Wire.caseName(reply)
        }
    }
    static let caseCount = 32
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
        .parentInput,
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
        .message(id: 0, text: "[from: worker] done", delivery: .report),
        .agentRequest(id: 0, requestID: "server-token", targetAgentID: AgentID(rawValue: "a2"),
                      request: AgentCoordinationRequest(operation: .steer, text: "[from: worker] change course")),
        .agentResult(id: 19, result: AgentCoordinationResult(text: "request cancelled", code: "cancelled")),
        .suggestion(id: 20, outcome: .dismissed),
        .design(id: 21, snapshot: snapshot),
        .designBoard(id: 22, board: DesignBoardSource(path: board, source: "<!doctype html>\n<x-dc>Hi</x-dc>\n", sha256: "5e1f", revision: 4)),
        .designWritten(id: 23, result: DesignWriteResult(revision: 5, changed: true, sha256: "9c0d", created: true,
                                                          warnings: [.innerHTML, .missingPreview], title: "Checkout funnel", boardCount: 1)),
        .designEdited(id: 36, result: DesignWriteResult(revision: 6, changed: true, sha256: "4b1e", created: false,
                                                        warnings: [.globalKeyHandler], title: "Checkout funnel", boardCount: 2),
                      replaced: [1, 4]),
        .designWritten(id: 37, result: DesignWriteResult(
            revision: 8, changed: true, sha256: "3f2a", created: false, title: "Checkout funnel", boardCount: 2,
            report: DesignBoardReport(
                created: false, bytes: 31_204, delta: 212, imbalance: DesignMarkupImbalance(kind: .unclosed, tag: "span", line: 12, reached: "div", reachedLine: 14),
                roots: 2, root: DesignBoardCheck.Size(width: 1280, height: 800), preview: DesignBoardCheck.Size(width: 1280, height: 800),
                frame: DesignBoardCheck.Size(width: 1280, height: 810),
                diff: DesignTextDiff(added: 1, removed: 1, lines: ["-14 <p>old</p>", "+14 <p>new</p>"], more: 0), missingImports: ["Card"],
                tokenSource: "night-watch", offSystem: [DesignTokenFinding(value: "#3a56d4", count: 2, lines: [14, 30], nearest: "--accent #3056d3")],
                snapped: [DesignTokenReplacement(from: "13px", to: "var(--space-3)", line: 20, token: "12px")]))),
        .designBatchEdited(id: 38, result: DesignBatchResult(
            result: DesignWriteResult(revision: 9, changed: true, title: "Checkout funnel", boardCount: 3),
            boards: [
                DesignBatchBoardResult(path: "A.dc.html", status: .edited, replaced: [2, 1],
                                       report: DesignBoardReport(created: false, bytes: 900, delta: -3)),
                DesignBatchBoardResult(path: "B.dc.html", status: .noMatch, edit: 2, matches: 0, message: "edit 2 matched nothing"),
                DesignBatchBoardResult(path: "C.dc.html", status: .wouldEdit), DesignBatchBoardResult(path: "D.dc.html", status: .unchanged),
                DesignBatchBoardResult(path: "E.dc.html", status: .refused, message: "the root is 400×300 but $preview is 390×844"),
                DesignBatchBoardResult(path: "F.dc.html", status: .missing), DesignBatchBoardResult(path: "../x", status: .invalid),
            ],
            dryRun: false, atomic: true, blocked: false,
            checkpoint: DesignCheckpointInfo(name: "before chip move", createdAt: 1_758_000_000_000, boards: 3, bytes: 90_000, revision: 8),
            pruned: ["old one"])),
        .designSearchResult(id: 39, result: DesignSearchResult(
            boards: [DesignSearchBoard(path: "A.dc.html", count: 2, matches: [
                DesignSearchMatch(line: 14, element: "A.dc.html#4:0/1", tag: "div", ancestors: ["main", "section[data-el=Steps]"], snippet: "<div class=\"top\">"),
                DesignSearchMatch(snippet: "Pay now"),
            ])],
            totalMatches: 2, totalBoards: 1, searched: 4, omittedBoards: 0, piece: "Card.dc.html", pieceExists: true, timedOut: false)),
        .designCheckpoints(id: 40, result: DesignCheckpointResult(
            action: .restore,
            checkpoints: [DesignCheckpointInfo(name: "before chip move", createdAt: 1, boards: 3, bytes: 9, revision: 2)],
            checkpoint: DesignCheckpointInfo(name: "before chip move", createdAt: 1, boards: 3, bytes: 9, revision: 2),
            automatic: DesignCheckpointInfo(name: "before restore before chip move", createdAt: 2, boards: 4, bytes: 12, revision: 5),
            pruned: ["oldest"], write: DesignWriteResult(revision: 6, changed: true, title: nil, boardCount: 3),
            restored: ["A.dc.html"], recreated: ["B.dc.html"], removed: ["C.dc.html"])),
        .designRendered(id: 41, text: "A.dc.html at 1280×800, 2x", image: BrowserImage(data: "iVBORw0KGgo=", mimeType: "image/png")),
        .designExtracted(id: 42, result: DesignExtractResult(
            result: DesignWriteResult(revision: 10, changed: true, title: "Checkout funnel", boardCount: 5), piece: "Card.dc.html",
            importTag: #"<dc-import name="Card" hint-size="320px,120px" label="Pay now"></dc-import>"#,
            boards: [DesignExtractResult.Replaced(path: "B.dc.html", count: 2, report: DesignBoardReport(created: false, bytes: 10))],
            skipped: [DesignExtractResult.Skipped(path: "flows/C.dc.html", why: "it is in another folder")],
            warnings: ["the piece still reads {{ step.name }}"], pieceReport: DesignBoardReport(created: true, bytes: 800),
            sourceReport: DesignBoardReport(created: false, bytes: 900, delta: -100),
            checkpoint: DesignCheckpointInfo(name: "before extract", createdAt: 1, boards: 4, bytes: 5, revision: 9), pruned: ["old"])),
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
        .designReference(id: 30, answer: DesignReferenceAnswer(text: "design_get image of …\nA PNG.", files: ["/tmp/d/Hero@2x.png"],
                                                               image: "/tmp/d/Hero@2x.png")),
        .designReference(id: 31, answer: DesignReferenceAnswer(text: "unchanged")),
        .designReference(id: 32, answer: DesignReferenceAnswer(
            text: "design_get tokens of …", lookedAt: DesignReferenceLookedAt(
                ref: "shepherd-design-ref://local/d1/A.dc.html@4", title: "Checkout › A", aspects: [.tokens],
                tokens: .init(names: ["--accent"], sources: ["web/static/tokens.css:8"])))),
        .designNote(id: 33, note: DesignThreadNote(
            id: UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!, agentID: AgentID(rawValue: "a1"), thread: "Checkout page polish",
            board: DesignPath("A.dc.html")!, element: DesignElementID("A.dc.html#2:0/1"), label: "Pay now", revision: 23,
            text: "Implemented in #142.", createdAt: 1_000)),
        .browserResult(id: 34, text: "Page: Checkout — http://localhost:5173/checkout\n- heading \"Checkout\"", image: nil),
        .browserResult(id: 35, text: "Screenshot of the visible page, 1280×720.",
                       image: BrowserImage(data: "/9j/4AAQSkZJRgABAQ==", mimeType: "image/jpeg")),
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

    /// What `board_edit` reads: the write as `board_write` reads it, and how many matches each edit replaced.
    @Test func boardEditRepliesCarryTheShapeTheExtensionReads() throws {
        let edited = try Wire.object(ExtensionReply.designEdited(id: 3, result: DesignWriteResult(
            revision: 5, changed: true, sha256: "9c0d", created: false, warnings: [.innerHTML], title: nil, boardCount: 2), replaced: [1, 3]))
        #expect(edited["type"] as? String == "designEdited" && edited["id"] as? Int == 3)
        #expect(edited["replaced"] as? [Int] == [1, 3])
        let result = try #require(edited["result"] as? [String: Any])
        #expect(result["revision"] as? Int == 5 && result["changed"] as? Bool == true && result["created"] as? Bool == false)
        #expect(result["warnings"] as? [String] == ["inner_html"] && result["sha256"] as? String == "9c0d")
    }

    @Test func parentInputHasNoPayload() throws {
        #expect(try Wire.decode(ExtensionReply.self, #"{"type":"parentInput"}"#) == .parentInput)
        #expect(try Wire.object(ExtensionReply.parentInput) as NSDictionary == ["type": "parentInput"] as NSDictionary)
    }

    @Test func peerReportsCarryDeliveryAndTasksKeepTheLegacyWireShape() throws {
        let report = ExtensionMessage.sendToAgent(id: 3, agentID: AgentID(rawValue: "a1"), targetAgentID: AgentID(rawValue: "a2"), text: "done", delivery: .report)
        #expect(try Wire.decode(ExtensionMessage.self, #"{"type":"sendToAgent","id":3,"agentID":"a1","targetAgentID":"a2","text":"done","delivery":"report"}"#) == report)
        #expect(try Wire.object(report)["delivery"] as? String == "report")
        #expect(try Wire.object(ExtensionReply.message(id: 0, text: "done", delivery: .report))["delivery"] as? String == "report")
        #expect(try Wire.object(ExtensionReply.message(id: 0, text: "done"))["delivery"] == nil)
        #expect(try Wire.decode(ExtensionReply.self, #"{"type":"message","text":"done","delivery":"report"}"#) == .message(id: 0, text: "done", delivery: .report))
        #expect(throws: (any Error).self) {
            try Wire.decode(ExtensionMessage.self, #"{"type":"sendToAgent","id":3,"agentID":"a1","targetAgentID":"a2","text":"done","delivery":"unknown"}"#)
        }
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

    /// What design_get reads: the answer's text, its files, and the image it hands pi inline.
    @Test func designReferenceRepliesCarryTheShapeTheExtensionReads() throws {
        let object = try Wire.object(ExtensionReply.designReference(
            id: 4, answer: DesignReferenceAnswer(text: "A PNG.", files: ["/drops/Hero@2x.png"], image: "/drops/Hero@2x.png")))
        #expect(object["type"] as? String == "designReference" && object["id"] as? Int == 4)
        let answer = try #require(object["answer"] as? [String: Any])
        #expect(answer["text"] as? String == "A PNG." && answer["files"] as? [String] == ["/drops/Hero@2x.png"])
        #expect(answer["image"] as? String == "/drops/Hero@2x.png")
        let bare = try #require(try Wire.object(ExtensionReply.designReference(id: 5, answer: DesignReferenceAnswer(text: "x")))["answer"]
            as? [String: Any])
        #expect(bare["image"] == nil && bare["files"] as? [String] == [])
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

    /// The children extension's exact `JSON.stringify` shape: a minimal child row with every
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
