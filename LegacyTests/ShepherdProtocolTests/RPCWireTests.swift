import Foundation
import Testing
@testable import ShepherdProtocol

/// JSON literals below are copied from pi's docs/rpc.md.
@Suite("RPC wire")
struct RPCWireTests {
    private func decode(_ json: String) throws -> RPCIncoming {
        try NDJSON.decode(RPCIncoming.self, from: Data(json.utf8))
    }

    private func encode(_ command: RPCCommand, id: String? = nil) throws -> NSDictionary {
        let data = try NDJSON.encode(RPCCommandFrame(id: id, command: command))
        return try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test func commandsEncodeAsDocumented() throws {
        #expect(try encode(.prompt(message: "Hello, world!"), id: "req-1")
            == ["id": "req-1", "type": "prompt", "message": "Hello, world!"])
        #expect(try encode(.prompt(message: "What's in this image?", images: [RPCImage(data: "base64-encoded-data", mimeType: "image/png")]))
            == ["type": "prompt", "message": "What's in this image?",
                "images": [["type": "image", "data": "base64-encoded-data", "mimeType": "image/png"]]])
        #expect(try encode(.prompt(message: "New instruction", streamingBehavior: .steer))
            == ["type": "prompt", "message": "New instruction", "streamingBehavior": "steer"])
        #expect(try encode(.abort) == ["type": "abort"])
        #expect(try encode(.getState) == ["type": "get_state"])
        #expect(try encode(.getMessages) == ["type": "get_messages"])
        #expect(try encode(.getSessionStats) == ["type": "get_session_stats"])
        #expect(try encode(.getCommands) == ["type": "get_commands"])
        #expect(try encode(.setModel(provider: "anthropic", modelId: "claude-sonnet-4-20250514"))
            == ["type": "set_model", "provider": "anthropic", "modelId": "claude-sonnet-4-20250514"])
        #expect(try encode(.setThinkingLevel(level: "high")) == ["type": "set_thinking_level", "level": "high"])
        #expect(try encode(.newSession) == ["type": "new_session"])
        #expect(try encode(.extensionUIResponse(id: "uuid-1", value: "Allow"))
            == ["type": "extension_ui_response", "id": "uuid-1", "value": "Allow"])
        #expect(try encode(.extensionUIResponse(id: "uuid-2", confirmed: true))
            == ["type": "extension_ui_response", "id": "uuid-2", "confirmed": true])
        #expect(try encode(.extensionUIResponse(id: "uuid-3", cancelled: true))
            == ["type": "extension_ui_response", "id": "uuid-3", "cancelled": true])
    }

    @Test func responsesDecode() throws {
        guard case .response(let ok) = try decode(#"{"id": "req-1", "type": "response", "command": "prompt", "success": true}"#) else {
            Issue.record("expected response"); return
        }
        #expect(ok.id == "req-1")
        #expect(ok.command == "prompt")
        #expect(ok.success)
        #expect(ok.data == nil)

        guard case .response(let state) = try decode("""
            {"type":"response","command":"get_state","success":true,"data":{"model":{"id":"claude-sonnet-4-20250514","provider":"anthropic","contextWindow":200000},"thinkingLevel":"medium","isStreaming":false,"isCompacting":false,"steeringMode":"all","followUpMode":"one-at-a-time","sessionFile":"/path/to/session.jsonl","sessionId":"abc123","sessionName":"my-feature-work","autoCompactionEnabled":true,"messageCount":5,"pendingMessageCount":0}}
            """) else { Issue.record("expected response"); return }
        #expect(state.data?["thinkingLevel"]?.stringValue == "medium")
        #expect(state.data?["isStreaming"]?.boolValue == false)
        #expect(state.data?["messageCount"]?.doubleValue == 5)
        #expect(state.data?["model"]?["contextWindow"]?.doubleValue == 200000)

        guard case .response(let failed) = try decode(#"{"type":"response","command":"set_model","success":false,"error":"Model not found: invalid/model"}"#) else {
            Issue.record("expected response"); return
        }
        #expect(!failed.success)
        #expect(failed.error == "Model not found: invalid/model")

        guard case .response(let stats) = try decode("""
            {"type":"response","command":"get_session_stats","success":true,"data":{"sessionFile":"/path/to/session.jsonl","sessionId":"abc123","userMessages":5,"assistantMessages":5,"toolCalls":12,"toolResults":12,"totalMessages":22,"tokens":{"input":50000,"output":10000,"cacheRead":40000,"cacheWrite":5000,"total":105000},"cost":0.45,"contextUsage":{"tokens":60000,"contextWindow":200000,"percent":30}}}
            """) else { Issue.record("expected response"); return }
        #expect(stats.data?["cost"]?.doubleValue == 0.45)
        #expect(stats.data?["contextUsage"]?["percent"]?.doubleValue == 30)
        #expect(stats.data?["contextUsage"]?["tokens"]?.doubleValue == 60000)

        guard case .response(let commands) = try decode("""
            {"type":"response","command":"get_commands","success":true,"data":{"commands":[{"name":"session-name","description":"Set or clear session name","source":"extension","path":"/home/user/.pi/agent/extensions/session.ts"},{"name":"skill:brave-search","description":"Web search via Brave API","source":"skill","location":"user","path":"/home/user/.pi/agent/skills/brave-search/SKILL.md"}]}}
            """) else { Issue.record("expected response"); return }
        #expect(commands.data?["commands"]?.arrayValue?.map { $0["name"]?.stringValue } == ["session-name", "skill:brave-search"])
    }

    @Test func messagesDecodeLeniently() throws {
        guard case .response(let r) = try decode("""
            {"type":"response","command":"get_messages","success":true,"data":{"messages":[
              {"role":"user","content":"Hello!","timestamp":1733234567890,"attachments":[]},
              {"role":"assistant","content":[{"type":"text","text":"Hello! How can I help?"},{"type":"thinking","thinking":"User is greeting me..."},{"type":"toolCall","id":"call_123","name":"bash","arguments":{"command":"ls"}}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-20250514","usage":{"input":100,"output":50},"stopReason":"stop","timestamp":1733234567890},
              {"role":"toolResult","toolCallId":"call_123","toolName":"bash","content":[{"type":"text","text":"total 48\\ndrwxr-xr-x ..."}],"isError":false,"timestamp":1733234567890},
              {"role":"bashExecution","command":"ls -la","output":"total 48","exitCode":0,"cancelled":false,"truncated":false,"fullOutputPath":null,"timestamp":1733234567890},
              {"role":"user","content":[{"type":"text","text":"look"},{"type":"image","data":"AAAA","mimeType":"image/png"},{"type":"sticker","id":"x"}]},
              {"role":"assistant","content":[],"stopReason":"error","errorMessage":"529 overloaded"}
            ]}}
            """) else { Issue.record("expected response"); return }
        let messages = try #require(r.data?["messages"]).decode([RPCMessage].self)
        #expect(messages.count == 6)
        #expect(messages[5].stopReason == "error")
        #expect(messages[5].errorMessage == "529 overloaded")
        #expect(messages[1].errorMessage == nil)
        #expect(messages[0].role == "user")
        #expect(messages[0].content == [.text("Hello!")])
        #expect(messages[0].timestamp == 1733234567890)
        #expect(messages[1].content == [
            .text("Hello! How can I help?"),
            .thinking("User is greeting me..."),
            .toolCall(id: "call_123", name: "bash", arguments: .object(["command": .string("ls")])),
        ])
        #expect(messages[1].stopReason == "stop")
        #expect(messages[2].role == "toolResult")
        #expect(messages[2].toolCallId == "call_123")
        #expect(messages[2].toolName == "bash")
        #expect(messages[2].isError == false)
        #expect(messages[3].role == "bashExecution")
        #expect(messages[3].content == [])
        #expect(messages[4].content == [.text("look"), .image(mimeType: "image/png", data: "AAAA"), .unknown(type: "sticker")])

        // Content blocks round-trip through the encoder for callers that persist them.
        let reencoded = try JSONDecoder().decode([RPCContentBlock].self, from: JSONEncoder().encode(messages[1].content))
        #expect(reencoded == messages[1].content)
    }

    @Test func lifecycleEventsDecode() throws {
        guard case .event(.agentStart) = try decode(#"{"type": "agent_start"}"#) else { Issue.record("agent_start"); return }
        guard case .event(.agentSettled) = try decode(#"{"type": "agent_settled"}"#) else { Issue.record("agent_settled"); return }
        guard case .event(.turnStart) = try decode(#"{"type": "turn_start"}"#) else { Issue.record("turn_start"); return }

        guard case .event(.agentEnd(let messages, let willRetry)) = try decode(#"{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"done"}]}],"willRetry":false}"#) else {
            Issue.record("agent_end"); return
        }
        #expect(messages.count == 1)
        #expect(!willRetry)

        guard case .event(.turnEnd(let message, let toolResults)) = try decode(#"{"type":"turn_end","message":{"role":"assistant","content":[]},"toolResults":[{"role":"toolResult","toolCallId":"c","toolName":"bash","content":[]}]}"#) else {
            Issue.record("turn_end"); return
        }
        #expect(message?.role == "assistant")
        #expect(toolResults.map(\.role) == ["toolResult"])

        guard case .event(.messageStart(let start)) = try decode(#"{"type": "message_start", "message": {"role":"assistant","content":[]}}"#) else {
            Issue.record("message_start"); return
        }
        #expect(start.role == "assistant")
        guard case .event(.messageEnd(let end)) = try decode(#"{"type": "message_end", "message": {"role":"assistant","content":[{"type":"text","text":"Hello world"}],"stopReason":"stop"}}"#) else {
            Issue.record("message_end"); return
        }
        #expect(end.content == [.text("Hello world")])
        #expect(end.stopReason == "stop")

        guard case .event(.queueUpdate(let steering, let followUp)) = try decode(#"{"type":"queue_update","steering":["Focus on error handling"],"followUp":["After that, summarize the result"]}"#) else {
            Issue.record("queue_update"); return
        }
        #expect(steering == ["Focus on error handling"])
        #expect(followUp == ["After that, summarize the result"])

        guard case .event(.extensionError(let path, let event, let error)) = try decode(#"{"type":"extension_error","extensionPath":"/path/to/extension.ts","event":"tool_call","error":"Error message..."}"#) else {
            Issue.record("extension_error"); return
        }
        #expect(path == "/path/to/extension.ts")
        #expect(event == "tool_call")
        #expect(error == "Error message...")

        guard case .event(.unknown(let type)) = try decode(#"{"type": "compaction_start", "reason": "threshold"}"#) else {
            Issue.record("unknown"); return
        }
        #expect(type == "compaction_start")
        guard case .event(.unknown("")) = try decode(#"{"reason": "threshold"}"#) else { Issue.record("typeless"); return }
    }

    @Test func messageUpdateDeltasDecode() throws {
        let usage = #"{"input":100,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":101,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}"#
        guard case .event(.messageUpdate(let textDelta, let u)) = try decode(#"{"type":"message_update","usage":\#(usage),"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hello "}}"#) else {
            Issue.record("text_delta"); return
        }
        #expect(textDelta.type == "text_delta")
        #expect(textDelta.contentIndex == 0)
        #expect(textDelta.delta == "Hello ")
        #expect(u?["totalTokens"]?.doubleValue == 101)

        guard case .event(.messageUpdate(let textEnd, _)) = try decode(#"{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"Hello world"}}"#) else {
            Issue.record("text_end"); return
        }
        #expect(textEnd.content == "Hello world")

        guard case .event(.messageUpdate(let toolStart, _)) = try decode(#"{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"toolcall_start","contentIndex":1,"id":"call_abc123","toolName":"write"}}"#) else {
            Issue.record("toolcall_start"); return
        }
        #expect(toolStart.id == "call_abc123")
        #expect(toolStart.toolName == "write")
        #expect(toolStart.contentIndex == 1)

        guard case .event(.messageUpdate(let toolEnd, _)) = try decode(#"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","contentIndex":1,"toolCall":{"type":"toolCall","id":"call_abc123","name":"write","arguments":{"path":"a.txt"}}}}"#) else {
            Issue.record("toolcall_end"); return
        }
        #expect(toolEnd.toolCall == .toolCall(id: "call_abc123", name: "write", arguments: .object(["path": .string("a.txt")])))

        // A U+2028 inside a string is data, not a record boundary.
        guard case .event(.messageUpdate(let sep, _)) = try decode("{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"thinking_delta\",\"contentIndex\":0,\"delta\":\"a\u{2028}b\"}}") else {
            Issue.record("thinking_delta"); return
        }
        #expect(sep.delta == "a\u{2028}b")
    }

    @Test func toolExecutionEventsDecode() throws {
        guard case .event(.toolExecutionStart(let id, let name, let args)) = try decode(#"{"type":"tool_execution_start","toolCallId":"call_abc123","toolName":"bash","args":{"command":"ls -la"}}"#) else {
            Issue.record("start"); return
        }
        #expect(id == "call_abc123")
        #expect(name == "bash")
        #expect(args?["command"]?.stringValue == "ls -la")

        guard case .event(.toolExecutionUpdate(_, _, _, let partial)) = try decode(#"{"type":"tool_execution_update","toolCallId":"call_abc123","toolName":"bash","args":{"command":"ls -la"},"partialResult":{"content":[{"type":"text","text":"partial output so far..."}],"details":{"truncation":null,"fullOutputPath":null}}}"#) else {
            Issue.record("update"); return
        }
        #expect(partial?.content == [.text("partial output so far...")])
        #expect(partial?.details?["truncation"] == .null)

        guard case .event(.toolExecutionEnd(let endID, _, let result, let isError)) = try decode(#"{"type":"tool_execution_end","toolCallId":"call_abc123","toolName":"bash","result":{"content":[{"type":"text","text":"total 48\n..."}],"details":{}},"isError":false}"#) else {
            Issue.record("end"); return
        }
        #expect(endID == "call_abc123")
        #expect(result?.content == [.text("total 48\n...")])
        #expect(!isError)
    }

    @Test func extensionUIRequestsDecode() throws {
        func ui(_ json: String) throws -> RPCExtensionUIRequest {
            guard case .event(.extensionUIRequest(let r)) = try decode(json) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an extension_ui_request"))
            }
            return r
        }
        let select = try ui(#"{"type":"extension_ui_request","id":"uuid-1","method":"select","title":"Allow dangerous command?","options":["Allow","Block"],"timeout":10000}"#)
        #expect(select.id == "uuid-1")
        #expect(select.method == "select")
        #expect(select.title == "Allow dangerous command?")
        #expect(select.options == ["Allow", "Block"])
        #expect(select.timeout == 10000)

        let confirm = try ui(#"{"type":"extension_ui_request","id":"uuid-2","method":"confirm","title":"Clear session?","message":"All messages will be lost.","timeout":5000}"#)
        #expect(confirm.method == "confirm")
        #expect(confirm.message == "All messages will be lost.")

        let input = try ui(#"{"type":"extension_ui_request","id":"uuid-3","method":"input","title":"Enter a value","placeholder":"type something..."}"#)
        #expect(input.placeholder == "type something...")
        #expect(input.timeout == nil)

        let editor = try ui(#"{"type":"extension_ui_request","id":"uuid-4","method":"editor","title":"Edit some text","prefill":"Line 1\nLine 2\nLine 3"}"#)
        #expect(editor.prefill == "Line 1\nLine 2\nLine 3")

        let notify = try ui(#"{"type":"extension_ui_request","id":"uuid-5","method":"notify","message":"Command blocked by user","notifyType":"warning"}"#)
        #expect(notify.notifyType == "warning")
        #expect(notify.message == "Command blocked by user")

        let status = try ui(#"{"type":"extension_ui_request","id":"uuid-6","method":"setStatus","statusKey":"my-ext","statusText":"Turn 3 running..."}"#)
        #expect(status.statusKey == "my-ext")
        #expect(status.statusText == "Turn 3 running...")

        let widget = try ui(#"{"type":"extension_ui_request","id":"uuid-7","method":"setWidget","widgetKey":"my-ext","widgetLines":["--- My Widget ---","Line 1","Line 2"],"widgetPlacement":"aboveEditor"}"#)
        #expect(widget.widgetKey == "my-ext")
        #expect(widget.widgetLines == ["--- My Widget ---", "Line 1", "Line 2"])
        #expect(widget.widgetPlacement == "aboveEditor")

        let title = try ui(#"{"type":"extension_ui_request","id":"uuid-8","method":"setTitle","title":"pi - my project"}"#)
        #expect(title.title == "pi - my project")

        let editorText = try ui(#"{"type":"extension_ui_request","id":"uuid-9","method":"set_editor_text","text":"prefilled text for the user"}"#)
        #expect(editorText.text == "prefilled text for the user")
    }
}
