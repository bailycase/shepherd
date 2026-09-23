import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// The pure half of the native-thread projection: how one pi message becomes one thread row,
/// how streamed deltas rebuild an assistant message, and how the command list is bounded.
@Suite("Thread projection")
struct ThreadProjectionTests {
    // MARK: - project(entryID:message:args:)

    @Test func textAndThinkingBlocksBecomeRowBlocksInOrder() throws {
        let message: RPCMessage = try decode(#"""
        {"role":"assistant","content":[{"type":"thinking","thinking":"weighing it"},
         {"type":"text","text":"Done."}],"stopReason":"stop","timestamp":1733234567891}
        """#)
        let row = RPCThreadState.project(entryID: "m:1", message: message)
        #expect(row.entryID == "m:1")
        #expect(row.role == "assistant")
        #expect(row.blocks == [NativeThreadBlock(kind: .thinking, text: "weighing it"), NativeThreadBlock(kind: .text, text: "Done.")])
        #expect(row.status == "stop")
        #expect(row.timestamp == 1733234567891)
        #expect(!row.truncated)
    }

    @Test func toolCallBlocksAreNotRenderedAsProse() throws {
        let message: RPCMessage = try decode(#"""
        {"role":"assistant","content":[{"type":"text","text":"Listing."},
         {"type":"toolCall","id":"call_1","name":"bash","arguments":{"command":"ls"}}],"stopReason":"toolUse"}
        """#)
        let row = RPCThreadState.project(entryID: "m:0", message: message)
        #expect(row.blocks.map(\.text) == ["Listing."])
        #expect(row.status == "toolUse")
    }

    @Test func imagesProjectAsAnUnsupportedPlaceholder() throws {
        let message: RPCMessage = try decode(#"""
        {"role":"user","content":[{"type":"image","mimeType":"image/png","data":"iVBORw0KGgo="},{"type":"text","text":"look"}]}
        """#)
        let row = RPCThreadState.project(entryID: "m:0", message: message)
        #expect(row.blocks == [
            NativeThreadBlock(kind: .unsupportedImage, text: "[Image unavailable in native thread]"),
            NativeThreadBlock(kind: .text, text: "look"),
        ])
    }

    @Test func unknownContentBlocksAreDropped() throws {
        let message: RPCMessage = try decode(#"{"role":"assistant","content":[{"type":"hologram"},{"type":"text","text":"hi"}]}"#)
        #expect(RPCThreadState.project(entryID: "m:0", message: message).blocks.map(\.text) == ["hi"])
    }

    @Test func toolResultsCarryNameCallIDErrorFlagAndSortedArguments() throws {
        let message: RPCMessage = try decode(#"""
        {"role":"toolResult","toolCallId":"call_9","toolName":"edit","isError":true,
         "content":[{"type":"text","text":"conflict"}]}
        """#)
        let args: JSONValue = try decode(#"{"path":"a/b.swift","edits":[1,2],"all":true}"#)
        let row = RPCThreadState.project(entryID: "m:4", message: message, args: args)
        #expect(row.toolName == "edit")
        #expect(row.toolCallID == "call_9")
        #expect(row.isError == true)
        // Stable key order and unescaped slashes: the arguments render as the user reads them.
        #expect(row.argumentsText == #"{"all":true,"edits":[1,2],"path":"a/b.swift"}"#)
    }

    @Test func anErrorMessageIsAppendedAsText() throws {
        let message: RPCMessage = try decode(#"{"role":"assistant","content":[],"stopReason":"error","errorMessage":"overloaded"}"#)
        let row = RPCThreadState.project(entryID: "m:0", message: message)
        #expect(row.blocks == [NativeThreadBlock(kind: .text, text: "overloaded")])
        #expect(row.status == "error")
    }

    @Test func aMissingRoleProjectsAsCustom() throws {
        let message: RPCMessage = try decode(#"{"content":"note"}"#)
        #expect(RPCThreadState.project(entryID: "m:0", message: message).role == "custom")
    }

    @Test func textIsClippedToTheBudgetOnACharacterBoundary() {
        // 16 KiB - 1 ASCII bytes, then a two-byte character straddling the limit.
        let head = String(repeating: "a", count: RPCThreadState.textLimit - 1)
        let message = RPCMessage(role: "assistant", content: [.text(head + "é tail"), .text("second block")])
        let row = RPCThreadState.project(entryID: "m:0", message: message)
        #expect(row.truncated)
        #expect(row.blocks.count == 1)
        #expect(row.blocks[0].text == head)
    }

    @Test func theTextBudgetIsSharedAcrossBlocks() {
        let half = String(repeating: "b", count: RPCThreadState.textLimit / 2)
        let message = RPCMessage(role: "assistant", content: [.text(half), .text(half), .text("over")])
        let row = RPCThreadState.project(entryID: "m:0", message: message)
        #expect(row.blocks.map(\.text.utf8.count) == [half.utf8.count, half.utf8.count])
        #expect(row.truncated)
    }

    @Test func atMost128BlocksAreProjected() {
        let message = RPCMessage(role: "assistant", content: Array(repeating: .text("x"), count: 200))
        let row = RPCThreadState.project(entryID: "m:0", message: message)
        #expect(row.blocks.count == 128)
        #expect(row.truncated)
    }

    // MARK: - apply(_:to:) — rebuilding a streamed assistant message

    private func stream(_ deltas: [String], into message: RPCMessage = RPCMessage(role: "assistant", content: [])) throws -> RPCMessage {
        var message = message
        for json in deltas {
            RPCThreadState.apply(try decode(json, as: RPCAssistantDelta.self), to: &message)
        }
        return message
    }

    @Test func textDeltasAccumulateIntoOneBlock() throws {
        let message = try stream([
            #"{"type":"text_start","contentIndex":0}"#,
            #"{"type":"text_delta","contentIndex":0,"delta":"Hello"}"#,
            #"{"type":"text_delta","contentIndex":0,"delta":" line sep"}"#,
        ])
        #expect(message.content == [.text("Hello line\u{2028}sep")])
    }

    @Test func blockEndEventsReplaceTheAccumulatedContent() throws {
        let message = try stream([
            #"{"type":"thinking_start","contentIndex":0}"#,
            #"{"type":"thinking_delta","contentIndex":0,"delta":"hmm"}"#,
            #"{"type":"thinking_end","contentIndex":0,"content":"hmm, yes"}"#,
            #"{"type":"text_delta","contentIndex":1,"delta":"partial"}"#,
            #"{"type":"text_end","contentIndex":1,"content":"final text"}"#,
        ])
        #expect(message.content == [.thinking("hmm, yes"), .text("final text")])
    }

    @Test func toolCallsStartBareAndCompleteWithArguments() throws {
        let started = try stream([#"{"type":"toolcall_start","contentIndex":0,"id":"call_abc","toolName":"bash"}"#])
        #expect(started.content == [.toolCall(id: "call_abc", name: "bash", arguments: nil)])
        let ended = try stream([
            #"{"type":"toolcall_delta","contentIndex":0,"delta":"{\"comm"}"#,
            #"{"type":"toolcall_end","contentIndex":0,"toolCall":{"type":"toolCall","id":"call_abc","name":"bash","arguments":{"command":"ls"}}}"#,
        ], into: started)
        #expect(ended.content == [.toolCall(id: "call_abc", name: "bash", arguments: .object(["command": .string("ls")]))])
    }

    @Test func aDeltaForALaterIndexPadsTheGap() throws {
        let message = try stream([#"{"type":"text_delta","contentIndex":2,"delta":"third"}"#])
        #expect(message.content == [.text(""), .text(""), .text("third")])
    }

    @Test(arguments: [
        #"{"type":"text_delta","delta":"no index"}"#,
        #"{"type":"text_delta","contentIndex":-1,"delta":"negative"}"#,
    ])
    func deltasWithoutAUsableIndexAreIgnored(json: String) throws {
        let before = RPCMessage(role: "assistant", content: [.text("kept")])
        #expect(try stream([json], into: before) == before)
    }

    // MARK: - projectCommands

    @Test func commandsKeepNameDescriptionAndSource() throws {
        let value: JSONValue = try decode(#"""
        [{"name":"session-name","description":"Set or clear session name","source":"extension"},
         {"name":"fix-tests","source":"prompt","location":"project"}]
        """#)
        #expect(RPCThreadState.projectCommands(value) == [
            NativeCommand(name: "session-name", description: "Set or clear session name", source: "extension"),
            NativeCommand(name: "fix-tests", description: nil, source: "prompt"),
        ])
    }

    @Test func commandsAreBoundedInCountNameAndDescription() {
        let items: [JSONValue] = (0..<200).map { i in
            .object([
                "name": .string(i == 0 ? String(repeating: "n", count: NativeCommand.maxNameBytes + 1) : "c\(i)"),
                "description": .string(String(repeating: "d", count: NativeCommand.maxDescriptionBytes + 44)),
            ])
        }
        let projected = RPCThreadState.projectCommands(.array(items))
        #expect(projected.count == NativeCommand.maxCount)
        #expect(projected.first?.name == "c1", "an over-long name is dropped, not clipped")
        #expect(projected.allSatisfy { $0.description?.utf8.count == NativeCommand.maxDescriptionBytes })
    }

    @Test(arguments: [nil, JSONValue.string("not a list"), .array([.object(["name": .string("")]), .number(3)])])
    func malformedCommandListsProjectToNothing(value: JSONValue?) {
        #expect(RPCThreadState.projectCommands(value).isEmpty)
    }

    // MARK: - Widgets

    @Test(arguments: [
        ("PI_SUBAGENT_ASYNC_JSON:{\"kind\":\"snapshot\"}", true),
        ("  {\"a\":1}", true),
        ("[1,2]", true),
        ("TASK_42: queued", true),
        ("Build: green", false),
        ("ABC: too short a marker", false),
        ("no colon at all", false),
    ])
    func machinePayloadWidgetsAreRecognised(text: String, isMachine: Bool) {
        #expect(RPCThreadState.isMachineWidget(text) == isMachine)
    }

    @Test(arguments: [
        ("\u{1B}[1mBold\u{1B}[22m line", "Bold line"),
        ("\u{1B}[38;2;1;2;3mrgb\u{1B}[0m", "rgb"),
        ("\u{1B}]8;;http://x\u{1B}\\link\u{1B}]8;;\u{1B}\\", "link"),
        ("\u{1B}]0;title\u{07}after", "after"),
        ("plain", "plain"),
    ])
    func ansiIsStrippedFromWidgetText(input: String, expected: String) {
        #expect(RPCThreadState.stripANSI(input) == expected)
    }
}
