import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

/// design_show's result names the kept copy its board card draws (ThreadBoardShown): read from
/// the live event and from history, carried on the thread's row and over the wire, and never
/// taken from another tool or a failed call.
@Suite("Board card receipt")
struct DesignBoardCardTests {
    static let copy = UUID(uuidString: "0D3B2C1A-0000-4000-8000-000000000001")!

    private func history(_ name: String, details: [String: Any], isError: Bool = false) throws -> RPCMessage {
        let payload: [String: Any] = ["role": "toolResult", "toolName": name, "toolCallId": "call", "isError": isError,
                                      "content": [["type": "text", "text": "Showed it."]], "details": details]
        return try JSONDecoder().decode(RPCMessage.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    @Test func historyAndTheLiveEventBothNameTheCopy() throws {
        let row = RPCThreadState.project(entryID: "t:call", message: try history("design_show", details: ["board": Self.copy.uuidString]))
        #expect(row.designBoard == Self.copy)

        let event = Data(#"{"type":"tool_execution_end","toolCallId":"call","toolName":"design_show","isError":false,"result":{"content":[],"details":{"board":"0D3B2C1A-0000-4000-8000-000000000001"}}}"#.utf8)
        guard case .toolExecutionEnd(_, _, let result, _, _) = try JSONDecoder().decode(RPCEvent.self, from: event) else {
            Issue.record("not a tool end"); return
        }
        #expect(result?.designBoard == Self.copy)
    }

    @Test func anotherToolAFailedCallOrABadIDDrawNoCard() throws {
        for message in [try history("design_get", details: ["board": Self.copy.uuidString]),
                        try history("design_show", details: ["board": Self.copy.uuidString], isError: true),
                        try history("design_show", details: ["board": "../escape"]),
                        try history("design_show", details: [:])] {
            #expect(RPCThreadState.project(entryID: "t", message: message).designBoard == nil)
        }
    }

    @Test func theRowCarriesItOverTheWireAndOlderRowsReadWithout() throws {
        let row = NativeThreadMessage(entryID: "tool", role: "toolResult", blocks: [], toolName: "design_show")
        var shown = row
        shown.designBoard = Self.copy
        #expect(try JSONDecoder().decode(NativeThreadMessage.self, from: JSONEncoder().encode(shown)) == shown)
        #expect(try JSONDecoder().decode(NativeThreadMessage.self, from: JSONEncoder().encode(row)).designBoard == nil)
        let bad = Data(#"{"entryID":"tool","role":"toolResult","blocks":[],"truncated":false,"designBoard":7}"#.utf8)
        #expect(try JSONDecoder().decode(NativeThreadMessage.self, from: bad).designBoard == nil)
    }
}
