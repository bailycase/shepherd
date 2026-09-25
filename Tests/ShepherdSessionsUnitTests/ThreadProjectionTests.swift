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

    // MARK: - projectHistory

    private static let history = #"""
    [{"role":"user","content":"Fix it","timestamp":1000},
     {"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"ls"}}],"timestamp":2000},
     {"role":"toolResult","toolCallId":"c1","toolName":"bash","content":[{"type":"text","text":"a"}],"timestamp":2500},
     {"role":"custom","customType":"memo","content":"model only","timestamp":2600},
     {"role":"custom","customType":"shepherd-child","display":true,"content":"Child done","timestamp":2700},
     {"role":"user","content":"again","timestamp":3000},
     {"role":"user","content":"same millisecond","timestamp":3000},
     {"role":"assistant","content":[{"type":"text","text":"no time"}]}]
    """#

    /// Ids name the message, not its place, so a page read from pi's session file (which starts
    /// wherever the file's tail does) lands on the same rows as pi's own answer.
    @Test func historyIDsNameEachMessageWhereverTheListStarts() throws {
        let messages: [RPCMessage] = try decode(Self.history)
        let rows = RPCThreadState.projectHistory(messages)
        #expect(rows.map(\.entryID) == ["user:1000", "assistant:2000", "t:c1", "user:3000", "user:3000#1", "m:7"])
        #expect(rows[2].startedAt == 2000 && rows[2].argumentsText == #"{"command":"ls"}"#, "a result carries its call's start and arguments")

        let tail = RPCThreadState.projectHistory(Array(messages[2...]))
        #expect(tail.prefix(3).map(\.entryID) == ["t:c1", "user:3000", "user:3000#1"])
    }

    /// The history decoded straight into messages projects row for row as the history decoded
    /// through a JSONValue tree did.
    @Test func aTypedHistoryProjectsExactlyAsTheLenientOneDid() throws {
        let line = Data(#"""
        {"type":"response","id":"r","command":"get_messages","success":true,"data":{"messages":[
         {"role":"user","content":"Fix the build","timestamp":1733234567890},
         {"role":"assistant","content":[{"type":"thinking","thinking":"check"},{"type":"text","text":"Running it."},
          {"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"make","timeout":120,"env":{"CI":true},"args":["-j",8,null]}}],
          "stopReason":"toolUse","timestamp":1733234567891.25},
         {"role":"toolResult","toolCallId":"c1","toolName":"bash","content":[{"type":"text","text":"ok \u2028 done"}],"isError":false},
         {"role":"user","content":[{"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"}]},
         {"role":"custom","customType":"note","display":true,"content":"shown"},
         {"role":"assistant","content":[],"stopReason":"error","errorMessage":"529 overloaded"}
        ]}}
        """#.utf8)
        guard case .response(let response) = try NDJSON.decode(RPCIncoming.self, from: line),
              case .messages(let typed) = response.payload else {
            Issue.record("expected a typed history"); return
        }
        struct Lenient: Decodable { let data: JSONValue }
        let lenient = try JSONDecoder().decode(Lenient.self, from: line).data["messages"]?.decode([RPCMessage].self)

        func rows(_ messages: [RPCMessage]) -> [NativeThreadMessage] {
            var arguments: [String: JSONValue] = [:]
            for message in messages {
                for case .toolCall(let id, _, let args?) in message.content { arguments[id] = args }
            }
            return messages.enumerated().map { index, message in
                RPCThreadState.project(entryID: "m:\(index)", message: message,
                                       args: message.toolCallId.flatMap { arguments[$0] })
            }
        }
        #expect(rows(typed) == rows(try #require(lenient)))
        #expect(rows(typed)[2].argumentsText == #"{"args":["-j",8,null],"command":"make","env":{"CI":true},"timeout":120}"#)
    }

    // MARK: - Snapshot budgets

    /// A snapshot's parts before the budgets apply.
    struct SnapshotFixture: Sendable, CustomTestStringConvertible {
        let name: String
        var clipped = false
        var widgets: [NativeThreadWidget] = []
        var active: [NativeThreadMessage] = []
        var dialogs: [NativeThreadDialog] = []
        var history: [NativeThreadMessage] = []
        var queue: NativeQueue? = nil
        var testDescription: String { name }

        func base() -> NativeThreadSnapshot {
            NativeThreadSnapshot(
                piSessionID: "s-1", generation: "g-1", revision: 42, running: !active.isEmpty, model: "anthropic/claude",
                thinking: "medium", supportedActions: RPCThreadState.supportedActions, dialogsSupported: true, dialogs: [],
                widgets: widgets, messages: [], provisional: [], clipped: clipped, runtime: "rpc",
                stats: NativeThreadStats(contextTokens: 1, contextWindow: 2, contextPercent: 3, totalTokens: 4, cost: 0.5),
                commands: [NativeCommand(name: "fix", description: "Fix it", source: "prompt")], subagents: [], queue: queue)
        }
    }

    private static func row(_ index: Int, _ role: String = "assistant", text: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: "m:\(index)", role: role, blocks: [NativeThreadBlock(kind: .text, text: text)],
                            status: role == "assistant" ? "stop" : nil, timestamp: 1_733_234_567_890 + Double(index))
    }

    private static func queued(_ index: Int) -> NativeQueuedMessage {
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!
        let images = index == 2 ? [NativeQueuedImage(mimeType: "image/png", name: "shot.png")] : []
        let text = "queued ü/\(index)\n" + String(repeating: "w", count: 3000)
        return NativeQueuedMessage(id: id, text: text, images: images, sentAt: 1_733_234_570_000 + Double(index),
                                   state: index == 0 ? .steering : .queued, held: index == 3)
    }

    private static let queueFixture = NativeQueue(items: (0..<6).map(queued), mode: .oneAtATime, paused: true, notice: "pi refused it.")

    /// A steered message pi read, and a delivery from the queue it has not started yet.
    private static let queuedRun: [NativeThreadMessage] = {
        let steered = NativeThreadMessage(entryID: "user:1733234569000", role: "user",
                                          blocks: [NativeThreadBlock(kind: .text, text: "look/at \"this\"")],
                                          origin: .steered, operationID: UUID(uuidString: "6E2A3C1D-3F1B-4D7A-9C2E-1A2B3C4D5E6F"))
        let parts = [NativeQueuePart(text: "one", sentAt: 1), NativeQueuePart(text: "two", sentAt: 2, images: 1)]
        let pending = NativeThreadMessage(entryID: "pending:0B1C", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "one\n\ntwo")],
                                          status: "pending", origin: .queue(parts: parts))
        return [steered, pending]
    }()

    static let snapshotFixtures: [SnapshotFixture] = [
        SnapshotFixture(name: "empty"),
        SnapshotFixture(name: "50 small and more",
                        active: [NativeThreadMessage(entryID: "provisional:assistant:1", role: "assistant",
                                                     blocks: [NativeThreadBlock(kind: .text, text: "streaming")], status: "streaming")],
                        history: (0..<80).map { row($0, $0 % 2 == 0 ? "user" : "assistant", text: "message \($0)") }),
        SnapshotFixture(name: "oversize tool output",
                        active: (0..<12).map { NativeThreadMessage(entryID: "provisional:tool:c\($0)", role: "toolResult",
                                                                    blocks: [NativeThreadBlock(kind: .text, text: String(repeating: "x", count: 15 * 1024))],
                                                                    toolName: "bash", toolCallID: "c\($0)", argumentsText: #"{"command":"make"}"#, status: "running") },
                        history: (0..<30).map { row($0, text: String(repeating: "y", count: 8 * 1024)) }),
        SnapshotFixture(name: "oversize tool output between the user rows that open its turns",
                        active: (0..<12).map { index -> NativeThreadMessage in
                            index % 4 == 0
                                ? NativeThreadMessage(entryID: "user:\(index)", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "go on \(index)")],
                                                      origin: index == 4 ? .steered : nil)
                                : NativeThreadMessage(entryID: "provisional:tool:c\(index)", role: "toolResult",
                                                      blocks: [NativeThreadBlock(kind: .text, text: String(repeating: "x", count: 20 * 1024))],
                                                      toolName: "bash", toolCallID: "c\(index)", status: "running")
                        },
                        history: (0..<10).map { row($0, text: "short") }),
        SnapshotFixture(name: "a queue and a steered message beside the run", active: queuedRun,
                        history: (0..<40).map { row($0, text: String(repeating: "q", count: 5000)) }, queue: queueFixture),
        SnapshotFixture(name: "dialogs over budget", clipped: true,
                        dialogs: (0..<8).map { NativeThreadDialog(id: "d\($0)", kind: .editor, title: "Edit \($0)",
                                                                  prefill: String(repeating: "z", count: 20 * 1024)) },
                        history: (0..<5).map { row($0, text: "short") }),
        SnapshotFixture(name: "widgets",
                        widgets: (0..<3).map { NativeThreadWidget(namespace: "pi", key: "w\($0)", kind: .text, text: String(repeating: "w", count: 4000)) },
                        history: (0..<60).map { row($0, text: String(repeating: "h", count: 3000)) }),
        SnapshotFixture(name: "unicode",
                        active: [NativeThreadMessage(entryID: "provisional:tool:ü/\"1", role: "toolResult",
                                                     blocks: [NativeThreadBlock(kind: .text, text: "café \u{2028} 👩‍💻 \"q\" a/b \\ \u{01}\t\n")],
                                                     toolName: "edit", argumentsText: #"{"path":"é/ü.swift"}"#)],
                        history: (0..<60).map {
                            NativeThreadMessage(entryID: "m:\($0)/ü\"\u{07}", role: "user",
                                                blocks: [NativeThreadBlock(kind: .text, text: String(repeating: "日本語 \u{2029}/\\\"", count: 400))])
                        }),
    ]

    /// Today's budget, applied by encoding the growing snapshot: the reference the arithmetic
    /// must match decision for decision.
    private static func encodingBudget(_ fixture: SnapshotFixture) -> NativeThreadSnapshot {
        func bytes<T: Encodable>(_ value: T) -> Int { (try? JSONEncoder().encode(value).count) ?? Int.max }
        var value = fixture.base()
        value.provisional = fixture.active
        value.dialogs = fixture.dialogs
        while bytes(value) > RPCThreadState.activeLimit, let first = value.provisional.firstIndex(where: { $0.role != "user" }) {
            value.provisional.remove(at: first)
            value.clipped = true
        }
        while bytes(value) > RPCThreadState.activeLimit, !value.dialogs.isEmpty {
            value.dialogs.removeLast()
            value.clipped = true
        }
        var size = bytes(value)
        var index = fixture.history.count - 1
        while index >= 0 {
            size += bytes(fixture.history[index]) + 1
            if size > RPCThreadState.snapshotLimit {
                value.clipped = true
                break
            }
            value.messages.insert(fixture.history[index], at: 0)
            index -= 1
            if value.messages.count == RPCThreadState.pageSize { break }
        }
        if index >= 0, let first = value.messages.first { value.olderCursor = first.entryID }
        return value
    }

    /// Sized from each element's own encoding, the budget keeps and clips exactly what encoding
    /// the whole snapshot did, and its arithmetic is the snapshot's encoded size to the byte.
    @Test(arguments: snapshotFixtures)
    func theBudgetByArithmeticMatchesEncodingTheSnapshot(_ fixture: SnapshotFixture) throws {
        func sized<T: Encodable>(_ value: T) throws -> RPCThreadState.Sized<T> {
            RPCThreadState.Sized(value: value, bytes: try JSONEncoder().encode(value).count)
        }
        let base = fixture.base()
        let history = try fixture.history.map(sized)
        let (snapshot, bytes) = RPCThreadState.budget(
            base, baseBytes: try JSONEncoder().encode(base).count,
            active: try fixture.active.map(sized), dialogs: try fixture.dialogs.map(sized),
            historyEnd: history.count, history: { history[$0] })

        #expect(snapshot == Self.encodingBudget(fixture))
        let encoded = try JSONEncoder().encode(snapshot).count
        #expect(bytes == encoded)
        #expect(bytes <= RPCThreadState.snapshotLimit)
    }

    @Test(arguments: ["m:12", "", "ü/\"\\ \u{01}\u{1F}\t\n\r\u{08}\u{0C} \u{2028} 👩‍💻"])
    func aStringIsSizedAsJSONEncoderWritesIt(text: String) throws {
        let encoded = try JSONEncoder().encode(text).count
        #expect(RPCThreadState.jsonStringBytes(text) == encoded)
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

    // MARK: - projectStats

    @Test func statsCarryTheContextTheTokensAndTheCost() throws {
        let data: JSONValue = try decode(#"""
        {"contextUsage":{"tokens":8123,"contextWindow":1000000,"percent":0.81},"tokens":{"total":20400},"cost":0.012}
        """#)
        #expect(RPCThreadState.projectStats(data) == NativeThreadStats(
            contextTokens: 8123, contextWindow: 1_000_000, contextPercent: 0.81, totalTokens: 20400, cost: 0.012))
    }

    /// pi estimates the context from the thread's messages: before its first reply that is 0,
    /// which is no figure at all.
    @Test(arguments: [#"{"tokens":0,"contextWindow":200000,"percent":0}"#, #"{"tokens":null,"contextWindow":200000,"percent":null}"#])
    func aContextPiHasNotMeasuredIsUnknown(usage: String) throws {
        let data: JSONValue = try decode(#"{"contextUsage":\#(usage),"tokens":{"total":0}}"#)
        let stats = RPCThreadState.projectStats(data)
        #expect(stats.contextTokens == nil)
        #expect(stats.contextPercent == nil)
        #expect(stats.contextWindow == 200_000)
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
