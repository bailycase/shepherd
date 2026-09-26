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
        (.setThinkingLevel(level: "xhigh"), nil, #"{"type":"set_thinking_level","level":"xhigh"}"#),
        (.getAvailableThinkingLevels, nil, #"{"type":"get_available_thinking_levels"}"#),
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

    /// pi 0.87.1's own replies (a scratch models.json: a model mapping xhigh and max with minimal
    /// null, one reasoning model without a map, and one without reasoning), then a pi without the
    /// command.
    @Test(arguments: [
        (#"{"id":"1","type":"response","command":"get_available_thinking_levels","success":true,"data":{"levels":["off","low","medium","high","xhigh","max"]}}"#,
         ["off", "low", "medium", "high", "xhigh", "max"]),
        (#"{"id":"1","type":"response","command":"get_available_thinking_levels","success":true,"data":{"levels":["off","minimal","low","medium","high"]}}"#,
         ["off", "minimal", "low", "medium", "high"]),
        (#"{"id":"1","type":"response","command":"get_available_thinking_levels","success":true,"data":{"levels":["off"]}}"#, ["off"]),
        (#"{"id":"1","type":"response","command":"get_available_thinking_levels","success":false,"error":"Unknown command: get_available_thinking_levels"}"#, nil),
    ] as [(String, [String]?)])
    func availableThinkingLevelsDecodeFromPisReply(json: String, levels: [String]?) throws {
        #expect(try Self.response(json).thinkingLevels == levels)
    }

    // MARK: Messages

    @Test func messagesDecodeLeniently() throws {
        let response = try Self.response("""
        {"type":"response","command":"get_messages","success":true,"data":{"messages":[
          {"role":"user","content":"Hello!","timestamp":1733234567890,"attachments":[]},
          {"role":"assistant","content":[{"type":"text","text":"Hi"},{"type":"thinking","thinking":"greeting"},{"type":"toolCall","id":"call_1","name":"bash","arguments":{"command":"ls"}}],"stopReason":"stop","usage":{"input":1}},
          {"role":"toolResult","toolCallId":"call_1","toolName":"bash","content":[{"type":"text","text":"out"}],"isError":false},
          {"role":"bashExecution","command":"ls -la","output":"total 48","exitCode":0},
          {"role":"user","content":[{"type":"text","text":"look"},{"type":"image","data":"AAAA","mimeType":"image/png"},{"type":"sticker","id":"x"}]},
          {"role":"assistant","content":[],"stopReason":"error","errorMessage":"529 overloaded"},
          {"role":"custom","customType":"note","display":false,"content":"model only"}
        ]}}
        """)
        let messages = try #require(response.messages)
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

    /// get_messages records, by what they hold after `"success":true` (nil: no `data` at all).
    static let historyRecords: [(String, String?)] = [
        ("normal", #"{"messages":[{"role":"user","content":"Hello!","timestamp":1733234567890},{"role":"assistant","content":[{"type":"text","text":"Hi"},{"type":"thinking","thinking":"hm"}],"stopReason":"stop","timestamp":1733234567891.5}]}"#),
        ("unknown fields", #"{"count":2,"messages":[{"role":"user","content":"a","attachments":[],"mood":{"x":1}},{"role":"bashExecution","command":"ls","exitCode":0,"output":"x"}],"next":null}"#),
        ("no data", nil),
        ("null data", "null"),
        ("messages not an array", #"{"messages":{"role":"user","content":"a"}}"#),
        ("a malformed element", #"{"messages":[{"role":"user","content":"a"},42]}"#),
        ("images", #"{"messages":[{"role":"user","content":[{"type":"text","text":"look"},{"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"},{"type":"sticker"}]}]}"#),
        ("tool call arguments", #"{"messages":[{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"edit","arguments":{"path":"a/b.swift","n":3,"f":0.25,"big":12345678901234,"on":true,"off":false,"none":null,"list":[1,"two",[false]],"text":"café   \"q\""}}],"stopReason":"toolUse"},{"role":"toolResult","toolCallId":"c1","toolName":"edit","content":[{"type":"text","text":"ok"}],"isError":false}]}"#),
    ]

    private static func historyLine(_ data: String?) -> Data {
        Data((#"{"type":"response","id":"r1","command":"get_messages","success":true"# + (data.map { #","data":\#($0)"# } ?? "") + "}").utf8)
    }

    /// The typed payload decodes exactly the messages the lenient JSONValue path did, and a
    /// record it does not fit falls back to that path.
    @Test(arguments: historyRecords)
    func historyDecodesTypedExactlyAsTheLenientPathDid(name: String, data: String?) throws {
        let line = Self.historyLine(data)
        guard case .response(let response) = try NDJSON.decode(RPCIncoming.self, from: line) else {
            Issue.record("\(name): not a response"); return
        }
        struct Lenient: Decodable { let data: JSONValue? }
        let lenient = try JSONDecoder().decode(Lenient.self, from: line).data
        let expected = try? lenient?["messages"]?.decode([RPCMessage].self)
        #expect(response.messages == expected, "\(name)")
        #expect(response.id == "r1" && response.success)
    }

    @Test func aHistoryResponseCarriesTheTypedPayloadNotJSON() throws {
        let response = try Self.response(String(decoding: Self.historyLine(Self.historyRecords[0].1), as: UTF8.self))
        guard case .messages(let messages) = response.payload else {
            Issue.record("expected the typed payload, got \(String(describing: response.payload))"); return
        }
        #expect(messages.map(\.role) == ["user", "assistant"])
        #expect(response.data == nil)
    }

    /// Only get_messages is typed, and only when its data fits.
    @Test func otherResponsesAndMisfitHistoriesKeepTheirJSON() throws {
        let state = try Self.response(#"{"type":"response","command":"get_state","success":true,"data":{"messages":[]}}"#)
        #expect(state.payload == .json(.object(["messages": .array([])])))
        let misfit = try Self.response(String(decoding: Self.historyLine(#"{"messages":[{"role":"user"},42]}"#), as: UTF8.self))
        #expect(misfit.payload == .json(.object(["messages": .array([.object(["role": .string("user")]), .number(42)])])))
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
        (#"{"type":"compaction_start","reason":"threshold"}"#, .compactionStart(reason: "threshold")),
        (#"{"type":"compaction_end","reason":"manual","aborted":true,"willRetry":false}"#,
         .compactionEnd(reason: "manual", result: nil, aborted: true, willRetry: false, errorMessage: nil)),
        (#"{"type":"compaction_end","reason":"manual","aborted":false,"errorMessage":"Compaction failed: Nothing to compact"}"#,
         .compactionEnd(reason: "manual", result: nil, aborted: false, willRetry: false, errorMessage: "Compaction failed: Nothing to compact")),
        (#"{"type":"compaction_end","reason":"overflow","result":{"summary":"S","tokensBefore":203000,"estimatedTokensAfter":21000,"firstKeptEntryId":"k"},"aborted":false,"willRetry":true}"#,
         .compactionEnd(reason: "overflow", result: RPCCompactionResult(summary: "S", tokensBefore: 203_000, estimatedTokensAfter: 21_000, firstKeptEntryId: "k"),
                        aborted: false, willRetry: true, errorMessage: nil)),
        (#"{"type":"auto_retry_start","attempt":2,"maxAttempts":3,"delayMs":4000,"errorMessage":"529 overloaded"}"#,
         .autoRetryStart(attempt: 2, maxAttempts: 3, delayMs: 4000, errorMessage: "529 overloaded")),
        (#"{"type":"auto_retry_start"}"#, .autoRetryStart(attempt: 1, maxAttempts: 0, delayMs: 0, errorMessage: nil)),
        (#"{"type":"auto_retry_end","success":false,"attempt":3,"finalError":"529 overloaded"}"#, .autoRetryEnd(success: false)),
        (#"{"type":"auto_retry_end","success":true,"attempt":1}"#, .autoRetryEnd(success: true)),
        (#"{"type":"entry_appended","entry":{}}"#, .unknown(type: "entry_appended")),
        (#"{"reason":"threshold"}"#, .unknown(type: "")),
    ]

    /// Compact now: pi's `compact`, with what to keep only when there is some.
    @Test func compactCarriesItsInstructionsOnlyWhenGiven() throws {
        let with = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RPCCommandFrame(id: "1", command: .compact(customInstructions: "keep the files")))) as? [String: Any]
        #expect(with?["type"] as? String == "compact" && with?["customInstructions"] as? String == "keep the files" && with?["id"] as? String == "1")
        let without = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RPCCommandFrame(id: nil, command: .compact()))) as? [String: Any]
        #expect(without?.keys.sorted() == ["type"])
    }

    /// A compaction summary carries its summary and size; pi's structured system prompt its
    /// sections (a null removes one) and tools. Other roles decode as before.
    @Test func summariesAndSystemPromptsDecodeTheirOwnFields() throws {
        let summary = try JSONDecoder().decode(RPCMessage.self, from: Data(#"{"role":"compactionSummary","summary":"S","tokensBefore":184000,"timestamp":5}"#.utf8))
        #expect(summary.summary == "S" && summary.tokensBefore == 184_000 && summary.content.isEmpty)
        let system = try JSONDecoder().decode(RPCMessage.self, from: Data(#"{"role":"system","content":"","sections":{"preamble":"You are","docs":null},"toolsAdded":[{"name":"read"}],"toolsRemoved":[{"name":"ls"}]}"#.utf8))
        #expect(system.sections?["preamble"] == .some("You are") && system.sections?["docs"] == .some(nil))
        #expect(system.toolsAdded?.first?["name"]?.stringValue == "read" && system.toolsRemoved?.count == 1)
        let user = try JSONDecoder().decode(RPCMessage.self, from: Data(#"{"role":"user","content":"hi","summary":"not mine","sections":{"a":"b"}}"#.utf8))
        #expect(user.summary == nil && user.sections == nil)
    }

    /// A failed reply carries the provider and model it went to; other messages don't read them.
    @Test func aFailedReplyDecodesItsProviderAndModel() throws {
        let failed = try JSONDecoder().decode(RPCMessage.self, from: Data(#"{"role":"assistant","content":[],"stopReason":"error","errorMessage":"401","provider":"openai","model":"gpt-5"}"#.utf8))
        #expect(failed.provider == "openai" && failed.model == "gpt-5")
        let reply = try JSONDecoder().decode(RPCMessage.self, from: Data(#"{"role":"assistant","content":[],"stopReason":"stop","provider":"openai","model":"gpt-5"}"#.utf8))
        #expect(reply.provider == nil && reply.model == nil)
    }

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

    /// pi's `usage` rides every delta and is not read, whatever shape it has.
    @Test func assistantDeltasDecode() throws {
        guard case .messageUpdate(let text) = try Self.event(
            #"{"type":"message_update","usage":{"totalTokens":101,"cost":{"total":[1,true]}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hello "}}"#
        ) else { Issue.record("text_delta"); return }
        #expect(text.type == "text_delta" && text.contentIndex == 0 && text.delta == "Hello ")

        guard case .messageUpdate(let start) = try Self.event(
            #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","contentIndex":1,"id":"call_1","toolName":"write"}}"#
        ) else { Issue.record("toolcall_start"); return }
        #expect(start.id == "call_1" && start.toolName == "write")

        guard case .messageUpdate(let end) = try Self.event(
            #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","toolCall":{"type":"toolCall","id":"call_1","name":"write","arguments":{"path":"a.txt"}}}}"#
        ) else { Issue.record("toolcall_end"); return }
        #expect(end.toolCall == .toolCall(id: "call_1", name: "write", arguments: .object(["path": .string("a.txt")])))

        guard case .messageUpdate(let textEnd) = try Self.event(
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_end","content":"Hello world"}}"#
        ) else { Issue.record("text_end"); return }
        #expect(textEnd.content == "Hello world")
    }

    @Test func aLineSeparatorInsideAStringIsData() throws {
        guard case .messageUpdate(let delta) = try Self.event(
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

    /// Strings and objects are tried first; booleans must still never read as numbers, nor
    /// numbers as booleans or strings.
    @Test(arguments: [
        ("false", JSONValue.bool(false)), ("true", .bool(true)), ("0", .number(0)), ("1", .number(1)),
        ("1.0", .number(1)), ("-2.5e3", .number(-2500)), (#""1""#, .string("1")), (#""true""#, .string("true")),
        ("[true,1,\"x\",null,{}]", .array([.bool(true), .number(1), .string("x"), .null, .object([:])])),
        (#"{"b":false,"n":0,"s":"","a":[]}"#, .object(["b": .bool(false), "n": .number(0), "s": .string(""), "a": .array([])])),
    ])
    func eachKindDecodesAsItself(json: String, expected: JSONValue) throws {
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) == expected)
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
