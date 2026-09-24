import Foundation
import Testing
@testable import ShepherdProtocol

/// `pi --mode rpc` stdin/stdout. JSON literals follow pi's docs/rpc.md; decoding is lenient
/// because pi's format is not a contract Shepherd controls.
@Suite("pi RPC wire")
struct RPCWireTests {
    private static func incoming(_ json: String) throws -> RPCIncoming {
        try NDJSON.decode(RPCIncoming.self, from: Data(json.utf8))
    }

    private static func event(_ json: String) throws -> RPCEvent {
        guard case .event(let event) = try incoming(json) else { throw CocoaError(.coderReadCorrupt) }
        return event
    }

    private static func response(_ json: String) throws -> RPCResponse {
        guard case .response(let response) = try incoming(json) else { throw CocoaError(.coderReadCorrupt) }
        return response
    }

    // MARK: Commands

    /// (command, frame id, expected JSON)
    static let commands: [(RPCCommand, String?, String)] = [
        (.prompt(message: "Hello, world!"), "req-1", #"{"id":"req-1","type":"prompt","message":"Hello, world!"}"#),
        (.prompt(message: "What's this?", images: [RPCImage(data: "AAAA", mimeType: "image/png")]), nil,
         #"{"type":"prompt","message":"What's this?","images":[{"type":"image","data":"AAAA","mimeType":"image/png"}]}"#),
        (.prompt(message: "New instruction", streamingBehavior: .steer), nil,
         #"{"type":"prompt","message":"New instruction","streamingBehavior":"steer"}"#),
        (.prompt(message: "Later", streamingBehavior: .followUp), nil,
         #"{"type":"prompt","message":"Later","streamingBehavior":"followUp"}"#),
        (.abort, nil, #"{"type":"abort"}"#),
        (.getState, nil, #"{"type":"get_state"}"#),
        (.getMessages, nil, #"{"type":"get_messages"}"#),
        (.getSessionStats, nil, #"{"type":"get_session_stats"}"#),
        (.getCommands, nil, #"{"type":"get_commands"}"#),
        (.setModel(provider: "anthropic", modelId: "claude-sonnet-4"), nil,
         #"{"type":"set_model","provider":"anthropic","modelId":"claude-sonnet-4"}"#),
        (.setThinkingLevel(level: "high"), nil, #"{"type":"set_thinking_level","level":"high"}"#),
        (.newSession, "n", #"{"id":"n","type":"new_session"}"#),
        (.extensionUIResponse(id: "uuid-1", value: "Allow"), nil, #"{"type":"extension_ui_response","id":"uuid-1","value":"Allow"}"#),
        (.extensionUIResponse(id: "uuid-2", confirmed: true), nil, #"{"type":"extension_ui_response","id":"uuid-2","confirmed":true}"#),
        (.extensionUIResponse(id: "uuid-3", cancelled: true), nil, #"{"type":"extension_ui_response","id":"uuid-3","cancelled":true}"#),
    ]

    @Test(arguments: commands)
    func commandsEncodeAsDocumented(command: RPCCommand, id: String?, expected: String) throws {
        let line = try NDJSON.encode(RPCCommandFrame(id: id, command: command))
        let actual = try JSONSerialization.jsonObject(with: line) as? NSDictionary
        let wanted = try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary
        #expect(actual == wanted)
    }

    @Test func commandTypeMatchesTheWireType() throws {
        for (command, _, _) in Self.commands {
            let object = try JSONSerialization.jsonObject(with: NDJSON.encode(RPCCommandFrame(id: nil, command: command))) as? [String: Any]
            #expect(object?["type"] as? String == command.type)
        }
    }

    // MARK: Responses

    @Test func aBareSuccessResponseDecodes() throws {
        let ok = try Self.response(#"{"id":"req-1","type":"response","command":"prompt","success":true}"#)
        #expect(ok == RPCResponse(id: "req-1", command: "prompt", success: true))
    }

    @Test func aFailedResponseCarriesTheError() throws {
        let failed = try Self.response(#"{"type":"response","command":"set_model","success":false,"error":"Model not found"}"#)
        #expect(!failed.success && failed.error == "Model not found" && failed.id == nil)
    }

    @Test func aResponseMissingFieldsDefaultsToAnUnnamedFailure() throws {
        let bare = try Self.response(#"{"type":"response"}"#)
        #expect(bare.command == "" && !bare.success)
    }

    @Test func responseDataIsNavigableAsJSON() throws {
        let state = try Self.response("""
        {"type":"response","command":"get_state","success":true,"data":{"model":{"id":"m","provider":"p","contextWindow":200000},"thinkingLevel":"medium","isStreaming":false,"messageCount":5,"sessionId":"abc123"}}
        """)
        #expect(state.data?["thinkingLevel"]?.stringValue == "medium")
        #expect(state.data?["isStreaming"]?.boolValue == false)
        #expect(state.data?["messageCount"]?.doubleValue == 5)
        #expect(state.data?["model"]?["contextWindow"]?.doubleValue == 200000)
        #expect(state.data?["missing"] == nil)
    }

    @Test func commandListsDecodeFromResponseData() throws {
        let commands = try Self.response("""
        {"type":"response","command":"get_commands","success":true,"data":{"commands":[{"name":"session-name","source":"extension","path":"/x"},{"name":"skill:brave","source":"skill"}]}}
        """)
        #expect(commands.data?["commands"]?.arrayValue?.map { $0["name"]?.stringValue } == ["session-name", "skill:brave"])
    }

    // MARK: Messages

    @Test func messagesDecodeLeniently() throws {
        let data = try Self.response("""
        {"type":"response","command":"get_messages","success":true,"data":{"messages":[
          {"role":"user","content":"Hello!","timestamp":1733234567890,"attachments":[]},
          {"role":"assistant","content":[{"type":"text","text":"Hi"},{"type":"thinking","thinking":"greeting"},{"type":"toolCall","id":"call_1","name":"bash","arguments":{"command":"ls"}}],"stopReason":"stop","usage":{"input":1}},
          {"role":"toolResult","toolCallId":"call_1","toolName":"bash","content":[{"type":"text","text":"out"}],"isError":false},
          {"role":"bashExecution","command":"ls -la","output":"total 48","exitCode":0},
          {"role":"user","content":[{"type":"text","text":"look"},{"type":"image","data":"AAAA","mimeType":"image/png"},{"type":"sticker","id":"x"}]},
          {"role":"assistant","content":[],"stopReason":"error","errorMessage":"529 overloaded"},
          {"role":"custom","customType":"note","display":false,"content":"model only"}
        ]}}
        """).data
        let messages = try #require(data?["messages"]).decode([RPCMessage].self)
        #expect(messages.map(\.role) == ["user", "assistant", "toolResult", "bashExecution", "user", "assistant", "custom"])
        #expect(messages[0].content == [.text("Hello!")], "string content is one text block")
        #expect(messages[0].timestamp == 1733234567890)
        #expect(messages[1].content == [
            .text("Hi"), .thinking("greeting"),
            .toolCall(id: "call_1", name: "bash", arguments: .object(["command": .string("ls")])),
        ])
        #expect(messages[2].toolCallId == "call_1" && messages[2].toolName == "bash" && messages[2].isError == false)
        #expect(messages[3].content.isEmpty, "roles without content decode empty")
        #expect(messages[4].content == [.text("look"), .image(mimeType: "image/png", data: "AAAA"), .unknown(type: "sticker")])
        #expect(messages[5].errorMessage == "529 overloaded" && messages[1].errorMessage == nil)
        #expect(messages[6].customType == "note" && messages[6].display == false)
    }

    @Test(arguments: [
        RPCContentBlock.text("t"), .thinking("th"), .toolCall(id: "i", name: "n", arguments: .object(["a": .array([.null, .bool(true)])])),
        .toolCall(id: "i", name: "n", arguments: nil), .image(mimeType: "image/png", data: "AA"), .unknown(type: "sticker"),
    ])
    func contentBlocksRoundTrip(_ block: RPCContentBlock) throws {
        #expect(try Wire.roundTrip(block) == block)
    }

    @Test func aBlockWithoutFieldsDecodesToEmptyValues() throws {
        #expect(try Wire.decode(RPCContentBlock.self, #"{"type":"text"}"#) == .text(""))
        #expect(try Wire.decode(RPCContentBlock.self, #"{}"#) == .unknown(type: ""))
    }

    // MARK: Events

    static let simpleEvents: [(String, RPCEvent)] = [
        (#"{"type":"agent_start"}"#, .agentStart),
        (#"{"type":"agent_settled"}"#, .agentSettled),
        (#"{"type":"turn_start"}"#, .turnStart),
        (#"{"type":"agent_end"}"#, .agentEnd(messages: [], willRetry: false)),
        (#"{"type":"agent_end","messages":[{"role":"assistant","content":"done"}],"willRetry":true}"#,
         .agentEnd(messages: [RPCMessage(role: "assistant", content: [.text("done")])], willRetry: true)),
        (#"{"type":"turn_end"}"#, .turnEnd(message: nil, toolResults: [])),
        (#"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
         .messageStart(message: RPCMessage(role: "assistant", content: []))),
        (#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Hello"}],"stopReason":"stop"}}"#,
         .messageEnd(message: RPCMessage(role: "assistant", content: [.text("Hello")], stopReason: "stop"))),
        (#"{"type":"queue_update","steering":["Focus"],"followUp":["Then summarize"]}"#,
         .queueUpdate(steering: ["Focus"], followUp: ["Then summarize"])),
        (#"{"type":"queue_update"}"#, .queueUpdate(steering: [], followUp: [])),
        (#"{"type":"tool_execution_start","toolCallId":"c1","toolName":"bash","args":{"command":"ls -la"}}"#,
         .toolExecutionStart(toolCallId: "c1", toolName: "bash", args: .object(["command": .string("ls -la")]))),
        (#"{"type":"tool_execution_end","toolCallId":"c1","toolName":"bash"}"#,
         .toolExecutionEnd(toolCallId: "c1", toolName: "bash", result: nil, isError: false)),
        (#"{"type":"extension_error","extensionPath":"/x.ts","event":"tool_call","error":"boom"}"#,
         .extensionError(extensionPath: "/x.ts", event: "tool_call", error: "boom")),
        (#"{"type":"compaction_start","reason":"threshold"}"#, .unknown(type: "compaction_start")),
        (#"{"reason":"threshold"}"#, .unknown(type: "")),
    ]

    @Test(arguments: simpleEvents)
    func eventsDecode(json: String, expected: RPCEvent) throws {
        #expect(try Self.event(json) == expected)
    }

    @Test func toolResultsCarryContentAndDetails() throws {
        guard case .toolExecutionUpdate(_, _, _, let partial) = try Self.event(
            #"{"type":"tool_execution_update","toolCallId":"c","toolName":"bash","partialResult":{"content":[{"type":"text","text":"so far"}],"details":{"truncation":null}}}"#
        ) else { Issue.record("expected update"); return }
        #expect(partial?.content == [.text("so far")])
        #expect(partial?.details?["truncation"] == .null)

        guard case .toolExecutionEnd(_, _, let result, let isError) = try Self.event(
            #"{"type":"tool_execution_end","toolCallId":"c","toolName":"bash","result":{"details":{}},"isError":true}"#
        ) else { Issue.record("expected end"); return }
        #expect(result?.content == [] && isError)
    }

    @Test func assistantDeltasDecode() throws {
        guard case .messageUpdate(let text, let usage) = try Self.event(
            #"{"type":"message_update","usage":{"totalTokens":101},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hello "}}"#
        ) else { Issue.record("text_delta"); return }
        #expect(text.type == "text_delta" && text.contentIndex == 0 && text.delta == "Hello ")
        #expect(usage?["totalTokens"]?.doubleValue == 101)

        guard case .messageUpdate(let start, nil) = try Self.event(
            #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","contentIndex":1,"id":"call_1","toolName":"write"}}"#
        ) else { Issue.record("toolcall_start"); return }
        #expect(start.id == "call_1" && start.toolName == "write")

        guard case .messageUpdate(let end, _) = try Self.event(
            #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","toolCall":{"type":"toolCall","id":"call_1","name":"write","arguments":{"path":"a.txt"}}}}"#
        ) else { Issue.record("toolcall_end"); return }
        #expect(end.toolCall == .toolCall(id: "call_1", name: "write", arguments: .object(["path": .string("a.txt")])))

        guard case .messageUpdate(let textEnd, _) = try Self.event(
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_end","content":"Hello world"}}"#
        ) else { Issue.record("text_end"); return }
        #expect(textEnd.content == "Hello world")
    }

    @Test func aLineSeparatorInsideAStringIsData() throws {
        guard case .messageUpdate(let delta, _) = try Self.event(
            "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"thinking_delta\",\"delta\":\"a\u{2028}b\"}}"
        ) else { Issue.record("thinking_delta"); return }
        #expect(delta.delta == "a\u{2028}b")
    }

    @Test func messageEventsWithoutAMessageFailToDecode() {
        #expect(throws: DecodingError.self) { try Self.event(#"{"type":"message_start"}"#) }
    }

    // MARK: Extension UI

    @Test func dialogRequestsDecode() throws {
        guard case .extensionUIRequest(let select) = try Self.event(
            #"{"type":"extension_ui_request","id":"u1","method":"select","title":"Allow?","options":["Allow","Block"],"timeout":10000}"#
        ) else { Issue.record("select"); return }
        #expect(select.id == "u1" && select.method == "select" && select.title == "Allow?")
        #expect(select.options == ["Allow", "Block"] && select.timeout == 10000)

        guard case .extensionUIRequest(let editor) = try Self.event(
            #"{"type":"extension_ui_request","id":"u4","method":"editor","title":"Edit","prefill":"L1\nL2","placeholder":"type"}"#
        ) else { Issue.record("editor"); return }
        #expect(editor.prefill == "L1\nL2" && editor.placeholder == "type" && editor.timeout == nil)
    }

    @Test func fireAndForgetUIRequestsDecode() throws {
        guard case .extensionUIRequest(let notify) = try Self.event(
            #"{"type":"extension_ui_request","id":"u5","method":"notify","message":"Blocked","notifyType":"warning"}"#
        ) else { Issue.record("notify"); return }
        #expect(notify.notifyType == "warning" && notify.message == "Blocked")

        guard case .extensionUIRequest(let status) = try Self.event(
            #"{"type":"extension_ui_request","id":"u6","method":"setStatus","statusKey":"ext","statusText":"Turn 3"}"#
        ) else { Issue.record("setStatus"); return }
        #expect(status.statusKey == "ext" && status.statusText == "Turn 3")

        guard case .extensionUIRequest(let widget) = try Self.event(
            #"{"type":"extension_ui_request","id":"u7","method":"setWidget","widgetKey":"ext","widgetLines":["a","b"],"widgetPlacement":"aboveEditor"}"#
        ) else { Issue.record("setWidget"); return }
        #expect(widget.widgetKey == "ext" && widget.widgetLines == ["a", "b"] && widget.widgetPlacement == "aboveEditor")

        guard case .extensionUIRequest(let text) = try Self.event(
            #"{"type":"extension_ui_request","id":"u9","method":"set_editor_text","text":"prefilled"}"#
        ) else { Issue.record("set_editor_text"); return }
        #expect(text.text == "prefilled")
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test(arguments: [
        ("null", JSONValue.null), ("true", .bool(true)), ("3.5", .number(3.5)), (#""s""#, .string("s")),
        ("[1,\"a\"]", .array([.number(1), .string("a")])), (#"{"k":{"n":false}}"#, .object(["k": .object(["n": .bool(false)])])),
    ])
    func everyJSONKindDecodesAndRoundTrips(json: String, expected: JSONValue) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value == expected)
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func booleansAreNotReadAsNumbers() throws {
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data("false".utf8)) == .bool(false))
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data("0".utf8)) == .number(0))
    }

    @Test func accessorsReturnNilForTheWrongKind() {
        let value = JSONValue.string("s")
        #expect(value.stringValue == "s")
        #expect(value.doubleValue == nil && value.boolValue == nil && value.arrayValue == nil && value["k"] == nil)
    }

    @Test func aValueRedecodesAsAConcreteType() throws {
        struct Usage: Decodable, Equatable { var input: Int; var output: Int }
        let value = JSONValue.object(["input": .number(3), "output": .number(4), "extra": .null])
        #expect(try value.decode(Usage.self) == Usage(input: 3, output: 4))
    }
}
